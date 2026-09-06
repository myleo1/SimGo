# CellBridge Vibe Coding Prompt

## 项目概述

CellBridge 是一个远程蜂窝电话网关：将 Quectel EC20 4G 模块通过 USB 连接到 Linux 主机，运行容器化的 Asterisk 服务，手机通过 SIP 客户端（Groundwire）实现远程接打电话、收发短信。

## 已有文件（不要修改）

以下文件已实现，只需了解其接口，不要修改：

| 文件 | 用途 |
|------|------|
| `config/pjsip.conf` | PJSIP 配置模板（含 `__PJSIP_EXTEN__` 等占位符） |
| `config/extensions.conf` | 主拨号计划（6 行，include extensions_custom.conf） |
| `config/extensions_custom.conf` | 自定义拨号计划（含 `__PJSIP_EXTEN__` 占位符） |
| `config/quectel.conf` | Quectel 模块配置模板（含 `__AT_PORT__`、`__ALSA_DEV__`） |
| `config/modules.conf` | 模块加载配置（静态） |
| `config/rtp.conf` | RTP 端口范围 42077-42126（静态） |
| `scripts/bot.conf` | Bot 配置模板（含 `__TG_BOT_TOKEN__` 等占位符） |
| `scripts/sms_notify.py` | 短信通知脚本（TG + 企业微信双通道） |
| `scripts/telegram_bot.py` | Telegram Bot 主程序（1518 行，长轮询） |
| `.github/workflows/build.yml` | GitHub Actions 构建工作流（已就绪） |
| `docs/REQUIREMENTS.md` | 需求文档 |
| `docs/DESIGN.md` | 详细设计文档（880 行，包含所有待实现文件的完整代码） |
| `docs/TASKS.md` | 任务拆解 |
| `README.md` | 项目说明 |

## 待实现文件

### P0 — 核心容器化（必须先完成）

#### 1. `docker/Dockerfile`

Multi-stage build。参考 DESIGN.md §4.2。

**Build 阶段**（builder，编译 chan-quectel 后丢弃）：
- 基础镜像：`ubuntu:24.04`
- 安装编译依赖：build-essential, git, autoconf, automake, libtool, pkg-config, asterisk-dev, libsqlite3-dev, libasound2-dev
- clone `https://github.com/myleo1/asterisk-chan-quectel-lts.git`（固定 commit）
- 使用 `dpkg-architecture -qDEB_HOST_MULTIARCH` 动态获取模块路径
- `./bootstrap && ./configure DESTDIR=<module_path> --with-astversion=$(asterisk -V | grep -oP '[\d.]+') && make && make install`

**Runtime 阶段**：
- 基础镜像：`ubuntu:24.04`
- apt 安装：asterisk, asterisk-dev, libasound2t64, libsqlite3-0, python3, python3-requests, python3-socks
- 复制 chan-quectel.so 到 runtime 阶段
- 设置时区、locale、Asterisk 用户权限

#### 2. `start.sh`

容器入口脚本。参考 DESIGN.md §10。

功能：
1. 从 `/etc/asterisk/templates/` 复制配置文件到 `/etc/asterisk/`，用 sed 替换占位符为环境变量
2. bot.conf 特殊处理：从 `/etc/asterisk/scripts/bot.conf` 复制到 `/etc/asterisk/bot.conf`，单独 sed 替换
3. 如果有企业微信环境变量，追加到 bot.conf
4. `chmod +x` 两个 Python 脚本
5. 后台启动 Telegram Bot（`python3 /etc/asterisk/scripts/telegram_bot.py &`）
6. 前台启动 Asterisk（`asterisk -f -vvvg`）
7. `wait` 等待任一进程退出

#### 3. `docker/docker-compose.yml`

模板文件。参考 DESIGN.md §9。

关键配置：
- `network_mode: host`（不需要 ports 映射）
- `privileged: true`（UAC 音频 + USB 热插拔）
- `devices`: by-id 路径映射 EC20 AT 端口 + `/dev/snd`
- `volumes`: `./config:/etc/asterisk/templates:ro`、`./scripts:/etc/asterisk/scripts:ro`、`./certs:/etc/asterisk/certs:ro`、`./logs:/var/log/asterisk`、`./spool:/var/spool/asterisk`
- `environment`: 所有环境变量使用 `${VAR}` 语法（由 setup.sh sed 替换）
- 企业微信环境变量不在模板中，由 setup.sh 动态追加

#### 4. `.gitignore`

参考 DESIGN.md §13。排除：docker-compose.yml、duckdns-update.sh、.cellbridge-manifest、certs/、logs/、__pycache__/、*.pyc、.DS_Store

### P1 — 部署脚本（P0 完成后）

#### 5. `setup.sh`

交互式部署脚本。参考 DESIGN.md §14。

19 步流程：
1-10: 收集用户输入（AT 端口、ALSA 设备、PJSIP 用户名/密码、局域网段、DuckDNS 域名、TG Bot 配置、SOCKS5 代理、企业微信、DuckDNS Token、邮箱）
11: 打印安装清单确认
12: 安装 acme.sh + 签发 TLS 证书
13: 安装 DuckDNS cron
14: 安装 fail2ban + nftables + filter/jail
15: 创建 logs/ 目录
16: 生成 docker-compose.yml（从模板 sed 替换）
17: 生成 docker-compose.yml（从模板 sed 替换）
18: 生成 .cellbridge-manifest
19: 提示启动命令

关键逻辑：
- 企业微信配置：只有用户填写时才追加到 bot.conf 和 docker-compose.yml
- DuckDNS cron：`*/5 * * * * /path/to/duckdns-update.sh >/dev/null 2>&1 # CellBridge`
- fail2ban：检查是否已安装，未安装则 apt install；安装 filter 到 `/etc/fail2ban/filter.d/`，jail 到 `/etc/fail2ban/jail.d/`
- manifest：记录所有宿主机变更（cron、文件、目录）

#### 6. `duckdns-update.sh`

DuckDNS IP 自动更新脚本。参考 DESIGN.md §11。

```bash
#!/bin/bash
DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN}"
# 检查变量 → curl 更新 → 记录日志
```

#### 7. `fail2ban/filter.d/asterisk-pjsip.conf`

参考 DESIGN.md §12.2。

```ini
[Definition]
failregex = ^.*res_pjsip/pjsip_distributor\.c: Request .* failed for '<HOST>:\d+' .* - No matching endpoint found$
            ^.*res_pjsip/pjsip_distributor\.c: Request .* failed for '<HOST>:\d+' .* - Failed to authenticate$
ignoreregex =
```

#### 8. `fail2ban/jail.d/asterisk-pjsip.local`

参考 DESIGN.md §12.3。

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

#### 9. `uninstall.sh`

Manifest-based 卸载。参考 DESIGN.md §16。

逻辑：
1. 读取 .cellbridge-manifest
2. `docker compose down -v`
3. crontab 精确删除 `# CellBridge` 标记行
4. 逐项删除 manifest 中的文件和目录
5. 如果删了 fail2ban 配置，重启 fail2ban
6. 不卸载 acme.sh、fail2ban、nftables

#### 10. `LICENSE`

GPL v2 许可证。参考 chan-quectel 上游协议。

## 实现顺序

```
Phase 1: .gitignore → Dockerfile → start.sh → docker-compose.yml
Phase 2: setup.sh → duckdns-update.sh → fail2ban configs
Phase 3: uninstall.sh → LICENSE
```

每个 Phase 完成后进行基本验证（文件是否存在、语法是否正确），然后进入下一个 Phase。

## 主 Agent 职责

1. 按 Phase 顺序调度子 Agent
2. 每个子 Agent 完成后，验证输出文件是否符合 DESIGN.md 规范
3. 检查文件间引用一致性（如 docker-compose.yml 的 volume 挂载路径是否与 start.sh 的目录结构匹配）
4. 跟踪整体进度，所有 Phase 完成后汇总

## 子 Agent 职责

每个子 Agent 接收一个模块任务，需要：
1. 阅读 DESIGN.md 中对应章节获取完整实现代码
2. 阅读已有文件了解上下文（如 config/ 下的模板文件了解占位符格式）
3. 生成目标文件
4. 自检：文件内容是否与 DESIGN.md 一致，占位符格式是否正确

## 需要人工介入的测试

以下测试需要人工配合完成，AI 不执行：

| 测试项 | 操作 |
|--------|------|
| Docker 镜像构建 | `docker compose build` |
| 容器启动 | `docker compose up -d` |
| AT 端口连接 | 确认 EC20 模块 USB 连接正常 |
| ALSA 声卡 | 确认 UAC 音频设备可用 |
| TLS 证书签发 | 确认 DuckDNS 域名解析正常 |
| SIP 注册 | Groundwire 连接测试 |
| 接打电话 | 实际拨入拨出测试 |
| 短信收发 | 实际发送接收短信 |
| Telegram Bot | 实际发送 Bot 命令 |
| Fail2ban | 确认 IP 被封禁（`fail2ban-client status`） |

AI 完成所有文件生成后，输出一份"人工测试检查清单"供用户执行。

## 约束

1. **不要修改已有文件**（config/、scripts/、docs/、.github/ 下的现有文件）
2. **DESIGN.md 是唯一事实来源**，接口路径、参数名、占位符格式以此为准
3. **占位符格式统一**：`__PLACEHOLDER__`（双下划线包裹）
4. **安全**：不在代码中硬编码任何密码、Token、密钥
5. **每个文件生成后立即自检**，确认与 DESIGN.md 一致
