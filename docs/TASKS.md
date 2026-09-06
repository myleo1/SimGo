# CellBridge 任务拆解

## 阶段一：容器化基础

### 1.1 Dockerfile
- [x] 基于 `ubuntu:24.04` 创建 Multi-stage Dockerfile
- [x] Build 阶段：安装编译依赖（build-essential, git, autoconf, automake, libtool, pkg-config, asterisk-dev, libsqlite3-dev, libasound2-dev）
- [x] Build 阶段：使用 `dpkg-architecture` 动态获取模块路径，编译 chan-quectel（myleo1 fork，main 分支）
- [x] Runtime 阶段：apt 安装 Asterisk 20 + 运行时库（libasound2t64, libsqlite3-0）
- [x] Runtime 阶段：apt 安装 Python 依赖（python3, python3-requests, python3-socks）
- [x] Runtime 阶段：设置时区、locale、Asterisk 用户权限
- [x] 复制 chan-quectel.so 到 runtime 阶段

### 1.2 启动脚本 (start.sh)
- [x] 从模板复制配置文件
- [x] sed 替换占位符为环境变量
- [x] chmod +x 脚本
- [x] 启动 Bot（后台 &）
- [x] 启动 Asterisk（前台 -vvv）

### 1.3 docker-compose.yml 模板
- [x] 设备映射（by-id 路径）
- [x] 声卡透传（/dev/snd）
- [x] 网络模式（host，无需端口映射）
- [x] 环境变量定义
- [x] 配置文件挂载
- [x] 数据卷持久化（logs、spool bind mount）

### 1.4 .gitignore
- [x] 排除生成的部署文件（docker-compose.yml, duckdns-update.sh, .cellbridge-manifest）
- [x] 排除 certs/ 目录
- [x] 排除 logs/（运行时日志）
- [x] 排除 Python 缓存文件

### 1.5 GitHub Actions
- [x] `.github/workflows/build.yml`（已存在）
- [x] 触发条件：push tags `v*` + workflow_dispatch
- [x] 多架构构建：linux/amd64 + linux/arm64
- [x] 推送到 GitHub Container Registry（ghcr.io）
- [x] 使用 GHA 缓存加速构建

## 阶段二：配置模板化

### 2.1 配置文件改造
- [x] quectel.conf — `__AT_PORT__` 和 `__ALSA_DEV__` 占位符
- [x] pjsip.conf — `__PJSIP_EXTEN__`、`__PJSIP_SECRET__`、`__LOCAL_NET__`、`__EXTERNAL_MEDIA_ADDRESS__` 占位符
- [x] extensions_custom.conf — `__PJSIP_EXTEN__` 占位符
- [x] bot.conf — `__TG_BOT_TOKEN__`、`__TG_CHAT_ID__`、`__TG_SOCKS5_PROXY__` 占位符
- [x] modules.conf — 保持不变（无敏感信息）
- [x] rtp.conf — RTP 端口范围 42077-42126

### 2.2 环境变量定义
- [x] 定义所有环境变量名称
- [x] 在 docker-compose.yml 中声明
- [x] 在 start.sh 中读取并替换

## 阶段三：部署脚本

### 3.1 setup.sh 交互式脚本
- [x] 收集 AT 端口信息（by-id 优先，回退 /dev/ttyUSB*）
- [x] 自动检测 ALSA 音频设备（aplay -L → /proc/asound/cards → /dev/snd/）
- [x] 收集 PJSIP 用户名和密码
- [x] 收集本地局域网段（CIDR 格式）
- [x] 收集公网 IP 或域名（DuckDNS）
- [x] 收集 Telegram Bot 配置
- [x] 收集 SOCKS5 代理（可选）
- [x] 收集企业微信配置（可选）
- [x] 收集 DuckDNS Token
- [x] 收集 Let's Encrypt 邮箱
- [x] 打印安装清单，用户确认后继续
- [x] 安装 acme.sh，签发 TLS 证书（DuckDNS DNS-01）
- [x] 生成 docker-compose.yml
- [x] 生成 docker-compose.yml
- [x] 生成 duckdns-update.sh
- [x] 安装 DuckDNS IP 更新 cron
- [x] 安装 fail2ban + nftables
- [x] 安装 filter 和 jail
- [x] 重启 fail2ban 服务
- [x] 创建日志目录
- [x] 生成 .cellbridge-manifest
- [x] 提供启动命令

### 3.2 uninstall.sh 卸载脚本
- [x] 读取 .cellbridge-manifest，逐项清理
- [x] docker compose down -v
- [x] crontab 精确删除 CellBridge cron 条目
- [x] 删除 manifest 中记录的文件和目录
- [x] 删除 fail2ban filter 和 jail，重启 fail2ban
- [x] 不卸载 acme.sh、fail2ban

## 阶段四：README 与文档

### 4.1 README.md
- [x] 项目介绍和背景
- [x] 硬件要求和型号说明
- [x] 模块初始化步骤（手动）
- [x] 部署步骤（setup.sh）
- [x] 配置说明
- [x] 使用说明（TG Bot 命令、Groundwire 配置）
- [x] 常见问题
- [x] 来源与致谢

### 4.2 文档更新
- [x] REQUIREMENTS.md — 需求文档
- [x] DESIGN.md — 设计文档
- [x] TASKS.md — 任务拆解

## 阶段五：测试与优化

### 5.1 基础测试
- [ ] 镜像构建测试
- [ ] 容器启动测试
- [ ] AT 端口连接测试
- [ ] 短信收发测试
- [ ] 语音通话测试
- [ ] TG Bot 功能测试

### 5.2 边界测试
- [ ] 多模块场景
- [ ] 容器重启后配置持久化
- [ ] 设备热插拔
- [ ] 网络异常恢复

## 优先级

| 优先级 | 任务 | 说明 |
|--------|------|------|
| P0 | Dockerfile + start.sh | 核心容器化 |
| P0 | 配置模板化 | 支持用户自定义 |
| P0 | setup.sh | 用户部署入口 |
| P0 | docker-compose.yml 模板 | 部署配置 |
| P0 | .gitignore | 敏感信息保护 |
| P1 | GitHub Actions | 自动构建多架构镜像 |
| P1 | duckdns-update.sh | 动态 DNS 更新 |
| P1 | acme.sh + TLS 证书签发 | 安全通信 |
| P1 | .cellbridge-manifest | 安装清单 |
| P1 | uninstall.sh | 安全卸载 |
| P1 | fail2ban + nftables | SIP 爆破防护 |
| P1 | README | 项目文档 |
| P1 | 完整功能测试 | 验证通话/短信 |
| P2 | 多模块支持 | 扩展功能 |
