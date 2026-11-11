# -*- coding: utf-8 -*-
"""ITtool в терминале: общие окна — вопрос, ввод строки, текст, месяц, форма."""
from __future__ import annotations

import asyncio
import datetime
import functools

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.suggester import SuggestFromList
from textual.widgets import Button, Input, Label, Select, Static, TextArea

MONTHS = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август",
          "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]

# Русская раскладка: «ф» на месте «a» и т.д. — горячие клавиши работают в обеих.
_RU = str.maketrans("qwertyuiop[]asdfghjkl;'zxcvbnm,.",
                    "йцукенгшщзхъфывапролджэячсмитьбю")


def keys(*names):
    """Клавиша и её двойник в русской раскладке: keys("a") → "a,ф"."""
    out = []
    for k in names:
        out.append(k)
        if len(k) == 1 and k.isascii() and k.isalpha():
            out.append(k.lower().translate(_RU))
    return ",".join(out)


def guard(fn):
    """Отказ проверки (ValueError) — уведомлением, а не падением программы.
    Работает и для обычных, и для async-обработчиков."""
    if asyncio.iscoroutinefunction(fn):
        @functools.wraps(fn)
        async def wrapper(self, *a, **k):
            try:
                return await fn(self, *a, **k)
            except ValueError as ex:
                self.app.notify(str(ex), severity="warning", timeout=8)
            except Exception as ex:                          # noqa: BLE001
                self.app.notify(f"{type(ex).__name__}: {ex}", title="Ошибка",
                                severity="error", timeout=12)
        return wrapper

    @functools.wraps(fn)
    def wrapper(self, *a, **k):
        try:
            return fn(self, *a, **k)
        except ValueError as ex:
            self.app.notify(str(ex), severity="warning", timeout=8)
        except Exception as ex:                              # noqa: BLE001
            self.app.notify(f"{type(ex).__name__}: {ex}", title="Ошибка",
                            severity="error", timeout=12)
    return wrapper


async def busy(app, text, fn, *a, **k):
    """Долгое дело (ИИ, почта, выгрузка) — в потоке, интерфейс не замирает."""
    app.notify(text + "…", timeout=4)
    return await asyncio.to_thread(fn, *a, **k)


def suggest(values):
    vals = [v for v in dict.fromkeys(values) if v]
    return SuggestFromList(vals, case_sensitive=False) if vals else None


def options(values):
    return [(str(v), v) for v in values]


# ═══════════════════════════════ окна ═══════════════════════════════
class Modal(ModalScreen):
    """Окно поверх: Esc — закрыть без результата."""

    BINDINGS = [Binding("escape", "cancel", "Закрыть")]
    DEFAULT_CSS = """
    Modal { align: center middle; }
    Modal > .box {
        width: 90%; max-width: 110; height: auto; max-height: 92%;
        border: round $accent; background: $surface; padding: 1 2;
    }
    Modal .title { text-style: bold; color: $accent; margin-bottom: 1; }
    Modal .buttons { height: auto; margin-top: 1; align-horizontal: right; }
    Modal .buttons Button { margin-left: 2; }
    Modal .lbl { color: $text-muted; margin-top: 1; }
    Modal Input.-textual-compact, Modal SelectCurrent { background: $panel; }
    Modal Input, Modal Select { margin: 0; }
    Modal TextArea { height: 5; }
    Modal .row { height: auto; }
    Modal .row > Vertical { width: 1fr; height: auto; margin-right: 1; }
    """

    def on_mount(self):
        compact(self)

    def action_cancel(self):
        self.dismiss(None)


def compact(root):
    """Поля в одну строку — в форму на экране влезает больше."""
    for w in root.query("Input, Select, Button"):
        w.compact = True


class Confirm(Modal):
    BINDINGS = [Binding(keys("y", "enter"), "yes", "Да"), Binding(keys("n"), "cancel", "Нет")]

    def __init__(self, text, title="Подтвердите", yes="Да"):
        super().__init__()
        self.text, self.ttl, self.yes = text, title, yes

    def compose(self) -> ComposeResult:
        with Vertical(classes="box"):
            yield Label(self.ttl, classes="title")
            yield Static(self.text)
            with Horizontal(classes="buttons"):
                yield Button(self.yes, variant="primary", id="yes")
                yield Button("Отмена", id="no")

    def on_mount(self):
        self.query_one("#yes").focus()

    def action_yes(self):
        self.dismiss(True)

    def action_cancel(self):
        self.dismiss(False)

    @on(Button.Pressed)
    def pressed(self, ev):
        self.dismiss(ev.button.id == "yes")


class Prompt(Modal):
    """Одна строка. Enter — готово."""

    def __init__(self, title, label="", value="", suggestions=()):
        super().__init__()
        self.ttl, self.lbl, self.value, self.sugg = title, label, value, suggestions

    def compose(self) -> ComposeResult:
        with Vertical(classes="box"):
            yield Label(self.ttl, classes="title")
            if self.lbl:
                yield Label(self.lbl)
            yield Input(self.value, suggester=suggest(self.sugg), id="val")
            with Horizontal(classes="buttons"):
                yield Button("OK", variant="primary", id="ok")
                yield Button("Отмена", id="no")

    @on(Input.Submitted)
    @on(Button.Pressed, "#ok")
    def ok(self):
        self.dismiss(self.query_one("#val", Input).value.strip())

    @on(Button.Pressed, "#no")
    def no(self):
        self.dismiss(None)


class TextView(Modal):
    """Длинный текст (статистика, ответ ИИ). save_name — можно сохранить в Word (w)."""

    BINDINGS = [Binding(keys("w"), "save", "В Word", show=True)]
    DEFAULT_CSS = """
    TextView > .box { height: 92%; }
    TextView TextArea { height: 1fr; }
    """

    def __init__(self, title, text, save_name=None):
        super().__init__()
        self.ttl, self.text, self.save_name = title, text, save_name

    def compose(self) -> ComposeResult:
        with Vertical(classes="box"):
            yield Label(self.ttl, classes="title")
            yield TextArea(self.text, read_only=not self.save_name, id="txt")
            with Horizontal(classes="buttons"):
                if self.save_name:
                    yield Button("Сохранить в Word (w)", variant="primary", id="save")
                yield Button("Закрыть (Esc)", id="close")

    def check_action(self, action, parameters):
        return self.save_name is not None if action == "save" else True

    @on(Button.Pressed, "#save")
    def action_save(self):
        self.dismiss(("save", self.query_one("#txt", TextArea).text))

    @on(Button.Pressed, "#close")
    def close(self):
        self.dismiss(None)


class MonthPick(Modal):
    """Месяц и год. allow_year — ещё «весь год» (месяц 0)."""

    def __init__(self, title, month=None, year=None, allow_year=False):
        super().__init__()
        today = datetime.date.today()
        self.ttl = title
        self.month = today.month if month is None else month
        self.year = year or today.year
        self.allow_year = allow_year

    def compose(self) -> ComposeResult:
        months = ([("Весь год", 0)] if self.allow_year else []) + \
                 [(m, i) for i, m in enumerate(MONTHS, 1)]
        y = datetime.date.today().year
        with Vertical(classes="box"):
            yield Label(self.ttl, classes="title")
            with Horizontal(classes="row"):
                with Vertical():
                    yield Select(months, value=self.month, allow_blank=False, id="m")
                with Vertical():
                    yield Select(options(range(y - 4, y + 2)), value=self.year,
                                 allow_blank=False, id="y")
            with Horizontal(classes="buttons"):
                yield Button("OK", variant="primary", id="ok")
                yield Button("Отмена", id="no")

    @on(Button.Pressed, "#ok")
    def ok(self):
        self.dismiss((self.query_one("#m", Select).value, self.query_one("#y", Select).value))

    @on(Button.Pressed, "#no")
    def no(self):
        self.dismiss(None)


class Form(Modal):
    """Основа форм: Ctrl+S — сохранить, Esc — закрыть. Поля — по id."""

    BINDINGS = [Binding("ctrl+s", "save", "Сохранить", priority=True)]

    def val(self, wid):
        w = self.query_one("#" + wid)
        if isinstance(w, TextArea):
            return w.text.strip()
        if isinstance(w, Select):
            return None if w.value is Select.NULL else w.value
        if hasattr(w, "value"):
            return w.value.strip() if isinstance(w.value, str) else w.value
        return None

    def field(self, label, widget):
        """Подпись и поле одним блоком."""
        box = Vertical(Label(label, classes="lbl"), widget)
        box.styles.height = "auto"
        return box

    def buttons(self, save="Сохранить (Ctrl+S)"):
        return Horizontal(Button(save, variant="primary", id="save"),
                          Button("Отмена (Esc)", id="no"), classes="buttons")

    @on(Button.Pressed, "#save")
    def _save_btn(self):
        self.run_action("save")

    @on(Button.Pressed, "#no")
    def _no_btn(self):
        self.dismiss(None)


def scroll_box(*children):
    v = VerticalScroll(*children, classes="box")
    return v
