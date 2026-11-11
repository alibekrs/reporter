# -*- coding: utf-8 -*-
"""ITtool в терминале: «Сотрудники и техника» — дерево, карточка, редактор, выгрузки."""
from __future__ import annotations

from rich.text import Text
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import (Button, Checkbox, Input, Label, OptionList, Select, Static,
                             TextArea, Tree)
from textual.widgets.option_list import Option

import assets as ma
import settings
from tui_common import (Confirm, Form, Prompt, TextView, busy, guard, keys, options,
                        scroll_box, suggest)

COND_STYLE = {"рабочее": "green", "требует замены": "yellow",
              "неисправно": "bold red", "отсутствует": "dim"}
DEV_FMT = {"pcs": ma.fmt_pc_line, "monitors": ma.fmt_monitor_line,
           "phones": ma.fmt_phone_line, "printers": ma.fmt_printer_line}


def field_choices(store, group, key, base):
    """Значения для подсказки: список по умолчанию + что уже встречается в учёте."""
    vals = [v for v in (base or []) if v]
    for e in store["employees"]:
        for dev in e.get(group) or []:
            v = str(dev.get(key, "") or "").strip()
            if v and v not in vals:
                vals.append(v)
    return vals


def card_text(store, emp):
    """Карточка сотрудника для правой панели."""
    t = Text()
    t.append(("★ " if emp.get("is_head") else "") + ma.fio(emp) + "\n", style="bold")
    if emp.get("position"):
        t.append(emp["position"] + "\n")
    t.append(ma.unit_path(store["units"], emp.get("unit_id")) + "\n", style="cyan")
    loc = ", ".join(x for x in (
        f"корпус {emp['building']}" if emp.get("building") else "",
        f"этаж {emp['floor']}" if emp.get("floor") else "",
        f"каб. {emp['office']}" if emp.get("office") else "") if x)
    if loc:
        t.append(loc + "\n")
    if emp.get("account"):
        t.append(f"Учётная запись: {emp['account']}\n")
    w = ma.worst_condition(emp)
    t.append("Состояние: ")
    t.append(w + "\n", style=COND_STYLE.get(w, ""))
    for g, sp in ma.DEVICE_SPECS.items():
        devs = emp.get(g) or []
        if not devs:
            continue
        t.append(f"\n{sp['title']}\n", style="bold underline")
        for d in devs:
            t.append("  • " + DEV_FMT[g](d) + "\n", style=COND_STYLE.get(d.get("condition"), ""))
            if g == "pcs" and (d.get("mac") or d.get("ip")):
                t.append("    " + "  ".join(x for x in (d.get("mac"), d.get("ip")) if x) + "\n",
                         style="dim")
    t.append("\nМышь: ")
    t.append(emp["mouse"]["condition"], style=COND_STYLE.get(emp["mouse"]["condition"], ""))
    t.append("   Клавиатура: ")
    t.append(emp["keyboard"]["condition"] + "\n",
             style=COND_STYLE.get(emp["keyboard"]["condition"], ""))
    if emp.get("notes"):
        t.append("\nПримечание\n", style="bold underline")
        t.append(emp["notes"] + "\n")
    if emp.get("updated"):
        t.append(f"\nИзменено: {emp['updated']}", style="dim")
    return t


def unit_text(store, uid):
    u = ma.unit_by_id(store["units"], uid) or {}
    emps = [e for e in store["employees"] if e.get("unit_id") == uid]
    head = next((ma.fio(e) for e in emps if e.get("is_head")), "—")
    t = Text()
    t.append(u.get("name", "") + "\n", style="bold")
    t.append(ma.unit_path(store["units"], uid) + "\n\n", style="cyan")
    t.append(f"Руководитель: {head}\nСотрудников: {len(emps)}\n"
             f"Подотделов: {len(ma.unit_children(store['units'], uid))}\n")
    bad = [e for e in emps if ma.worst_condition(e) in ("неисправно", "требует замены")]
    if bad:
        t.append("\nТребует внимания:\n", style="bold")
        for e in bad:
            w = ma.worst_condition(e)
            t.append(f"  • {ma.fio(e)} — {w}\n", style=COND_STYLE[w])
    return t


# ═══════════════════════════ редактор техники ═══════════════════════════
class DeviceEdit(Form):
    def __init__(self, store, group, dev):
        super().__init__()
        self.store, self.group, self.dev = store, group, dict(dev or {})

    def compose(self) -> ComposeResult:
        sp = ma.DEVICE_SPECS[self.group]
        rows = [Label(sp["singular"], classes="title")]
        for key, label, kind, base in sp["fields"]:
            v = self.dev.get(key)
            if kind == "check":
                rows.append(Checkbox(label, bool(v), id="f_" + key))
            elif kind == "combo":
                rows.append(self.field(label, Select(options(ma.CONDITIONS), allow_blank=False,
                                                     value=v if v in ma.CONDITIONS else ma.CONDITIONS[0],
                                                     id="f_" + key)))
            else:
                sugg = field_choices(self.store, self.group, key, base) if kind == "choice" else []
                rows.append(self.field(label, Input(str(v or ""), suggester=suggest(sugg),
                                                    id="f_" + key)))
        rows.append(self.buttons("Готово (Ctrl+S)"))
        yield scroll_box(*rows)

    def action_save(self):
        out = {}
        for key, _label, kind, _b in ma.DEVICE_SPECS[self.group]["fields"]:
            v = self.val("f_" + key)
            out[key] = bool(v) if kind == "check" else (v or "")
        self.dismiss(out)


class DeviceList(Vertical):
    """Техника одного вида в редакторе карточки: Enter — изменить, + / Del."""

    DEFAULT_CSS = """
    DeviceList { height: auto; margin-top: 1; }
    DeviceList OptionList { height: auto; max-height: 8; }
    DeviceList Horizontal { height: auto; }
    DeviceList Button { min-width: 10; margin-right: 1; }
    """
    BINDINGS = [Binding("plus,insert", "add", "Добавить"),
                Binding("delete", "remove", "Убрать")]

    def __init__(self, store, group, devs):
        super().__init__()
        self.store, self.group, self.devs = store, group, [dict(d) for d in devs]

    def compose(self) -> ComposeResult:
        yield Label(ma.DEVICE_SPECS[self.group]["title"], classes="lbl")
        yield OptionList()
        with Horizontal():
            yield Button("+" + ma.DEVICE_SPECS[self.group]["add_label"], id="add")
            yield Button("Изменить", id="edit")
            yield Button("Убрать", id="del")

    def on_mount(self):
        self.refresh_list()

    def refresh_list(self, select=None):
        ol = self.query_one(OptionList)
        ol.clear_options()
        fmt = DEV_FMT[self.group]
        ol.add_options([Option(Text(fmt(d), style=COND_STYLE.get(d.get("condition"), "")))
                        for d in self.devs] or [Option("— нет —", disabled=True)])
        if self.devs:
            ol.highlighted = min(select if select is not None else 0, len(self.devs) - 1)

    def _current(self):
        i = self.query_one(OptionList).highlighted
        return i if self.devs and i is not None and i < len(self.devs) else None

    @on(Button.Pressed, "#add")
    @work
    async def action_add(self):
        dev = await self.app.push_screen_wait(DeviceEdit(self.store, self.group,
                                                         {"condition": "рабочее"}))
        if dev is not None:
            self.devs.append(dev)
            self.refresh_list(len(self.devs) - 1)

    @on(OptionList.OptionSelected)
    @on(Button.Pressed, "#edit")
    @work
    async def edit(self):
        i = self._current()
        if i is None:
            return
        dev = await self.app.push_screen_wait(DeviceEdit(self.store, self.group, self.devs[i]))
        if dev is not None:
            self.devs[i] = dev
            self.refresh_list(i)

    @on(Button.Pressed, "#del")
    def action_remove(self):
        i = self._current()
        if i is not None:
            self.devs.pop(i)
            self.refresh_list(i)


# ═══════════════════════════ редактор карточки ═══════════════════════════
class EmployeeEdit(Form):
    DEFAULT_CSS = "EmployeeEdit > .box { height: 92%; }"

    def __init__(self, emp_id):
        super().__init__()
        self.store = ma.load_store()
        self.emp = ma.find_employee(self.store, emp_id)

    def compose(self) -> ComposeResult:
        e, st = self.emp, self.store
        units = [(("  " * depth) + name, uid) for uid, name, depth in ma.unit_flat(st["units"])]
        blds = sorted({x.get("building", "") for x in st["employees"] if x.get("building")})
        conds = options(ma.CONDITIONS)
        yield scroll_box(
            Label("Карточка сотрудника", classes="title"),
            Horizontal(self.field("Фамилия", Input(e["last_name"], id="last_name")),
                       self.field("Имя", Input(e["first_name"], id="first_name")),
                       self.field("Отчество", Input(e["middle_name"], id="middle_name")),
                       classes="row"),
            Horizontal(self.field("Должность", Input(e["position"], id="position")),
                       self.field("Учётная запись", Input(e.get("account", ""), id="account")),
                       classes="row"),
            self.field("Подразделение", Select(units, value=e["unit_id"], allow_blank=False,
                                               id="unit_id")),
            Checkbox("Руководитель подразделения", bool(e.get("is_head")), id="is_head"),
            Horizontal(self.field("Корпус", Input(e["building"], suggester=suggest(blds),
                                                  id="building")),
                       self.field("Этаж", Input(e["floor"], id="floor")),
                       self.field("Кабинет", Input(e["office"], id="office")),
                       classes="row"),
            *[DeviceList(st, g, e.get(g) or []) for g in ma.DEVICE_GROUPS],
            Horizontal(self.field("Мышь", Select(conds, value=e["mouse"]["condition"],
                                                 allow_blank=False, id="mouse")),
                       self.field("Клавиатура", Select(conds, value=e["keyboard"]["condition"],
                                                       allow_blank=False, id="keyboard")),
                       classes="row"),
            self.field("Примечание", TextArea(e.get("notes", ""), id="notes")),
            self.buttons(),
        )

    def on_mount(self):
        self.query_one("#last_name").focus()

    @guard
    def action_save(self):
        d = {k: self.val(k) for k in ("last_name", "first_name", "middle_name", "position",
                                      "account", "building", "floor", "office", "notes",
                                      "unit_id", "is_head")}
        d["mouse"] = {"condition": self.val("mouse")}
        d["keyboard"] = {"condition": self.val("keyboard")}
        for dl in self.query(DeviceList):
            d[dl.group] = dl.devs
        ma.save_employee(self.emp["id"], d)
        self.dismiss(True)


# ═══════════════════════════ анализ парка ═══════════════════════════
class AuditView(Form):
    DEFAULT_CSS = """
    AuditView > .box { height: 92%; }
    AuditView TextArea { height: 1fr; }
    """
    BINDINGS = [Binding(keys("a"), "ai", "Текст записки — ИИ")]

    def __init__(self):
        super().__init__()
        self.store = ma.load_store()
        self.rows, self.summ = ma.audit(self.store)

    def compose(self) -> ComposeResult:
        import pc_audit as pa
        s = self.summ
        head = (f"ПК в учёте: {s['total']}.  Замена: {s['replace']}, модернизация: "
                f"{s['upgrade']}, норма: {s['ok']}.\nГотовы к Windows 11: {s['win11_ready']}; "
                f"нужна память: {s['need_ram']}, нужен SSD: {s['need_ssd']}; "
                f"устаревшая ОС: {s['dead_os']}.\n")
        lines = []
        for r in self.rows:
            if r["verdict"] != pa.VERDICT_OK:
                lines.append(f"{r['verdict']:<13} {r['employee']} ({r['dept']}) — {r['need']}")
        with Vertical(classes="box"):
            yield Label("Анализ парка ПК", classes="title")
            yield Static(head)
            yield Label("Что делать (ниже — текст служебной записки, его можно править):",
                        classes="lbl")
            yield Static("\n".join(lines[:12]) + ("\n…" if len(lines) > 12 else ""))
            yield TextArea(pa.default_body(self.summ), id="body")
            with Horizontal(classes="buttons"):
                yield Button("Текст — ИИ (a)", id="ai")
                yield Button("Записка в Word (Ctrl+S)", variant="primary", id="save")
                yield Button("Закрыть (Esc)", id="no")

    @on(Button.Pressed, "#ai")
    @work
    @guard
    async def action_ai(self):
        cfg = settings.assets_ai_config()
        text = await busy(self.app, "ИИ готовит текст записки", ma.audit_ai_text, cfg, self.store)
        self.query_one("#body", TextArea).text = text

    @guard
    def action_save(self):
        path = settings.export_path("Служебная_записка_замена_техники.docx")
        ma.audit_memo(self.store, path, self.val("body"))
        self.app.notify(f"Служебная записка сохранена:\n{path}", timeout=10)
        self.dismiss(path)


# ═══════════════════════════ вкладка ═══════════════════════════
class AssetsTab(Vertical):
    DEFAULT_CSS = """
    AssetsTab #search { margin: 0 0 1 0; }
    AssetsTab #tree { width: 1fr; min-width: 30; border: round $panel; }
    AssetsTab #card { width: 1fr; border: round $panel; padding: 0 1; }
    AssetsTab #status { height: 1; color: $text-muted; }
    """
    BINDINGS = [
        Binding("slash", "search", "Поиск"),
        Binding(keys("e"), "edit", "Изменить"),
        Binding(keys("a"), "add_emp", "+Сотрудник"),
        Binding(keys("u"), "add_unit", "+Отдел"),
        Binding(keys("r"), "rename", "Переим.", show=False),
        Binding("delete", "delete", "Удалить"),
        Binding("alt+up", "move(-1)", "Выше", show=False),
        Binding("alt+down", "move(1)", "Ниже", show=False),
        Binding(keys("s"), "stats", "Статистика"),
        Binding(keys("x"), "excel", "Excel"),
        Binding(keys("w"), "uchetki", "Учётки", show=False),
        Binding(keys("i"), "import_csv", "Импорт CSV", show=False),
        Binding(keys("p"), "audit", "Анализ ПК"),
        Binding(keys("f"), "ai_fill", "ИИ: заметка", show=False),
        Binding(keys("q"), "ai_ask", "ИИ: вопрос", show=False),
        Binding(keys("z"), "ai_analyze", "ИИ: анализ", show=False),
    ]

    def compose(self) -> ComposeResult:
        yield Input(placeholder="/ — поиск: ФИО, кабинет, инв. номер, модель, IP… "
                                "(Esc — к дереву)", id="search")
        with Horizontal():
            yield Tree("Организация", id="tree")
            with VerticalScroll(id="card"):
                yield Static(id="card_text")
        yield Static(id="status")

    def on_mount(self):
        self.reload()

    # ---- данные ----
    def reload(self, select=None):
        """select — ("emp"|"unit", id), чтобы остаться на том же месте."""
        self.store = ma.load_store()
        st = self.store
        tree = self.query_one("#tree", Tree)
        if select is None and tree.cursor_node and tree.cursor_node.data:
            select = tree.cursor_node.data
        tree.clear()
        tree.show_root = False
        q = self.query_one("#search", Input).value.strip()
        target = None
        if q:
            for e, hint in ma.search(st, q):
                w = ma.worst_condition(e)
                lbl = Text(("★ " if e.get("is_head") else "") + ma.fio(e),
                           style=COND_STYLE.get(w, ""))
                lbl.append(f" — {e.get('position') or '—'}", style="")
                lbl.append(f"  [{ma.unit_path(st['units'], e.get('unit_id'))}]", style="dim")
                if hint:
                    lbl.append("  · " + hint, style="italic")
                n = tree.root.add_leaf(lbl, data=("emp", e["id"]))
                if select == ("emp", e["id"]):
                    target = n
        else:
            def add(unit, parent):
                nonlocal target
                direct = sorted((e for e in st["employees"] if e.get("unit_id") == unit["id"]),
                                key=ma.emp_sort_key)
                lbl = Text("▣ " + unit["name"], style="bold")
                if direct:
                    lbl.append(f"  · {len(direct)}", style="dim")
                node = parent.add(lbl, data=("unit", unit["id"]), expand=True)
                if select == ("unit", unit["id"]):
                    target = node
                for e in direct:
                    w = ma.worst_condition(e)
                    t = Text(("★ " if e.get("is_head") else "") + ma.fio(e),
                             style=COND_STYLE.get(w, ""))
                    if e.get("position"):
                        t.append(" — " + e["position"], style="dim")
                    n = node.add_leaf(t, data=("emp", e["id"]))
                    if select == ("emp", e["id"]):
                        target = n
                for child in sorted(ma.unit_children(st["units"], unit["id"]),
                                    key=ma.unit_sort_key):
                    add(child, node)

            for root in sorted([u for u in st["units"] if not u.get("parent_id")],
                               key=ma.unit_sort_key):
                add(root, tree.root)
        if target is not None:
            self.call_after_refresh(tree.move_cursor, target)
        emps = st["employees"]
        broken = sum(1 for e in emps if ma.worst_condition(e) == "неисправно")
        repl = sum(1 for e in emps if ma.worst_condition(e) == "требует замены")
        self.query_one("#status", Static).update(
            f"Сотрудников: {len(emps)} · неисправно: {broken} · требует замены: {repl}")
        self.show_card()

    def selected(self):
        node = self.query_one("#tree", Tree).cursor_node
        return node.data if node and node.data else (None, None)

    def show_card(self):
        kind, item = self.selected()
        card = self.query_one("#card_text", Static)
        if kind == "emp":
            e = ma.find_employee(self.store, item)
            card.update(card_text(self.store, e) if e else "")
        elif kind == "unit":
            card.update(unit_text(self.store, item))
        else:
            card.update(Text("Выберите сотрудника или подразделение.\n\n"
                             "Enter/e — изменить, a — сотрудник, u — подразделение,\n"
                             "Del — удалить, Alt+↑/↓ — порядок, / — поиск.\n"
                             "s — статистика, x — Excel, w — учётки в Word,\n"
                             "i — импорт MAC/IP из CSV, p — анализ ПК,\n"
                             "f — ИИ заполнит карточку из заметки, q — вопрос ИИ,\n"
                             "z — ИИ-анализ парка.", style="dim"))

    @on(Tree.NodeHighlighted)
    def _hl(self):
        self.show_card()

    @on(Tree.NodeSelected)
    def _sel(self, ev):
        if ev.node.data and ev.node.data[0] == "emp":
            self.action_edit()

    @on(Input.Changed, "#search")
    def _search(self):
        self.reload()

    @on(Input.Submitted, "#search")
    def _search_done(self):
        self.query_one("#tree").focus()

    def on_key(self, ev):
        if ev.key == "escape" and self.query_one("#search").has_focus:
            self.query_one("#tree").focus()
            ev.stop()

    def action_search(self):
        self.query_one("#search").focus()

    # ---- правка ----
    @work
    async def action_edit(self):
        kind, item = self.selected()
        if kind == "emp":
            if await self.app.push_screen_wait(EmployeeEdit(item)):
                self.app.notify("Карточка сохранена")
                self.reload(("emp", item))
        elif kind == "unit":
            await self.rename(item)

    @work
    async def action_rename(self):
        kind, item = self.selected()
        if kind == "unit":
            await self.rename(item)

    @guard
    async def rename(self, uid):
        u = ma.unit_by_id(self.store["units"], uid)
        name = await self.app.push_screen_wait(Prompt("Переименовать", "Новое название:",
                                                      u["name"]))
        if name:
            ma.rename_unit(uid, name)
            self.reload(("unit", uid))

    def _unit_for_new(self):
        kind, item = self.selected()
        if kind == "unit":
            return item
        if kind == "emp":
            e = ma.find_employee(self.store, item)
            return e.get("unit_id") if e else None
        return None

    @work
    async def action_add_emp(self):
        emp_id = ma.add_employee(self._unit_for_new())
        self.query_one("#search", Input).value = ""
        self.reload(("emp", emp_id))
        if await self.app.push_screen_wait(EmployeeEdit(emp_id)):
            self.app.notify("Сотрудник добавлен")
        self.reload(("emp", emp_id))

    @work
    @guard
    async def action_add_unit(self):
        parent = self._unit_for_new() or ma.unit_root_id(self.store["units"])
        pu = ma.unit_by_id(self.store["units"], parent)
        name = await self.app.push_screen_wait(
            Prompt("Новое подразделение", f"Название (внутри «{pu['name'] if pu else '—'}»):"))
        if name:
            uid = ma.add_unit(parent, name)
            self.app.notify(f"Создано: {name}")
            self.reload(("unit", uid))

    @work
    @guard
    async def action_delete(self):
        kind, item = self.selected()
        if kind == "emp":
            e = ma.find_employee(self.store, item)
            if e and await self.app.push_screen_wait(
                    Confirm(f"Удалить сотрудника «{ma.fio(e)}»?", "Удаление", "Удалить")):
                ma.delete_employee(item)
                self.reload(("unit", e.get("unit_id")))
        elif kind == "unit":
            u = ma.unit_by_id(self.store["units"], item)
            if not u.get("parent_id"):
                raise ValueError("Корневую организацию удалить нельзя.")
            msg = f"Удалить подразделение «{u['name']}»?"
            if ma.unit_has_content(self.store, item):
                msg += "\n\nЕго сотрудники и подотделы будут перемещены на уровень выше."
            if await self.app.push_screen_wait(Confirm(msg, "Удаление", "Удалить")):
                parent = ma.delete_unit(item)
                self.reload(("unit", parent))

    def action_move(self, delta):
        kind, item = self.selected()
        if kind and ma.move(kind, item, int(delta)):
            self.reload((kind, item))

    # ---- статистика и выгрузки ----
    def action_stats(self):
        self.app.push_screen(TextView("Статистика парка техники", ma.stats_text(self.store)))

    @work
    @guard
    async def action_excel(self):
        path = settings.export_path("Учёт_техники.xlsx")
        await busy(self.app, "Собираю Excel", ma.export_excel, self.store, path)
        self.app.notify(f"Файл сохранён:\n{path}", timeout=10)

    @work
    @guard
    async def action_uchetki(self):
        import uchetki_export as ux
        rows = ux.rows_from_store(self.store["employees"], self.store["units"])
        with_ip = False
        if any(r.get("ip") for r in rows):
            with_ip = await self.app.push_screen_wait(Confirm(
                f"Заполнено IP-адресов: {sum(1 for r in rows if r.get('ip'))}.\n"
                "Добавить колонку «IP-адрес» в таблицу?", "Учётные записи", "Добавить"))
        path = settings.export_path("Учетные_записи.docx")
        n, with_mac = ma.export_uchetki(self.store, path, with_ip=bool(with_ip))
        self.app.notify(f"Сохранено строк: {n}, из них с MAC-адресом: {with_mac}.\n{path}",
                        timeout=10)

    @work
    @guard
    async def action_import_csv(self):
        path = await self.app.push_screen_wait(Prompt(
            "Импорт MAC и IP", "Путь к CSV сканера сети (scan_net.ps1):",
            str(settings.export_dir()) + "/"))
        if path:
            import os
            filled, total = ma.import_scan_csv(os.path.expanduser(path))
            self.app.notify(f"Заполнено полей: {filled}. Записей в файле: {total}.")
            self.reload()

    def action_audit(self):
        self.app.push_screen(AuditView())

    # ---- ИИ ----
    @work
    @guard
    async def action_ai_fill(self):
        kind, item = self.selected()
        if kind != "emp":
            raise ValueError("Сначала выберите или добавьте сотрудника в дереве.")
        cfg = settings.assets_ai_config()
        note = await self.app.push_screen_wait(Prompt(
            "ИИ: заполнить карточку из заметки",
            "Например: «Петров Иван, инженер, 2 этаж каб 205, ПК инв 4471 i5/16ГБ/512 SSD "
            "Windows 11, монитор Dell 24 дюйма»"))
        if note:
            data = await busy(self.app, "Запрос к ИИ", ma.ai_fill, cfg, note)
            ma.apply_ai_fill(item, data)
            self.reload(("emp", item))
            self.app.notify("Поля заполнены — проверьте карточку (e)")

    @work
    @guard
    async def action_ai_ask(self):
        cfg = settings.assets_ai_config()
        q = await self.app.push_screen_wait(Prompt(
            "ИИ: вопрос по базе", "Например: «сколько ПК требуют замены в метрологии?»"))
        if q:
            text = await busy(self.app, "Запрос к ИИ", ma.ai_question, cfg, self.store, q)
            await self.app.push_screen_wait(TextView("Ответ ИИ", text))

    @work
    @guard
    async def action_ai_analyze(self):
        cfg = settings.assets_ai_config()
        text = await busy(self.app, "ИИ анализирует парк", ma.ai_analyze, cfg, self.store)
        res = await self.app.push_screen_wait(TextView("ИИ-анализ парка", text, save_name=True))
        if res:
            import reports
            path = settings.export_path("ИИ-анализ_парка.docx")
            reports.save_text_docx("ИИ-анализ парка", res[1], path)
            self.app.notify(f"Сохранено:\n{path}", timeout=10)
