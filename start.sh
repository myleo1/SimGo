#!/bin/bash
set -e

TEMPLATE_DIR="/etc/asterisk/templates"
CONFIG_DIR="/etc/asterisk"
SCRIPT_DIR="/etc/asterisk/scripts"

# 1. 初始化目录和文件
mkdir -p /var/log/asterisk/cdr-csv
mkdir -p /var/spool/asterisk/monitor

# 录音格式（wav49 默认，可切换 ulaw）
REC_FORMAT="${REC_FORMAT:-wav49}"
# 自动录音总开关（setup.sh 配置，关闭时移除拨号计划中的录音区间）
RECORDING_ENABLED="${RECORDING_ENABLED:-yes}"

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
        -e "s|__REC_FORMAT__|${REC_FORMAT}|g" \
        "${CONFIG_DIR}/${dst}"
}

render_config pjsip.conf pjsip.conf
render_config extensions.conf extensions.conf
render_config extensions_custom.conf extensions_custom.conf
render_config quectel.conf quectel.conf
render_config modules.conf modules.conf
render_config rtp.conf rtp.conf

# 自动录音关闭时，删除拨号计划中的录音区间（含标记注释行）
if [ "${RECORDING_ENABLED}" != "yes" ]; then
    sed -i '/; SIMGO_REC_OUT_BEGIN/,/; SIMGO_REC_OUT_END/d' "${CONFIG_DIR}/extensions_custom.conf"
    sed -i '/; SIMGO_REC_IN_BEGIN/,/; SIMGO_REC_IN_END/d' "${CONFIG_DIR}/extensions_custom.conf"
fi

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
