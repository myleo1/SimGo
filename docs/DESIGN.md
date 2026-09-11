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
│   ├── pjsip.conf               # PJSIP 配置（模板）
│   ├── extensions.conf          # 主拨号计划（模板）
│   ├── extensions_custom.conf   # 自定义拨号计划（模板，含通话录音）
│   ├── quectel.conf             # Quectel 模块配置（模板）
│   ├── modules.conf             # 模块加载配置
│   ├── rtp.conf                 # RTP 配置
│   └── contacts.csv.example     # 联系人映射模板（setup.sh 复制为 spool/contacts.csv）
├── scripts/
│   ├── sms_notify.py            # 短信通知脚本（TG + 企业微信）
│   ├── telegram_bot.py          # Bot 主程序
│   ├── archive-recordings.sh    # 录音归档守护（宿主机侧，--watch/--scan 双模式）
│   ├── vcard_to_csv.py          # vCard → contacts.csv 一次性导入工具
│   └── bot.conf                 # Bot 配置文件（模板）
├── docker/
│   ├── Dockerfile               # 镜像构建文件
│   └── docker-compose.yml       # 部署配置（模板）
├── fail2ban/
│   ├── filter.d/
│   │   └── asterisk-pjsip.conf  # Fail2ban 过滤器
│   └── jail.d/
│       └── asterisk-pjsip.local # Fail2ban 监狱配置
├── .github/
│   └── workflows/
│       └── build.yml            # GitHub Actions 构建
├── setup.sh                     # 交互式部署脚本
├── uninstall.sh                 # 卸载脚本
├── docs/
│   ├── REQUIREMENTS.md          # 需求文档
│   ├── DESIGN.md                # 设计文档
│   ├── TASKS.md                 # 任务拆解
│   └── PROMPT-RECORD.md         # 录音归档功能的迭代 prompt
├── LICENSE                      # GPL v2 许可证
└── README.md                    # 项目说明

# 运行时（由 setup.sh 生成/初始化，git 忽略）
logs/                            # 日志（bind mount 到容器）
.simgo-archive.conf              # 录音归档配置（ARCHIVE_DIR / 保留策略，由 archive-recordings.sh 读取）
spool/                           # Asterisk 运行时数据（bind mount 到容器）
│   └── contacts.csv             # 联系人映射（运行时文件，从模板复制后维护）
│   └── monitor/                 # 录音临时中转目录（归档成功或按策略清理）
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
| `__REC_FORMAT__` | 录音格式（`wav49` / `ulaw`） | `wav49` |

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

### 8.5 extensions_custom.conf（含通话录音）

```ini
[from-internal]
exten => _[+0-9].,1,NoOp(Calling out via EC20: ${EXTEN})
; SIMGO_REC_OUT_BEGIN
same => n,Set(REC_TIME=${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)})
same => n,Set(RECNUM=${FILTER(0-9,${EXTEN})})
same => n,Set(RECNUM=${IF($[${LEN(${RECNUM})=0}]?${EXTEN}:${RECNUM})})
same => n,Set(REC_NAME=${SHELL(grep -m1 "^${RECNUM}," /var/spool/asterisk/contacts.csv 2>/dev/null | cut -d, -f2 | tr -d '\r\n')})
same => n,Set(REC_NAME=${IF($[${LEN(${REC_NAME})=0}]?${RECNUM}:${REC_NAME})})
same => n,Set(REC_NAME=${REPLACE(${REC_NAME}, ,_)})
same => n,MixMonitor(/var/spool/asterisk/monitor/${REC_TIME}_out_${REC_NAME}_${RECNUM}.__REC_FORMAT__,b)
; SIMGO_REC_OUT_END
same => n,Dial(Quectel/quectel0/${EXTEN})
same => n,Hangup()

[incoming-mobile]
exten => sms,1,Verbose(Incoming SMS from ${CALLERID(num)})
same => n,System(/usr/bin/python3 /etc/asterisk/scripts/sms_notify.py "${CALLERID(num)}" "${SMS_BASE64}" "${QUECTELNAME}" &)
same => n,Hangup()

exten => ussd,1,Verbose(Incoming USSD: ${BASE64_DECODE(${USSD_BASE64})})
same => n,Hangup()

exten => s,1,NoOp(Incoming call from ${CALLERID(num)})
same => n,Set(CALLERID(all)="${CALLERID(num)}" <${CALLERID(num)}>)

same => n,Set(MAX_RETRIES=8)
same => n,Set(COUNTER=0)

same => n(check_reg),NoOp(Checking if __PJSIP_EXTEN__ is online... Attempt ${COUNTER})
same => n,Set(CONTACTS=${PJSIP_DIAL_CONTACTS(__PJSIP_EXTEN__)})
same => n,GotoIf($[ "${CONTACTS}" != "" ]?dial_now)

same => n,Set(COUNTER=$[${COUNTER} + 1])
same => n,GotoIf($[${COUNTER} >= ${MAX_RETRIES}]?timeout)

same => n,Ringing()
same => n,Wait(5)
same => n,Goto(check_reg)

same => n(dial_now),NoOp(__PJSIP_EXTEN__ is online, dialing...)
same => n,Set(DIAL_CONTACTS=${PJSIP_DIAL_CONTACTS(__PJSIP_EXTEN__)})
; SIMGO_REC_IN_BEGIN
same => n,Set(REC_TIME=${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)})
same => n,Set(RECNUM=${FILTER(0-9,${CALLERID(num)})})
same => n,Set(RECNUM=${IF($[${LEN(${RECNUM})=0}]?${CALLERID(num)}:${RECNUM})})
same => n,Set(REC_NAME=${SHELL(grep -m1 "^${RECNUM}," /var/spool/asterisk/contacts.csv 2>/dev/null | cut -d, -f2 | tr -d '\r\n')})
same => n,Set(REC_NAME=${IF($[${LEN(${REC_NAME})=0}]?${RECNUM}:${REC_NAME})})
same => n,Set(REC_NAME=${REPLACE(${REC_NAME}, ,_)})
same => n,MixMonitor(/var/spool/asterisk/monitor/${REC_TIME}_in_${REC_NAME}_${RECNUM}.__REC_FORMAT__,b)
; SIMGO_REC_IN_END
same => n,Dial(${DIAL_CONTACTS},30)
same => n,Hangup()

same => n(timeout),NoOp(__PJSIP_EXTEN__ did not register in time. Hanging up.)
same => n,Hangup()
```

**录音要点**：
- 录音块用注释标记 `; SIMGO_REC_OUT_BEGIN/END`、`; SIMGO_REC_IN_BEGIN/END` 包裹；start.sh 在渲染后根据环境变量 `RECORDING_ENABLED`（`yes`/其他）决定是否用 `sed` 删除区间（关闭录音时不产生录音行，拨号计划回退为纯 NoOp + Dial）
- `MixMonitor(file,b)` 的 `b` 选项 = 仅在 bridge 期间录音（接通才录，不录等待音/振铃），挂机自动停止写盘
- 录音文件落在 `/var/spool/asterisk/monitor/`，该目录为既有 `./spool:/var/spool/asterisk` bind mount 的子目录，即宿主机 `<部署目录>/spool/monitor/`（录音临时中转目录）
- `RECNUM` 用 `${FILTER(0-9,...)}` 将对方号码规范为纯数字（去掉 `+`/- 等），同时照顾 csv 中 `+86`/`0086` 去前缀后的双行变体，提高匹配率；空值回退原始号码
- 联系人查询使用 `contacts.csv`（UTF-8，`号码,名字` 每行）；未命中回退为号码；文件名中的空格统一替换为 `_`
- 模板中的 `__REC_FORMAT__` 是占位符，start.sh 渲染时替换为实际格式字符串（`wav49` / `ulaw`，来自环境变量 `REC_FORMAT`），避免 dialplan 里把 `${REC_FORMAT}` 当成未设置的空 channel 变量
- 去电方向为 `out`；来电方向为 `in`，对方号码为 `${CALLERID(num)}`

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
      - REC_FORMAT=${REC_FORMAT}
      - RECORDING_ENABLED=${RECORDING_ENABLED}
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
- `./spool:/var/spool/asterisk`：bind mount Asterisk 运行时数据到宿主机。**录音文件落在其中 `monitor/` 子目录，作为临时中转**；持久化归档由宿主机侧的 `archive-recordings.sh` 守护完成（cp + cmp 校验 → 归档到持久化归档目录 → 按保留策略处理本地），**容器与归档目录保持解耦，不直接挂载归档卷**
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
mkdir -p /var/spool/asterisk/monitor

# 录音格式（wav49 默认，可切换 ulaw）
REC_FORMAT="${REC_FORMAT:-wav49}"
# 自动录音总开关（setup.sh 配置，关闭时移除拨号计划中的录音区间）
RECORDING_ENABLED="${RECORDING_ENABLED:-yes}"

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
        -e "s|__REC_FORMAT__|${REC_FORMAT}|g" \
        "${CONFIG_DIR}/${dst}"
}

render_config pjsip.conf pjsip.conf
render_config extensions.conf extensions.conf
render_config extensions_custom.conf extensions_custom.conf
render_config quectel.conf quectel.conf
render_config modules.conf modules.conf
render_config rtp.conf rtp.conf

# 自动录音关闭时，删除拨号计划中的录音区间（含标记注释行）
if [ "${RECORDING_ENABLED}" != "yes" ]; then
    sed -i '/; SIMGO_REC_OUT_BEGIN/,/; SIMGO_REC_OUT_END/d' "${CONFIG_DIR}/extensions_custom.conf"
    sed -i '/; SIMGO_REC_IN_BEGIN/,/; SIMGO_REC_IN_END/d' "${CONFIG_DIR}/extensions_custom.conf"
fi

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
11. 录音归档配置（录音总开关、格式、归档目录、保留策略，见 §17.9）
12. 打印安装清单，确认后继续（见 §14.3）
13. 安装 acme.sh，签发 Let's Encrypt TLS 证书（DuckDNS DNS-01），chown 证书目录给 asterisk 用户（uid 101）
14. 安装 DuckDNS IP 更新 cron
15. 安装 fail2ban + nftables + inotify-tools + logrotate（如未安装），安装 filter 和 jail，重启 fail2ban
16. 创建日志目录（`./logs`）、录音归档配置（`.simgo-archive.conf`）、`spool/monitor` 与 `spool/contacts.csv`；写入 `/etc/logrotate.d/simgo`（日志轮转，见 §17.5 运行约束）
17. 生成 docker-compose.yml（含设备路径、环境变量与 `REC_FORMAT`/`RECORDING_ENABLED` 替换）
18. 安装录音归档 cron（`# SimGo-record` 标记）
19. 生成 .simgo-manifest（记录所有宿主机变更，供 uninstall.sh 使用）
20. 提示启动命令
```

### 14.2 生成的文件

| 文件 | 说明 |
|------|------|
| `docker-compose.yml` | 从模板生成，填入设备路径和环境变量 |
| `certs/asterisk.pem` | Let's Encrypt TLS 证书（DuckDNS DNS-01） |
| `certs/asterisk.key` | TLS 私钥 |
| `duckdns-update.sh` | DuckDNS IP 自动更新脚本（安装 cron 每 5 分钟更新） |
| `.simgo-archive.conf` | 录音归档守护配置（`ARCHIVE_DIR` / `LOCAL_KEEP_DAYS` / `LOCAL_MAX_MB`），git 忽略 |
| `spool/contacts.csv` | 电话号码 → 联系人映射（复制自 `config/contacts.csv.example`），git 忽略 |
| `spool/monitor/` | 录音本地中转目录（容器 bind mount 子目录） |
| `.simgo-manifest` | 安装清单，记录所有宿主机变更（cron 条目、生成的文件），供 uninstall.sh 使用 |
| `/etc/logrotate.d/simgo` | 宿主机日志轮转配置（录音日志 daily×7、Asterisk daily×14，gzip），setup.sh 生成 |

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

[录音归档与日志]
  - 安装 inotify-tools 与 logrotate（如未安装）
  - 写入 /etc/logrotate.d/simgo（录音日志保留 7 份 / Asterisk 日志 14 份，gzip，随卸载删除）
  - 安装录音归档 cron（@reboot watch + */5 scan，带 # SimGo-record 标记）

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

## 17. 通话录音与归档

### 17.1 存储链路概览

```
容器内 Asterisk
  /var/spool/asterisk/monitor/{ts}_{out|in}_{联系人}_{号码}.wav49
        ↕ bind mount（既有 ./spool:/var/spool/asterisk）
宿主机 <部署目录>/spool/monitor/
        ↕ archive-recordings.sh（宿主机守护：cp + cmp 校验 → 归档 → 按保留策略处理本地）
持久化归档目录/<YYYY-MM>/{录音文件}
```

- **录音临时中转目录**（本地）：`<部署目录>/spool/monitor/`
- **持久化归档目录**（最终存档，可配置，典型为挂载到宿主机本地的 NAS 共享目录）：`ARCHIVE_DIR`，按 `YYYY-MM` 分月子目录
- 容器与归档目录**解耦**：容器不挂载归档卷，归档完全由宿主机侧守护完成

### 17.2 录音实现

拨号计划中在 `Dial()` 之前调用 `MixMonitor(路径,b)`：

- `b`（bridge）选项：仅在通话真正桥接期间录音，不录等待音/振铃；挂机自动停止并写盘
- 文件名：`<YYYYMMDD-HHMMSS>_<out|in>_<联系人>_<号码>.<格式>`
- 格式与命名细节见 §8.5（`extensions_custom.conf` 模板）
- **总开关**：录音可行性由环境变量 `RECORDING_ENABLED` 控制（`yes`/其他，setup.sh 记录到 docker-compose）。关闭时 start.sh 用 `sed` 删除拨号计划中的 `SIMGO_REC_OUT/IN_BEGIN..END` 区间，拨号计划回退为不录音版本；录音配套（cron 归档守护、`contacts.csv`、`REC_FORMAT`）保留不动，日后改回 `RECORDING_ENABLED=yes` 重启容器即恢复

### 17.3 录音格式对照

| 格式 | 编码 | 约每分钟 | 质量 |
|------|------|---------|------|
| `.wav` | PCM 16bit | ~947 KB | 无损（PCM），体积浪费 |
| `.ulaw` | G.711 8bit | ~473 KB | 8kHz 带宽下无损，体积适中 |
| `.gsm` | GSM 06.10 | ~99 KB | 有损，电话语音针对性编码，体积最小 |
| **`.wav49`** | GSM 封装进 WAV | ~100 KB | 同 GSM 编码，播放器兼容最好（**默认**） |

- 电话/EC20 音频原生为 **8kHz 窄带**，高于 8kHz 的采样没有意义
- 格式通过环境变量 `REC_FORMAT` 注入（start.sh 渲染 `__REC_FORMAT__`，默认 `wav49`，可切 `ulaw`）
- 不采用 m4a/AAC：Asterisk 无 AAC 编码模块，MixMonitor 不能直接录；且 8kHz 下 AAC 体积与 GSM 相当，无额外收益，避免引入 ffmpeg 转码依赖

### 17.4 联系人映射（contacts.csv）

```
config/contacts.csv.example   ← 仓库内模板（头行 + 注释示例）
        ↓ setup.sh 复制
<部署目录>/spool/contacts.csv ← 运行时文件（.gitignore，隐私不上库）
        ↓ vcard_to_csv.py / 手工编辑
号码,名字  数据行
```

- 格式：UTF-8 CSV，头行 `号码,名字`，每行一条，号码不含分隔符
- 拨号计划通过 `${SHELL(grep -m1 "^号码," ... | cut -d, -f2 ...)}` 查询，未命中回退为号码（详见 §8.5）
- **`scripts/vcard_to_csv.py`**（一次性导入工具）：
  - 用法：`python3 scripts/vcard_to_csv.py 输入.vcf [输出.csv]`（默认输出 `<部署目录>/spool/contacts.csv`）
  - 解析 vCard：`FN`（或 `N`）为名字，`TEL` 优先取 type 含 `cell`/`voice` 的号码，回退第一个 `TEL`
  - 兼容 Apple/iCloud 导出的带 vCard 属性组前缀写法（`item1.TEL;type=pref` 等），属性名前缀 `itemN.` 会被剥除；安卓（`TEL;TYPE=CELL` / `TEL;CELL`）同样支持
  - 号码规范化：同一名字同时生成"原始号码"与"去掉 `+86`/`0086` 前缀"两行（去前缀仅当结果为 `1[3-9]` 开头的 11 位手机号，排除 `8610/8620` 等非手机写法），提高与拨号计划侧 CALLERID 的匹配率；只保留数字
  - 同名去重；默认不清空原文件（追加合并），`--replace` 可选全量覆盖

### 17.5 归档守护 archive-recordings.sh（宿主机侧）

纯 `bash` + `inotifywait`，不引入 rclone（归档目录已挂载到宿主机本地路径，直接 `cp` + `cmp` 即可）。

**配置注入**：脚本为静态源码（无占位符），运行时从 `<部署目录>/.simgo-archive.conf`（由 setup.sh 生成，`.gitignore` 忽略）读取，shell 变量格式：

```bash
ARCHIVE_DIR=""        # 持久化归档目录；空串 = 不归档（录音仅本地保存）
LOCAL_KEEP_DAYS=0     # 本地保留天数；0 = 不按天数清理
LOCAL_MAX_MB=0        # 本地大小上限（MB）；0 = 不按大小清理
```

**配置变量**：

| 变量 | 含义 | 取值 |
|------|------|------|
| `ARCHIVE_DIR` | 持久化归档目录 | 路径；**空串 = 不归档**（录音仅本地保存） |
| `LOCAL_KEEP_DAYS` | 本地保留天数 | `0` = 不按天数清理 |
| `LOCAL_MAX_MB` | 本地大小上限（MB） | `0` = 不按大小清理 |
| `MONITOR_DIR` | 本地录音中转目录 | 脚本从自身路径推导：`<部署目录>/spool/monitor` |

**两种运行模式**：

- `--watch`（常驻守护）：`inotifywait -m -e close_write,moved_to --format '%f' "$MONITOR_DIR"` 监听新录音落盘，逐文件处理：
  1. 等待 1s 落盘稳定
  2. `ARCHIVE_DIR=""` → 跳过归档（仅本地保存，永不自动删除）
  3. `month` 取文件 mtime 对应的 `%Y-%m`（`stat` 推导，补归档旧录音仍落到录制月份）；`mkdir -p "$ARCHIVE_DIR/$month"`
  4. `timeout 120 cp` 到 `<ARCHIVE_DIR>/<month>/`（优先 `cp -p` 保留 mtime；NAS 不支持保留属主时报 `Operation not permitted`，降级为普通复制，最终以 `cmp` 内容校验为准）
  5. `cmp` 逐字节校验
  6. 校验通过：
     - `LOCAL_KEEP_DAYS=0` 且 `LOCAL_MAX_MB=0` → 立即删除本地文件（A 模式）
     - 否则保留本地（B/C 模式），由 `--scan` 按策略清理
  7. 记录归档日志（文件、目标目录）

- `--scan`（兜底扫描，供 cron 调用）：
  1. 遍历 `MONITOR_DIR` 本地文件，尝试归档尚未归档/上次失败的文件（幂等，按 `--watch` 同一流程）
  2. 执行本地清理：
     - `LOCAL_KEEP_DAYS>0`：删除本地 mtime 超过 N 天的录音（仅在实际删除文件时写清除日志，无删除则静默，避免每 5 分钟刷一条）
     - `LOCAL_MAX_MB>0`：本地总大小超上限时，按最旧优先删除直到达标
  3. **保活**：检查 `--watch` 进程是否存活（按脚本 PID 锁 `pgrep -f "archive-recordings.sh --watch"`），不存在则重启

**运行约束**：
- 脚本自带 PID 锁（`--watch` 仅允许一个实例）
- 所有 `cp` 用 `timeout` 包裹，防止归档目录不可达（如 NFS hard 挂载）时永久挂起
- 录音文件扩展名按**大小写不敏感**匹配（MixMonitor 的 wav49 落盘为 `.WAV` 大写），`--scan` 与本地清理均覆盖
- 日志写入 `<部署目录>/logs/recordings-archive.log`
- **日志轮转**（宿主机 `logrotate`，`/etc/logrotate.d/simgo`，由 setup.sh 生成、卸载时随 manifest 删除）：每日运行——
  - `recordings-archive.log`：保留 **7 份** + gzip，用 `create`（脚本每次 `>>` 重新打开文件，rename 无损）
  - Asterisk `messages.log` / `queue_log`：保留 **14 份** + gzip，用 `copytruncate`（容器内进程长期持 fd，须复制+截断而非换文件，避免 uid 权限问题）

### 17.6 保留策略（局部存储语义）

| 模式 | `ARCHIVE_DIR` | `LOCAL_KEEP_DAYS` / `LOCAL_MAX_MB` | 本地行为 |
|------|--------------|-----------------------------------|---------|
| A（默认） | 非空 | 均为 `0` | 归档校验成功即删本地，归档目录为唯一副本 |
| B | 非空 | `KEEP_DAYS>0` | 本地保留最近 N 天（双保险），到期由 `--scan` 清理 |
| C | 非空 | `MAX_MB>0` | 本地总量超上限删最旧，直到达标 |
| B+C | 非空 | 两者均 >0 | 任一条件触发即清理旧录音 |
| 不归档 | 空串 | — | 录音仅保存在本地，永不自动删除（可另配 `LOCAL_MAX_MB` 兜底） |

**默认即方案 A**：归档完成后本地恒为空，`spool/monitor` 只作临时中转，不产生双副本。

### 17.7 cron 设计

由 setup.sh 安装，均带 `# SimGo-record` 标记（`# SimGo` 的子串，uninstall 的 `grep -v "# SimGo"` 会一并精确删除，§16 兼容）：

```
@reboot <部署目录>/scripts/archive-recordings.sh --watch >/dev/null 2>&1   # SimGo-record
*/5 *    * * * <部署目录>/scripts/archive-recordings.sh --scan  >/dev/null 2>&1   # SimGo-record
```

setup.sh 用 `grep -Fq "archive-recordings.sh"` 独立去重（与 DuckDNS cron 的 `grep -Fq "duckdns-update.sh"` 去重互不干扰，避免交叉误判）。

- `@reboot`：开机自动拉起常驻守护（cron 管理，无需 nohup/PID 文件）
- `*/5`：兜底扫描（补归档 + 本地清理 + watch 保活），即使守护崩溃也能恢复

### 17.8 为什么要"本地中转 + 守护归档"（PVE 时序容错）

典型部署：宿主机为 PVE（Proxmox），NAS 是运行在 PVE 下的虚拟机，NFs/SMB 挂载点在 PVE 开机流程中可能早于 NAS VM 完全就绪。

**若将归档目录直接 bind mount 给容器录制，存在两类真实风险**：

1. **开机时序**：容器创建时 bind mount 源目录若不存在，Docker 会创建一个本地空目录并绑定；此后 NAS 挂载点才出现，**容器内的绑定不会自动切换**，录音会写入假目录"看似消失"，直到容器重启才恢复
2. **运行中掉线**：NFS 默认 hard 挂载下 `write()` 会永久挂起 → 通话线程被阻塞，最坏情况下整个通话卡死

因此录音必须与归档目录解耦：
- 录音永远写入本地（bind mount 的 spool 目录），通话全程不依赖归档存储
- 归档由宿主机守护负责，归档目录不可用时跳过、`timeout` 限时、恢复后 5 分钟内由 `--scan` 自动补传
- 录音数据安全性优先（本地先有副本，校验通过才删）

### 17.9 setup.sh 交互新增

在既有步骤 10（Let's Encrypt 邮箱）之后、安装清单（步骤 12）之前插入新步骤：

- **步骤 11：录音归档配置**
  1. **自动录音总开关**：询问"是否启用自动通话录音？[Y/n]"（默认启用），写入 docker-compose 环境变量 `RECORDING_ENABLED`；关闭时跳过后续格式/归档询问，`REC_FORMAT` 归 `wav49`、`ARCHIVE_DIR` 归空、保留策略归 0（仍安装归档 cron/inotify-tools，便于日后开启）
  2. **录音格式**：`wav49`（默认） / `ulaw`
  3. **持久化归档目录**（脱敏提示，示例路径一律使用通用占位，不绑定任何具体部署环境）：
     ```
     请输入语音录音的持久化归档目录（录音归档的最终存放位置）：
       - 常见做法：挂载到本机的 NAS 共享目录（NFS / SMB / WebDAV 等挂载点）
       - 也可以是本机大容量磁盘目录（如 /data/recordings）
       留空表示不启用归档，录音仅保存在本地：
     ```
     填写后校验目录存在且可写（`-w` 测试）；不存在或不可写时告警，允许留空继续
  4. **本地保留策略**：询问"归档成功后本地如何处理"，输入格式 **`天数,MB`**（逗号分隔两个数字，`0` = 不启用该维度）：
     - `30,500` → 保留 30 天 且 不超过 500MB（超限删最旧）
     - `30` → 只按天数保留（不限制大小）
     - `,500` → 只按大小限制（不按天数清理）
     - 回车 / `0,0` → 默认 A：归档校验成功即删除本地（归档目录为唯一副本）
     <br>解析为 `LOCAL_KEEP_DAYS` / `LOCAL_MAX_MB`（非数字输入忽略）
- **依赖安装**：检查 `inotifywait`（`command -v inotifywait`）与 `logrotate`（`command -v logrotate`），未安装则 `apt install -y inotify-tools` / `logrotate`（写入安装清单）
- **生成**：
  - 生成 `.simgo-archive.conf`（写入 `ARCHIVE_DIR` / `LOCAL_KEEP_DAYS` / `LOCAL_MAX_MB`）
  - 生成 `/etc/logrotate.d/simgo`（录音日志 daily×7 用 `create`、Asterisk `messages.log`/`queue_log` daily×14 用 `copytruncate`，均 gzip；manifest 记录供卸载）
  - `chmod +x scripts/archive-recordings.sh`
  - 复制 `config/contacts.csv.example` 为 `<部署目录>/spool/contacts.csv`（若不存在）
  - `mkdir -p <部署目录>/spool/monitor`
- **cron**：安装 §17.7 两条 cron（带 `# SimGo-record` 标记、`grep -Fq "archive-recordings.sh"` 独立去重后追加）
- **安装清单与 manifest 追加**：新 cron 行、生成的 `.simgo-archive.conf`、`spool/contacts.csv`、`spool/monitor` 目录、`/etc/logrotate.d/simgo` 记录

### 17.10 未来增强（Backlog）

| 需求 | 描述 | 涉及改动 |
|------|------|---------|
| Bot 管理联系人 | `/contact <名字> <号码>` 命令 + vcf 文件批量导入 | `telegram_bot.py`（命令 handler + 文档接收），写入 `spool/contacts.csv` |
| iPhone 通讯录自动同步 | 快捷指令定期导出 vCard 上传，宿主机自动拉取转换 | 新增拉取/转换脚本 + 手机端快捷指令，依赖手机端配合 |

两项目前均不实现，`contacts.csv` 格式保持兼容，未来可直接扩展。
