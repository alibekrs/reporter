# -*- coding: utf-8 -*-
"""ITtool в терминале: «Заявки», «Картриджи», «Настройки»."""
from __future__ import annotations

import datetime

from rich.text import Text
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import (Button, Checkbox, DataTable, Input, Label, Select, Static,
                             TextArea)

import assets as ma
import cartridges as mc
import db
import purchase as mp
import settings
from tui_common import (Confirm, Form, MonthPick, busy, guard, keys, options,
                        scroll_box, suggest)


def fmt_qty(q):
    q = float(q or 0)
    return str(int(q)) if q == int(q) else str(q).replace(".", ",")


# ═══════════════════════════════ заявки ═══════════════════════════════
class PurchaseEdit(Form):
    """Заявка на закуп. Позиции — по строке: «Название ; кол-во ; ед.»."""

    BINDINGS = [Binding("ctrl+w", "export", "В Word", priority=True)]
    DEFAULT_CSS = "PurchaseEdit > .box { height: 92%; } PurchaseEdit #items { height: 8; }"

    def __init__(self, rid=None):
        super().__init__()
        self.rec = mp.get_request(rid) if rid else mp.new_request()
        self.depts = db.departments()
        store = ma.load_store()
        self.emps = sorted(({"id": e["id"], "fio": ma.fio(e), "unit_id": e.get("unit_id")}
                            for e in store["employees"] if ma.fio(e) != "(без имени)"),
                           key=lambda x: x["fio"])

    def compose(self) -> ComposeResult:
        r = self.rec
        unit = next((d["id"] for d in self.depts
                     if d["genitive"] and d["genitive"] == r.get("department")), Select.NULL)
        items = "\n".join(f"{it['name']} ; {fmt_qty(it['qty'])} ; {it['unit']}"
                          for it in r.get("items") or [])
        titles = list(dict.fromkeys(mp.DIRECTOR_TITLES + [r.get("director_title") or "Директор"]))
        yield scroll_box(
            Label(f"Заявка {r['number']}" if r.get("id") else "Новая заявка", classes="title"),
            Horizontal(self.field("Номер", Input(r["number"], id="number")),
                       self.field("Статус", Select(options(mp.STATUSES), value=r["status"]
                                                   if r["status"] in mp.STATUSES else "Черновик",
                                                   allow_blank=False, id="status")),
                       classes="row"),
            self.field("Подразделение (из учёта)",
                       Select([(d["path"], d["id"]) for d in self.depts], value=unit,
                              prompt="— выбрать отдел —", id="unit_id")),
            Horizontal(self.field("Отдел в бланке (род. падеж: «…отдела метрологии»)",
                                  Input(r.get("department", ""), id="department")),
                       self.field("Начальник отдела", Input(r.get("head_of_dept", ""),
                                                            id="head_of_dept")),
                       classes="row"),
            self.field("Инициатор", Select([(e["fio"], e["id"]) for e in self.emps],
                                           value=r.get("employee_id") or Select.NULL,
                                           prompt="— не указан —", id="employee_id")),
            self.field("Обоснование", TextArea(r.get("justification", ""), id="justification")),
            self.field("Позиции — по строке: Название ; кол-во ; ед.  (например: Картридж 285A ; 2 ; шт.)",
                       TextArea(items, id="items")),
            Static("Расходники: " + ", ".join(mp.MATERIALS), classes="lbl"),
            Horizontal(self.field("Адресат", Select(options(titles),
                                                    value=r.get("director_title") or "Директор",
                                                    allow_blank=False, id="director_title")),
                       self.field("Директор (дат. падеж)", Input(r.get("director", ""),
                                                                 id="director")),
                       classes="row"),
            Horizontal(Button("В Word (Ctrl+W)", id="export"),
                       Button("Сохранить (Ctrl+S)", variant="primary", id="save"),
                       Button("Отмена (Esc)", id="no"), classes="buttons"),
        )

    @on(Select.Changed, "#unit_id")
    def _dept(self, ev):
        """Выбор отдела — род. падеж и начальник из учёта, если поле пустое."""
        d = next((x for x in self.depts if x["id"] == ev.value), None)
        if not d:
            return
        dep = self.query_one("#department", Input)
        if not dep.value.strip() and d["genitive"]:
            dep.value = d["genitive"]
        head = self.query_one("#head_of_dept", Input)
        if not head.value.strip() and d["head_short"]:
            head.value = d["head_short"]

    def gather(self):
        items = []
        for line in self.val("items").splitlines():
            parts = [p.strip() for p in line.split(";")]
            if parts and parts[0]:
                items.append({"name": parts[0], "qty": parts[1] if len(parts) > 1 and parts[1] else "1",
                              "unit": parts[2] if len(parts) > 2 else "шт."})
        d = {k: self.val(k) for k in ("number", "status", "department", "head_of_dept",
                                      "justification", "director_title", "director")}
        d.update(id=self.rec.get("id"), created_at=self.rec.get("created_at"),
                 employee_id=self.val("employee_id") or "", unit_id=self.val("unit_id"),
                 items=items)
        return d

    @guard
    def action_save(self):
        self.dismiss(("saved", mp.save(self.gather())))

    @on(Button.Pressed, "#export")
    @work
    @guard
    async def action_export(self):
        d = self.gather()
        path = settings.export_path(mp.file_name(d["number"]))
        rid = await busy(self.app, "Собираю Word", mp.export_docx, d, path)
        self.app.notify(f"Заявка выгружена в Word:\n{path}", timeout=10)
        self.dismiss(("saved", rid))


class PurchasesTab(Vertical):
    DEFAULT_CSS = "PurchasesTab DataTable { height: 1fr; } PurchasesTab #hint { height: 1; color: $text-muted; }"
    BINDINGS = [Binding(keys("a"), "add", "+Заявка"),
                Binding(keys("e"), "edit", "Изменить", show=False),
                Binding("delete", "delete", "Удалить")]

    def compose(self) -> ComposeResult:
        yield DataTable(cursor_type="row", zebra_stripes=True)
        yield Static("a — новая заявка · Enter — открыть (там Ctrl+W — в Word) · Del — удалить",
                     id="hint")

    def on_mount(self):
        self.query_one(DataTable).add_columns("Номер", "Дата", "Отдел", "Статус", "Позиций")
        self.reload()

    def reload(self, select=None):
        t = self.query_one(DataTable)
        t.clear()
        self.items = db.pr_list()
        for r in self.items:
            try:
                d = datetime.date.fromisoformat(r["created_at"]).strftime("%d.%m.%Y")
            except Exception:
                d = r["created_at"] or ""
            t.add_row(r["number"] or "", d, r["department"] or "—", r["status"] or "",
                      str(r["items_count"]), key=str(r["id"]))
        if select is not None:
            try:
                t.move_cursor(row=t.get_row_index(str(select)))
            except Exception:
                pass

    def current(self):
        t = self.query_one(DataTable)
        return self.items[t.cursor_row] if self.items and t.cursor_row is not None \
            and t.cursor_row < len(self.items) else None

    @work
    async def action_add(self):
        res = await self.app.push_screen_wait(PurchaseEdit())
        if res:
            self.app.notify("Заявка сохранена")
            self.reload(res[1])

    @on(DataTable.RowSelected)
    @work
    async def action_edit(self):
        r = self.current()
        if r:
            res = await self.app.push_screen_wait(PurchaseEdit(r["id"]))
            if res:
                self.app.notify("Заявка сохранена")
                self.reload(res[1])

    @work
    async def action_delete(self):
        r = self.current()
        if r and await self.app.push_screen_wait(Confirm(f"Удалить заявку {r['number']}?",
                                                         "Удаление", "Удалить")):
            db.pr_delete(r["id"])
            self.reload()


# ═══════════════════════════════ картриджи ═══════════════════════════════
class CartEdit(Form):
    def __init__(self, people, item=None):
        super().__init__()
        self.people, self.item = people, item or {}

    def compose(self) -> ComposeResult:
        it = self.item
        yield scroll_box(
            Label("Исправить выдачу" if it.get("id") else "Выдать картридж", classes="title"),
            self.field("Кто забрал (ФИО или начало: «Даулет», «Кенж Әл»)",
                       Input(it.get("employee", ""), id="employee",
                             suggester=suggest(p["fio"] for p in self.people))),
            Horizontal(self.field("Картридж", Input(it.get("model", ""), id="model",
                                                    suggester=suggest(db.cart_models()))),
                       self.field("Кол-во", Input(str(it.get("qty", 1)), id="qty",
                                                  restrict=r"[0-9]*")),
                       self.field("Дата (ГГГГ-ММ-ДД)",
                                  Input(it.get("date") or datetime.date.today().isoformat(),
                                        id="date")),
                       classes="row"),
            self.field("Примечание", Input(it.get("note", ""), id="note")),
            Static(id="last", classes="lbl"),
            self.buttons(),
        )

    @on(Input.Changed, "#employee")
    def _hint(self, ev):
        """Что человек брал в прошлый раз — подсказка (и в пустое поле картриджа)."""
        found = mc.find_people(ev.value, self.people)
        last = db.cart_last_models().get(found[0]["id"], "") if len(found) == 1 else ""
        self.query_one("#last", Static).update(f"В прошлый раз брал: {last}" if last else "")

    @work
    @guard
    async def action_save(self):
        d = {k: self.val(k) for k in ("employee", "model", "qty", "date", "note")}
        d["id"] = self.item.get("id")
        try:
            rid, text = mc.save(d, self.people)
        except mc.UnknownPerson as ex:
            if not await self.app.push_screen_wait(Confirm(str(ex), "Нет в списке", "Записать")):
                return
            rid, text = mc.save(d, self.people, allow_unknown=True)
        self.dismiss((rid, text))


class CartridgesTab(Vertical):
    DEFAULT_CSS = """
    CartridgesTab #period { height: 1; text-style: bold; }
    CartridgesTab #filter { margin-bottom: 1; }
    CartridgesTab DataTable { width: 3fr; height: 1fr; }
    CartridgesTab #summary { width: 2fr; border: round $panel; padding: 0 1; }
    CartridgesTab #hint { height: 1; color: $text-muted; }
    """
    BINDINGS = [Binding(keys("a"), "add", "+Выдача"),
                Binding(keys("e"), "edit", "Изменить", show=False),
                Binding("delete", "delete", "Удалить"),
                Binding(keys("p"), "period", "Период"),
                Binding("slash", "filter", "Фильтр"),
                Binding(keys("x"), "export", "Excel")]

    def compose(self) -> ComposeResult:
        yield Static(id="period")
        yield Input(placeholder="/ — фильтр: сотрудник, отдел, картридж, примечание", id="filter")
        with Horizontal():
            yield DataTable(cursor_type="row", zebra_stripes=True)
            with VerticalScroll(id="summary"):
                yield Static(id="summary_text")
        yield Static("a — выдать · Enter — исправить · Del — удалить · p — месяц/год · "
                     "x — отчёт в Excel", id="hint")

    def on_mount(self):
        today = datetime.date.today()
        self.year, self.month = today.year, today.month
        self.query_one(DataTable).add_columns("Дата", "Сотрудник", "Отдел", "Картридж",
                                              "Шт.", "Примечание")
        self.reload()

    def reload(self, select=None):
        self.people = mc.people(ma.load_store())
        self.items, label = mc.items(self.year, self.month, self.people,
                                     self.query_one("#filter", Input).value)
        summ = mc.summary(self.items)
        self.query_one("#period", Static).update(
            f"{label} · выдано: {summ['total']} шт. · записей: {len(self.items)}")
        t = self.query_one(DataTable)
        t.clear()
        for it in self.items:
            d = datetime.date.fromisoformat(it["date"])
            t.add_row(f"{d:%d.%m.%Y}", it["employee"], it["unit"] or "", it["model"],
                      str(it["qty"]), it["note"], key=str(it["id"]))
        if select is not None:
            try:
                t.move_cursor(row=t.get_row_index(str(select)))
            except Exception:
                pass
        txt = Text()
        txt.append("Кто сколько взял\n", style="bold")
        for p in summ["by_employee"][:15]:
            txt.append(f"{p['employee']} — {p['total']}  ")
            txt.append(f"({mc.mix(p['models'])})\n", style="dim")
        txt.append("\nПо моделям\n", style="bold")
        for c in summ["by_model"][:15]:
            txt.append(f"{c['model']} — {c['total']}\n")
        if not self.month:
            txt.append("\nПо месяцам\n", style="bold")
            for i, q in enumerate(summ["months"]):
                if q:
                    txt.append(f"{mc.MONTHS_SHORT[i]}: {q}\n")
        self.query_one("#summary_text", Static).update(txt)

    def current(self):
        t = self.query_one(DataTable)
        return self.items[t.cursor_row] if self.items and t.cursor_row is not None \
            and t.cursor_row < len(self.items) else None

    @on(Input.Changed, "#filter")
    def _filter(self):
        self.reload()

    @on(Input.Submitted, "#filter")
    def _filter_done(self):
        self.query_one(DataTable).focus()

    def action_filter(self):
        self.query_one("#filter").focus()

    @work
    async def action_period(self):
        res = await self.app.push_screen_wait(MonthPick("Период: месяц или весь год",
                                                        self.month, self.year, allow_year=True))
        if res:
            self.month, self.year = res
            self.reload()

    @work
    async def action_add(self):
        res = await self.app.push_screen_wait(CartEdit(self.people))
        if res:
            self.app.notify("Картридж выдан: " + res[1])
            self.reload(res[0])

    @on(DataTable.RowSelected)
    @work
    async def action_edit(self):
        it = self.current()
        if it:
            res = await self.app.push_screen_wait(CartEdit(self.people, it))
            if res:
                self.app.notify("Выдача исправлена: " + res[1])
                self.reload(res[0])

    @work
    async def action_delete(self):
        it = self.current()
        if it and await self.app.push_screen_wait(Confirm(
                f"Удалить выдачу: {it['employee']} — {it['model']}, {it['qty']} шт.?",
                "Удаление", "Удалить")):
            db.cart_delete(it["id"])
            self.reload()

    @work
    @guard
    async def action_export(self):
        if not self.items:
            raise ValueError("За выбранный период выдач нет — выгружать нечего.")
        path = settings.export_path(mc.export_name(self.year, self.month))
        await busy(self.app, "Собираю Excel", mc.export_xlsx, path, self.items,
                   mc.summary(self.items), by_months=not self.month)
        self.app.notify(f"Отчёт по картриджам сохранён:\n{path}", timeout=10)


# ═══════════════════════════════ настройки ═══════════════════════════════
class BackupsView(Form):
    DEFAULT_CSS = "BackupsView DataTable { height: 16; }"

    def compose(self) -> ComposeResult:
        with Vertical(classes="box"):
            yield Label("Резервные копии базы", classes="title")
            yield Static(f"Папка: {db.backups_dir()}\nКопия делается сама после каждого "
                         "сохранения (не чаще раза в 5 минут, хранится 200 последних).")
            yield DataTable(cursor_type="row")
            with Horizontal(classes="buttons"):
                yield Button("Сделать копию сейчас", id="now")
                yield Button("Восстановить выбранную (Ctrl+S)", variant="primary", id="save")
                yield Button("Закрыть (Esc)", id="no")

    def on_mount(self):
        self.reload()

    def reload(self):
        t = self.query_one(DataTable)
        t.clear(columns=True)
        t.add_columns("Когда", "Размер", "Файл")
        self.items = settings.backups()
        for p, when, size in self.items:
            t.add_row(when, f"{size // 1024} КБ", p.rsplit("/", 1)[-1])

    @on(Button.Pressed, "#now")
    def now(self):
        settings.backup_now()
        self.app.notify("Резервная копия создана.")
        self.reload()

    @work
    @guard
    async def action_save(self):
        t = self.query_one(DataTable)
        if not self.items or t.cursor_row is None:
            return
        path, when, _s = self.items[t.cursor_row]
        if await self.app.push_screen_wait(Confirm(
                f"Заменить текущие данные копией от {when}?\nТекущая база будет "
                "сохранена в копию.", "Восстановление", "Восстановить")):
            settings.restore(path)
            self.app.notify("База восстановлена.")
            self.dismiss(True)


class SettingsTab(VerticalScroll):
    DEFAULT_CSS = """
    SettingsTab { padding: 0 1; }
    SettingsTab .h { text-style: bold; color: $accent; margin-top: 1; }
    SettingsTab .lbl { color: $text-muted; margin-top: 1; }
    SettingsTab .row { height: auto; }
    SettingsTab .row > Vertical { width: 1fr; height: auto; margin-right: 1; }
    SettingsTab Input.-textual-compact, SettingsTab SelectCurrent { background: $panel; }
    SettingsTab .buttons { height: auto; margin: 1 0; }
    SettingsTab .buttons Button { margin-right: 2; }
    """
    BINDINGS = [Binding("ctrl+s", "save", "Сохранить")]

    def compose(self) -> ComposeResult:
        s = settings.get_all()

        def f(label, wid, value, **kw):
            box = Vertical(Label(label, classes="lbl"), Input(str(value or ""), id=wid, **kw))
            box.styles.height = "auto"
            return box

        o, rep, ai, em, tg = s["org"], s["report"], s["ai"], s["email"], s["tg"]
        yield Label("Организация", classes="h")
        yield f("Полное наименование организации", "org_name", o["org_name"])
        yield Horizontal(f("Филиал", "branch", o["branch"]),
                         f("Филиал в род. падеже (для бланка заявки)", "branch_gen",
                           o["branch_gen"]), classes="row")
        yield Horizontal(f("Ваше ФИО (подпись в документах)", "fio", o["fio"]),
                         f("Должность", "position", o["position"]),
                         f("Главный бухгалтер", "accountant", o["accountant"]), classes="row")
        yield Horizontal(f("Адресат заявок (титул)", "dir_title", s["director"]["title"]),
                         f("Директор (дат. падеж)", "dir_name", s["director"]["name"]),
                         classes="row")
        yield Label("Шапка недельного отчёта", classes="h")
        yield Horizontal(f("Филиал", "rep_branch", rep["branch"]),
                         f("Ответственный", "rep_resp", rep["responsible"]), classes="row")
        yield Label("ИИ (OpenAI-совместимый API; по умолчанию Google Gemini)", classes="h")
        yield f("Адрес API (base URL)", "ai_url", ai["base_url"])
        yield Horizontal(f("Модель", "ai_model", ai["model"]),
                         f("API-ключ", "ai_key", ai["api_key"], password=True), classes="row")
        yield Label("Почта (отправка отчёта)", classes="h")
        yield Horizontal(f("SMTP-сервер", "em_server", em["server"]),
                         f("Порт", "em_port", em["port"]), classes="row")
        sec = em["security"] if em["security"] in ("SSL", "STARTTLS", "Нет") else "SSL"
        box = Vertical(Label("Защита", classes="lbl"),
                       Select(options(["SSL", "STARTTLS", "Нет"]), value=sec, allow_blank=False,
                              id="em_security"))
        box.styles.height = "auto"
        yield box
        yield Horizontal(f("От кого", "em_sender", em["sender"]),
                         f("Пароль приложения", "em_password", em["password"], password=True),
                         f("Кому", "em_recipient", em["recipient"]), classes="row")
        yield Label("Телеграм-бот (записи в отчёт с телефона)", classes="h")
        yield f("Токен от @BotFather", "tg_token", tg["token"], password=True)
        yield f("Разрешённые chat ID (через пробел)", "tg_allowed", " ".join(tg["allowed"]))
        yield Checkbox("Бот включён (работает службой ittool-bot)", tg["enabled"], id="tg_enabled")
        yield Label("Данные", classes="h")
        yield f(f"Папка выгрузок (пусто — {settings.export_dir()})", "export_dir", s["export_dir"])
        yield Static(f"База: {db.DB_PATH}", classes="lbl")
        with Horizontal(classes="buttons"):
            yield Button("Сохранить (Ctrl+S)", variant="primary", id="save")
            yield Button("Проверить токен бота", id="tg_check")
            yield Button("Резервные копии", id="backups")

    def on_mount(self):
        from tui_common import compact
        compact(self)

    def v(self, wid):
        w = self.query_one("#" + wid)
        return w.value

    @on(Button.Pressed, "#save")
    @guard
    def action_save(self):
        settings.save_all({
            "org": {"org_name": self.v("org_name"), "branch": self.v("branch"),
                    "branch_gen": self.v("branch_gen"), "fio": self.v("fio"),
                    "position": self.v("position"), "accountant": self.v("accountant")},
            "director": {"title": self.v("dir_title"), "name": self.v("dir_name")},
            "report": {"branch": self.v("rep_branch"), "responsible": self.v("rep_resp")},
            "ai": {"base_url": self.v("ai_url"), "model": self.v("ai_model"),
                   "api_key": self.v("ai_key")},
            "email": {"server": self.v("em_server"), "port": self.v("em_port"),
                      "security": self.v("em_security"), "sender": self.v("em_sender"),
                      "password": self.v("em_password"), "recipient": self.v("em_recipient")},
            "tg": {"token": self.v("tg_token"), "allowed": self.v("tg_allowed"),
                   "enabled": self.v("tg_enabled")},
            "export_dir": self.v("export_dir"),
        })
        self.app.notify("Настройки сохранены. Бот подхватит их в течение минуты.")

    @on(Button.Pressed, "#tg_check")
    @work
    @guard
    async def tg_check(self):
        import tg_bot
        token = self.v("tg_token").strip()
        if not token:
            raise ValueError("Вставьте токен бота от @BotFather.")
        ok, info = await busy(self.app, "Проверяю токен", tg_bot.ReportBot(token).check)
        self.app.notify(f"Бот {info} — токен рабочий." if ok else f"Не получилось: {info}",
                        severity="information" if ok else "error", timeout=8)

    @on(Button.Pressed, "#backups")
    @work
    async def backups(self):
        if await self.app.push_screen_wait(BackupsView()):
            self.app.reload_all()

