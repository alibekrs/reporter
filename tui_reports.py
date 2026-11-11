# -*- coding: utf-8 -*-
"""ITtool в терминале: «Отчёт» — неделя записей, Word, почта, ИИ."""
from __future__ import annotations

from datetime import date, timedelta

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, Checkbox, DataTable, Input, Label, Select, Static, TextArea

import reports as mr
import settings
from tui_common import (Confirm, Form, MonthPick, TextView, busy, guard, keys, options,
                        scroll_box, suggest)

DAYS = ["Пн", "Вт", "Ср", "Чт", "Пт"]


class EntryEdit(Form):
    """Запись отчёта. Строка «Заметка для ИИ» + Ctrl+E — ИИ заполнит три поля."""

    BINDINGS = [Binding("ctrl+e", "ai", "Дополнить ИИ", priority=True)]
    DEFAULT_CSS = "EntryEdit TextArea { height: 4; }"

    def __init__(self, monday, entry=None, day=None):
        super().__init__()
        self.monday, self.entry = monday, entry or {}
        self.day = entry["date"] if entry else (day or monday).isoformat()
        self.data = mr.load_data()

    def compose(self) -> ComposeResult:
        e = self.entry
        days = [(f"{DAYS[i]} {self.monday + timedelta(days=i):%d.%m}",
                 (self.monday + timedelta(days=i)).isoformat()) for i in range(5)]
        if self.day not in [v for _l, v in days]:
            days.append((self.day, self.day))
        yield scroll_box(
            Label("Изменить запись" if e else "Новая запись", classes="title"),
            self.field("День", Select(days, value=self.day, allow_blank=False, id="date")),
            self.field("Сотрудник / объект",
                       Input(e.get("employee", ""), id="employee",
                             suggester=suggest(mr.candidates(self.data, "employee")[:400]))),
            self.field("Заметка для ИИ (Ctrl+E — заполнить три поля ниже)",
                       Input(placeholder="например: не печатал принтер у бухгалтера, "
                                         "переустановил драйвер", id="note")),
            self.field("Описание обращения", TextArea(e.get("description", ""), id="description")),
            self.field("Выполненные действия", TextArea(e.get("actions", ""), id="actions")),
            self.field("Результат", TextArea(e.get("result", ""), id="result")),
            Horizontal(Button("✨ Дополнить ИИ (Ctrl+E)", id="ai"),
                       Button("Сохранить (Ctrl+S)", variant="primary", id="save"),
                       Button("Отмена (Esc)", id="no"), classes="buttons"),
        )

    def on_mount(self):
        self.query_one("#employee").focus()

    @on(Button.Pressed, "#ai")
    @work
    @guard
    async def action_ai(self):
        note = self.val("note")
        if not note:
            raise ValueError("Впишите короткую заметку для ИИ.")
        cfg = mr.ai_config(self.data)
        res = await busy(self.app, "ИИ думает", mr.ai_expand, cfg, note, self.val("employee"),
                         mr.gather_history(self.data))
        for k in ("description", "actions", "result"):
            self.query_one("#" + k, TextArea).text = res.get(k, "")
        self.app.notify("✨ Поля заполнены — проверьте и сохраните")

    @guard
    def action_save(self):
        uid = mr.save_entry(self.val("date"), self.val("employee"), self.val("description"),
                            self.val("actions"), self.val("result"), uid=self.entry.get("uid"))
        self.dismiss(uid)


class EmailForm(Form):
    def __init__(self, day):
        super().__init__()
        self.day = day
        self.d = mr.email_draft(mr.load_data(), day)

    def compose(self) -> ComposeResult:
        d = self.d
        yield scroll_box(
            Label("Отправить отчёт за неделю", classes="title"),
            Horizontal(self.field("SMTP-сервер", Input(d["server"], id="server")),
                       self.field("Порт", Input(d["port"], id="port")),
                       self.field("Защита", Select(options(["SSL", "STARTTLS", "Нет"]),
                                                   value=d["security"] if d["security"] in
                                                   ("SSL", "STARTTLS", "Нет") else "SSL",
                                                   allow_blank=False, id="security")),
                       classes="row"),
            Horizontal(self.field("От кого", Input(d["sender"], id="sender")),
                       self.field("Пароль", Input(d["password"], password=True, id="password")),
                       classes="row"),
            Checkbox("Запомнить пароль", d["remember"], id="remember"),
            self.field("Кому", Input(d["recipient"], id="recipient")),
            self.field("Тема", Input(d["subject"], id="subject")),
            self.field("Текст письма", TextArea(d["body"], id="body")),
            self.buttons("Отправить (Ctrl+S)"),
        )

    @work
    @guard
    async def action_save(self):
        d = {k: self.val(k) for k in ("server", "port", "security", "sender", "password",
                                      "remember", "recipient", "subject", "body")}
        d["password"] = self.query_one("#password", Input).value     # пробелы — часть пароля
        text = await busy(self.app, "Отправка", mr.send_week, self.day, d)
        self.app.notify(text, timeout=8)
        self.dismiss(True)


class ReportsTab(Vertical):
    DEFAULT_CSS = """
    ReportsTab #week { height: 1; text-style: bold; }
    ReportsTab #hint { height: 1; color: $text-muted; }
    ReportsTab DataTable { height: 1fr; }
    """
    BINDINGS = [
        Binding("comma,left_square_bracket,б,х", "week(-1)", "< Неделя"),
        Binding("full_stop,right_square_bracket,ю,ъ", "week(1)", "Неделя >"),
        Binding(keys("t"), "today", "Сегодня"),
        Binding(keys("a"), "add", "+Запись"),
        Binding(keys("e"), "edit", "Изменить", show=False),
        Binding("delete", "delete", "Удалить"),
        Binding(keys("w"), "export_week", "Word: неделя"),
        Binding(keys("m"), "export_month", "Word: месяц"),
        Binding(keys("s"), "email", "Почта"),
        Binding(keys("p"), "ai_polish", "ИИ: причесать", show=False),
        Binding(keys("c"), "ai_categories", "ИИ: категории", show=False),
        Binding(keys("i"), "ai_month('insights')", "ИИ: выводы", show=False),
        Binding(keys("n"), "ai_month('narrative')", "ИИ: месяц", show=False),
    ]

    def compose(self) -> ComposeResult:
        yield Static(id="week")
        yield DataTable(cursor_type="row", zebra_stripes=True, id="table")
        yield Static("< > неделя · a запись · Enter изменить · Del удалить · w/m Word · "
                     "s почта · ИИ: p причесать, c категории, i выводы, n отчёт за месяц",
                     id="hint")

    def on_mount(self):
        self.monday = mr.monday_of(date.today())
        t = self.query_one(DataTable)
        t.add_columns("№", "Дата", "Сотрудник / объект", "Описание", "Действия", "Результат")
        self.reload()

    def reload(self, select=None):
        data = mr.load_data()
        st = data["settings"]
        fri = self.monday + timedelta(days=4)
        self.entries = mr.week_entries(data, self.monday)
        mark = "  (текущая)" if self.monday == mr.monday_of(date.today()) else ""
        self.query_one("#week", Static).update(
            f"Неделя {self.monday:%d.%m}–{fri:%d.%m.%Y}{mark} · записей: {len(self.entries)} · "
            f"{st.get('branch') or 'филиал не указан'} · {st.get('responsible') or ''}")
        t = self.query_one(DataTable)
        t.clear()

        def cut(s, n):
            s = " ".join(str(s or "").split())
            return s if len(s) <= n else s[:n - 1] + "…"

        for i, e in enumerate(self.entries, 1):
            d = date.fromisoformat(e["date"])
            t.add_row(str(i), f"{DAYS[min(d.weekday(), 4)]} {d:%d.%m}", cut(e.get("employee"), 28),
                      cut(e.get("description"), 40), cut(e.get("actions"), 40),
                      cut(e.get("result"), 30), key=e["uid"])
        if select:
            try:
                t.move_cursor(row=t.get_row_index(select))
            except Exception:
                pass

    def current(self):
        t = self.query_one(DataTable)
        if not self.entries or t.cursor_row is None:
            return None
        return self.entries[min(t.cursor_row, len(self.entries) - 1)]

    def action_week(self, delta):
        self.monday += timedelta(days=7 * int(delta))
        self.reload()

    def action_today(self):
        self.monday = mr.monday_of(date.today())
        self.reload()

    @work
    async def action_add(self):
        today = date.today()
        day = today if self.monday <= today <= self.monday + timedelta(days=4) else self.monday
        uid = await self.app.push_screen_wait(EntryEdit(self.monday, day=day))
        if uid:
            self.app.notify("✓ Запись добавлена")
            self.reload(uid)

    @on(DataTable.RowSelected)
    @work
    async def action_edit(self):
        e = self.current()
        if not e:
            return
        uid = await self.app.push_screen_wait(EntryEdit(self.monday, e))
        if uid:
            self.app.notify("✓ Изменения сохранены")
            data = mr.load_data()
            _wk, moved = mr.find_entry(data, uid)
            if moved:
                self.monday = mr.monday_of(date.fromisoformat(moved["date"]))
            self.reload(uid)

    @work
    async def action_delete(self):
        e = self.current()
        if e and await self.app.push_screen_wait(Confirm(
                f"Удалить запись «{(e.get('employee') or e.get('description') or '')[:60]}»?",
                "Удаление", "Удалить")):
            mr.delete_entry(e["uid"])
            self.app.notify("Запись удалена")
            self.reload()

    @work
    @guard
    async def action_export_week(self):
        data = mr.load_data()
        path = settings.export_path(mr.week_file_name(self.monday))
        await busy(self.app, "Собираю Word", mr.export_week, data, self.monday, path)
        self.app.notify(f"Файл сохранён:\n{path}", timeout=10)

    @work
    @guard
    async def action_export_month(self):
        res = await self.app.push_screen_wait(MonthPick("Отчёт за месяц в Word",
                                                        self.monday.month, self.monday.year))
        if res:
            m, y = res
            data = mr.load_data()
            path = settings.export_path(f"Отчёт_{mr.RU_MONTHS_NOM[m]}_{y}.docx")
            await busy(self.app, "Собираю Word", mr.export_month, data, m, y, path)
            self.app.notify(f"Файл сохранён:\n{path}", timeout=10)

    @work
    @guard
    async def action_email(self):
        if not self.entries:
            raise ValueError("За эту неделю нет записей для отправки.")
        await self.app.push_screen_wait(EmailForm(self.monday))

    # ---- ИИ ----
    @work
    @guard
    async def action_ai_polish(self):
        if not self.entries:
            raise ValueError("За эту неделю нет записей.")
        if not await self.app.push_screen_wait(Confirm(
                f"ИИ перепишет {len(self.entries)} записей за эту неделю в едином официальном "
                "стиле: исправит орфографию и приведёт термины к единому виду. Тексты будут "
                "заменены (копия базы остаётся в резервных). Продолжить?",
                "Причесать отчёт", "Причесать")):
            return
        n = await busy(self.app, "Причёсываю", mr.polish_week, self.monday)
        self.app.notify(f"Обновлено записей: {n}.")
        self.reload()

    @work
    @guard
    async def action_ai_categories(self):
        counts = await busy(self.app, "Определяю категории", mr.categorize_week, self.monday)
        text = "Обращения по категориям:\n\n" + "\n".join(f"•  {k} — {v}"
                                                         for k, v in counts.items())
        await self.app.push_screen_wait(TextView("Категории за неделю", text))

    @work
    @guard
    async def action_ai_month(self, kind):
        res = await self.app.push_screen_wait(MonthPick(
            "Выводы для руководства" if kind == "insights" else "Месячный отчёт (ИИ)",
            self.monday.month, self.monday.year))
        if not res:
            return
        title, text = await busy(self.app, "Думаю", mr.month_text, kind, *res)
        out = await self.app.push_screen_wait(TextView(title, text, save_name=True))
        if out:
            path = settings.export_path(f"{title}.docx")
            mr.save_text_docx(title, out[1], path)
            self.app.notify(f"Сохранено:\n{path}", timeout=10)

