#!/bin/bash
# ============================================================
# SimGo 录音归档守护（宿主机侧）
#
# 用法：
#   archive-recordings.sh --watch   # 常驻监听（cron @reboot 启动）
#   archive-recordings.sh --scan    # 兜底扫描（cron */5 启动）
#
# 行为：
#   - 监听 <部署目录>/spool/monitor/ 新录音落盘
#   - cp + cmp 校验归档到 ARCHIVE_DIR/<YYYY-MM>/
#   - 按保留策略处理本地文件（A: 即删 / B: 保 N 天 / C: 大小上限）
#   - ARCHIVE_DIR 为空 = 不归档，录音仅保存在本地
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
MONITOR_DIR="${DEPLOY_DIR}/spool/monitor"
LOG_FILE="${DEPLOY_DIR}/logs/recordings-archive.log"
CONFIG_FILE="${DEPLOY_DIR}/.simgo-archive.conf"

# ==== 配置（由 setup.sh 生成 <部署目录>/.simgo-archive.conf 注入）====
ARCHIVE_DIR=""
LOCAL_KEEP_DAYS=0
LOCAL_MAX_MB=0
if [ -f "${CONFIG_FILE}" ]; then
    . "${CONFIG_FILE}"
fi

FILE_PATTERNS=(-name '*.wav49' -o -name '*.ulaw' -o -name '*.gsm' -o -name '*.wav')

log() {
    echo "$(date '+%F %T') $*" >> "$LOG_FILE"
}

mkdir -p "$(dirname "$LOG_FILE")"

# ---------- 工具函数 ----------

is_watch_running() {
    pgrep -f "archive-recordings.sh --watch" 2>/dev/null | grep -vw "$$" | grep -q .
}

# 按保留策略处理已成功归档的本地文件
handle_local() {
    local src="$1"
    if [ -z "${ARCHIVE_DIR}" ]; then
        return 0    # 未启用归档模式，不动本地
    fi
    if [ "${LOCAL_KEEP_DAYS}" -gt 0 ] || [ "${LOCAL_MAX_MB}" -gt 0 ]; then
        return 0    # B/C 模式：本地保留，由 apply_cleanup 统一清理
    fi
    # A 模式：归档校验成功后立即删除本地
    rm -f "$src" && log "删除本地: $(basename "$src")"
}

# 归档单个文件（幂等），成功返回 0
archive_file() {
    local src="$1" base month dst_dir dst_path
    [ -f "$src" ] || return 0
    base="$(basename "$src")"

    if [ -z "${ARCHIVE_DIR}" ]; then
        return 0
    fi
    if [ ! -d "${ARCHIVE_DIR}" ]; then
        log "WARN 归档目录不存在: ${ARCHIVE_DIR}（跳过，稍后重试）"
        return 1
    fi

    # 按文件 mtime 归入对应月份（补归档时仍落到录制月份）
    month="$(date -d "@$(stat -c %Y "$src")" +%Y-%m 2>/dev/null || date +%Y-%m)"
    dst_dir="${ARCHIVE_DIR}/${month}"
    mkdir -p "$dst_dir" || { log "WARN 无法创建 ${dst_dir}"; return 1; }
    dst_path="${dst_dir}/${base}"

    # 目标已存在且内容一致 → 视为已归档，直接处理本地
    if [ -f "$dst_path" ] && [ "$(stat -c %s "$dst_path")" = "$(stat -c %s "$src")" ] && cmp -s "$src" "$dst_path"; then
        handle_local "$src"
        return 0
    fi

    if ! timeout 120 cp -p "$src" "$dst_path"; then
        log "WARN 归档失败: ${base} → ${dst_path}（归档存储可能不可用）"
        return 1
    fi
    if cmp -s "$src" "$dst_path"; then
        log "OK 归档: ${base} → ${dst_path}"
        handle_local "$src"
        return 0
    else
        log "ERROR 校验失败: ${base}（保留本地，等待重试）"
        return 1
    fi
}

# 本地保留策略清理（B/C 模式）
apply_cleanup() {
    [ -d "${MONITOR_DIR}" ] || return 0

    if [ "${LOCAL_KEEP_DAYS}" -gt 0 ]; then
        find "${MONITOR_DIR}" -maxdepth 1 -type f \( "${FILE_PATTERNS[@]}" \) \
            -mtime "+${LOCAL_KEEP_DAYS}" -delete 2>/dev/null
        log "清理超过 ${LOCAL_KEEP_DAYS} 天的本地录音"
    fi

    if [ "${LOCAL_MAX_MB}" -gt 0 ]; then
        local max_kb=$((LOCAL_MAX_MB * 1024))
        local total_kb oldest
        total_kb=$(du -sk "${MONITOR_DIR}" 2>/dev/null | cut -f1)
        local safety=0
        while [ -n "${total_kb}" ] && [ "${total_kb}" -gt "${max_kb}" ] 2>/dev/null; do
            oldest=$(find "${MONITOR_DIR}" -maxdepth 1 -type f \( "${FILE_PATTERNS[@]}" \) \
                -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-)
            [ -n "$oldest" ] || break
            rm -f "$oldest"
            log "本地超限（${total_kb}KB / ${max_kb}KB），删除最旧: $(basename "$oldest")"
            total_kb=$(du -sk "${MONITOR_DIR}" 2>/dev/null | cut -f1)
            safety=$((safety + 1))
            [ "${safety}" -gt 1000 ] && break
        done
    fi
}

# ---------- --watch 常驻守护 ----------

watch_loop() {
    if is_watch_running; then
        echo "archive-recordings.sh --watch 已在运行，退出"
        exit 0
    fi
    mkdir -p "${MONITOR_DIR}"
    log "watch 启动，监听 ${MONITOR_DIR}"
    inotifywait -m -e close_write -e moved_to --format '%f' "${MONITOR_DIR}" 2>/dev/null |
    while IFS= read -r fname; do
        sleep 1    # 等待落盘稳定
        archive_file "${MONITOR_DIR}/${fname}"
        apply_cleanup
    done
}

# ---------- --scan 兜底扫描 ----------

scan_mode() {
    mkdir -p "${MONITOR_DIR}" || return 0
    local f
    for f in "${MONITOR_DIR}"/*; do
        [ -f "$f" ] || continue
        case "$f" in
            *.wav49|*.ulaw|*.gsm|*.wav) ;;
            *) continue ;;
        esac
        archive_file "$f"
    done
    apply_cleanup

    # 保活：守护不在则重新拉起
    if ! is_watch_running; then
        nohup "$0" --watch >>"${LOG_FILE}" 2>&1 &
        log "watch 守护未在运行，已重新启动"
    fi
}

# ---------- 入口 ----------

case "${1:-}" in
    --watch) watch_loop ;;
    --scan)  scan_mode ;;
    *)
        echo "用法: $0 {--watch|--scan}"
        echo "  --watch  常驻监听录音落盘并归档（cron @reboot）"
        echo "  --scan   兜底扫描：补归档 + 本地清理 + watch 保活（cron */5）"
        exit 1
        ;;
esac