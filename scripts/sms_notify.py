#!/usr/bin/env python3

import sys
import base64
import requests
import html
import os
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


def decode_sms(b64_content):
    try:
        b64_content = b64_content.strip()

        raw = base64.b64decode(
            b64_content
        )

        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            pass

        try:
            return raw.decode("utf-16")
        except UnicodeDecodeError:
            pass

        return raw.decode(
            "utf-8",
            errors="replace",
        )

    except Exception as e:
        return f"[短信解码失败: {e}]"


# ---------------------------------------------------------
# Telegram
# ---------------------------------------------------------

def send_telegram(
    config,
    cid,
    content,
    device,
):
    try:

        bot_token = config.get(
            "BOT_TOKEN"
        )

        chat_id = config.get(
            "CHAT_ID"
        )

        socks5_proxy = config.get(
            "SOCKS5_PROXY"
        )

        if not bot_token:
            raise ValueError(
                "BOT_TOKEN is not configured"
            )

        if not chat_id:
            raise ValueError(
                "CHAT_ID is not configured"
            )

        safe_device = html.escape(
            str(device)
        )

        safe_cid = html.escape(
            str(cid)
        )

        safe_content = html.escape(
            content
        )

        message = (
            "📩 <b>收到短信</b>\n\n"
            f"📱 <b>模块：</b>"
            f"<code>{safe_device}</code>\n"
            f"📱 <b>来自：</b>"
            f"<code>{safe_cid}</code>\n\n"
            f"💬 <b>内容：</b>\n"
            f"{safe_content}"
        )

        # Telegram 回复按钮
        reply_markup = {
            "inline_keyboard": [
                [
                    {
                        "text": "↩️ 回复",
                        "callback_data": (
                            f"reply:{device}:{cid}"
                        ),
                    }
                ]
            ]
        }

        url = (
            "https://api.telegram.org/"
            f"bot{bot_token}/sendMessage"
        )

        data = {
            "chat_id": chat_id,
            "text": message,
            "parse_mode": "HTML",
            "reply_markup": json.dumps(
                reply_markup,
                ensure_ascii=False,
            ),
        }

        proxies = None

        if socks5_proxy:
            proxies = {
                "http": socks5_proxy,
                "https": socks5_proxy,
            }

        response = requests.post(
            url,
            data=data,
            proxies=proxies,
            timeout=15,
        )

        response.raise_for_status()

        result = response.json()

        if not result.get("ok"):
            print(
                f"Telegram API returned error: {result}",
                file=sys.stderr,
                flush=True,
            )

            return False

        print(
            "Telegram notification sent",
            flush=True,
        )

        return True

    except Exception as e:

        print(
            f"Telegram notification failed: {e}",
            file=sys.stderr,
            flush=True,
        )

        return False


# ---------------------------------------------------------
# 企业微信
# ---------------------------------------------------------

def send_wechat(
    config,
    cid,
    content,
    device,
):
    api = config.get("WECHAT_WORK_API")
    token = config.get("WECHAT_WORK_TOKEN")
    to = config.get("WECHAT_WORK_TO")

    if not api or not token or not to:
        return None

    # 跳过未替换的占位符值
    if any("__" in v for v in [api, token, to]):
        return None

    try:

        # 企业微信通知使用纯文本
        message = (
            "📩 收到短信\n\n"
            f"📱 模块：{device}\n"
            f"📱 来自：{cid}\n\n"
            f"💬 内容：\n{content}"
        )

        headers = {
            "Cookie": f"session={token}",
        }

        data = {
            "to": to,
            "content": message,
        }

        response = requests.post(
            api,
            headers=headers,
            data=data,
            timeout=15,
        )

        response.raise_for_status()

        print(
            "WeChat Work notification sent",
            flush=True,
        )

        return True

    except Exception as e:

        print(
            f"WeChat Work notification failed: {e}",
            file=sys.stderr,
            flush=True,
        )

        return False


# ---------------------------------------------------------
# 双通道通知
# ---------------------------------------------------------

def send_notification(
    cid,
    b64_content,
    device,
):
    try:

        config = load_config()

        content = decode_sms(
            b64_content
        )

        # -------------------------------------------------
        # Telegram
        # -------------------------------------------------

        telegram_ok = send_telegram(
            config,
            cid,
            content,
            device,
        )

        # -------------------------------------------------
        # 企业微信
        # -------------------------------------------------

        wechat_ok = send_wechat(
            config,
            cid,
            content,
            device,
        )

        # -------------------------------------------------
        # 最终结果
        # -------------------------------------------------

        results = []
        if telegram_ok:
            results.append("Telegram=True")
        if wechat_ok is True:
            results.append("WeChat=True")
        if wechat_ok is None:
            results.append("WeChat=skipped")

        if telegram_ok or wechat_ok is True:

            print(
                "SMS notification delivered "
                f"({', '.join(results)})",
                flush=True,
            )

            return True

        print(
            "SMS notification failed on all channels",
            file=sys.stderr,
            flush=True,
        )

        return False

    except Exception as e:

        print(
            f"SMS notification failed: {e}",
            file=sys.stderr,
            flush=True,
        )

        return False


# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

if __name__ == "__main__":

    if len(sys.argv) < 4:

        print(
            f"Usage: {sys.argv[0]} "
            "<caller_id> <base64_message> <device>",
            file=sys.stderr,
        )

        sys.exit(1)

    caller_id = sys.argv[1]

    msg_base64 = sys.argv[2]

    device = sys.argv[3]

    success = send_notification(
        caller_id,
        msg_base64,
        device,
    )

    sys.exit(
        0 if success else 1
    )
