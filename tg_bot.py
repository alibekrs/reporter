# -*- coding: utf-8 -*-
"""Телеграм-бот ITtool: записи в еженедельный отчёт — удалённо, из переписки.

Порядок работы:
    «Добавить запись» → отдел → сотрудник (или весь отдел) → коротко словами,
    что сделано → ИИ разворачивает заметку в «Описание обращения»,
    «Выполненные действия» и «Результат» (та же генерация, что у кнопки
    «Дополнить ИИ» в программе) → запись появляется в отчёте текущей недели →
    бот присылает результат с кнопками «Переделать», «Другой день», «Удалить».

Бот живёт в фоновом потоке службы ittool-bot (bot_service.py). Все изменения
отчёта идут через мост `ui` (reports.BotBridge): каждая правка — транзакция
в общей базе, поэтому бот и открытый ITtool не затирают записи друг друга.
"""
from __future__ import annotations

import datetime
import html
import re
import threading
import time

import db

API = "https://api.telegram.org/bot{token}/{method}"
POLL_TIMEOUT = 25
DAYS = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]


def _post(token: str, method: str, payload: dict, timeout: int = 35):
    import requests
    r = requests.post(API.format(token=token, method=method),
                      json=payload, timeout=timeout)
    return r.json()


def _get(token: str, method: str, params: dict, timeout: int = 35):
    import requests
    r = requests.get(API.format(token=token, method=method),
                     params=params, timeout=timeout)
    return r.json()


def esc(text) -> str:
    return html.escape(str(text or ""), quote=False)


def plural(n: int, one: str, few: str, many: str) -> str:
    """1 запись, 2 записи, 5 записей."""
    n = abs(int(n))
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


def default_day(today: datetime.date = None) -> tuple:
    """Дата записи: сегодня; в выходные — пятница этой недели."""
    today = today or datetime.date.today()
    if today.weekday() >= 5:
        return today - datetime.timedelta(days=today.weekday() - 4), True
    return today, False


def week_days(any_day: datetime.date) -> list:
    monday = any_day - datetime.timedelta(days=any_day.weekday())
    return [monday + datetime.timedelta(days=i) for i in range(5)]


class ReportBot:
    """Бот в фоновом потоке. `ui` — мост к отчёту (reports.BotBridge)."""

    def __init__(self, token: str, allowed: list = None, ui=None, on_log=None):
        self.token = (token or "").strip()
        self.allowed = {str(a).strip() for a in (allowed or []) if str(a).strip()}
        self.ui = ui
        self.on_log = on_log
        self._stop = threading.Event()
        self._thread = None
        self._state = {}            # chat_id → шаг диалога
        self._notes = {}            # uid записи → (заметка, сотрудник)
        self._mail_to = {}          # chat → разовый адрес получателя
        self._offset = 0

    # ── управление ──────────────────────────────────────────────────────────
    def start(self) -> bool:
        if not self.token or self.running:
            return False
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return True

    def stop(self):
        self._stop.set()

    @property
    def running(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    def check(self) -> tuple:
        try:
            data = _get(self.token, "getMe", {}, timeout=15)
            if data.get("ok"):
                return True, "@" + data["result"].get("username", "bot")
            return False, data.get("description", "неизвестная ошибка")
        except Exception as ex:
            return False, str(ex)

    def _log(self, msg):
        if callable(self.on_log):
            try:
                self.on_log(msg)
            except Exception:
                pass

    def _loop(self):
        self._log("Телеграм-бот запущен")
        fails = 0
        while not self._stop.is_set():
            try:
                data = _get(self.token, "getUpdates",
                            {"offset": self._offset, "timeout": POLL_TIMEOUT},
                            timeout=POLL_TIMEOUT + 10)
                fails = 0
                if not data.get("ok"):
                    time.sleep(3)
                    continue
                for upd in data.get("result", []):
                    self._offset = upd["update_id"] + 1
                    if self._stop.is_set():
                        break
                    try:
                        self._handle(upd)
                    except Exception as ex:
                        self._log(f"Бот: ошибка обработки — {ex}")
            except Exception:
                fails += 1
                time.sleep(min(30, 3 * fails))
        self._log("Телеграм-бот остановлен")

    # ── отправка ────────────────────────────────────────────────────────────
    def send(self, chat_id, text, keyboard=None, edit_id=None):
        payload = {"chat_id": chat_id, "text": text, "parse_mode": "HTML",
                   "disable_web_page_preview": True}
        if keyboard:
            payload["reply_markup"] = {"inline_keyboard": keyboard}
        method = "sendMessage"
        if edit_id:
            payload["message_id"] = edit_id
            method = "editMessageText"
        try:
            return _post(self.token, method, payload)
        except Exception as ex:
            self._log(f"Бот: не удалось отправить — {ex}")
            return {}

    def _allowed(self, chat_id) -> bool:
        return not self.allowed or str(chat_id) in self.allowed

    # ── разбор обновлений ───────────────────────────────────────────────────
    def _handle(self, upd: dict):
        if "callback_query" in upd:
            cq = upd["callback_query"]
            chat = cq["message"]["chat"]["id"]
            try:
                _post(self.token, "answerCallbackQuery",
                      {"callback_query_id": cq["id"]}, timeout=15)
            except Exception:
                pass
            if self._allowed(chat):
                self._on_button(chat, cq.get("data", ""),
                                cq["message"]["message_id"])
            return

        msg = upd.get("message") or {}
        chat = (msg.get("chat") or {}).get("id")
        text = (msg.get("text") or "").strip()
        if chat is None:
            return
        if not self._allowed(chat):
            self.send(chat, "Доступ не разрешён.\n"
                            f"Ваш ID: <code>{chat}</code> — добавьте его "
                            "в настройках ITtool.")
            return
        if text.startswith("/id"):
            self.send(chat, f"Ваш ID: <code>{chat}</code>")
            return
        if text.startswith("/start") or text.lower() == "меню":
            self._state.pop(chat, None)
            self._menu(chat)
            return
        st = self._state.get(chat)
        if st and st.get("step") == "text" and text:
            self._create(chat, text)
            return
        if st and st.get("step") == "email" and text:
            if re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", text):
                self._state.pop(chat, None)
                self._mail_to[chat] = text
                self._ask_mail(chat, st.get("offset", 0))
            else:
                self.send(chat, "Это не похоже на адрес почты. Пришлите адрес "
                                "вида <i>name@example.com</i>.",
                          [[{"text": "← Отмена", "callback_data": "menu"}]])
            return
        self._menu(chat)

    def _menu(self, chat, edit_id=None):
        self.send(chat, "<b>ITtool</b> · еженедельный отчёт\nЧто сделать?",
                  [[{"text": "➕ Добавить запись", "callback_data": "new"}],
                   [{"text": "📋 Записи за неделю", "callback_data": "week"}],
                   [{"text": "✉️ Отправить неделю на почту",
                     "callback_data": "mail:0"}]],
                  edit_id=edit_id)

    # ── кнопки ──────────────────────────────────────────────────────────────
    def _on_button(self, chat, data, msg_id):
        if data == "new":
            self._ask_dept(chat, msg_id)
        elif data == "week":
            self._show_week(chat, msg_id)
        elif data == "menu":
            self._state.pop(chat, None)
            self._menu(chat, msg_id)
        elif data.startswith("d:"):
            self._ask_emp(chat, data[2:], msg_id)
        elif data.startswith("e:"):
            emp = self._employee(data[2:])
            self._ask_text(chat, emp.get("name", ""), msg_id)
        elif data.startswith("dep:"):
            unit = next((d for d in db.departments() if d["id"] == data[4:]), {})
            self._ask_text(chat, unit.get("name", ""), msg_id)
        elif data == "free":
            self._ask_text(chat, "", msg_id)
        elif data.startswith("re:"):
            self._regenerate(chat, data[3:], msg_id)
        elif data.startswith("day:"):
            self._ask_day(chat, data[4:], msg_id)
        elif data.startswith("mv:"):
            _, uid, iso = data.split(":", 2)
            self._move(chat, uid, iso, msg_id)
        elif data.startswith("rm:"):
            self._remove(chat, data[3:], msg_id)
        elif data.startswith("show:"):
            self._report(chat, data[5:], edit_id=msg_id)
        elif data.startswith("mail:"):
            self._ask_mail(chat, int(data[5:]), msg_id)
        elif data.startswith("send:"):
            self._send_week(chat, int(data[5:]), msg_id)
        elif data.startswith("mailto:"):
            self._state[chat] = {"step": "email", "offset": int(data[7:])}
            self.send(chat, "Пришлите адрес, на который отправить отчёт:",
                      [[{"text": "← Отмена", "callback_data": "menu"}]],
                      edit_id=msg_id)

    # ── шаги ────────────────────────────────────────────────────────────────
    def _ask_dept(self, chat, msg_id=None):
        depts = db.departments()
        kb = [[{"text": d["name"][:60], "callback_data": "d:" + d["id"]}]
              for d in depts[:40]]
        kb.append([{"text": "✍️ Без отдела (объект, сервер…)",
                    "callback_data": "free"}])
        kb.append([{"text": "← Отмена", "callback_data": "menu"}])
        self.send(chat, "Выберите <b>подразделение</b>:", kb, edit_id=msg_id)

    def _employees(self, unit_id) -> list:
        store = db.get_assets_raw() or {}
        out = []
        for e in store.get("employees", []):
            if e.get("unit_id") == unit_id:
                name = " ".join(x for x in (e.get("last_name"),
                                            e.get("first_name")) if x).strip()
                if name:
                    out.append({"id": e.get("id"), "name": name})
        return sorted(out, key=lambda x: x["name"])

    def _employee(self, emp_id) -> dict:
        store = db.get_assets_raw() or {}
        for e in store.get("employees", []):
            if e.get("id") == emp_id:
                # как в отчёте: «Фамилия Имя»
                name = " ".join(x for x in (e.get("last_name"),
                                            e.get("first_name")) if x).strip()
                return {"id": emp_id, "name": name}
        return {}

    def _ask_emp(self, chat, unit_id, msg_id=None):
        emps = self._employees(unit_id)
        kb = [[{"text": e["name"][:60], "callback_data": "e:" + e["id"]}]
              for e in emps[:40]]
        kb.append([{"text": "🏢 Весь отдел", "callback_data": "dep:" + unit_id}])
        kb.append([{"text": "← Назад", "callback_data": "new"}])
        self.send(chat, "Выберите <b>сотрудника</b>:", kb, edit_id=msg_id)

    def _ask_text(self, chat, who: str, msg_id=None):
        self._state[chat] = {"step": "text", "employee": who}
        head = f"Сотрудник / объект: <b>{esc(who)}</b>\n\n" if who else ""
        self.send(chat,
                  head + "Напишите коротко, что было и что сделано. Например:\n"
                  "<i>не печатал принтер, переустановил драйвер</i>",
                  [[{"text": "← Отмена", "callback_data": "menu"}]],
                  edit_id=msg_id)

    # ── генерация ───────────────────────────────────────────────────────────
    def _expand(self, note: str, employee: str) -> tuple:
        """(поля записи, сделал ли это ИИ)."""
        fallback = {"description": note.strip(), "actions": "", "result": ""}
        try:
            cfg = self.ui.ai_config() or {}
        except Exception:
            cfg = {}
        if not (cfg.get("api_key") and cfg.get("base_url") and cfg.get("model")):
            return fallback, False
        try:
            import reports as mod_reports
            history = ""
            try:
                history = self.ui.history()
            except Exception:
                pass
            res = mod_reports.ai_expand(cfg, note, employee, history)
            fields = {k: (res.get(k) or "").strip()
                      for k in ("description", "actions", "result")}
            if not any(fields.values()):
                return fallback, False
            return fields, True
        except Exception as ex:
            self._log(f"Бот: ИИ недоступен — {ex}")
            return fallback, False

    def _create(self, chat, note: str):
        st = self._state.pop(chat, {}) or {}
        employee = st.get("employee", "")
        self.send(chat, "✨ Готовлю запись…")
        fields, by_ai = self._expand(note, employee)
        day, weekend = default_day()
        try:
            uid = self.ui.add_entry(day.isoformat(), employee, **fields)
        except Exception as ex:
            self.send(chat, f"Не удалось добавить запись: {esc(ex)}")
            return
        self._notes[uid] = (note, employee)
        self._log(f"Запись из Telegram: {employee or 'без сотрудника'}")
        extra = []
        if weekend:
            extra.append("Выходной — записано на пятницу, можно сменить день.")
        if not by_ai:
            extra.append("ИИ не настроен или недоступен — заметка взята как есть.")
        self._report(chat, uid, notes=extra)

    def _report(self, chat, uid, notes=None, edit_id=None):
        e = None
        try:
            e = self.ui.get_entry(uid)
        except Exception:
            pass
        if not e:
            self.send(chat, "Запись не найдена (возможно, удалена в программе).",
                      [[{"text": "➕ Добавить запись", "callback_data": "new"}]],
                      edit_id=edit_id)
            return
        d = datetime.date.fromisoformat(e["date"])
        tail = "".join(f"\n\n<i>{esc(n)}</i>" for n in (notes or []))
        self.send(
            chat,
            f"✅ Запись в отчёте · <b>{DAYS[d.weekday()]} {d:%d.%m.%Y}</b>\n\n"
            f"<b>Сотрудник / объект:</b> {esc(e.get('employee')) or '—'}\n\n"
            f"<b>Описание обращения:</b>\n{esc(e.get('description')) or '—'}\n\n"
            f"<b>Выполненные действия:</b>\n{esc(e.get('actions')) or '—'}\n\n"
            f"<b>Результат:</b>\n{esc(e.get('result')) or '—'}{tail}",
            [[{"text": "♻️ Переделать", "callback_data": f"re:{uid}"},
              {"text": "📅 Другой день", "callback_data": f"day:{uid}"}],
             [{"text": "🗑 Удалить", "callback_data": f"rm:{uid}"},
              {"text": "➕ Ещё запись", "callback_data": "new"}]],
            edit_id=edit_id)

    def _regenerate(self, chat, uid, msg_id):
        e = self.ui.get_entry(uid)
        if not e:
            self.send(chat, "Запись не найдена.", edit_id=msg_id)
            return
        note, employee = self._notes.get(
            uid, (e.get("description", ""), e.get("employee", "")))
        self.send(chat, "♻️ Переделываю…", edit_id=msg_id)
        fields, by_ai = self._expand(note, employee)
        if not by_ai:
            self._report(chat, uid, notes=["ИИ недоступен — текст не изменён."],
                         edit_id=msg_id)
            return
        self.ui.update_entry(uid, **fields)
        self._report(chat, uid, edit_id=msg_id)

    def _ask_day(self, chat, uid, msg_id):
        e = self.ui.get_entry(uid)
        if not e:
            self.send(chat, "Запись не найдена.", edit_id=msg_id)
            return
        cur = datetime.date.fromisoformat(e["date"])
        row = []
        for d in week_days(cur):
            mark = "• " if d == cur else ""
            row.append({"text": f"{mark}{DAYS[d.weekday()]} {d:%d.%m}",
                        "callback_data": f"mv:{uid}:{d.isoformat()}"})
        self.send(chat, "На какой день перенести запись?",
                  [row[:3], row[3:],
                   [{"text": "← Назад", "callback_data": f"show:{uid}"}]],
                  edit_id=msg_id)

    def _move(self, chat, uid, iso, msg_id):
        self.ui.update_entry(uid, date=iso)
        self._report(chat, uid, edit_id=msg_id)

    def _remove(self, chat, uid, msg_id):
        ok = self.ui.delete_entry(uid)
        self._notes.pop(uid, None)
        self.send(chat, "🗑 Запись удалена." if ok else "Запись не найдена.",
                  [[{"text": "➕ Добавить запись", "callback_data": "new"}]],
                  edit_id=msg_id)

    def _show_week(self, chat, msg_id=None):
        today = datetime.date.today()
        entries = self.ui.week_entries(today.isoformat())
        if not entries:
            self.send(chat, "За эту неделю записей нет.",
                      [[{"text": "➕ Добавить запись", "callback_data": "new"}]],
                      edit_id=msg_id)
            return
        lines, kb = [], []
        for e in sorted(entries, key=lambda x: x.get("date", "")):
            d = datetime.date.fromisoformat(e["date"])
            who = e.get("employee") or "—"
            what = (e.get("description") or "").strip()
            lines.append(f"<b>{DAYS[d.weekday()]}</b> · {esc(who)} — "
                         f"{esc(what[:60])}{'…' if len(what) > 60 else ''}")
            kb.append([{"text": f"{DAYS[d.weekday()]} · {who[:40]}",
                        "callback_data": f"show:{e['uid']}"}])
        kb.append([{"text": "➕ Добавить запись", "callback_data": "new"}])
        self.send(chat, f"<b>Записи за неделю</b> — {len(entries)} "
                  f"{plural(len(entries), 'запись', 'записи', 'записей')}\n\n"
                  + "\n".join(lines[:25]), kb[:30], edit_id=msg_id)


    # ── отправка отчёта на почту ────────────────────────────────────────────
    def _week_day(self, offset: int) -> str:
        return (datetime.date.today()
                + datetime.timedelta(weeks=offset)).isoformat()

    def _ask_mail(self, chat, offset=0, msg_id=None):
        to = self._mail_to.get(chat)
        try:
            info = self.ui.week_email(self._week_day(offset), to, False)
        except Exception as ex:
            self.send(chat, f"Не удалось проверить отчёт: {esc(ex)}", edit_id=msg_id)
            return
        other = ({"text": "⬅️ Прошлая неделя", "callback_data": "mail:-1"}
                 if offset == 0 else
                 {"text": "➡️ Текущая неделя", "callback_data": "mail:0"})
        if not info.get("ok"):
            self.send(chat, f"✉️ Неделя {esc(info.get('label', ''))}\n\n"
                            f"{esc(info.get('error', ''))}\n\n"
                            "<i>Реквизиты почты задаются в программе: Настройки → "
                            "«Почта (SMTP)».</i>",
                      [[other], [{"text": "← Меню", "callback_data": "menu"}]],
                      edit_id=msg_id)
            return
        self.send(chat,
                  f"✉️ Отправить отчёт за <b>{esc(info['label'])}</b>\n"
                  f"Записей: <b>{info['count']}</b>\n"
                  f"Кому: <b>{esc(info['to'])}</b>",
                  [[{"text": "✅ Отправить", "callback_data": f"send:{offset}"}],
                   [other, {"text": "✏️ Другой адрес",
                            "callback_data": f"mailto:{offset}"}],
                   [{"text": "← Меню", "callback_data": "menu"}]],
                  edit_id=msg_id)

    def _send_week(self, chat, offset, msg_id):
        to = self._mail_to.get(chat)
        try:
            info = self.ui.week_email(self._week_day(offset), to, True)
        except Exception as ex:
            self.send(chat, f"Не удалось подготовить отчёт: {esc(ex)}",
                      edit_id=msg_id)
            return
        if not info.get("ok"):
            self._ask_mail(chat, offset, msg_id)
            return
        self.send(chat, f"✉️ Отправляю отчёт за {esc(info['label'])}…",
                  edit_id=msg_id)
        import os
        try:
            import reports as mod_reports
            mod_reports.send_email(info["smtp"], info["to"], info["subject"],
                                   info["body"], info["path"])
        except Exception as ex:
            self.send(chat, f"❌ Не отправлено: {esc(ex)}\n\n<i>Проверьте реквизиты "
                            "почты в программе. Для Gmail нужен пароль приложения.</i>",
                      [[{"text": "🔁 Ещё раз", "callback_data": f"send:{offset}"}],
                       [{"text": "← Меню", "callback_data": "menu"}]])
            return
        finally:
            try:
                os.remove(info.get("path", ""))
            except Exception:
                pass
        self._mail_to.pop(chat, None)
        self._log(f"Отчёт за {info['label']} отправлен из Telegram")
        self.send(chat, f"✅ Отчёт за <b>{esc(info['label'])}</b> отправлен на "
                        f"<b>{esc(info['to'])}</b> — {info['count']} "
                        f"{plural(info['count'], 'запись', 'записи', 'записей')}.",
                  [[{"text": "← Меню", "callback_data": "menu"}]])


# совместимость со старым именем класса
PurchaseBot = ReportBot
