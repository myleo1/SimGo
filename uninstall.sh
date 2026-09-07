#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${SCRIPT_DIR}/.simgo-manifest"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "SimGo 卸载"
echo "==============="
echo ""

# 1. 读取 manifest
if [ ! -f "$MANIFEST" ]; then
    echo -e "${RED}错误：未找到 ${MANIFEST}，无法安全卸载${NC}" >&2
    exit 1
fi

# 2. 停止并删除容器和匿名卷
echo "停止容器..."
docker compose down -v 2>/dev/null || true
echo ""

# 3. 删除 cron 条目（只删带 # SimGo 标记的行）
echo "清理 cron..."
if crontab -l 2>/dev/null | grep -q "# SimGo"; then
    crontab -l 2>/dev/null | grep -v "# SimGo" | crontab - 2>/dev/null || true
    info "DuckDNS cron 已删除"
else
    info "未找到 SimGo cron 条目"
fi
echo ""

# 4. 删除 manifest 中记录的文件和目录
echo "删除文件..."
fail2ban_changed=false
while IFS= read -r line; do
    case "$line" in
        \#*|"") ;;  # 跳过注释和空行
        cron:*) ;;  # 已在步骤 3 处理
        file:*)
            target="${line#file:}"
            if [ -f "$target" ]; then
                rm -f "$target"
                info "删除 $target"
            fi
            [[ "$target" == /etc/fail2ban/* ]] && fail2ban_changed=true
            ;;
        dir:*)
            target="${line#dir:}"
            if [ -d "$target" ]; then
                rm -rf "$target"
                info "删除 $target/"
            fi
            ;;
    esac
done < "$MANIFEST"
echo ""

# 5. 如果删除了 fail2ban 配置，重启 fail2ban
if [ "$fail2ban_changed" = true ] && systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo "重启 fail2ban..."
    systemctl restart fail2ban
    info "fail2ban 已重启"
    echo ""
fi

echo "========================================="
echo "  卸载完成"
echo "========================================="
echo ""
echo "注意：acme.sh、fail2ban、nftables 未被移除（系统级工具，由各自管理）"
echo "如需卸载 acme.sh，请执行：acme.sh --uninstall"
echo "如需卸载 fail2ban，请执行：apt remove fail2ban"
echo ""
