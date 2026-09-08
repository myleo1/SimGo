#!/usr/bin/env python3

import os
import re
import time
import subprocess
import requests
import json

CONFIG_FILE = "/etc/asterisk/bot.conf"


def load_config():
    config = {}

    if not os.path.exists(CONFIG_FILE):
        raise FileNotFoundError(
            f"Config file not found: {CONFIG_FILE}"
        )

    with open(CONFIG_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()

            if not line or line.startswith("#"):
                continue

            if "=" not in line:
                continue

            key, value = line.split("=", 1)
            config[key.strip()] = value.strip()

    return config


config = load_config()

BOT_TOKEN = config.get("BOT_TOKEN")
ALLOWED_CHAT_ID = str(config.get("CHAT_ID", ""))
SOCKS5_PROXY = config.get("SOCKS5_PROXY")

if not BOT_TOKEN:
    raise RuntimeError("BOT_TOKEN is not configured")

if not ALLOWED_CHAT_ID:
    raise RuntimeError("CHAT_ID is not configured")


TELEGRAM_API = (
    f"https://api.telegram.org/bot{BOT_TOKEN}"
)


# ---------------------------------------------------------
# Telegram API
# ---------------------------------------------------------

def telegram_request(method, data=None):
    proxies = None

    if SOCKS5_PROXY:
        proxies = {
            "http": SOCKS5_PROXY,
            "https": SOCKS5_PROXY,
        }

    response = requests.post(
        f"{TELEGRAM_API}/{method}",
        data=data,
        proxies=proxies,
        timeout=60,
    )

    response.raise_for_status()

    result = response.json()

    if not result.get("ok"):
        raise RuntimeError(str(result))

    return result


def send_message(chat_id, text, reply_markup=None):
    data = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
    }

    if reply_markup is not None:
        data["reply_markup"] = json.dumps(
            reply_markup,
            ensure_ascii=False,
        )

    telegram_request(
        "sendMessage",
        data,
    )

def set_bot_commands():

    commands = [
        {
            "command": "start",
            "description": "启动 EC20 短信网关",
        },
        {
            "command": "help",
            "description": "查看帮助",
        },
        {
            "command": "send",
            "description": "发送短信",
        },
    ]

    try:

        result = telegram_request(
            "setMyCommands",
            {
                "commands": json.dumps(
                    commands,
                    ensure_ascii=False,
                ),
            },
        )

        print(
            "Telegram Bot commands registered",
            flush=True,
        )

    except Exception as e:

        print(
            f"Failed to register Telegram Bot commands: {e}",
            flush=True,
        )

def answer_callback(callback_id):
    try:
        telegram_request(
            "answerCallbackQuery",
            {
                "callback_query_id": callback_id,
            },
        )
    except Exception as e:
        print(
            f"answerCallbackQuery failed: {e}",
            flush=True,
        )


# ---------------------------------------------------------
# Asterisk
# ---------------------------------------------------------

def asterisk_cli(command):
    result = subprocess.run(
        [
            "asterisk",
            "-rx",
            command,
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )

    output = (
        result.stdout +
        result.stderr
    ).strip()

    return result.returncode == 0, output


def get_devices():
    """
    动态获取 Asterisk 当前所有 quectelX 设备。
    不写死 quectel0。
    """

    success, output = asterisk_cli(
        "quectel show devices"
    )

    if not success:
        print(
            f"Failed to get devices: {output}",
            flush=True,
        )
        return []

    devices = set()

    # 从输出中提取 quectel0 / quectel1 / quectel2 ...
    for match in re.findall(
        r"\bquectel[0-9]+\b",
        output,
        re.IGNORECASE,
    ):
        devices.add(match)

    def device_sort_key(name):
        match = re.search(
            r"(\d+)$",
            name,
        )

        if match:
            return int(match.group(1))

        return 999999

    return sorted(
        devices,
        key=device_sort_key,
    )


def get_device_state(device):
    success, output = asterisk_cli(
        f"quectel show device state {device}"
    )

    if not success:
        return None

    return output


def get_device_info(device):
    output = get_device_state(device)

    if not output:
        return None

    info = {}

    for line in output.splitlines():

        if ":" not in line:
            continue

        key, value = line.split(
            ":",
            1,
        )

        key = key.strip()
        value = value.strip()

        if key:
            info[key] = value

    return info


def restart_device(device):
    return asterisk_cli(
        f"quectel cmd {device} AT+CFUN=1,1"

    )


def send_sms(device, phone, message):

    # 防止换行破坏 CLI 参数
    message = message.replace(
        "\r",
        " ",
    )
    message = message.replace(
        "\n",
        " ",
    )

    # 转义 shell/CLI 中的特殊字符
    message = message.replace(
        "\\",
        "\\\\",
    )
    message = message.replace(
        '"',
        '\\"',
    )

    command = (
        f'quectel sms {device} '
        f'{phone} "{message}"'
    )

    return asterisk_cli(command)


# ---------------------------------------------------------
# UI
# ---------------------------------------------------------

def main_menu():
    return {
        "inline_keyboard": [
            [
                {
                    "text": "✉️ 发送短信",
                    "callback_data": "send_sms",
                }
            ],
            [
                {
                    "text": "📊 模块状态",
                    "callback_data": "device_status",
                },
                {
                    "text": "🔄 重启模块",
                    "callback_data": "device_restart",
                },
            ],
        ]
    }


def device_keyboard(
    action,
    devices,
):
    keyboard = []

    for device in devices:
        keyboard.append(
            [
                {
                    "text": f"📱 {device}",
                    "callback_data": (
                        f"{action}:{device}"
                    ),
                }
            ]
        )

    keyboard.append(
        [
            {
                "text": "⬅️ 返回",
                "callback_data": "main_menu",
            }
        ]
    )

    return {
        "inline_keyboard": keyboard
    }


def restart_confirm_keyboard(device):
    return {
        "inline_keyboard": [
            [
                {
                    "text": "✅ 确认重启",
                    "callback_data": (
                        f"restart_confirm:{device}"
                    ),
                }
            ],
            [
                {
                    "text": "❌ 取消",
                    "callback_data": "main_menu",
                }
            ],
        ]
    }


# ---------------------------------------------------------
# Conversation state
# ---------------------------------------------------------

# 一个聊天只有一个发送流程即可。
#
# 例如：
# {
#     "action": "send_sms",
#     "device": "quectel1",
#     "phone": "13800138000"
# }
USER_STATE = {}


def clear_state(chat_id):
    USER_STATE.pop(
        str(chat_id),
        None,
    )


# ---------------------------------------------------------
# SMS workflow
# ---------------------------------------------------------

def start_send_sms(chat_id):

    devices = get_devices()

    if not devices:
        send_message(
            chat_id,
            "❌ <b>没有发现 Quectel 模块</b>",
        )
        return

    send_message(
        chat_id,
        "📱 <b>选择发送短信的模块</b>",
        device_keyboard(
            "select_send",
            devices,
        ),
    )


def ask_phone(chat_id, device):

    USER_STATE[str(chat_id)] = {
        "action": "send_sms",
        "device": device,
    }

    send_message(
        chat_id,
        "✉️ <b>发送短信</b>\n\n"
        f"📱 <b>模块：</b><code>{device}</code>\n\n"
        "请输入手机号码：",
        {
            "inline_keyboard": [
                [
                    {
                        "text": "❌ 取消",
                        "callback_data": "cancel_sms",
                    }
                ]
            ]
        },
    )

def ask_sms_content(chat_id, phone):

    state = USER_STATE.get(
        str(chat_id)
    )

    if not state:
        send_message(
            chat_id,
            "❌ 操作已过期，请重新开始。",
        )
        return

    state["phone"] = phone

    send_message(
        chat_id,
        "✉️ <b>发送短信</b>\n\n"
        f"📱 <b>模块：</b>"
        f"<code>{state['device']}</code>\n"
        f"📞 <b>号码：</b>"
        f"<code>{phone}</code>\n\n"
        "请输入短信内容：",
        {
            "inline_keyboard": [
                [
                    {
                        "text": "❌ 取消",
                        "callback_data": "cancel_sms",
                    }
                ]
            ]
        },
    )


def process_sms_content(chat_id, message):

    state = USER_STATE.get(
        str(chat_id)
    )

    if not state:
        send_message(
            chat_id,
            "❌ 操作已过期，请重新开始。",
        )
        return

    device = state["device"]
    phone = state["phone"]

    if not message.strip():
        send_message(
            chat_id,
            "❌ 短信内容不能为空。",
        )
        return

    print(
        f"Sending SMS via {device} "
        f"to {phone}: {message}",
        flush=True,
    )

    try:
        success, output = send_sms(
            device,
            phone,
            message,
        )

        if success:
            send_message(
                chat_id,
                "✅ <b>短信已发送</b>\n\n"
                f"📱 <b>模块：</b>"
                f"<code>{device}</code>\n"
                f"📞 <b>号码：</b>"
                f"<code>{phone}</code>\n\n"
                f"💬 <b>内容：</b>\n"
                f"{message}",
            )
        else:
            send_message(
                chat_id,
                "❌ <b>短信发送失败</b>\n\n"
                f"📱 <b>模块：</b>"
                f"<code>{device}</code>\n"
                f"📞 <b>号码：</b>"
                f"<code>{phone}</code>\n\n"
                f"💬 <b>内容：</b>\n"
                f"{message}\n\n"
                f"<b>Asterisk：</b>\n"
                f"<code>{output}</code>",
            )

    except Exception as e:
        send_message(
            chat_id,
            "❌ <b>短信发送异常</b>\n\n"
            f"<code>{e}</code>",
        )

    clear_state(chat_id)


# ---------------------------------------------------------
# Device status
# ---------------------------------------------------------

def show_device_status(chat_id, device):

    info = get_device_info(device)

    if not info:
        send_message(
            chat_id,
            "❌ <b>无法获取模块状态</b>\n\n"
            f"模块：<code>{device}</code>",
        )
        return

    state = info.get(
        "State",
        "Unknown",
    )

    registration = info.get(
        "GSM Registration Status",
        "Unknown",
    )

    rssi = info.get(
        "RSSI",
        "Unknown",
    )

    provider = info.get(
        "Provider Name",
        "Unknown",
    )

    model = info.get(
        "Model",
        "Unknown",
    )

    firmware = info.get(
        "Firmware",
        "Unknown",
    )

    voice = info.get(
        "Voice",
        "Unknown",
    )

    sms = info.get(
        "SMS",
        "Unknown",
    )

    queue = info.get(
        "Tasks in queue",
        "0",
    )

    calls = info.get(
        "Calls/Channels",
        "0",
    )

    # RSSI:
    # "24, -65 dBm"
    if "," in rssi:
        rssi_text = rssi
    else:
        rssi_text = rssi

    # 简单根据状态显示图标
    if state.lower() == "free":
        state_icon = "🟢"
    else:
        state_icon = "🟡"

    if (
        "registered" in
        registration.lower()
    ):
        reg_icon = "🟢"
    else:
        reg_icon = "🔴"

    message = (
        "📊 <b>EC20 模块状态</b>\n\n"
        f"📱 <b>模块：</b>"
        f"<code>{device}</code>\n\n"

        f"{state_icon} <b>设备：</b>"
        f"{state}\n\n"

        f"{reg_icon} <b>注册：</b>"
        f"{registration}\n\n"

        f"📶 <b>信号：</b>"
        f"{rssi_text}\n\n"

        f"📡 <b>运营商：</b>"
        f"{provider}\n\n"

        f"📱 <b>型号：</b>"
        f"{model}\n\n"

        f"🔧 <b>固件：</b>"
        f"{firmware}\n\n"

        f"📞 <b>语音：</b>"
        f"{voice}\n\n"

        f"📨 <b>短信：</b>"
        f"{sms}\n\n"

        f"📋 <b>任务队列：</b>"
        f"{queue}\n\n"

        f"📞 <b>通话：</b>"
        f"{calls}"
    )

    send_message(
        chat_id,
        message,
    )


# ---------------------------------------------------------
# Device restart
# ---------------------------------------------------------

def confirm_restart(chat_id, device):

    info = get_device_info(device)

    state = "Unknown"

    if info:
        state = info.get(
            "State",
            "Unknown",
        )

    send_message(
        chat_id,
        "⚠️ <b>确认重启模块？</b>\n\n"
        f"📱 <b>模块：</b>"
        f"<code>{device}</code>\n"
        f"📊 <b>当前状态：</b>"
        f"{state}\n\n"
        "🔄 重启方式："
        "<b>AT+CFUN=1,1</b>\n\n"
        "确认后 Asterisk 将对该模块执行AT+CFUN=1,1重启。",
        restart_confirm_keyboard(device),
    )


def do_restart(chat_id, device):

    send_message(
        chat_id,
        "🔄 <b>正在重启模块...</b>\n\n"
        f"📱 模块：<code>{device}</code>",
    )

    try:
        success, output = restart_device(
            device
        )

        if success:
            send_message(
                chat_id,
                "✅ <b>重启命令已执行</b>\n\n"
                f"📱 模块：<code>{device}</code>\n\n"
                "Asterisk 已执行：\n"
                f"<code>quectel cmd "
                f"{device} AT+CFUN=1,1</code>",
            )
        else:
            send_message(
                chat_id,
                "❌ <b>重启失败</b>\n\n"
                f"📱 模块：<code>{device}</code>\n\n"
                f"<code>{output}</code>",
            )

    except Exception as e:
        send_message(
            chat_id,
            "❌ <b>重启异常</b>\n\n"
            f"<code>{e}</code>",
        )


# ---------------------------------------------------------
# Callback handlers
# ---------------------------------------------------------

def handle_callback(update):

    callback = update.get(
        "callback_query"
    )

    if not callback:
        return

    callback_id = callback.get(
        "id"
    )

    data = callback.get(
        "data",
        "",
    )

    message = callback.get(
        "message",
        {},
    )

    chat = message.get(
        "chat",
        {},
    )

    chat_id = str(
        chat.get("id", "")
    )

    if chat_id != ALLOWED_CHAT_ID:
        answer_callback(callback_id)
        return

    answer_callback(callback_id)

    # -------------------------
    # 主菜单
    # -------------------------

    if data == "main_menu":

        clear_state(chat_id)

        send_message(
            chat_id,
            "📱 <b>EC20 短信网关</b>\n\n"
            "请选择操作：",
            main_menu(),
        )

        return

    # -------------------------
    # 发送短信
    # -------------------------

    if data == "send_sms":

        clear_state(chat_id)

        start_send_sms(
            chat_id
        )

        return

    # -------------------------
    # /send 选择模块
    # -------------------------

    if data.startswith(
        "command_send:"
    ):

        device = data.split(
            ":",
            1,
        )[1]

        if device not in get_devices():
            send_message(
                chat_id,
                "❌ <b>模块不存在或已经离线。</b>",
            )
            clear_state(chat_id)
            return

        state = USER_STATE.get(
            chat_id
        )

        if (
            not state
            or state.get("action") != "command_send"
        ):
            send_message(
                chat_id,
                "❌ 操作已过期，请重新执行 /send。",
            )
            return

        phone = state["phone"]
        message = state["message"]

        print(
            f"Sending SMS via {device} "
            f"to {phone}: {message}",
            flush=True,
        )

        try:

            success, output = send_sms(
                device,
                phone,
                message,
            )

            if success:

                send_message(
                    chat_id,
                    "✅ <b>短信已发送</b>\n\n"
                    f"📱 <b>模块：</b>"
                    f"<code>{device}</code>\n"
                    f"📞 <b>号码：</b>"
                    f"<code>{phone}</code>\n\n"
                    f"💬 <b>内容：</b>\n{message}",
                )

            else:

                send_message(
                    chat_id,
                    "❌ <b>短信发送失败</b>\n\n"
                    f"📱 <b>模块：</b>"
                    f"<code>{device}</code>\n"
                    f"📞 <b>号码：</b>"
                    f"<code>{phone}</code>\n\n"
                    f"<b>Asterisk：</b>\n"
                    f"<code>{output}</code>",
                )

        except Exception as e:

            send_message(
                chat_id,
                "❌ <b>发送异常</b>\n\n"
                f"<code>{e}</code>",
            )

        clear_state(chat_id)

        return

    # -------------------------
    # 选择发送短信模块
    # -------------------------

    if data.startswith(
        "select_send:"
    ):

        device = data.split(
            ":",
            1,
        )[1]

        # 防止用户伪造 callback_data
        if device not in get_devices():

            send_message(
                chat_id,
                "❌ <b>模块不存在或已经离线。</b>",
            )

            return

        ask_phone(
            chat_id,
            device,
        )

        return

    # -------------------------
    # 查看状态
    # -------------------------

    if data == "device_status":

        devices = get_devices()

        if not devices:

            send_message(
                chat_id,
                "❌ <b>没有发现 Quectel 模块</b>",
            )

            return

        send_message(
            chat_id,
            "📊 <b>选择要查看的模块</b>",
            device_keyboard(
                "status",
                devices,
            ),
        )

        return

    # -------------------------
    # 查看指定模块状态
    # -------------------------

    if data.startswith("status:"):

        device = data.split(
            ":",
            1,
        )[1]

        # 防止用户伪造 callback_data
        if device not in get_devices():

            send_message(
                chat_id,
                "❌ <b>模块不存在或已经离线。</b>\n\n"
                f"模块：<code>{device}</code>",
            )

            return

        show_device_status(
            chat_id,
            device,
        )

        return

    # -------------------------
    # 重启模块
    # -------------------------

    if data == "device_restart":

        devices = get_devices()

        if not devices:
            send_message(
                chat_id,
                "❌ <b>没有发现 Quectel 模块</b>",
            )
            return

        send_message(
            chat_id,
            "🔄 <b>选择要重启的模块</b>",
            device_keyboard(
                "restart",
                devices,
            ),
        )

        return

    if data.startswith(
        "restart:"
    ):

        device = data.split(
            ":",
            1,
        )[1]

        if device not in get_devices():
            send_message(
                chat_id,
                "❌ <b>模块不存在或已经离线。</b>",
            )
            return

        confirm_restart(
            chat_id,
            device,
        )

        return

    if data.startswith(
        "restart_confirm:"
    ):

        device = data.split(
            ":",
            1,
        )[1]

        if device not in get_devices():
            send_message(
                chat_id,
                "❌ <b>模块不存在或已经离线。</b>",
            )
            return

        do_restart(
            chat_id,
            device,
        )

        return

    # -------------------------
    # 回复短信
    # -------------------------

    if data.startswith("reply:"):

        parts = data.split(
            ":",
            2,
        )

        if len(parts) != 3:

            send_message(
                chat_id,
                "❌ 回复信息无效。",
            )

            return

        device = parts[1]
        phone = parts[2]

        if device not in get_devices():

            send_message(
                chat_id,
                "❌ <b>原短信所在模块已经不存在。</b>\n\n"
                f"模块：<code>{device}</code>",
            )

            return

        USER_STATE[chat_id] = {
            "action": "reply_sms",
            "device": device,
            "phone": phone,
        }

        send_message(
            chat_id,
            "↩️ <b>回复短信</b>\n\n"
            f"📱 <b>模块：</b>"
            f"<code>{device}</code>\n"
            f"📱 <b>号码：</b>"
            f"<code>{phone}</code>\n\n"
            "请输入短信内容：",
            {
                "inline_keyboard": [
                    [
                        {
                            "text": "❌ 取消",
                            "callback_data": "cancel_sms",
                        }
                    ]
                ]
            },
        )

        return

    # -------------------------
    # 取消短信操作
    # -------------------------

    if data == "cancel_sms":

        clear_state(chat_id)

        send_message(
            chat_id,
            "❌ <b>已取消短信操作。</b>",
            main_menu(),
        )

        return
# ---------------------------------------------------------
# Text messages
# ---------------------------------------------------------

def handle_message(update):

    message = update.get(
        "message"
    )

    if not message:
        return

    chat = message.get(
        "chat",
        {},
    )

    chat_id = str(
        chat.get("id", "")
    )

    if chat_id != ALLOWED_CHAT_ID:
        return

    text = message.get(
        "text",
        "",
    )

    if not text:
        return

    text = text.strip()

    # -------------------------
    # /start
    # -------------------------

    if text == "/start":

        clear_state(chat_id)

        send_message(
            chat_id,
            "📱 <b>EC20 短信网关</b>\n\n"
            "请选择操作：",
            main_menu(),
        )

        return

    # -------------------------
    # /help
    # -------------------------

    if text == "/help":

        send_message(
            chat_id,
            "📱 <b>EC20 短信网关</b>\n\n"
            "可以通过下面的按钮进行操作：\n\n"
            "✉️ 发送短信\n"
            "📊 查看模块状态\n"
            "🔄 重启指定模块",
            main_menu(),
        )

        return

    # -------------------------
    # 保留原来的 /send
    # -------------------------

    if text.startswith(
        "/send"
    ):

        parts = text.split(
            maxsplit=2
        )

        if len(parts) < 3:
            send_message(
                chat_id,
                "❌ <b>格式错误</b>\n\n"
                "正确格式：\n"
                "<code>/send 手机号 短信内容</code>\n\n"
                "例如：\n"
                "<code>/send 10086 你好</code>",
            )
            return

        phone = parts[1].strip()
        sms_text = parts[2].strip()

        if not phone:
            send_message(
                chat_id,
                "❌ 号码不能为空",
            )
            return

        # 保持你现在的宽松校验
        if len(phone) > 30:
            send_message(
                chat_id,
                "❌ 号码过长",
            )
            return

        if not sms_text:
            send_message(
                chat_id,
                "❌ 短信内容不能为空",
            )
            return

        devices = get_devices()

        if not devices:
            send_message(
                chat_id,
                "❌ <b>没有发现 Quectel 模块</b>",
            )
            return

        # /send 也改成选择模块
        USER_STATE[chat_id] = {
            "action": "command_send",
            "phone": phone,
            "message": sms_text,
        }

        send_message(
            chat_id,
            "📱 <b>选择发送短信的模块</b>\n\n"
            f"📞 号码：<code>{phone}</code>\n"
            f"💬 内容：\n{sms_text}",
            device_keyboard(
                "command_send",
                devices,
            ),
        )

        return

    # -------------------------
    # 处理 /send 的模块选择
    # -------------------------

    state = USER_STATE.get(
        chat_id
    )

    if state:

        if state.get("action") == "send_sms":

            # 第一步：还没有手机号
            if "phone" not in state:

                phone = text.strip()

                if not phone:
                    send_message(
                        chat_id,
                        "❌ 手机号码不能为空。",
                    )
                    return

                if len(phone) > 30:
                    send_message(
                        chat_id,
                        "❌ 手机号码过长。",
                    )
                    return

                ask_sms_content(
                    chat_id,
                    phone,
                )

                return

            # 第二步：已经有手机号，现在输入短信内容
            process_sms_content(
                chat_id,
                text,
            )

            return

        if state.get("action") == "reply_sms":

            device = state["device"]
            phone = state["phone"]

            if not text:
                send_message(
                    chat_id,
                    "❌ 短信内容不能为空。",
                )
                return

            try:
                success, output = send_sms(
                    device,
                    phone,
                    text,
                )

                if success:
                    send_message(
                        chat_id,
                        "✅ <b>回复短信已发送</b>\n\n"
                        f"📱 <b>模块：</b>"
                        f"<code>{device}</code>\n"
                        f"📞 <b>号码：</b>"
                        f"<code>{phone}</code>\n\n"
                        f"💬 <b>内容：</b>\n{text}",
                    )
                else:
                    send_message(
                        chat_id,
                        "❌ <b>回复短信发送失败</b>\n\n"
                        f"<code>{output}</code>",
                    )

            except Exception as e:
                send_message(
                    chat_id,
                    "❌ <b>发送异常</b>\n\n"
                    f"<code>{e}</code>",
                )

            clear_state(chat_id)
            return


def handle_update(update):

    if update.get(
        "callback_query"
    ):
        handle_callback(update)
        return

    if update.get(
        "message"
    ):
        handle_message(update)
        return


# ---------------------------------------------------------
# Main loop
# ---------------------------------------------------------

def main():

    set_bot_commands()

    print(
        "Telegram SMS bot started",
        flush=True,
    )

    offset = None

    while True:

        try:

            data = {}

            if offset is not None:
                data["offset"] = offset

            data["timeout"] = 30

            result = telegram_request(
                "getUpdates",
                data,
            )

            updates = result.get(
                "result",
                [],
            )

            for update in updates:

                offset = (
                    update["update_id"] + 1
                )

                try:
                    handle_update(
                        update
                    )

                except Exception as e:
                    print(
                        f"Error handling update: {e}",
                        flush=True,
                    )

        except Exception as e:

            print(
                f"Telegram polling error: {e}",
                flush=True,
            )

            time.sleep(5)


if __name__ == "__main__":
    main()
