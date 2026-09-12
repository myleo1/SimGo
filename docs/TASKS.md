# SimGo 任务拆解

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
- [x] 排除生成的部署文件（docker-compose.yml, duckdns-update.sh, .simgo-manifest）
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
- [x] 生成 .simgo-manifest
- [x] 提供启动命令

### 3.2 uninstall.sh 卸载脚本
- [x] 读取 .simgo-manifest，逐项清理
- [x] docker compose down -v
- [x] crontab 精确删除 SimGo cron 条目
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

## 阶段六：通话录音与归档

### 6.1 拨号计划录音
- [ ] `config/extensions_custom.conf`：去电 `from-internal` 在 Dial 前插入 MixMonitor（`b` 选项 + 联系人查询）
- [ ] `config/extensions_custom.conf`：来电 `incoming-mobile` 的 `dial_now` 分支在 Dial 前插入 MixMonitor
- [ ] 验证既有 `sms` / `ussd` / `check_reg` / `timeout` 流程未被破坏

### 6.2 start.sh
- [ ] `mkdir -p /var/spool/asterisk/monitor`
- [ ] 渲染 `__REC_FORMAT__`（默认 `wav49`，`REC_FORMAT` 空值兜底）
- [ ] 录音总开关：`RECORDING_ENABLED` 非 `yes` 时删除拨号计划中的 `SIMGO_REC_OUT/IN_BEGIN..END` 区间

### 6.3 归档守护
- [ ] `scripts/archive-recordings.sh`：`--watch` 常驻守护（inotifywait、cp + cmp 校验、A/B/C 保留策略）
- [ ] `scripts/archive-recordings.sh`：`--scan` 兜底扫描（补归档 + 本地清理 + watch 保活）
- [ ] PID 锁与 `timeout` 防挂起
- [ ] `cp -p` 在 NAS 不支持保留属主时降级普通复制，以 `cmp` 内容校验为准
- [ ] 录音文件扩展名大小写不敏感匹配（wav49 落盘为 `.WAV`）
- [ ] `apply_cleanup` 仅在真正删除文件时记录清除日志（避免每 5 分钟刷日志）

### 6.4 联系人导入
- [ ] `config/contacts.csv.example` 模板
- [ ] `scripts/vcard_to_csv.py`（vCard 解析、号码规范化、+86 双行）

### 6.5 setup.sh 扩展
- [ ] 收集自动录音总开关（`RECORDING_ENABLED`，默认启用）+ 录音格式（wav49/ulaw）
- [ ] 收集持久化归档目录（脱敏提示）+ 本地保留策略（天数,MB 格式）
- [ ] 安装 `inotify-tools`
- [ ] 安装 `logrotate` + 写入 `/etc/logrotate.d/simgo`（录音 daily×7、Asterisk daily×14，gzip）
- [ ] 生成 `spool/contacts.csv` 模板、`spool/monitor` 目录
- [ ] 安装 `@reboot` + `*/5` 两条 cron（带 `# SimGo-record` 标记，`grep -Fq "archive-recordings.sh"` 独立去重）
- [ ] 安装清单文本与 `.simgo-manifest` 同步

### 6.6 文档同步
- [ ] REQUIREMENTS.md（需求 + Backlog）
- [ ] DESIGN.md（§17 录音归档章节）
- [ ] README.md / README.en.md（双语）
- [ ] PROMPT-RECORD.md（迭代 prompt）

### 6.7 人工测试
- [ ] 去电/来电各打一通，确认 `spool/monitor/` 生成 `*_out_*.wav49` / `*_in_*.wav49`
- [ ] 联系人已收录号码 → 文件名用名字；未收录 → 用号码
- [ ] 确认录音归档到 `<归档目录>/<YYYY-MM>/` 且本地已清理（A 模式）
- [ ] 录制至少 10 分钟通话，估算文件大小（约 0.1MB/分钟）
- [ ] 停掉归档存储 VM，再打一通：录音留在本地，恢复后 5 分钟内自动补归档
- [ ] `cmp` 校验失败场景（可选）：手动制造差异，确认本地保留 + 日志记录

## 阶段七：模块状态监控与自愈（watchdog）

### 7.1 scripts/watchdog-quectel.sh（新增，宿主机）
- [ ] `flock` 防重入；`quectel show devices` 枚举设备，逐个解析 `State:` 行
- [ ] 全状态分类：注册故障 / 初始化故障 / 链路故障走对应恢复链；托管态、`scheduled` 尾缀跳过；正常态清计数
- [ ] 自愈状态机：连续 2 轮同故障触发、通话保护（`core show channels count`）、30 分钟冷却、每日 ≤5 次、计数落盘 `scripts/.watchdog-state/`
- [ ] 恢复动作幂等且"轻→重"，执行后立即复查；升级失败只记+通知
- [ ] 查询失败（asterisk 不可用）只记日志不动作；日志写 `logs/watchdog-quectel.log`

### 7.2 scripts/notify_alarm.py（新增，容器内）
- [ ] CLI：`notify_alarm.py "<标题>" "<正文>"`，读 `/etc/asterisk/bot.conf`
- [ ] Telegram（HTML）+ 企业微信（纯文本 session-cookie）双通道；通道配置缺失/占位符未替换自动跳过；全失败退出码非 0
- [ ] 经 `./scripts` 挂载进容器（`/etc/asterisk/scripts/`），无需重建镜像

### 7.3 setup.sh 扩展
- [ ] logrotate 追加 `logs/watchdog-quectel.log`（daily/7/compress）
- [ ] 新增 cron 安装步：`*/2 * * * * ${SCRIPT_DIR}/scripts/watchdog-quectel.sh >/dev/null 2>&1 # SimGo-watchdog`（防重复添加）
- [ ] `.simgo-manifest` 增加对应 `cron:` 与 `file:` 条目；校验 uninstall 清理覆盖（`# SimGo` 标记 + manifest）

### 7.4 文档同步
- [ ] REQUIREMENTS.md（§3.6 watchdog，原 Backlog 顺延 §3.7）
- [ ] DESIGN.md（§18 章节）
- [ ] README.md / README.en.md（功能特性 + 新小节 + FAQ）
- [ ] PROMPT-WATCHDOG.md（迭代 prompt，以 DESIGN §18 为唯一事实来源）

### 7.5 测试
- [ ] `bash -n` + mock 场景：正常态、注册故障（reset→复查→CFUN）、初始化故障（reset→告警）、链路故障（restart→告警）、通话中跳过、asterisk 查询失败只记不动作
- [ ] 通知脚本 mock：Telegram 可用 / 企微可用 / 双通道全失败退出码
- [ ] 防抖与冷却：连续 2 轮才触发；动作后 30 分钟冷却不重复动作
- [ ] 恢复后清计数并推送"恢复"通知

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
| P1 | .simgo-manifest | 安装清单 |
| P1 | uninstall.sh | 安全卸载 |
| P1 | fail2ban + nftables | SIP 爆破防护 |
| P1 | README | 项目文档 |
| P1 | 完整功能测试 | 验证通话/短信 |
| P2 | 多模块支持 | 扩展功能 |
| P2 | 通话录音与归档 | 双向录音 + NAS 归档 |
