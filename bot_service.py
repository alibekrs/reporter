# -*- coding: utf-8 -*-
"""ITtool: телеграм-бот отдельной службой (systemd --user, ittool-bot.service).

Бот пишет в ту же базу, что и интерфейс, — каждая правка одной транзакцией.
Раз в минуту перечитывает настройки: включили, выключили, сменили токен или
список разрешённых — подхватывает без перезапуска службы.
"""
from __future__ import annotations

import signal
import sys
import threading
import time

import db
import reports
import tg_bot

CHECK_EVERY = 60
_LOG = threading.Lock()


def log(msg):
    with _LOG:                       # бот пишет из своего потока
        print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def main():
    stop = {"now": False}

    def on_term(*_a):
        stop["now"] = True
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    bot, current = None, None
    while not stop["now"]:
        cfg = db.get_tg_config()
        want = (cfg["token"], tuple(cfg["allowed"])) if cfg["enabled"] and cfg["token"] else None
        if want != current or (bot is not None and not bot.running):
            if bot is not None:
                bot.stop()
                bot = None
            if want:
                bot = tg_bot.ReportBot(want[0], list(want[1]), ui=reports.BotBridge(), on_log=log)
                bot.start()
                log(f"Бот запущен, разрешённых чатов: {len(want[1]) or 'все'}")
            elif current:
                log("Бот выключен в настройках")
            current = want
        for _ in range(CHECK_EVERY):
            if stop["now"]:
                break
            time.sleep(1)
    if bot is not None:
        bot.stop()
    log("Служба остановлена")
    return 0


if __name__ == "__main__":
    sys.exit(main())
