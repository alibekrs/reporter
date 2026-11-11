# -*- coding: utf-8 -*-
"""
docx_export.py — движок выгрузки заявок на закуп в Word.

Философия: шаблон .docx лежит на диске и правится в любой момент. Движок НЕ
знает, как выглядит шаблон, — он лишь отдаёт полный набор данных (контекст) и
все зарегистрированные фильтры. Поэтому шаблон можно переписать целиком: убрать
теги, переименовать, добавить новые поля из контекста, поменять вёрстку/шрифты/
логотип — движок подстроится и не упадёт.

Три вещи делают движок «полностью изменяемым»:

  1. Тихий Undefined — отсутствующий тег рендерится пустым, а не роняет экспорт.
     → можно свободно удалять и переименовывать теги в шаблоне.
  2. Полный контекст — движок отдаёт все поля заявки; лишние данные шаблон
     просто игнорирует. → можно убрать любой тег без правки кода.
  3. Валидация шаблона (validate) — до экспорта показывает, какие теги в шаблоне
     движок не сможет заполнить. → редизайн шаблона безопасен и предсказуем.

Плюс: register_filter() добавляет свои Jinja-фильтры на лету, а сам бэкенд
рендера меняется переопределением метода render() в наследнике.

Язык: docxtpl работает на уровне XML, Jinja — нативно в Unicode. Кириллица и
казахский в шаблоне и в данных сохраняются без искажений.
"""

from __future__ import annotations

import datetime as _dt_mod
import os
import sys
import shutil
import subprocess
from datetime import datetime, date
from pathlib import Path
from typing import Any, Callable, Iterable

from docxtpl import DocxTemplate
from jinja2 import Environment, ChainableUndefined


APP_NAME = "ITtool"                     # общая папка объединённого приложения
TEMPLATE_FILENAME = "purchase_request.docx"


# ─────────────────────────────────────────────────────────────────────────────
#  Тихий Undefined: любой неизвестный/пропущенный тег → пустая строка.
#  ChainableUndefined позволяет и цепочки ({{ it.foo.bar }}) без падения.
# ─────────────────────────────────────────────────────────────────────────────

def _org_profile() -> dict:
    """Данные организации, которые пользователь ввёл при первом запуске."""
    try:
        import db
        return db.get_org_profile()
    except Exception:
        return {}

class SilentUndefined(ChainableUndefined):
    __slots__ = ()

    def __str__(self) -> str:            # {{ missing }} → ''
        return ""

    def __html__(self) -> str:
        return ""


# ─────────────────────────────────────────────────────────────────────────────
#  Встроенные фильтры форматирования (доступны в шаблоне)
# ─────────────────────────────────────────────────────────────────────────────
NBSP = "\u00A0"


def flt_money(value: Any, symbol: str = "") -> str:
    """{{ 45000 | money }} → '45 000'; {{ 45000 | money('₸') }} → '45 000 ₸'.
    Разделитель разрядов — неразрывный пробел. Дробные — с запятой (рус.)."""
    if value is None or value == "":
        return ""
    try:
        num = float(value)
    except (TypeError, ValueError):
        return str(value)
    neg = num < 0
    num = abs(num)
    if abs(num - round(num)) < 1e-9:
        body = f"{int(round(num)):,}".replace(",", NBSP)
    else:
        body = f"{num:,.2f}".replace(",", NBSP).replace(".", ",")
    if neg:
        body = "-" + body
    if symbol:
        body = f"{body}{NBSP}{symbol}"
    return body


def flt_date(value: Any, fmt: str = "%d.%m.%Y") -> str:
    """{{ '2026-08-11' | date }} → '11.08.2026'. Понимает datetime/date/ISO-строку."""
    if value is None or value == "":
        return ""
    if isinstance(value, datetime):
        return value.strftime(fmt)
    if isinstance(value, date):
        return value.strftime(fmt)
    s = str(value).strip()
    for parse_fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S",
                      "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s[:len(parse_fmt) + 4], parse_fmt).strftime(fmt)
        except ValueError:
            continue
    return s  # не распознали — отдаём как есть, не роняем


def flt_upper(value: Any) -> str:
    return str(value or "").upper()


DEFAULT_FILTERS: dict[str, Callable] = {
    "money": flt_money,
    "date": flt_date,
    "upper": flt_upper,
}


# ─────────────────────────────────────────────────────────────────────────────
#  Экспортер
# ─────────────────────────────────────────────────────────────────────────────
class PurchaseRequestExporter:
    """Выгрузка заявки в Word по внешнему, свободно изменяемому шаблону.

    Пути:
        template_path — активный шаблон. По умолчанию:
            %APPDATA%/<APP_NAME>/templates/purchase_request.docx
        При отсутствии — install_default_template() кладёт эталон рядом с приложением.
    """

    def __init__(self, template_path: str | os.PathLike | None = None,
                 appdata_dir: str | os.PathLike | None = None) -> None:
        self.appdata_dir = Path(appdata_dir) if appdata_dir else self._default_appdata()
        self.template_dir = self.appdata_dir / "templates"
        self.template_dir.mkdir(parents=True, exist_ok=True)
        self.template_path = Path(template_path) if template_path \
            else self.template_dir / TEMPLATE_FILENAME
        # копия словаря — чтобы register_filter у одного экземпляра не влиял на другие
        self._filters: dict[str, Callable] = dict(DEFAULT_FILTERS)

    # ── пути / APPDATA ──────────────────────────────────────────────────────
    @staticmethod
    def _default_appdata() -> Path:
        base = os.environ.get("APPDATA")            # Windows
        if not base:
            base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
        return Path(base) / APP_NAME

    # ── управление шаблоном ─────────────────────────────────────────────────
    def install_default_template(self, source_path: str | os.PathLike,
                                 overwrite: bool = False) -> Path:
        """Кладёт эталонный шаблон в APPDATA, если его там ещё нет.
        Вызывать на старте приложения (source_path — файл рядом с exe)."""
        if self.template_path.exists() and not overwrite:
            return self.template_path
        shutil.copyfile(source_path, self.template_path)
        return self.template_path

    def set_template(self, path: str | os.PathLike) -> Path:
        """Подсунуть совсем другой файл шаблона (путь сохранить в settings)."""
        p = Path(path)
        if not p.is_file():
            raise FileNotFoundError(f"Шаблон не найден: {p}")
        self.template_path = p
        return p

    def open_template_folder(self) -> None:
        """Открыть папку с шаблоном в проводнике/файловом менеджере."""
        folder = str(self.template_path.parent)
        if sys.platform.startswith("win"):
            os.startfile(folder)                                    # noqa: S606
        elif sys.platform == "darwin":
            subprocess.Popen(["open", folder])
        else:
            subprocess.Popen(["xdg-open", folder])

    def open_template_in_word(self) -> None:
        """Открыть сам файл шаблона на редактирование."""
        path = str(self.template_path)
        if sys.platform.startswith("win"):
            os.startfile(path)                                      # noqa: S606
        elif sys.platform == "darwin":
            subprocess.Popen(["open", path])
        else:
            subprocess.Popen(["xdg-open", path])

    # ── расширяемость: свои фильтры ─────────────────────────────────────────
    def register_filter(self, name: str, func: Callable) -> None:
        """Добавить свой Jinja-фильтр, доступный в шаблоне как {{ x | name }}."""
        self._filters[name] = func

    # ── контекст ────────────────────────────────────────────────────────────
    def build_context(self, request: dict) -> dict:
        """Разворачивает запись заявки в полный контекст шаблона.

        Ожидаемые ключи request (все опциональны — чего нет, будет пустым):
            number, created_at, employee, org_unit, asset, priority, status,
            justification, notes, approver, approved_date,
            items: [ {name, qty, price|unit_price, ...}, ... ]

        FK на имена (employee/org_unit/asset) приложение подставляет заранее —
        экспортер БД не трогает.
        """
        items_in: Iterable[dict] = request.get("items") or []
        items_out: list[dict] = []
        total = 0.0
        for i, raw in enumerate(items_in, start=1):
            qty = _num(raw.get("qty"), default=0)
            qty = int(qty) if float(qty).is_integer() else qty   # 3.0 → 3
            price = _num(raw.get("price", raw.get("unit_price")), default=0.0)
            line_sum = qty * price
            total += line_sum
            item = dict(raw)                       # сохраняем все исходные поля позиции
            item.update({
                "n": i,
                "qty": qty,
                "unit": raw.get("unit", "шт."),   # единица измерения (по умолч. «шт.»)
                "price": price,
                "sum": line_sum,
            })
            items_out.append(item)

        org = _org_profile()
        return {
            # --- шапка / адресат бланка (данные организации — из профиля) ---
            "form_code": request.get("form_code", ""),
            "org_name": request.get("org_name", org.get("org_name", "")),
            "org_branch": request.get("org_branch", org.get("branch_gen")
                                      or org.get("branch", "")),
            "year": str(_dt_mod.date.today().year),
            "director_title": request.get("director_title", "Директор"),
            "director": request.get("director", ""),
            "department": request.get("department", ""),
            # --- тело заявки ---
            "number": request.get("number", ""),
            "date": flt_date(request.get("created_at")) or _today(),
            "employee": request.get("employee", ""),
            "org_unit": request.get("org_unit", ""),
            "asset": request.get("asset", ""),
            "priority": request.get("priority", ""),
            "status": request.get("status", ""),
            "justification": request.get("justification", ""),
            "notes": request.get("notes", ""),
            # --- подписанты (по умолч. — текущие лица филиала) ---
            "accountant": request.get("accountant", org.get("accountant", "")),
            "head_of_dept": request.get("head_of_dept", ""),
            "sysadmin": request.get("sysadmin", org.get("fio", "")),
            "responsible_title": request.get("responsible_title",
                                             org.get("position", "")
                                             or "Ответственный"),
            "approver": request.get("approver", ""),
            "approved_date": flt_date(request.get("approved_date")),
            # --- позиции ---
            "items": items_out,
            "total": total,
            "items_count": len(items_out),
            # удобный доступ ко всей исходной записи, если шаблон захочет своё поле
            "raw": request,
        }

    def available_keys(self) -> list[str]:
        """Верхнеуровневые переменные, которые движок кладёт в контекст.
        Плюс поля позиции внутри items[]: n, name, qty, price, sum (+ любые исходные)."""
        return sorted(self.build_context({}).keys())

    # ── интроспекция и валидация шаблона ────────────────────────────────────
    def template_variables(self, template_path: str | os.PathLike | None = None) -> set[str]:
        """Какие свободные переменные использует шаблон (loop-переменные не в счёт)."""
        tpl = DocxTemplate(str(template_path or self.template_path))
        return tpl.get_undeclared_template_variables(self._make_env())

    def validate(self, template_path: str | os.PathLike | None = None) -> dict:
        """Проверка перед экспортом. Возвращает:
            {'ok': bool,
             'used':    [теги в шаблоне],
             'unknown': [теги, которые движок НЕ заполнит],
             'unused':  [поля движка, которых нет в шаблоне]}
        unknown не роняет экспорт (тихий Undefined), но подсказывает опечатку."""
        used = self.template_variables(template_path)
        provided = set(self.available_keys())
        unknown = sorted(used - provided)
        return {
            "ok": not unknown,
            "used": sorted(used),
            "unknown": unknown,
            "unused": sorted(provided - used),
        }

    # ── рендер (единственная точка сборки; переопредели для смены бэкенда) ───
    def _make_env(self) -> Environment:
        env = Environment(undefined=SilentUndefined, autoescape=False)
        env.filters.update(self._filters)
        return env

    def render(self, request: dict, output_path: str | os.PathLike,
               template_path: str | os.PathLike | None = None) -> Path:
        """Собрать .docx по шаблону. Шаблон перечитывается КАЖДЫЙ раз — правки в
        Word применяются сразу, без кеша и перезапуска приложения."""
        tpl_path = Path(template_path or self.template_path)
        if not tpl_path.is_file():
            raise FileNotFoundError(
                f"Шаблон не найден: {tpl_path}. "
                f"Положите {TEMPLATE_FILENAME} в {self.template_dir} "
                f"или укажите другой файл через set_template()."
            )
        doc = DocxTemplate(str(tpl_path))
        context = self.build_context(request)
        doc.render(context, self._make_env())
        out = Path(output_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        doc.save(str(out))
        return out

    # ── демо-данные (для предпросмотра и тестов) ────────────────────────────
    @staticmethod
    def sample_request() -> dict:
        return {
            "number": "2026-014",
            "created_at": "2026-08-11 10:30:00",
            "department": "отдела информационных технологий",
            "employee": "Иванов Иван Иванович",
            "org_unit": "Отдел ИТ",
            "priority": "Высокий",
            "status": "На согласовании",
            "justification": "плановое обновление парка техники отдела",
            "items": [
                {"name": "Ремонт принтера HP LaserJet 1320", "qty": 1, "unit": "шт."},
                {"name": "SSD Samsung 990 EVO 2TB",          "qty": 3, "unit": "шт."},
                {"name": "Кабель питания C13",               "qty": 10, "unit": "шт."},
            ],
        }


# ── вспомогательное ─────────────────────────────────────────────────────────
def _num(value: Any, default: float = 0.0) -> float:
    if value is None or value == "":
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _today(fmt: str = "%d.%m.%Y") -> str:
    return datetime.now().strftime(fmt)
