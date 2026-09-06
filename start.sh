#!/bin/bash
set -e

TEMPLATE_DIR="/etc/asterisk/templates"
CONFIG_DIR="/etc/asterisk"
SCRIPT_DIR="/etc/asterisk/scripts"

# 1. 初始化目录和文件
mkdir -p /var/log/asterisk/cdr-csv

# 2. 渲染配置模板（sed 替换占位符）
render_config() {
    local src="$1"
    local dst="$2"
    cp "${TEMPLATE_DIR}/${src}" "${CONFIG_DIR}/${dst}"
    sed -i \
        -e "s|__PJSIP_EXTEN__|${PJSIP_EXTEN}|g" \
        -e "s|__PJSIP_SECRET__|${PJSIP_SECRET}|g" \
        -e "s|__LOCAL_NET__|${LOCAL_NET}|g" \
        -e "s|__EXTERNAL_MEDIA_ADDRESS__|${EXTERNAL_MEDIA_ADDRESS}|g" \
        -e "s|__AT_PORT__|${AT_PORT}|g" \
        -e "s|__ALSA_DEV__|${ALSA_DEV}|g" \
        -e "s|__TG_BOT_TOKEN__|${TG_BOT_TOKEN}|g" \
        -e "s|__TG_CHAT_ID__|${TG_CHAT_ID}|g" \
        -e "s|__TG_SOCKS5_PROXY__|${TG_SOCKS5_PROXY}|g" \
        -e "s|__WECHAT_WORK_API__|${WECHAT_WORK_API}|g" \
        -e "s|__WECHAT_WORK_TOKEN__|${WECHAT_WORK_TOKEN}|g" \
        -e "s|__WECHAT_WORK_TO__|${WECHAT_WORK_TO}|g" \
        "${CONFIG_DIR}/${dst}"
}

render_config pjsip.conf pjsip.conf
render_config extensions.conf extensions.conf
render_config extensions_custom.conf extensions_custom.conf
render_config quectel.conf quectel.conf
render_config modules.conf modules.conf
render_config rtp.conf rtp.conf

# bot.conf 模板在 scripts/ 目录，渲染到 /etc/asterisk/bot.conf
cp "${SCRIPT_DIR}/bot.conf" "${CONFIG_DIR}/bot.conf"
sed -i \
    -e "s|__TG_BOT_TOKEN__|${TG_BOT_TOKEN}|g" \
    -e "s|__TG_CHAT_ID__|${TG_CHAT_ID}|g" \
    -e "s|__TG_SOCKS5_PROXY__|${TG_SOCKS5_PROXY}|g" \
    "${CONFIG_DIR}/bot.conf"

# 动态追加企业微信配置到 bot.conf（未填写则跳过）
if [ -n "${WECHAT_WORK_API}" ] && [ -n "${WECHAT_WORK_TOKEN}" ] && [ -n "${WECHAT_WORK_TO}" ]; then
    cat >> "${CONFIG_DIR}/bot.conf" <<EOF

WECHAT_WORK_API=${WECHAT_WORK_API}
WECHAT_WORK_TOKEN=${WECHAT_WORK_TOKEN}
WECHAT_WORK_TO=${WECHAT_WORK_TO}
EOF
fi

# 3. 启动 Telegram Bot（后台）
python3 "${SCRIPT_DIR}/telegram_bot.py" &
BOT_PID=$!

# 4. 启动 Asterisk（前台，作为主进程）
asterisk -f -vvv
