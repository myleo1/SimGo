#!/bin/bash
set -e

# ============================================================
# SimGo 交互式部署脚本
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"
MANIFEST="${SCRIPT_DIR}/.simgo-manifest"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============================================================
# 步骤 1-10: 收集用户输入
# ============================================================

echo "========================================="
echo "  SimGo 部署向导"
echo "========================================="
echo ""

# --- 步骤 1: AT 端口 ---
echo "--- 步骤 1/10: AT 命令端口 ---"
FOUND_AT=($(ls /dev/serial/by-id/*if02* 2>/dev/null || true))
if [ ${#FOUND_AT[@]} -eq 1 ]; then
    AT_PORT="${FOUND_AT[0]}"
    info "检测到 EC20 模块: $AT_PORT"
elif [ ${#FOUND_AT[@]} -gt 1 ]; then
    info "检测到多个 EC20 模块:"
    for i in "${!FOUND_AT[@]}"; do
        echo "  [$((i+1))] ${FOUND_AT[$i]}"
    done
    echo "  [0] 手动输入路径"
    read -p "请选择 [1]: " PORT_CHOICE
    PORT_CHOICE=${PORT_CHOICE:-1}
    if [ "$PORT_CHOICE" = "0" ]; then
        read -p "请输入 AT 端口路径: " AT_PORT
    else
        AT_PORT="${FOUND_AT[$((PORT_CHOICE-1))]}"
    fi
else
    # 尝试查找所有 ttyUSB 设备
    FOUND_PORTS=($(ls /dev/ttyUSB* 2>/dev/null || true))
    if [ ${#FOUND_PORTS[@]} -gt 0 ]; then
        info "未找到 by-id 路径，检测到以下串口设备:"
        for i in "${!FOUND_PORTS[@]}"; do
            echo "  [$((i+1))] ${FOUND_PORTS[$i]}"
        done
        echo "  [0] 手动输入路径"
        read -p "请选择 [1]: " PORT_CHOICE
        PORT_CHOICE=${PORT_CHOICE:-1}
        if [ "$PORT_CHOICE" = "0" ]; then
            read -p "请输入 AT 端口路径: " AT_PORT
        else
            AT_PORT="${FOUND_PORTS[$((PORT_CHOICE-1))]}"
        fi
    else
        read -p "请输入 AT 端口路径 [/dev/ttyUSB2]: " AT_PORT
        AT_PORT=${AT_PORT:-/dev/ttyUSB2}
    fi
fi
echo ""

# --- 步骤 2: ALSA 音频设备 ---
echo "--- 步骤 2/10: ALSA 音频设备 ---"
ALSA_DEV=""
# 尝试 aplay -L
if command -v aplay &>/dev/null; then
    ALSA_LIST=$(aplay -L 2>/dev/null | grep -i "card\|EC20\|UAC" || true)
    if [ -n "$ALSA_LIST" ]; then
        info "检测到音频设备:"
        echo "$ALSA_LIST"
    fi
fi
# 尝试 /proc/asound/cards
if [ -z "$ALSA_LIST" ] && [ -f /proc/asound/cards ]; then
    info "声卡列表 (/proc/asound/cards):"
    cat /proc/asound/cards
fi
# 尝试 /dev/snd/
if [ -d /dev/snd ]; then
    info "/dev/snd/ 设备:"
    ls /dev/snd/
fi

echo ""
read -p "请输入 ALSA 音频设备 [hw:CARD=EC20CEHDLG,DEV=0]: " ALSA_DEV
ALSA_DEV=${ALSA_DEV:-"hw:CARD=EC20CEHDLG,DEV=0"}
echo ""

# --- 步骤 3: PJSIP 用户名和密码 ---
echo "--- 步骤 3/10: PJSIP 认证信息 ---"
echo "用户名：字母、数字、下划线、短横线（推荐 gw_ 前缀 + 随机字符串）"
echo "密码：32 位以上随机字符串（强口令）"
read -p "PJSIP 用户名: " PJSIP_EXTEN
while [ -z "$PJSIP_EXTEN" ]; do
    error "用户名不能为空"
    read -p "PJSIP 用户名: " PJSIP_EXTEN
done
read -s -p "PJSIP 密码: " PJSIP_SECRET
echo ""
while [ -z "$PJSIP_SECRET" ]; do
    error "密码不能为空"
    read -s -p "PJSIP 密码: " PJSIP_SECRET
    echo ""
done
echo ""

# --- 步骤 4: 局域网段 ---
echo "--- 步骤 4/10: 本地局域网段 ---"
read -p "局域网段 (CIDR, 如 192.168.1.0/24): " LOCAL_NET
while [ -z "$LOCAL_NET" ]; do
    error "局域网段不能为空"
    read -p "局域网段 (CIDR): " LOCAL_NET
done
echo ""

# --- 步骤 5: 公网 IP 或域名 ---
echo "--- 步骤 5/10: 公网 IP 或 DuckDNS 域名 ---"
read -p "公网 IP 或域名 (如 xxx.duckdns.org): " EXTERNAL_MEDIA_ADDRESS
while [ -z "$EXTERNAL_MEDIA_ADDRESS" ]; do
    error "公网 IP 或域名不能为空"
    read -p "公网 IP 或域名: " EXTERNAL_MEDIA_ADDRESS
done
echo ""

# --- 步骤 6: Telegram Bot ---
echo "--- 步骤 6/10: Telegram Bot ---"
read -p "Bot Token: " TG_BOT_TOKEN
while [ -z "$TG_BOT_TOKEN" ]; do
    error "Bot Token 不能为空"
    read -p "Bot Token: " TG_BOT_TOKEN
done
read -p "Chat ID: " TG_CHAT_ID
while [ -z "$TG_CHAT_ID" ]; do
    error "Chat ID 不能为空"
    read -p "Chat ID: " TG_CHAT_ID
done
echo ""

# --- 步骤 7: SOCKS5 代理 ---
echo "--- 步骤 7/10: SOCKS5 代理（可选）---"
read -p "SOCKS5 代理 (如 socks5://192.168.1.1:1080，回车跳过): " TG_SOCKS5_PROXY
echo ""

# --- 步骤 8: 企业微信 ---
echo "--- 步骤 8/10: 企业微信（可选）---"
read -p "企业 Webhook API (回车跳过): " WECHAT_WORK_API
if [ -n "$WECHAT_WORK_API" ]; then
    read -p "企业 Token: " WECHAT_WORK_TOKEN
    read -p "企业接收人: " WECHAT_WORK_TO
else
    WECHAT_WORK_TOKEN=""
    WECHAT_WORK_TO=""
fi
echo ""

# --- 步骤 9: DuckDNS Token ---
echo "--- 步骤 9/10: DuckDNS Token ---"
read -p "DuckDNS Token: " DUCKDNS_TOKEN
echo ""
while [ -z "$DUCKDNS_TOKEN" ]; do
    error "DuckDNS Token 不能为空（用于 TLS 证书签发和 IP 自动更新）"
read -p "DuckDNS Token: " DUCKDNS_TOKEN
    echo ""
done
echo ""

# --- 步骤 10: Let's Encrypt 邮箱 ---
echo "--- 步骤 10/10: Let's Encrypt 邮箱 ---"
read -p "邮箱 (用于 acme.sh 账户注册): " ACME_EMAIL
while [ -z "$ACME_EMAIL" ]; do
    error "邮箱不能为空"
    read -p "邮箱: " ACME_EMAIL
done
echo ""

# ============================================================
# 步骤 11: 打印安装清单，确认后执行
# ============================================================

echo "========================================="
echo "  SimGo 安装清单"
echo "========================================="
echo ""
echo "[Docker]"
echo "  - 拉取镜像：ubuntu:24.04（构建时）"
echo "  - 创建容器：simgo（Asterisk + Python 脚本）"
echo "  - bind mount：logs/, spool/"
echo ""
echo "[acme.sh]"
echo "  - 安装 acme.sh（如未安装）"
echo "  - 签发 Let's Encrypt TLS 证书到 ${CERT_DIR}/"
echo "  - acme.sh 自动注册续签 cron（宿主机 crontab，SimGo 不管理卸载）"
echo ""
echo "[fail2ban]"
echo "  - 安装 fail2ban + nftables（如未安装，SimGo 不管理卸载）"
echo "  - 安装 asterisk-pjsip filter 和 jail"
echo "  - 重启 fail2ban 服务"
echo ""
echo "[宿主机 cron]"
echo "  - 添加 DuckDNS IP 更新 cron（每 5 分钟，带 # SimGo 标记）"
echo ""
echo "[部署目录]"
echo "  - 生成：docker-compose.yml, duckdns-update.sh, logs/, .simgo-manifest"
echo ""
read -p "确认安装？[y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    info "已取消安装"
    exit 0
fi
echo ""

# ============================================================
# 步骤 12: 安装 acme.sh + 签发 TLS 证书
# ============================================================

info "安装 acme.sh..."
if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

info "签发 TLS 证书（DuckDNS DNS-01）..."
mkdir -p "$CERT_DIR"
export DuckDNS_Token="$DUCKDNS_TOKEN"
~/.acme.sh/acme.sh --issue --dns dns_duckdns -d "$EXTERNAL_MEDIA_ADDRESS" --keylength ec-256 --server letsencrypt || true
cp ~/.acme.sh/${EXTERNAL_MEDIA_ADDRESS}_ecc/fullchain.cer "${CERT_DIR}/asterisk.pem"
cp ~/.acme.sh/${EXTERNAL_MEDIA_ADDRESS}_ecc/${EXTERNAL_MEDIA_ADDRESS}.key "${CERT_DIR}/asterisk.key"
chown -R 101:101 "${CERT_DIR}"
info "TLS 证书已签发到 ${CERT_DIR}/"
echo ""

# ============================================================
# 步骤 13: 安装 DuckDNS cron
# ============================================================

info "安装 DuckDNS IP 更新 cron..."
# 生成 duckdns-update.sh
cat > "${SCRIPT_DIR}/duckdns-update.sh" <<DUCKEOF
#!/bin/bash
DUCKDNS_DOMAIN="${EXTERNAL_MEDIA_ADDRESS}"
DUCKDNS_TOKEN="${DUCKDNS_TOKEN}"

if [ -z "\$DUCKDNS_DOMAIN" ] || [ -z "\$DUCKDNS_TOKEN" ]; then
    echo "Missing DUCKDNS_DOMAIN or DUCKDNS_TOKEN"
    exit 1
fi

RESPONSE=\$(curl -fsS "https://www.duckdns.org/update?domains=\${DUCKDNS_DOMAIN}&token=\${DUCKDNS_TOKEN}&ip=")

if [ "\$RESPONSE" = "OK" ]; then
    echo "\$(date): DuckDNS IP updated for \${DUCKDNS_DOMAIN}"
else
    echo "\$(date): DuckDNS update failed: \${RESPONSE}" >&2
    exit 1
fi
DUCKEOF
chmod +x "${SCRIPT_DIR}/duckdns-update.sh"

# 添加 cron（避免重复）
CRON_LINE="*/5 * * * * ${SCRIPT_DIR}/duckdns-update.sh >/dev/null 2>&1 # SimGo"
if ! crontab -l 2>/dev/null | grep -q "# SimGo"; then
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    info "DuckDNS cron 已添加"
else
    warn "DuckDNS cron 已存在，跳过"
fi
echo ""

# ============================================================
# 步骤 14: 安装 fail2ban + nftables
# ============================================================

info "检查 fail2ban..."
if ! command -v fail2ban-client &>/dev/null; then
    info "安装 fail2ban..."
    apt-get update && apt-get install -y fail2ban
fi

info "检查 nftables..."
if ! command -v nft &>/dev/null; then
    info "安装 nftables..."
    apt-get update && apt-get install -y nftables
fi

info "安装 SimGo fail2ban filter..."
mkdir -p /etc/fail2ban/filter.d
cat > /etc/fail2ban/filter.d/asterisk-pjsip.conf <<'FILTEREOF'
[Definition]

failregex = ^.*res_pjsip/pjsip_distributor\.c: Request .* failed for '<HOST>:\d+' .* - No matching endpoint found$
            ^.*res_pjsip/pjsip_distributor\.c: Request .* failed for '<HOST>:\d+' .* - Failed to authenticate$

ignoreregex =
FILTEREOF

info "安装 SimGo fail2ban jail..."
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/asterisk-pjsip.local <<JILEOF
[asterisk-pjsip]
enabled = true
filter = asterisk-pjsip
backend = polling
logpath = ${SCRIPT_DIR}/logs/messages.log
maxretry = 5
findtime = 10m
bantime = 24h
banaction = nftables
port = 0:65535
protocol = tcp,udp
JILEOF

info "重启 fail2ban..."
systemctl restart fail2ban 2>/dev/null || warn "fail2ban 重启失败，请手动检查"
echo ""

# ============================================================
# 步骤 15: 创建日志目录
# ============================================================

mkdir -p "${SCRIPT_DIR}/logs"
info "日志目录已创建: ${SCRIPT_DIR}/logs/"
echo ""

# ============================================================
# 步骤 16: 生成 docker-compose.yml
# ============================================================

info "生成 docker-compose.yml..."
cp "${SCRIPT_DIR}/docker/docker-compose.yml" "${SCRIPT_DIR}/docker-compose.yml"
sed -i \
    -e "s|__AT_PORT__|${AT_PORT}|g" \
    -e "s|__ALSA_DEV__|${ALSA_DEV}|g" \
    -e "s|__LOCAL_NET__|${LOCAL_NET}|g" \
    -e "s|__EXTERNAL_MEDIA_ADDRESS__|${EXTERNAL_MEDIA_ADDRESS}|g" \
    -e "s|\${PJSIP_EXTEN}|${PJSIP_EXTEN}|g" \
    -e "s|\${PJSIP_SECRET}|${PJSIP_SECRET}|g" \
    -e "s|\${LOCAL_NET}|${LOCAL_NET}|g" \
    -e "s|\${EXTERNAL_MEDIA_ADDRESS}|${EXTERNAL_MEDIA_ADDRESS}|g" \
    -e "s|\${ALSA_DEV}|${ALSA_DEV}|g" \
    -e "s|\${TG_BOT_TOKEN}|${TG_BOT_TOKEN}|g" \
    -e "s|\${TG_CHAT_ID}|${TG_CHAT_ID}|g" \
    -e "s|\${TG_SOCKS5_PROXY}|${TG_SOCKS5_PROXY}|g" \
    "${SCRIPT_DIR}/docker-compose.yml"

# 动态追加企业微信环境变量到 docker-compose.yml
if [ -n "$WECHAT_WORK_API" ] && [ -n "$WECHAT_WORK_TOKEN" ] && [ -n "$WECHAT_WORK_TO" ]; then
    sed -i "/^      - TG_SOCKS5_PROXY=/a\\      - WECHAT_WORK_API=${WECHAT_WORK_API}\\n      - WECHAT_WORK_TOKEN=${WECHAT_WORK_TOKEN}\\n      - WECHAT_WORK_TO=${WECHAT_WORK_TO}" "${SCRIPT_DIR}/docker-compose.yml"
fi
info "docker-compose.yml 已生成"
echo ""

# ============================================================
# 步骤 17: 生成 .simgo-manifest
# ============================================================

info "生成安装清单..."
cat > "$MANIFEST" <<MANEOF
# SimGo uninstall manifest
cron:*/5 * * * * ${SCRIPT_DIR}/duckdns-update.sh
file:${SCRIPT_DIR}/duckdns-update.sh
file:${SCRIPT_DIR}/docker-compose.yml
file:/etc/fail2ban/filter.d/asterisk-pjsip.conf
file:/etc/fail2ban/jail.d/asterisk-pjsip.local
file:${SCRIPT_DIR}/.simgo-manifest
dir:${CERT_DIR}
dir:${SCRIPT_DIR}/logs
MANEOF
info "安装清单已生成: ${MANIFEST}"
echo ""

# ============================================================
# 步骤 18: 提示启动命令
# ============================================================

echo "========================================="
echo "  安装完成！"
echo "========================================="
echo ""
echo "启动 SimGo:"
echo "  cd ${SCRIPT_DIR} && docker compose up -d"
echo ""
echo "查看日志:"
echo "  docker compose logs -f"
echo ""
echo "停止:"
echo "  docker compose down"
echo ""
echo "卸载:"
echo "  ${SCRIPT_DIR}/uninstall.sh"
echo ""
