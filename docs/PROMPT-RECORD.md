# SimGo 迭代 Prompt — 自动通话录音与归档

> 本次迭代在 SimGo（EC20 + Asterisk 容器化中继）基础上新增**双向自动通话录音**与**持久化归档**能力。
> 整体架构与初始搭建规范见 `docs/PROMPT.md`，本次设计规范以 `docs/DESIGN.md §17` 为唯一事实来源。

## 项目概述

SimGo 将 Quectel EC20 4G 模块通过 USB 接入 Linux 主机，运行容器化 Asterisk，手机经 SIP 客户端（Groundwire）远程接打电话。音频走 UAC/ALSA，`./spool:/var/spool/asterisk` 已 bind mount。

## 已有文件（不要修改语义）

| 文件 | 状态 |
|------|------|
| `config/pjsip.conf`、`config/quectel.conf`、`config/modules.conf`、`config/rtp.conf` | 不变 |
| `scripts/sms_notify.py`、`scripts/telegram_bot.py`、`scripts/bot.conf` | 不变（Backlog 未来增强） |
| `docker/Dockerfile` | 不变 |
| `docker/docker-compose.yml` | 仅新增 `REC_FORMAT` / `RECORDING_ENABLED` 环境变量行（不新增挂载，容器与归档目录仍解耦） |
| `uninstall.sh` | 不变（cron 删除逻辑已按 `# SimGo` 标记通用处理） |

## 本次改动文件

| 文件 | 改动 |
|------|------|
| `config/extensions_custom.conf` | 去电/来电 Dial 前插入 `MixMonitor(...,b)`，联系人命名；录音块用 `; SIMGO_REC_OUT/IN_BEGIN..END` 注释区间标记 |
| `start.sh` | `mkdir -p /var/spool/asterisk/monitor` + 渲染 `__REC_FORMAT__` + `RECORDING_ENABLED` 非 `yes` 时删除录音区间 |
| `config/contacts.csv.example` | 新增，联系人映射模板 |
| `scripts/archive-recordings.sh` | 新增，宿主机归档守护（`--watch`/`--scan`） |
| `scripts/vcard_to_csv.py` | 新增，vCard 一次性导入工具 |
| `setup.sh` | 新增归档目录/保留策略交互、装 inotify-tools、cron、manifest |
| 文档 | REQUIREMENTS / DESIGN / TASKS / README 双语 |

## 核心规格

### 1. 录音（extensions_custom.conf）

- `MixMonitor(/var/spool/asterisk/monitor/${REC_TIME}_${dir}_${REC_NAME}_${号码}.__REC_FORMAT__,b)`
- `b` = 仅 bridge 期间录（不录等待/振铃），挂机自动写盘
- 去电 `dir=out`、对方号码=`${EXTEN}`；来电 `dir=in`、对方号码=`${CALLERID(num)}`
- 联系人：`${SHELL(grep -m1 "^<号码>," /var/spool/asterisk/contacts.csv ...)}`，未命中回退号码，空格→`_`，号码先 `${FILTER(0-9,...)}` 规范化
- 录音块包在 `; SIMGO_REC_OUT_BEGIN/END`、`; SIMGO_REC_IN_BEGIN/END` 注释区间中；`RECORDING_ENABLED`（默认 `yes`）非 `yes` 时由 start.sh 渲染后 `sed` 删除区间（拨号计划回退为不录音）
- 不破坏既有 `sms`/`ussd`/`check_reg`/`timeout` 流程

### 2. 格式

| 格式 | 约每分钟 | 定位 |
|------|---------|------|
| `wav49`（默认） | ~0.1MB | GSM 封装 WAV，8kHz 电话语音听觉无损 |
| `ulaw` | ~0.47MB | 8kHz 带宽下无损 |

- 由环境变量 `REC_FORMAT` 控制，start.sh 默认 `wav49` 空值兜底
- **不做 m4a/AAC**：Asterisk 无 AAC 编码模块；8kHz 下 AAC 体积与 GSM 相当，避免引入 ffmpeg

### 3. 归档（archive-recordings.sh，宿主机）

- 配置变量：`ARCHIVE_DIR`（持久化归档目录，空=不归档）、`LOCAL_KEEP_DAYS`、`LOCAL_MAX_MB`
- `--watch`：inotifywait 监听落盘 → 按月建 `<ARCHIVE_DIR>/YYYY-MM/` → `timeout 120 cp` → `cmp` 校验 → 通过后按保留策略处理；失败留本地+记日志
- `--scan`：补归档 + 本地清理（天数/大小）+ watch 保活
- A 模式（默认，KEEP=0 且 MAX=0）：校验成功即删本地，归档目录为唯一副本
- 日志：`<部署目录>/logs/recordings-archive.log`
- 只依赖 `inotify-tools`，不引入 rclone

### 4. 联系人（contacts.csv）

- 模板 `config/contacts.csv.example` → setup.sh 复制为 `<部署目录>/spool/contacts.csv`（git 忽略）
- `vcard_to_csv.py`（一次性）：解析 `.vcf`（FN/N + TEL），+86 双行处理，合并去重
- 隐私：真实数据只进运行时 `spool/`，不上库

### 5. setup.sh 新增交互

- **自动录音总开关**（默认启用）→ docker-compose `RECORDING_ENABLED`；关闭时跳过格式/归档询问（配套保留，日后可开启）
- 录音格式 `wav49`（默认）/ `ulaw` → docker-compose `REC_FORMAT`
- 持久化归档目录（**脱敏**提示，示例一律通用路径，不得出现具体部署环境目录）；校验可写，可留空
- 保留策略 `天数,MB` 询问 → `LOCAL_KEEP_DAYS`/`LOCAL_MAX_MB`
- 安装 `inotify-tools`；生成 `spool/contacts.csv`、`spool/monitor`
- cron（`# SimGo-record` 标记）：
  - `@reboot .../archive-recordings.sh --watch`
  - `*/5 * * * * .../archive-recordings.sh --scan`
- 清单与 `.simgo-manifest` 同步

### 6. 关键设计原因

- **本地中转 + 守护归档**而非"日志直接写归档目录"：避免 PVE 开机时序（bind mount 创建空目录后不随挂载点切换）与运行中 NFS hard 挂载阻塞通话。通话永远不依赖归档存储，恢复后 5 分钟内自动补传。

## 实现顺序

```
1. contacts.csv.example → vcard_to_csv.py → archive-recordings.sh
2. extensions_custom.conf → start.sh
3. setup.sh / uninstall.sh 兼容核对
4. 文档（已先行）→ 最终一致性 Review
5. bash -n / py_compile 语法自检
```

## 约束

1. 不修改录音无关的既有配置语义；只做"加入口"
2. cron 全部带 `# SimGo` 子串标记（archive 用 `# SimGo-record`），保证 uninstall 可清理
3. 不硬编码任何真实部署路径、密码、Token
4. 提示词与文档示例全部脱敏
5. setup.sh 对 `ARCHIVE_DIR` 为空值的语义：不启用归档，录音仅本地保存
6. 录音开关默认启用；关闭时保留归档守护配套，改 `RECORDING_ENABLED=yes` 重启容器即恢复