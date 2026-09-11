# SimGo 需求文档

## 1. 项目背景

### 1.1 问题

- 不同 Linux 发行版的 Asterisk 版本差异导致各种兼容性问题
- iOS 设备在国内无法接收 Telegram 推送

### 1.2 解决方案

将 SIM 卡插入 Quectel EC20 4G 模块，通过 USB 连接到任意 Linux 主机（树莓派、小主机、NAS 等），运行容器化的 Asterisk 服务，实现：

- **远程接打电话**：手机只需一张上网卡，通过 SIP 客户端（Groundwire）远程通话
- **远程收发短信**：通过 Telegram Bot / 企业微信接收和发送短信
- **来电通知**：来电实时推送到 Telegram / 企业微信
- **容器化部署**：消除系统差异，一键部署

## 2. 硬件要求

### 2.1 模块型号

- **型号**：Quectel EC20CEHDLGR08A03M1G（EC20 系列）
- **接口**：USB 转接板
- **天线**：附带天线可能信号较弱，建议另购长天线

> **注意**：本项目基于 EC20CEHDLG 型号开发测试，其他 EC20 子型号（如 EC20CEFAG-512-SGNS）可能存在适配差异。购买时建议确认固件版本为 R08 基线，R06 基线对新版中国电信卡支持不佳。

### 2.2 宿主机

- Linux 系统（Ubuntu / Debian / Armbian 等）
- 7x24 运行（树莓派、Orange Pi、x86 小主机等）
- Docker & Docker Compose
- USB 接口供电充足（建议独立供电，不要仅依赖 Pi USB 口）

## 3. 功能需求

### 3.1 核心功能

| 功能 | 描述 |
|------|------|
| 语音通话 | 通过 PJSIP 协议对接 Groundwire，实现远程接打手机电话 |
| 短信收发 | 收到短信自动转发到 Telegram / 企业微信；支持通过 TG Bot 发送短信 |
| 来电通知 | 来电实时推送到 Telegram / 企业微信 |
| 模块管理 | 通过 TG Bot 查看模块状态、重启模块 |
| UAC 数字音频 | 透传宿主机声卡，支持 EC20 的 UAC 数字音频 |
| 通话录音 | 所有经 EC20 的通话（去电 + 来电）接通后自动双向录音，挂机自动落盘 |
| 录音归档 | 自动归档到持久化归档目录，按月份分子目录，支持本地保留策略 |

### 3.2 通知渠道

| 渠道 | 用途 | 默认状态 |
|------|------|---------|
| Telegram Bot | 主通知渠道，支持收发短信、模块管理 | 开启 |
| 企业微信 | 兜底方案，仅接收信息（解决国内 iOS TG 推送问题） | 可选 |

### 3.3 来电处理

- 来电时检查 SIP 客户端是否在线
- 如果不在线，每 5 秒检查一次，最多等待 40 秒
- 期间向主叫播放回铃音
- 超时未上线则挂断

### 3.4 SIP 客户端要求

iOS 对 VoIP 推送有严格限制：
- VoIP 推送（PushKit）必须配合 CallKit 使用（iOS 13+ 起强制要求），否则 App 会被系统终止
- 自建 SIP 客户端需要 Apple Developer Program（$99/年）+ VoIP Services Certificate（.p12 格式，非 .p8）
- 需集成 PushKit + CallKit 框架，维护常驻后台的 SIP 连接

推荐使用 [Groundwire](https://apps.apple.com/app/groundwire-sip-softphone/id397417696)（[Android](https://play.google.com/store/apps/details?id=cz.acrobits.softphone.aliengroundwire)）（付费 SIP 客户端），已完整实现 CallKit 集成、常驻后台 SIP 注册、APNs VoIP 推送，用户无需自建 iOS App 或申请开发者证书。

### 3.5 通话录音与归档

#### 3.5.1 录音

- **可配置开关**：用户可在部署时选择是否启用自动录音（`RECORDING_ENABLED`，默认启用）；关闭后拨号计划不再插入录音逻辑，日后改回环境变量并重启容器即可恢复，无需改拨号计划
- **触发时机**：仅在通话真正接通（bridge）期间录音，不录等待音、振铃；挂机自动停止并落盘
- **覆盖范围**：经 EC20 的所有双向通话（去电 + 来电）
- **命名规则**：文件名包含时间戳、方向（`out`/`in`）、联系人名字（若已收录）、对方号码，如 `20260911-153045_out_张三_13800138000.wav49`
- **录音格式**：默认 `wav49`（GSM/WAV49 封装，约 0.1MB/分钟，8kHz 电话语音下听觉无损），可选 `ulaw`（约 0.47MB/分钟，8kHz 带宽下无失真）。电话/EC20 音频原生为 8kHz 窄带
- **联系人映射**：通过 `contacts.csv`（号码,名字）实现"号码 → 名字"，未收录的号码回退为号码本身；支持从 iPhone 通讯录导出的 vCard 一次性批量导入

#### 3.5.2 归档

- **归档目标**：持久化归档目录（典型为已挂载到宿主机本地的 NAS 共享目录，也支持任意本地大容量磁盘目录）；按 `YYYY-MM`（如 `2026-09`）每月子目录组织
- **归档方式**：宿主机守护脚本监听录音落盘，`cp` + 逐字节 `cmp` 校验成功后归档；校验失败保留本地并自动重试
- **本地保留策略**：
  - A（默认）：归档校验成功后立即删除本地，NAS 为唯一副本
  - B：本地保留最近 N 天，充当双保险
  - C：本地总量不超过大小上限，超限自动删除最旧的录音
  - B + C 可组合；任一触发即清理
- **健壮性**：归档目录不可用（如底层存储 VM 未启动）时，不影响通话录音（录音暂存本地），存储恢复后自动补归档，不丢录音

### 3.6 未实现需求（Backlog）

以下需求已明确方向但本期不实现，供后续迭代：

- **Bot 管理联系人**：为 Telegram Bot 增加 `/contact <名字> <号码>` 命令及 vcf 文件批量导入，动态维护联系人映射（需修改 `telegram_bot.py`）
- **iPhone 通讯录自动同步**：通过 iOS 快捷指令定期导出全部通讯录 vCard 并上传，宿主机自动拉取转换为 `contacts.csv`（需额外开发与维护，且依赖手机端配合）

## 4. 非功能需求

### 4.1 容器化

- Docker 镜像基于 `ubuntu:24.04`，apt 直接安装 Asterisk 20
- 采用 Multi-stage build：builder 阶段编译 chan-quectel，runtime 阶段只保留运行时依赖
- 配置通过 start.sh 在容器内渲染模板生成，不修改代码
- 支持 `docker compose` 一键部署
- 使用 `network_mode: host`，容器直接使用宿主机网络栈
- 使用 `privileged: true`，支持 UAC 音频透传和 USB 热插拔
- 设备映射使用 `by-id` 路径，防止 USB 序号漂移
- 日志通过 bind mount 持久化到宿主机（`./logs:/var/log/asterisk`）

### 4.2 安全

- SIP 信令加密：PJSIP over TLS（端口 52060），禁用 UDP
- 媒体流加密：SRTP（SDES 密钥交换）
- TLS 证书：通过 DuckDNS + acme.sh 自动签发 Let's Encrypt 证书
- **DuckDNS IP 自动更新**：cron 每 5 分钟更新 DuckDNS 记录（家庭宽带动态 IP）
- **Fail2ban 防护**：自动封禁 SIP 爆破 IP（nftables，TCP+UDP 全端口，24h 封禁）
- 敏感信息（Bot Token、密码等）通过环境变量或挂载文件传入，不写入镜像
- TG Bot 限制允许的 Chat ID
- PJSIP 配置限制访问
- 强口令要求：SIP 用户名推荐 `gw_` 前缀 + 随机字符串，密码 32 位以上随机字符串

### 4.3 可维护性

- 配置模板与运行时配置分离
- 日志持久化到宿主机
- 支持模块热插拔（通过 `by-id` 设备路径）
- **setup.sh**：交互式部署脚本，引导用户填写配置，安装 acme.sh/fail2ban，生成 docker-compose.yml
- **uninstall.sh**：基于 manifest 的安全卸载，精确清理 SimGo 安装的内容
- **manifest 文件**：记录所有宿主机变更，供 uninstall.sh 使用
- **录音保留策略可配置**：归档即删 / 保留 N 天 / 大小上限，由宿主机归档守护与 cron 管理

## 5. 来源与致谢

本项目基于以下开源项目和教程：

- [myth.cx - Asterisk + EC20 实现短信收发+语音通话+网络代理](https://myth.cx/p/asterisk-ec20/) — 核心教程
- [kafuneri/asterisk-docker-iax](https://github.com/kafuneri/asterisk-docker-iax) — Docker 容器化参考
- [IchthysMaranatha/asterisk-chan-quectel](https://github.com/IchthysMaranatha/asterisk-chan-quectel) — 原始 chan-quectel 驱动
- [missing233/asterisk-chan-quectel-lts](https://github.com/missing233/asterisk-chan-quectel-lts) — LTS 分支，支持 UAC
- [myleo1/asterisk-chan-quectel-lts](https://github.com/myleo1/asterisk-chan-quectel-lts) — 修复 swap hold/unhold bug
- [blog.wsl.moe - 安装基于 Quectel EC20 模块的短信及语音转发服务](https://blog.wsl.moe/2023/03/%E5%AE%89%E8%A3%85%E5%9F%BA%E4%BA%8E-quectel-ec20-%E6%A8%A1%E5%9D%97%E7%9A%84%E7%9F%AD%E4%BF%A1%E5%8F%8A%E8%AF%AD%E9%9F%B3%E8%BD%AC%E5%8F%91%E6%9C%8D%E5%8A%A1/)
- [blog.sparktour.me - 使用 EC20 模块配合 Asterisk 及 FreePBX 实现短信转发和网络电话](https://blog.sparktour.me/posts/2022/10/08/quectel-ec20-asterisk-freepbx-gsm-gateway/)
