# -*- coding: utf-8 -*-
"""ITtool: учёт выдачи картриджей — кто, когда, какой и сколько забрал.

Здесь правила записи, сводки по сотрудникам и по моделям, выдачи за период
и выгрузка в Excel; хранение — в db.py (таблица cartridge_issues).
"""
from __future__ import annotations

import datetime

import db

MONTHS = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август",
          "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]
MONTHS_SHORT = ["Янв", "Фев", "Мар", "Апр", "Май", "Июн", "Июл", "Авг", "Сен", "Окт",
                "Ноя", "Дек"]


def period(year, month=0):
    """(первый день, последний день, подпись): месяц или, при month=0, весь год."""
    if not month:
        return f"{year}-01-01", f"{year}-12-31", f"{year} год"
    first = datetime.date(year, month, 1)
    nxt = datetime.date(year + (month == 12), month % 12 + 1, 1)
    last = nxt - datetime.timedelta(days=1)
    return first.isoformat(), last.isoformat(), f"{MONTHS[month - 1]} {year}"


def find_people(text, people):
    """Кого имели в виду. Полное ФИО — точное совпадение; иначе подходят все, у
    кого каждое введённое слово начинает какое-то слово ФИО («Даулет», «Кенж Әл»).
    people — [{id, fio, ...}]."""
    want = " ".join(str(text or "").split()).casefold()
    if not want:
        return []
    exact = [p for p in people if p["fio"].casefold() == want]
    if exact:
        return exact
    tokens = want.split()
    return [p for p in people
            if all(any(w.startswith(t) for w in p["fio"].casefold().split())
                   for t in tokens)]


def clean(d, today=None):
    """Проверенные поля записи: дата, модель, количество, примечание.
    Отказ — ValueError с текстом, который форма покажет как есть."""
    today = today or datetime.date.today()
    try:
        day = datetime.date.fromisoformat(str(d.get("date") or ""))
    except ValueError:
        raise ValueError("Укажите дату выдачи.") from None
    if day > today:
        raise ValueError("Дата выдачи ещё не наступила — проверьте дату.")
    model = " ".join(str(d.get("model") or "").split())
    if not model:
        raise ValueError("Укажите картридж, например «285».")
    raw = d.get("qty")
    try:
        qty = int(str(1 if raw in (None, "") else raw).strip())
    except ValueError:
        qty = 0
    if not 1 <= qty <= 999:
        raise ValueError("Количество — целое число от 1.")
    return {"issued_at": day.isoformat(), "model": model, "qty": qty,
            "note": " ".join(str(d.get("note") or "").split())}


def summary(items):
    """Сводка по выдачам. items — [{date, key, employee, unit, model, qty}], где
    key — один на человека. Строки — от тех, кто взял больше; у каждой итог,
    разбивка по месяцам и состав (какие картриджи / кто брал)."""
    people, models, months = {}, {}, [0] * 12
    for it in items:
        m, q = int(it["date"][5:7]) - 1, it["qty"]
        months[m] += q
        p = people.setdefault(it["key"], {
            "key": it["key"], "employee": it["employee"], "unit": it["unit"],
            "total": 0, "months": [0] * 12, "models": {}})
        p["total"] += q
        p["months"][m] += q
        p["models"][it["model"]] = p["models"].get(it["model"], 0) + q
        c = models.setdefault(it["model"], {
            "model": it["model"], "total": 0, "months": [0] * 12, "people": {}})
        c["total"] += q
        c["months"][m] += q
        c["people"][it["employee"]] = c["people"].get(it["employee"], 0) + q

    def top(counts):
        return sorted(counts.items(), key=lambda x: (-x[1], x[0].casefold()))

    by_employee = sorted(people.values(),
                         key=lambda p: (-p["total"], p["employee"].casefold()))
    for p in by_employee:
        p["models"] = top(p["models"])
    by_model = sorted(models.values(), key=lambda c: (-c["total"], c["model"].casefold()))
    for c in by_model:
        c["people"] = top(c["people"])
    return {"by_employee": by_employee, "by_model": by_model, "months": months,
            "total": sum(months)}


def mix(pairs):
    """[(название, сколько)] → «285 × 3, 725 × 1»."""
    return ", ".join(f"{name} × {q}" for name, q in pairs)


def export_name(year, month=0):
    return f"Картриджи_{MONTHS[month - 1]}_{year}.xlsx" if month else f"Картриджи_{year}.xlsx"


def export_xlsx(path, items, summ, by_months=True):
    """Отчёт в Excel: кто сколько взял, расход по моделям и сам журнал выдач.
    by_months — показывать ли столбцы месяцев (для отчёта за год)."""
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter

    head_fill = PatternFill("solid", fgColor="1E66F5")
    head_font = Font(bold=True, color="FFFFFF", name="Calibri", size=11)
    bold = Font(bold=True, name="Calibri", size=11)
    thin = Side(style="thin", color="D0D0D0")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)

    def fill(ws, header, rows, widths, total=None, wrap=()):
        ws.append(header)
        for c in ws[1]:
            c.fill, c.font, c.border = head_fill, head_font, border
            c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        for row in rows + ([total] if total else []):
            ws.append(row)
            for ci in range(1, len(row) + 1):
                cell = ws.cell(row=ws.max_row, column=ci)
                cell.border = border
                cell.alignment = Alignment(vertical="center", wrap_text=ci in wrap)
                if row is total:
                    cell.font = bold
        for i, w in enumerate(widths, start=1):
            ws.column_dimensions[get_column_letter(i)].width = w
        ws.freeze_panes = "B2"

    cols = MONTHS_SHORT if by_months else []
    per_month = (lambda ms: [q or None for q in ms]) if by_months else (lambda ms: [])
    wb = Workbook()

    ws = wb.active
    ws.title = "По сотрудникам"
    fill(ws, ["Сотрудник", "Подразделение"] + cols + ["Итого", "Какие картриджи"],
         [[p["employee"], p["unit"]] + per_month(p["months"]) + [p["total"], mix(p["models"])]
          for p in summ["by_employee"]],
         [30, 26] + [6] * len(cols) + [8, 40],
         total=["Итого", ""] + per_month(summ["months"]) + [summ["total"], ""],
         wrap=(len(cols) + 4,))

    ws = wb.create_sheet("По картриджам")
    fill(ws, ["Картридж"] + cols + ["Итого", "Кто брал"],
         [[c["model"]] + per_month(c["months"]) + [c["total"], mix(c["people"])]
          for c in summ["by_model"]],
         [22] + [6] * len(cols) + [8, 60],
         total=["Итого"] + per_month(summ["months"]) + [summ["total"], ""],
         wrap=(len(cols) + 3,))

    ws = wb.create_sheet("Журнал")
    fill(ws, ["Дата", "Сотрудник", "Подразделение", "Картридж", "Кол-во", "Примечание"],
         [[datetime.date.fromisoformat(it["date"]), it["employee"], it["unit"],
           it["model"], it["qty"], it["note"]] for it in items],
         [12, 30, 26, 22, 8, 40], wrap=(6,))
    for row in ws.iter_rows(min_row=2, max_col=1):
        row[0].number_format = "DD.MM.YYYY"
    ws.auto_filter.ref = ws.dimensions

    wb.save(path)


# ── выдачи ──────────────────────────────────────────────────────────────────
def people(store):
    """Сотрудники из учёта — по ним ведётся счёт выдач. store — assets.load_store()."""
    import assets as ma
    out = []
    for e in sorted(store["employees"], key=lambda x: ma.fio(x).lower()):
        if not any(e.get(k) for k in ("last_name", "first_name", "middle_name")):
            continue                              # новая карточка без имени
        u = ma.unit_by_id(store["units"], e.get("unit_id"))
        out.append({"id": e["id"], "fio": ma.fio(e),
                    "unit": u["name"] if u and u.get("parent_id") else ""})
    return out


def items(year, month, plist, q=""):
    """Выдачи за период по фильтру (все слова — в сотруднике, отделе, картридже
    или примечании). Сотрудник из учёта показан как записан сейчас; кого в учёте
    уже нет или кто вписан вручную — под именем на день выдачи."""
    d1, d2, label = period(year, month)
    tokens = str(q or "").casefold().split()
    by_id = {p["id"]: p for p in plist}
    out = []
    for r in db.cart_list(d1, d2):
        p = by_id.get(r["employee_id"])
        it = {"id": r["id"], "date": r["issued_at"],
              "employee_id": r["employee_id"] or "",
              "employee": p["fio"] if p else (r["employee"] or ""),
              "unit": p["unit"] if p else "",
              "key": r["employee_id"] or "=" + (r["employee"] or "").casefold(),
              "model": r["model"] or "", "qty": int(r["qty"] or 0),
              "note": r["note"] or ""}
        hay = " ".join((it["employee"], it["unit"], it["model"], it["note"])).casefold()
        if all(t in hay for t in tokens):
            out.append(it)
    return out, label


class UnknownPerson(ValueError):
    """Имени нет в учёте — запись возможна только после подтверждения."""


def save(d, plist, allow_unknown=False):
    """Отметить выдачу или поправить запись (d["id"]). Имя, которого нет в учёте,
    — UnknownPerson, пока не передано allow_unknown. Возвращает (id, текст)."""
    rid = int(d.get("id") or 0)
    old = db.cart_get(rid) if rid else None
    if rid and not old:
        raise ValueError("Запись не найдена — возможно, её уже удалили.")
    who = " ".join(str(d.get("employee") or "").split())
    if not who:
        raise ValueError("Укажите, кто забрал картридж.")
    rec = clean(d)
    found = find_people(who, plist)
    if len({p["fio"].casefold() for p in found}) > 1:
        names = ", ".join(p["fio"] for p in found[:5]) + ("…" if len(found) > 5 else "")
        raise ValueError(f"По «{who}» нашлось несколько сотрудников: {names}. "
                         "Уточните имя.")
    if found:
        rec["employee_id"], rec["employee"] = found[0]["id"], found[0]["fio"]
    elif old and (old["employee"] or "").casefold() == who.casefold():
        rec["employee_id"], rec["employee"] = old["employee_id"] or "", old["employee"]
    else:
        if not allow_unknown:
            raise UnknownPerson(f"«{who}» нет в списке сотрудников.\n"
                                "Записать выдачу на это имя?")
        rec["employee_id"], rec["employee"] = "", who
    if not rid:                                   # «ce285a» и «CE285A» — одна модель
        known = {m.casefold(): m for m in db.cart_models()}
        rec["model"] = known.get(rec["model"].casefold(), rec["model"])
    rec["id"] = rid or None
    new_id = db.cart_save(rec)
    return new_id, f"{rec['employee']} — {rec['model']}, {rec['qty']} шт."
