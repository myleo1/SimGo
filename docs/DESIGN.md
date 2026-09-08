# SimGo 详细设计文档

## 1. 架构概览

```
┌─────────────────────────────────────────────────────┐
│                    宿主机 (Linux)                     │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │              Docker 容器                       │   │
│  │                                              │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐   │   │
│   │  │ Asterisk │  │  Bot    │  │  企业微信  │   │   │
│  │  │  (PJSIP) │  │  (Python)│  │  (Python) │   │   │
│  │  └────┬─────┘  └──────────┘  └──────────┘   │   │
│  │       │                                      │   │
│  │  ┌────┴─────┐                                │   │
│  │  │chan_quectel│                               │   │
│  │  │  (UAC)   │                                │   │
│  │  └────┬─────┘                                │   │
│  │       │                                      │   │
│  │  ┌────┴─────────────────────────────────┐    │   │
│  │  │  /dev/ttyUSB*  (AT/Data)             │    │   │
│  │  │  /dev/snd      (UAC Audio)           │    │   │
│  │  └──────────────────────────────────────┘    │   │
│  └──────────────────────────────────────────────┘   │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │         EC20 模块 (USB)                       │   │
│  │  ttyUSB0: 诊断口                              │   │
│  │  ttyUSB1: 音频/GPS                            │   │
│  │  ttyUSB2: AT 命令                             │   │
│  │  ttyUSB3: 拨号                                │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## 2. 目录结构

```
SimGo/
├── config/
│   ├── pjsip.conf              # PJSIP 配置（模板）
│   ├── extensions.conf         # 主拨号计划（模板）
│   ├── extensions_custom.conf  # 自定义拨号计划（模板）
│   ├── quectel.conf            # Quectel 模块配置（模板）
│   ├── modules.conf            # 模块加载配置
│   └── rtp.conf                # RTP 配置
├── scripts/
│   ├── sms_notify.py           # 短信通知脚本（TG + 企业微信）
│   ├── telegram_bot.py         # Bot 主程序
│   └── bot.conf               # Bot 配置文件（模板）
├── docker/
│   ├── Dockerfile              # 镜像构建文件
│   └── docker-compose.yml      # 部署配置（模板）
├── fail2ban/
│   ├── filter.d/
│   │   └── asterisk-pjsip.conf # Fail2ban 过滤器
│   └── jail.d/
│       └── asterisk-pjsip.local # Fail2ban 监狱配置
├── .github/
│   └── workflows/
│       └── build.yml           # GitHub Actions 构建
├── setup.sh                    # 交互式部署脚本
├── uninstall.sh                # 卸载脚本
├── docs/
│   ├── REQUIREMENTS.md         # 需求文档
│   ├── DESIGN.md               # 设计文档
│   └── TASKS.md                # 任务拆解
├── LICENSE                     # GPL v2 许可证
└── README.md                   # 项目说明
```

## 3. 配置模板系统

### 3.1 设计思路

参考 kafuneri 的环境变量注入方案，改为**部署脚本生成最终配置**的方式：

1. `config/` 目录下的配置文件使用占位符（如 `__PJSIP_SECRET__`）
2. `setup.sh` 交互式收集用户输入
3. 脚本将占位符替换为实际值，生成 `docker-compose.yml` 和运行时配置
4. 敏感信息不写入 Git

### 3.2 占位符定义

| 占位符 | 说明 | 示例 |
|--------|------|------|
| `__PJSIP_SECRET__` | PJSIP 密码 | （用户输入） |
| `__PJSIP_EXTEN__` | PJSIP 用户名（字母、数字、下划线、短横线，如 `gw_7Kx92mQ4`） | （用户输入） |
| `__AT_PORT__` | AT 命令端口 | `/dev/serial/by-id/usb-Quectel_Wireless_EC20-if02` |
| `__ALSA_DEV__` | ALSA 音频设备 | `hw:CARD=EC20CEHDLG,DEV=0` |
| `__LOCAL_NET__` | 本地局域网段 | `192.168.1.0/24` |
| `__EXTERNAL_MEDIA_ADDRESS__` | 公网 IP 或域名 | `xxx.duckdns.org` |
| `__TG_BOT_TOKEN__` | Telegram Bot Token | （用户输入） |
| `__TG_CHAT_ID__` | Telegram Chat ID | （用户输入） |
| `__TG_SOCKS5_PROXY__` | SOCKS5 代理 | `socks5://192.168.1.1:1080` |
| `__WECHAT_WORK_API__` | 企业微信 API | （用户输入） |
| `__WECHAT_WORK_TOKEN__` | 企业微信 Token | （用户输入） |
| `__WECHAT_WORK_TO__` | 企业微信接收人 | （用户输入） |
| `__ACME_EMAIL__` | Let's Encrypt 邮箱 | （用户输入） |

## 4. Docker 镜像设计

### 4.1 基础镜像

```dockerfile
FROM ubuntu:24.04
```

选择理由：
- Ubuntu 24.04 apt 源直接包含 Asterisk 20.6.0（universe 源），无需源码编译
- chan-quectel 仍需从源码编译，但 Asterisk 本体免编译，大幅简化构建流程

### 4.2 Multi-stage Build 依赖分层

采用 Multi-stage Build，builder 层编译完 chan-quectel 后整体丢弃，最终镜像只包含运行时依赖。

#### Build 阶段（builder，编译 chan-quectel 后丢弃）

| 包名 | 用途 | 编译后是否需要 |
|------|------|:------:|
| `build-essential` | GCC、Make 等编译工具 | ❌ 丢弃 |
| `git` | clone chan-quectel 源码 | ❌ 丢弃 |
| `autoconf` | `./bootstrap` 生成 configure | ❌ 丢弃 |
| `automake` | autotools 构建链 | ❌ 丢弃 |
| `libtool` | autotools 构建链 | ❌ 丢弃 |
| `pkg-config` | 编译时查找库路径 | ❌ 丢弃 |
| `asterisk-dev` | Asterisk 头文件，编译 chan-quectel 必须 | ❌ 丢弃 |
| `libsqlite3-dev` | chan-quectel 编译依赖（头文件） | ❌ 丢弃 |
| `libasound2-dev` | chan-quectel UAC 音频编译依赖（头文件） | ❌ 丢弃 |

#### Runtime 阶段（最终镜像）

所有 Python 依赖通过 apt 安装，无需 pip。

| 包名 | 用途 | 是否必须 |
|------|------|:------:|
| `asterisk` | Asterisk 主程序 + PJSIP | ✅ 必须 |
| `libasound2t64` | ALSA 运行时库（UAC 音频） | ✅ 必须 |
| `libsqlite3-0` | SQLite 运行时库 | ✅ 必须 |
| `python3` | Python 3.12 解释器（运行通知脚本） | ✅ 必须 |
| `python3-requests` | HTTP 请求库（Telegram/微信通知） | ✅ 必须 |
| `python3-socks` | SOCKS5 代理支持（requests 依赖） | ✅ 必须 |

Asterisk 自带依赖（`libjansson4`, `libuuid1`, `libxml2`, `libcurl4` 等）随 `apt install asterisk` 自动拉入。

#### 不需要的包

| 包名 | 原因 |
|------|------|
| `python3-pip` | 所有 Python 依赖通过 apt 安装 |
| `adb` | Android 调试，当前架构不需要 |
| `alsa-utils` | `aplay`/`arecord` 仅用于宿主机调试，容器内不需要 |
| `curl` | 容器内脚本使用 Python requests，不使用 curl |
| `wget` | apt 安装不需要下载 Asterisk 源码 |
| `python-telegram-bot` | 项目使用 requests 直接调用 Telegram API |
| `watchdog` | 项目不需要文件变化监听 |
| 所有 `-dev` 包 | 编译后头文件不再需要，运行时只需 `.so` |

### 4.3 多架构支持

chan-quectel 的 `./configure` 需要指定 `DESTDIR` 指向 Asterisk 模块目录。不同架构下路径不同：

```bash
# x86_64: /usr/lib/x86_64-linux-gnu/asterisk/modules/
# aarch64: /usr/lib/aarch64-linux-gnu/asterisk/modules/
```

使用 `dpkg-architecture` 动态获取架构路径，无需硬编码：

```bash
MODULE_DIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/asterisk/modules"
ASTERISK_VER=$(dpkg-query -W -f='${Version}' asterisk-dev | sed 's/.*://' | sed 's/~.*//')
./configure DESTDIR=${MODULE_DIR} --with-astversion=${ASTERISK_VER}
```

**跨阶段复制**：Dockerfile 的 `COPY --from=builder` 指令不支持 shell 展开，因此在 builder 阶段将编译产物复制到 `/tmp`，runtime 阶段先 COPY 到 `/tmp`，再用 `RUN cp` 配合 `dpkg-architecture` 动态定位目标路径：

```dockerfile
# builder 阶段
RUN ... && cp ${MODULE_DIR}/chan_quectel.so /tmp/chan_quectel.so

# runtime 阶段
COPY --from=builder /tmp/chan_quectel.so /tmp/chan_quectel.so
RUN cp /tmp/chan_quectel.so /usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/asterisk/modules/chan_quectel.so
```

### 4.4 关键差异（对比 kafuneri）

| 项目 | kafuneri | SimGo |
|------|----------|------------|
| chan-quectel 来源 | IchthysMaranatha | myleo1（含 bug 修复） |
| SIP 协议 | IAX2 | PJSIP (TLS + SRTP) |
| Asterisk 安装方式 | apt | apt |
| Asterisk 版本 | 16 | 20 |
| 基础镜像 | python:3.10-slim-bullseye | ubuntu:24.04 |
| 构建方式 | 单阶段 + purge 清理 | Multi-stage build |
| 多架构 | 不支持 | 支持（dpkg-architecture 动态路径） |
| 音频透传 | `/dev/snd` 全量挂载 | `/dev/snd` 全量挂载 + ALSA 设备指定 |
| Python 依赖 | python-telegram-bot, watchdog（pip） | python3-requests, python3-socks（apt） |
| 加密 | 无 | TLS 信令 + SRTP 媒体 |

## 5. 安全设计

### 5.1 TLS 信令加密

PJSIP 使用 TLS 传输 SIP 信令：

```ini
; === TLS Transport ===
[transport-tls]
type=transport
protocol=tls
bind=0.0.0.0:52060
cert_file=/etc/asterisk/certs/asterisk.pem
priv_key_file=/etc/asterisk/certs/asterisk.key
method=tlsv1_2
verify_server=no
verify_client=no
local_net=__LOCAL_NET__              ; 本地局域网段，CIDR 格式，如 192.168.1.0/24
external_media_address=__EXTERNAL_MEDIA_ADDRESS__   ; 公网 IP 或域名（如 DuckDNS）
external_signaling_address=__EXTERNAL_MEDIA_ADDRESS__ ; 同上
external_signaling_port=52060
```

> **注意：** 不要配置 `cipher=` 行，Ubuntu 24.04 的 OpenSSL 3.x 不兼容常见的 cipher 字符串，会导致 TLS transport 创建失败。使用 Asterisk 默认 cipher 即可。

### 5.2 SRTP 媒体加密

端点启用 SRTP 加密语音数据：

```ini
[__PJSIP_EXTEN__]
type=endpoint
media_encryption=sdes
```

### 5.3 TLS 证书管理

参考 [NasAnySim](https://github.com/mccding/NasAnySim) 的方案，使用 acme.sh + DuckDNS DNS-01 签发 Let's Encrypt 证书。

**流程**：
1. 安装 acme.sh（`curl https://get.acme.sh | sh`）
2. 注册 Let's Encrypt 账户
3. 通过 DuckDNS DNS-01 验证签发证书
4. 证书复制到 `certs/` 目录挂载到容器

```bash
# setup.sh 中的证书生成逻辑
CERT_DIR="./certs"
mkdir -p "$CERT_DIR"

install_acme.sh
export DuckDNS_Token="$DUCKDNS_TOKEN"
acme.sh --register-account -m "$EMAIL" --server letsencrypt
acme.sh --issue --dns dns_duckdns -d "$DOMAIN" --keylength ec-256 --server letsencrypt
cp ~/.acme.sh/${DOMAIN}_ecc/fullchain.cer "$CERT_DIR/asterisk.pem"
cp ~/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key "$CERT_DIR/asterisk.key"
```

**DuckDNS IP 自动更新**：

家庭宽带公网 IP 变动时，通过 cron 每 5 分钟更新 DuckDNS 记录：

```bash
# duckdns-update.sh
curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip="
```

```cron
*/5 * * * * /path/to/duckdns-update.sh >/dev/null 2>&1
```

证书挂载到容器：

```yaml
volumes:
  - ./certs:/etc/asterisk/certs:ro
```

### 5.4 RTP 端口范围

限制 RTP 端口为 50 个（够单路通话使用）：

```ini
[general]
rtpstart=42077
rtpend=42126
```

对应 docker-compose 端口映射：

```yaml
ports:
  - "52060:52060/tcp"                 # PJSIP TLS
  - "42077-42126:42077-42126/udp"   # RTP/SRTP
```

### 5.5 敏感信息保护

- 所有密码、Token 不写入 Git
- `bot.conf` 为模板文件，由 `start.sh` 在容器内渲染
- `docker-compose.yml` 为模板文件，由 `setup.sh` 生成
- `.gitignore` 排除生成的配置文件和证书

## 6. 启动流程

```
容器启动
  │
  ├─ 1. start.sh 执行
  │     ├─ 从模板复制配置文件到 /etc/asterisk/
  │     ├─ 用 sed 替换占位符为环境变量值
  │     ├─ chmod +x 脚本（sms_notify.py、telegram_bot.py）
  │     └─ 启动 Bot（后台 &）
  │
  ├─ 2. Asterisk 启动（前台）
  │     ├─ 加载 chan_quectel 模块
  │     ├─ 连接 EC20 AT 端口
  │     ├─ 初始化 UAC 音频
  │     └─ 就绪，等待呼叫
  │
  ├─ 容器退出时，Bot 和 Asterisk 同时停止
  │
  └─ 3. 运行时
        ├─ 短信 → extensions.conf 路由 → sms_notify.py → TG/企业微信
        ├─ 来电 → extensions.conf 路由 → 检查 PJSIP 注册 → 转接
        └─ TG Bot → asterisk -rx 命令 → 模块管理/发短信
```

## 7. 端口与设备映射

### 7.1 设备映射

```yaml
devices:
  # 使用 by-id 路径防止 USB 序号漂移
  - /dev/serial/by-id/usb-Quectel_Wireless_EC20-if02:/dev/ttyUSB2  # AT 端口
  - /dev/snd:/dev/snd  # UAC 音频透传
```

> **注意**：只需映射 AT 端口和声卡，不需要映射所有 ttyUSB*。chan-quectel 只用 AT 端口通信，音频走 UAC/ALSA。

### 7.2 端口映射（host 网络下不需要）

使用 `network_mode: host` 后，容器直接监听宿主机端口，不需要 Docker 端口映射。以下仅供参考：

```yaml
ports:
  - "52060:52060/tcp"                 # PJSIP TLS 信令
  - "42077-42126:42077-42126/udp"   # RTP/SRTP 媒体流（50 个端口）
```

## 8. 配置文件模板

### 8.1 quectel.conf

```ini
[general]
interval=15
smsdb=/var/lib/asterisk/smsdb
csmsttl=600

[defaults]
context=incoming-mobile
group=0
rxgain=0
txgain=0
autodeletesms=yes
resetquectel=yes
usecallingpres=yes
callingpres=allowed_passed_screen
disablesms=no
language=en
callwaiting=yes
disable=no
initstate=start
dtmf=relax

[quectel0]
data=__AT_PORT__                    ; AT 命令端口（用户传入）
quec_uac=1                         ; 启用 UAC 模式（UAC 走 ALSA，不走 tty 音频）
alsadev=__ALSA_DEV__               ; ALSA 音频设备（用户传入）
```

### 8.2 pjsip.conf

```ini
; === TLS Transport ===
[transport-tls]
type=transport
protocol=tls
bind=0.0.0.0:52060
cert_file=/etc/asterisk/certs/asterisk.pem
priv_key_file=/etc/asterisk/certs/asterisk.key
method=tlsv1_2
verify_server=no
verify_client=no
local_net=__LOCAL_NET__              ; 本地局域网段，CIDR 格式，如 192.168.1.0/24
external_media_address=__EXTERNAL_MEDIA_ADDRESS__   ; 公网 IP 或域名（如 DuckDNS）
external_signaling_address=__EXTERNAL_MEDIA_ADDRESS__ ; 同上
external_signaling_port=52060

; === Endpoint (TLS + SRTP) ===
[__PJSIP_EXTEN__]
type=endpoint
transport=transport-tls
context=from-internal
disallow=all
allow=ulaw,alaw,g722,gsm
auth=__PJSIP_EXTEN__
aors=__PJSIP_EXTEN__
rewrite_contact=yes
rtp_symmetric=yes
media_encryption=sdes
direct_media=no

; === Authentication ===
[__PJSIP_EXTEN__]
type=auth
auth_type=userpass
username=__PJSIP_EXTEN__
password=__PJSIP_SECRET__

; === AOR ===
[__PJSIP_EXTEN__]
type=aor
max_contacts=10
```

### 8.3 rtp.conf

```ini
[general]
rtpstart=42077
rtpend=42126
```

### 8.4 bot.conf

```ini
BOT_TOKEN=__TG_BOT_TOKEN__
CHAT_ID=__TG_CHAT_ID__
SOCKS5_PROXY=__TG_SOCKS5_PROXY__
```

> **注意**：企业微信配置行（`WECHAT_WORK_API`、`WECHAT_WORK_TOKEN`、`WECHAT_WORK_TO`）由 setup.sh 在用户填写时动态追加，未填写则不写入。

## 9. docker-compose.yml 模板

```yaml
services:
  simgo:
    build:
      context: .
      dockerfile: docker/Dockerfile
    container_name: simgo
    restart: unless-stopped
    privileged: true
    network_mode: host
    devices:
      - /dev/serial/by-id/usb-Quectel_Wireless_EC20-if02:/dev/ttyUSB2
      - /dev/snd:/dev/snd
    volumes:
      - ./config:/etc/asterisk/templates:ro
      - ./scripts:/etc/asterisk/scripts:ro
      - ./certs:/etc/asterisk/certs:ro
      - ./logs:/var/log/asterisk
      - ./spool:/var/spool/asterisk
    environment:
      - PJSIP_EXTEN=${PJSIP_EXTEN}
      - PJSIP_SECRET=${PJSIP_SECRET}
      - LOCAL_NET=${LOCAL_NET}
      - EXTERNAL_MEDIA_ADDRESS=${EXTERNAL_MEDIA_ADDRESS}
      - AT_PORT=${AT_PORT}
      - ALSA_DEV=${ALSA_DEV}
      - TG_BOT_TOKEN=${TG_BOT_TOKEN}
      - TG_CHAT_ID=${TG_CHAT_ID}
      - TG_SOCKS5_PROXY=${TG_SOCKS5_PROXY}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

**说明**：
- `privileged: true`：UAC 音频透传需要访问 `/dev/snd`，以及 USB 热插拔支持
- `network_mode: host`：容器直接使用宿主机网络栈，避免 Docker NAT 和 RTP 端口映射问题，同时让宿主机 nftables 能直接拦截 SIP 攻击流量
- 设备映射使用 `by-id` 路径，防止 USB 序号漂移
- `./logs:/var/log/asterisk`：bind mount 日志到宿主机，供 Fail2ban 读取
- `./spool:/var/spool/asterisk`：bind mount Asterisk 运行时数据（录音、CDR 等）到宿主机
- 配置文件以只读方式挂载，由 start.sh 在容器内渲染
- 环境变量由 setup.sh 直接写入 docker-compose.yml
- 企业微信环境变量（`WECHAT_WORK_API`、`WECHAT_WORK_TOKEN`、`WECHAT_WORK_TO`）仅在用户填写时由 setup.sh 追加
- 使用 host 网络后不再需要 `ports` 映射，PJSIP（52060）和 RTP（42077-42126）直接监听宿主机端口

## 10. start.sh 启动脚本

```bash
#!/bin/bash
set -e

TEMPLATE_DIR="/etc/asterisk/templates"
CONFIG_DIR="/etc/asterisk"
SCRIPT_DIR="/etc/asterisk/scripts"

# 1. 初始化目录和文件
mkdir -p /var/log/asterisk/cdr-csv

# 2. 渲染配置模板（sed 替换占位符）
render_config() {
    local src="$1"
    local dst="$2"
    cp "${TEMPLATE_DIR}/${src}" "${CONFIG_DIR}/${dst}"
    sed -i \
        -e "s|__PJSIP_EXTEN__|${PJSIP_EXTEN}|g" \
        -e "s|__PJSIP_SECRET__|${PJSIP_SECRET}|g" \
        -e "s|__LOCAL_NET__|${LOCAL_NET}|g" \
        -e "s|__EXTERNAL_MEDIA_ADDRESS__|${EXTERNAL_MEDIA_ADDRESS}|g" \
        -e "s|__AT_PORT__|${AT_PORT}|g" \
        -e "s|__ALSA_DEV__|${ALSA_DEV}|g" \
        -e "s|__TG_BOT_TOKEN__|${TG_BOT_TOKEN}|g" \
        -e "s|__TG_CHAT_ID__|${TG_CHAT_ID}|g" \
        -e "s|__TG_SOCKS5_PROXY__|${TG_SOCKS5_PROXY}|g" \
        -e "s|__WECHAT_WORK_API__|${WECHAT_WORK_API}|g" \
        -e "s|__WECHAT_WORK_TOKEN__|${WECHAT_WORK_TOKEN}|g" \
        -e "s|__WECHAT_WORK_TO__|${WECHAT_WORK_TO}|g" \
        "${CONFIG_DIR}/${dst}"
}

render_config pjsip.conf pjsip.conf
render_config extensions.conf extensions.conf
render_config extensions_custom.conf extensions_custom.conf
render_config quectel.conf quectel.conf
render_config modules.conf modules.conf
render_config rtp.conf rtp.conf

# bot.conf 模板在 scripts/ 目录，渲染到 /etc/asterisk/bot.conf
cp "${SCRIPT_DIR}/bot.conf" "${CONFIG_DIR}/bot.conf"
sed -i \
    -e "s|__TG_BOT_TOKEN__|${TG_BOT_TOKEN}|g" \
    -e "s|__TG_CHAT_ID__|${TG_CHAT_ID}|g" \
    -e "s|__TG_SOCKS5_PROXY__|${TG_SOCKS5_PROXY}|g" \
    "${CONFIG_DIR}/bot.conf"

# 动态追加企业微信配置到 bot.conf（未填写则跳过）
if [ -n "${WECHAT_WORK_API}" ] && [ -n "${WECHAT_WORK_TOKEN}" ] && [ -n "${WECHAT_WORK_TO}" ]; then
    cat >> "${CONFIG_DIR}/bot.conf" <<EOF

WECHAT_WORK_API=${WECHAT_WORK_API}
WECHAT_WORK_TOKEN=${WECHAT_WORK_TOKEN}
WECHAT_WORK_TO=${WECHAT_WORK_TO}
EOF
fi

# 3. 启动 Telegram Bot（后台）
python3 "${SCRIPT_DIR}/telegram_bot.py" &
BOT_PID=$!

# 4. 启动 Asterisk（前台，作为主进程）
asterisk -f -vvv
```

## 11. duckdns-update.sh

```bash
#!/bin/bash
# DuckDNS IP 自动更新脚本
# 家庭宽带公网 IP 变动时，通过 cron 每 5 分钟更新 DuckDNS 记录

DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN}"

if [ -z "$DUCKDNS_DOMAIN" ] || [ -z "$DUCKDNS_TOKEN" ]; then
    echo "Missing DUCKDNS_DOMAIN or DUCKDNS_TOKEN"
    exit 1
fi

RESPONSE=$(curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=")

if [ "$RESPONSE" = "OK" ]; then
    echo "$(date): DuckDNS IP updated for ${DUCKDNS_DOMAIN}"
else
    echo "$(date): DuckDNS update failed: ${RESPONSE}" >&2
    exit 1
fi
```

Cron 配置（由 setup.sh 安装）：

```cron
*/5 * * * * /path/to/SimGo/duckdns-update.sh >/dev/null 2>&1 # SimGo
```

> **注意**：`/path/to/SimGo/` 由 setup.sh 动态替换为实际部署目录。

## 12. Fail2ban 防护

### 12.1 架构

Fail2ban 运行在宿主机，不在容器内。Asterisk 日志通过 bind mount 暴露给宿主机，Fail2ban 读取日志并联动 nftables 封禁攻击 IP。

```text
SIP Scanner → Asterisk（容器）→ messages.log → Fail2ban（宿主机）→ nftables set → TCP+UDP 全封
```

### 12.2 Filter

文件：`fail2ban/filter.d/asterisk-pjsip.conf`

```ini
[Definition]

failregex = ^.*res_pjsip/pjsip_distributor\.c: Request .* failed for '<HOST>:\d+' .* - No matching endpoint found$
            ^.*res_pjsip/pjsip_distributor\.c: Request .* failed for '<HOST>:\d+' .* - Failed to authenticate$

ignoreregex =
```

### 12.3 Jail

文件：`fail2ban/jail.d/asterisk-pjsip.local`

```ini
[asterisk-pjsip]
enabled = true
filter = asterisk-pjsip
backend = polling
logpath = __DEPLOY_DIR__/logs/messages.log
maxretry = 5
findtime = 10m
bantime = 24h
banaction = nftables
port = 0:65535
protocol = tcp,udp
```

> **注意**：`__DEPLOY_DIR__` 由 setup.sh 替换为实际部署目录路径。

**关键配置说明**：
- `backend = polling`：不要使用 systemd backend，Asterisk 日志来自 bind mount 而非 journal
- `port = 0:65535`：全端口封禁，攻击者不应只被阻止 SIP
- `protocol = tcp,udp`：SIP 扫描大量使用 UDP，必须同时封禁
- `banaction = nftables`：使用 nftables。如系统不支持 nftables（老系统），改为 `banaction = iptables-allports`

### 12.4 nftables 规则

Fail2ban 自动创建的 nftables 规则：

```nft
table inet f2b-table {
    set addr-set-asterisk-pjsip {
        type ipv4_addr
    }

    chain f2b-chain {
        type filter hook input priority filter - 1;
        policy accept;
        tcp dport 0-65535 ip saddr @addr-set-asterisk-pjsip reject with icmp port-unreachable
        udp dport 0-65535 ip saddr @addr-set-asterisk-pjsip reject with icmp port-unreachable
    }
}
```

### 12.5 宿主机安装

setup.sh 负责：
1. 检查 fail2ban 和 nftables 是否已安装，未安装则通过 apt 安装
2. 将 filter 和 jail 配置文件安装到 `/etc/fail2ban/`
3. 重启 fail2ban 服务

> **注意**：fail2ban 和 nftables 是系统级工具，SimGo 卸载时只删除自己的 filter/jail 配置，不卸载 fail2ban 本身。

## 13. .gitignore

```gitignore
# 生成的部署文件（由 setup.sh 生成）
docker-compose.yml
duckdns-update.sh
.simgo-manifest

# TLS 证书
certs/

# 运行时日志
logs/

# Python
__pycache__/
*.pyc

# 系统文件
.DS_Store
```

> **注意**：`config/` 和 `scripts/` 下的模板文件是源码，需要提交到 Git。setup.sh 运行时会在容器内生成含实际 Token 的配置文件，与源码模板分离。

## 14. setup.sh 设计

### 14.1 交互流程

```
1. 收集 AT 端口（by-id 路径优先，如 `/dev/serial/by-id/usb-Quectel_Wireless_EC20-if02`；回退默认 `/dev/ttyUSB2`）
2. 自动检测 ALSA 音频设备（优先 `aplay -L`，不可用时降级读取 `/proc/asound/cards` 和 `/dev/snd/`）
3. 收集 PJSIP 用户名（字母、数字、下划线、短横线，推荐 `gw_` 前缀 + 随机字符串）和密码（强口令，32 位以上随机字符串）
4. 收集本地局域网段（CIDR 格式，如 192.168.1.0/24）
5. 收集公网 IP 或域名（DuckDNS 域名，如 xxx.duckdns.org）
6. 收集 Telegram Bot Token 和 Chat ID
7. 收集 SOCKS5 代理（可选）
8. 收集企业微信配置（可选，未填写则不写入配置文件和 docker-compose.yml）
9. 收集 DuckDNS Token（用于签发 TLS 证书和 IP 自动更新）
10. 收集 Let's Encrypt 邮箱（用于 acme.sh 账户注册）
11. 打印安装清单，确认后继续（见 §14.3）
12. 安装 acme.sh，签发 Let's Encrypt TLS 证书（DuckDNS DNS-01），chown 证书目录给 asterisk 用户（uid 101）
13. 安装 DuckDNS IP 更新 cron
14. 安装 fail2ban + nftables（如未安装），安装 filter 和 jail，重启 fail2ban
15. 创建日志目录（`./logs`）
16. 生成 docker-compose.yml
17. 生成 .simgo-manifest（记录所有宿主机变更，供 uninstall.sh 使用）
18. 提示启动命令
```

### 14.2 生成的文件

| 文件 | 说明 |
|------|------|
| `docker-compose.yml` | 从模板生成，填入设备路径和环境变量 |
| `certs/asterisk.pem` | Let's Encrypt TLS 证书（DuckDNS DNS-01） |
| `certs/asterisk.key` | TLS 私钥 |
| `duckdns-update.sh` | DuckDNS IP 自动更新脚本（安装 cron 每 5 分钟更新） |
| `.simgo-manifest` | 安装清单，记录所有宿主机变更（cron 条目、生成的文件），供 uninstall.sh 使用 |

### 14.3 宿主机安装清单

setup.sh 执行前会打印以下清单，用户确认后继续：

```
SimGo 将在宿主机上安装/变更以下内容：

[Docker]
  - 拉取镜像：ubuntu:24.04（构建时）
  - 创建容器：simgo（Asterisk + Python 脚本）
  - bind mount：logs/, spool/

[acme.sh]
  - 安装 acme.sh（如未安装）
  - 签发 Let's Encrypt TLS 证书到 ./certs/
  - acme.sh 自动注册续签 cron（宿主机 crontab，SimGo 不管理卸载）

[fail2ban]
  - 安装 fail2ban + nftables（如未安装，SimGo 不管理卸载）
  - 安装 asterisk-pjsip filter 和 jail
  - 重启 fail2ban 服务

[宿主机 cron]
  - 添加 DuckDNS IP 更新 cron（每 5 分钟，带 # SimGo 标记）

[部署目录]
  - 生成：docker-compose.yml, duckdns-update.sh, logs/, .simgo-manifest

确认安装？[y/N]
```

> **注意**：acme.sh 一旦安装，由 acme.sh 自身管理续签 cron，SimGo 卸载时不会移除 acme.sh。

## 15. 参考与致谢

| 项目 | 用途 | 许可证 |
|------|------|--------|
| [NasAnySim](https://github.com/mccding/NasAnySim) | TLS 证书自动管理方案（DuckDNS DNS-01 + HTTP-01 + 自签名优先级链）、DuckDNS IP 更新脚本 | PolyForm NC |
| [kafuneri/asterisk-docker-iax](https://github.com/kafuneri/asterisk-docker-iax) | 容器化 Asterisk + chan-quectel 参考 | MIT |
| [myleo1/asterisk-chan-quectel-lts](https://github.com/myleo1/asterisk-chan-quectel-lts) | chan-quectel 模块（含 swap hold/unhold bug 修复） | GPL-2.0 |
| [mlan/docker-asterisk](https://github.com/mlan/docker-asterisk) | TLS/ACME 证书管理参考 | MIT |

## 16. uninstall.sh 设计

### 16.1 读取 manifest

```bash
manifest=".simgo-manifest"
if [ ! -f "$manifest" ]; then
    echo "错误：未找到 ${manifest}，无法安全卸载" >&2
    exit 1
fi
```

manifest 格式（每行一条记录）：

```
# SimGo uninstall manifest
cron:*/5 * * * * /path/to/duckdns-update.sh
file:./duckdns-update.sh
file:./config/pjsip.conf
file:./config/extensions.conf
file:./config/extensions_custom.conf
file:./config/quectel.conf
file:./config/modules.conf
file:./config/rtp.conf
file:./scripts/bot.conf
file:./docker-compose.yml
file:/etc/fail2ban/filter.d/asterisk-pjsip.conf
file:/etc/fail2ban/jail.d/asterisk-pjsip.local
file:./.simgo-manifest
dir:./certs
dir:./logs
```

### 16.2 清理逻辑

```bash
echo "SimGo 卸载"
echo "==============="

# 1. 停止并删除容器和匿名卷
echo "停止容器..."
docker compose down -v 2>/dev/null || true

# 2. 删除 cron 条目（只删带 # SimGo 标记的行）
echo "清理 cron..."
crontab -l 2>/dev/null | grep -v "# SimGo" | crontab - 2>/dev/null || true

# 3. 删除 manifest 中记录的文件和目录
echo "删除文件..."
fail2ban_changed=false
while IFS= read -r line; do
    case "$line" in
        cron:*) ;;  # 已在步骤 2 处理
        file:*)
            target="${line#file:}"
            rm -f "$target"
            echo "  删除 $target"
            [[ "$target" == /etc/fail2ban/* ]] && fail2ban_changed=true
            ;;
        dir:*)
            target="${line#dir:}"
            rm -rf "$target"
            echo "  删除 $target/"
            ;;
    esac
done < "$manifest"

# 4. 如果删除了 fail2ban 配置，重启 fail2ban
if [ "$fail2ban_changed" = true ] && systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo "重启 fail2ban..."
    systemctl restart fail2ban
fi

echo ""
echo "卸载完成"
echo ""
echo "注意：acme.sh、fail2ban、nftables 未被移除（系统级工具，由各自管理）"
echo "如需卸载 acme.sh，请执行：acme.sh --uninstall"
echo "如需卸载 fail2ban，请执行：apt remove fail2ban"
```

### 16.3 设计原则

| 原则 | 说明 |
|------|------|
| acme.sh 不卸载 | acme.sh 是系统级工具，可能被其他项目使用，SimGo 只管自己签的证书 |
| fail2ban 不卸载 | fail2ban 是系统级安全工具，SimGo 只删除自己的 filter/jail 配置，然后重启 fail2ban |
| cron 精确删除 | 只删带 `# SimGo` 标记的行，不动用户其他 cron |
| manifest 自删 | 最后一行删除 `.simgo-manifest` 自身 |
| 容器和卷全清 | `docker compose down -v` 删除容器和匿名卷 |
| 挂载的源目录不删 | `./config/`、`./scripts/`、`./certs/`、`./logs/` 是用户部署目录下的文件，由 manifest 的 file/dir 记录逐个清理 |
