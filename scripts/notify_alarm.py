#!/usr/bin/env python3
"""SimGo watchdog alarm notifier (container-side CLI).

Reads /etc/asterisk/bot.conf (rendered by start.sh, contains TG_* and
WECHAT_WORK_*) and delivers a message through Telegram (HTML) and/or
WeChat Work (plain text, session-cookie API).

Usage: notify_alarm.py "<title>" "<body>"
Exit 0 if at least one channel succeeded, non-zero otherwise.
"""

import html
import sys

import requests

CONFIG_FILE = "/etc/asterisk/bot.conf"
TELEGRAM_API = "https://api.telegram.org/bot"


def load_config():
    config = {}
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip()
    except OSError as e:
        print(f"config error: {e}", file=sys.stderr)
    return config


def _unconfigured(value):
    return not value or "__" in value


def send_telegram(config, title, body):
    token = config.get("BOT_TOKEN")
    chat_id = config.get("CHAT_ID")
    if _unconfigured(token) or _unconfigured(chat_id):
        return False

    socks5 = config.get("SOCKS5_PROXY")
    proxies = {"http": socks5, "https": socks5} if not _unconfigured(socks5) else None

    text = "🔧 <b>{}</b>\n\n{}".format(
        html.escape(title), html.escape(body)
    )
    response = requests.post(
        f"{TELEGRAM_API}{token}/sendMessage",
        data={
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "HTML",
        },
        proxies=proxies,
        timeout=30,
    )
    response.raise_for_status()
    return response.json().get("ok", False)


def send_wechat(config, title, body):
    api = config.get("WECHAT_WORK_API")
    token = config.get("WECHAT_WORK_TOKEN")
    to = config.get("WECHAT_WORK_TO")
    if _unconfigured(api) or _unconfigured(token) or _unconfigured(to):
        return False

    content = f"🔧 {title}\n\n{body}"
    response = requests.post(
        api,
        headers={"Cookie": f"session={token}"},
        data={"to": to, "content": content},
        timeout=15,
    )
    response.raise_for_status()
    return True


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <title> <body>", file=sys.stderr)
        return 2

    title, body = sys.argv[1], sys.argv[2]
    config = load_config()

    ok_tg = False
    ok_wx = False
    try:
        ok_tg = bool(send_telegram(config, title, body))
    except Exception as e:
        print(f"telegram channel failed: {e}", file=sys.stderr)
    try:
        ok_wx = bool(send_wechat(config, title, body))
    except Exception as e:
        print(f"wechat channel failed: {e}", file=sys.stderr)

    if ok_tg or ok_wx:
        return 0

    print("all notification channels failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())