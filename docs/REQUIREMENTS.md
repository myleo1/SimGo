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

## 5. 来源与致谢

本项目基于以下开源项目和教程：

- [myth.cx - Asterisk + EC20 实现短信收发+语音通话+网络代理](https://myth.cx/p/asterisk-ec20/) — 核心教程
- [kafuneri/asterisk-docker-iax](https://github.com/kafuneri/asterisk-docker-iax) — Docker 容器化参考
- [IchthysMaranatha/asterisk-chan-quectel](https://github.com/IchthysMaranatha/asterisk-chan-quectel) — 原始 chan-quectel 驱动
- [missing233/asterisk-chan-quectel-lts](https://github.com/missing233/asterisk-chan-quectel-lts) — LTS 分支，支持 UAC
- [myleo1/asterisk-chan-quectel-lts](https://github.com/myleo1/asterisk-chan-quectel-lts) — 修复 swap hold/unhold bug
- [blog.wsl.moe - 安装基于 Quectel EC20 模块的短信及语音转发服务](https://blog.wsl.moe/2023/03/%E5%AE%89%E8%A3%85%E5%9F%BA%E4%BA%8E-quectel-ec20-%E6%A8%A1%E5%9D%97%E7%9A%84%E7%9F%AD%E4%BF%A1%E5%8F%8A%E8%AF%AD%E9%9F%B3%E8%BD%AC%E5%8F%91%E6%9C%8D%E5%8A%A1/)
- [blog.sparktour.me - 使用 EC20 模块配合 Asterisk 及 FreePBX 实现短信转发和网络电话](https://blog.sparktour.me/posts/2022/10/08/quectel-ec20-asterisk-freepbx-gsm-gateway/)
