# SimGo 迭代 Prompt — 模块状态监控与自愈（watchdog）

> 本次迭代在 SimGo（EC20 + Asterisk 容器化中继）基础上新增**模块状态监控与自愈（watchdog）**能力。
> 整体架构与初始搭建规范见 `docs/PROMPT.md`，**本次设计以 `docs/DESIGN.md §18` 为唯一事实来源**，本文档是给实现者的提示词；需求/任务/README 双语已先行同步，**实现完成后无需再改文档**。

## 项目概述

SimGo 将 Quectel EC20 4G 模块通过 USB 接入 Linux 主机，运行容器化 Asterisk，手机经 SIP 客户端（Groundwire）远程接打电话。chan-quectel 驱动按 GSM 域（+CREG）与 LTE 域（+CEREG）任一注册判定模块可用性（上游已修复）；信号偏弱、驻留/重驻留波动导致两域短暂同时未注册时，驱动报告 `GSM not registered` 并拦截呼叫（真实未注册，非误报）。watchdog 用作通用兜底：监控驱动状态、分级自动恢复、异常/恢复可选推送通知。

## 已有文件（不要修改语义）

| 文件 | 状态 |
|------|------|
| `config/*`、`docker/*`、`start.sh`、`scripts/telegram_bot.py`、`scripts/sms_notify.py`、`scripts/archive-recordings.sh`、`scripts/bot.conf` | 不变 |
| `docs/DESIGN.md`（已含 §18）、`docs/REQUIREMENTS.md`（已含 §3.6，Backlog 为 §3.7）、`docs/TASKS.md`（已含阶段七）、`README.md`/`README.en.md`（已含 watchdog 小节与 FAQ） | 已同步，实现中**不要改动** |

## 本次改动文件

| 文件 | 动作 |
|------|------|
| `scripts/watchdog-quectel.sh` | 新增，宿主侧 watchdog 主脚本（bash，无第三方依赖） |
| `scripts/notify_alarm.py` | 新增，容器内双通道通知 CLI（经 `./scripts:/etc/asterisk/scripts` 挂载自动进容器，**无需重建镜像**） |
| `setup.sh` | 扩展：logrotate 段 + watchdog cron 安装步 + `.simgo-manifest` 条目 |
| `uninstall.sh` | 核对/如需最小配套（cron 已按 `# SimGo` 通用清理，manifest `file:` 清理按现有逻辑） |

## 核心规格

### 1. 状态全集与分类（scripts/watchdog-quectel.sh）

数据源：`docker exec simgo asterisk -rx "quectel show device state <dev>"` 的 `State:` 行（形如 `  State                   : <text>`，正则 `^[[:space:]]+State[[:space:]]*:[[:space:]]*(.*)$`）。

| 分类 | 匹配 `State:` 文本 | watchdog 动作 |
|------|--------------------|----------------|
| SKIP | 文本含 `scheduled`（尾巴，desired≠current 切换中）或等于 `Stopped` | 跳过，不改状态 |
| FAULT_REG | 文本等于 `GSM not registered` | 恢复链 A |
| FAULT_INIT | 文本等于 `Not initialized` | 恢复链 B |
| FAULT_LINK | 文本等于 `Not connected` | 恢复链 C |
| OK | 其余全部（`Free` / `Ring` / `Dialing` / `Waiting` / `Active N` / `Held N` / `Incoming SMS` / `Outgoing SMS` 及组合） | 清故障计数；若此前为故障 → 记恢复日志并通知 |

设备枚举：先 `quectel show devices` 拿设备列表（可能多设备），逐台循环。**未知/空文本按查询失败处理（只日志不动作）**。

### 2. 恢复链（幂等，"轻→重"，执行后立即复查）

| 链 | 第 1 步 | 第 2 步 | 复查 |
|----|---------|---------|------|
| A | 探针：`quectel cmd <dev> AT+CEREG?`、`AT+CREG?` 记值 → `quectel reset <dev>` | 仍故障：`quectel cmd <dev> AT+CFUN=1,1` | 每次动作后 sleep ~15s 再查 `State:`，命中 OK/SKIP 即视为恢复退出 |
| B | `quectel reset <dev>` | —（失败升级，**不做 CFUN**） | 同上 |
| C | `quectel restart <now> <dev>` | —（失败升级，**不做 CFUN**） | 同上 |

每动作记录日志；链走完仍故障 → 升级（日志 ERROR + 通知）。

### 3. 自愈状态机

- **防抖**：同一设备连续 **2 轮** 同类故障才触发恢复链；计数存 `scripts/.watchdog-state/<dev>.state`（文本 `key=value`：`fault`、`count`、`cool_until`、`actions`、`last_seen`）。
- **通话保护**：触发动作前 `docker exec simgo asterisk -rx "core show channels count"`，输出含 `N active channel` 且 N>0 → 本轮跳过且**不清计数**。
- **冷却**：设备执行过动作后 `COOLDOWN_SEC=1800`（30min）内不再动作（继续检测记录）。
- **日上限**：每设备每日动作 ≤ `DAILY_MAX=5`，超限当日只记 ERROR 并通知一次。
- **flock 防重入**：入口对锁文件（如 `/tmp/simgo-watchdog.lock`）`flock -n`，拿不到直接退出 0。
- **查询失败**：`docker exec` 或 CLI 返回非零 / 空输出 → 只写日志，不动作、不计次数。

### 4. 通知（scripts/notify_alarm.py）

- 用法：`python3 /etc/asterisk/scripts/notify_alarm.py "<标题>" "<正文>"`（容器内路径）。
- 读取 `/etc/asterisk/bot.conf`（key：`BOT_TOKEN`/`CHAT_ID`/`SOCKS5_PROXY`，企微 `WECHAT_WORK_API`/`WECHAT_WORK_TOKEN`/`WECHAT_WORK_TO`）。
- **Telegram**：`sendMessage`、HTML、复用 `telegram_bot.py` 的 `requests.post` + `proxies`（SOCKS5）风格；消息结构：`🔧 <b>标题</b>` + 纯文本正文（保留换行，不加 `<pre>`/`<code>` 代码包裹）。
- **企业微信**：复用 `sms_notify.py:send_wechat()` 的 session-cookie API 规格：`POST {API}`，header `Cookie: session={token}`，body `{"to": ..., "content": ...}`，纯文本；含 `__` 占位符未替换或配置缺失 → 跳过该通道。
- 双通道全失败 → `exit 1`（watchdog 只记日志，不影响主流程）。
- watchdog 宿主侧调用：`docker exec simgo python3 /etc/asterisk/scripts/notify_alarm.py "$TITLE" "$BODY"`（远程通信不可达时 `docker exec` 失败 → 只记日志）。

### 5. 日志与调度

- 诊断日志：`logs/watchdog-quectel.log`，行格式 `[YYYY-MM-DD HH:MM:SS] <dev> [INFO|WARN|ERROR] <msg>`。
- 定时：宿主机 cron `*/2 * * * * ${SCRIPT_DIR}/scripts/watchdog-quectel.sh >/dev/null 2>&1 # SimGo-watchdog`（setup.sh 安装，防重复，行尾标记被 uninstall 的 `# SimGo` 通用清理覆盖）。
- 状态目录 `scripts/.watchdog-state/` 加入 `.gitignore`（同 `.simgo-archive.conf` 的 git 忽略模式）。

### 6. setup.sh 变更

1. logrotate 段（现 `/etc/logrotate.d/simgo` 内）追加：
   ```
   ${SCRIPT_DIR}/logs/watchdog-quectel.log {
       daily
       rotate 7
       compress
       missingok
       notifempty
       create 0644 root root
   }
   ```
2. 安装 cron（参考现存 archive `--scan` cron 的写法）：先 `crontab -l | grep -Fq "watchdog-quectel.sh"` 判断去重。
3. `.simgo-manifest` 追加：
   ```
   cron:*/2 * * * * ${SCRIPT_DIR}/scripts/watchdog-quectel.sh >/dev/null 2>&1 # SimGo-watchdog
   file:${SCRIPT_DIR}/scripts/watchdog-quectel.sh
   file:${SCRIPT_DIR}/scripts/notify_alarm.py
   ```
   （`uninstall.sh` 的执行逻辑如未删除 `file:` 列表项，核对后补齐最小配套，不得改动现有 `# SimGo` token 依赖。）

## 验收清单

- [ ] `bash -n scripts/watchdog-quectel.sh` 通过；python3 语法检查通过
- [ ] mock 五场景：OK（清计数）/ FAULT_REG（reset→复查→CFUN→升级）/ FAULT_INIT（reset→升级）/ FAULT_LINK（restart→升级）/ 通话中（跳过不清计数）
- [ ] asterisk 查询失败 → 仅日志不动作
- [ ] `scheduled` 尾缀与 `Stopped` 跳过且不改计数
- [ ] 冷却期内不重复动作；日上限生效；恢复后推送"恢复"通知
- [ ] notify_alarm.py：仅 Telegram 可用 / 仅企微可用 / 全配置 / 全缺失（exit≠0）
- [ ] setup.sh 幂等（重复运行不重复加 cron）；manifest 与实际文件一致
- [ ] 文档一致性：实现行为与 DESIGN §18 / REQUIREMENTS 3.6 / README 双语描述一致（实现不改文档）

## 文档同步

本文档（PROMPT-WATCHDOG.md）作为本次迭代 prompt 归档；迭代结束后在 `docs/TASKS.md` 阶段七勾选完成。若实现中偏离 DESIGN §18，须先改 DESIGN 再改本 prompt 与 README 双语。