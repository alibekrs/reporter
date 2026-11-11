# -*- coding: utf-8 -*-
"""ITtool: заявки на закуп — списки для формы, сборка, сохранение, выгрузка в Word.

Хранение — таблицы purchase_requests / purchase_items в db.py; бланк — шаблон
docxtpl в папке данных (templates/purchase_request.docx).
"""
from __future__ import annotations

import datetime
import os
import shutil

import db

STATUSES = ["Черновик", "На согласовании", "Согласовано", "Закуплено", "Отклонено"]
UNITS = ["шт.", "компл.", "уп.", "м", "кг", "л"]
# расходники, которые не заводятся в карточке сотрудника
MATERIALS = ["Мышь", "Клавиатура", "Коврик для мыши", "Картридж", "Тонер",
             "Кабель HDMI", "Кабель питания", "Патч-корд (сетевой кабель)",
             "Наушники", "Веб-камера", "USB-флеш-накопитель", "Батарейки",
             "Сетевой фильтр / удлинитель"]
DIRECTOR_TITLES = ["И.о. директора", "Директор", "Генеральный директор"]
_REQUIRED_TAGS = ("head_of_dept", "director_title", "director",
                  "org_name", "accountant", "sysadmin")


def exporter():
    """Выгрузка по шаблону из папки данных. Нет шаблона или он старый (без
    обязательных полей) — ставим эталонный из программы."""
    from docx_export import PurchaseRequestExporter
    ex = PurchaseRequestExporter(appdata_dir=db.data_dir())
    bundled = os.path.join(os.path.dirname(os.path.abspath(__file__)), "purchase_request.docx")
    if os.path.exists(bundled):
        try:
            if not ex.template_path.exists():
                shutil.copyfile(bundled, ex.template_path)
            else:
                from docx import Document
                text = " ".join(p.text for p in Document(str(ex.template_path)).paragraphs)
                if not all(tag in text for tag in _REQUIRED_TAGS):
                    shutil.copyfile(bundled, ex.template_path)
        except Exception:
            pass
    return ex


def new_request():
    pd = db.get_purchase_defaults()
    return {"id": None, "number": db.next_pr_number(),
            "created_at": datetime.date.today().isoformat(), "department": "",
            "employee_id": "", "justification": "", "status": "Черновик",
            "head_of_dept": "", "items": [],
            "director_title": pd.get("director_title", "Директор"),
            "director": pd.get("director", "")}


def get_request(rid):
    rec = db.pr_get(int(rid))
    if not rec:
        raise ValueError("Заявка не найдена — возможно, её уже удалили.")
    pd = db.get_purchase_defaults()
    rec.setdefault("director_title", pd.get("director_title", "Директор"))
    rec.setdefault("director", pd.get("director", ""))
    return rec


def build(d):
    """Запись заявки из формы: пустые позиции отброшены, «1,5» → 1.5."""
    items = []
    for it in d.get("items") or []:
        name = str(it.get("name") or "").strip()
        if not name:
            continue
        try:
            qty = float(str(it.get("qty", "")).replace(",", "."))
        except ValueError:
            qty = 1
        items.append({"name": name, "qty": qty, "unit": str(it.get("unit") or "").strip() or "шт."})
    return {"id": d.get("id") or None, "number": str(d.get("number") or "").strip(),
            "created_at": str(d.get("created_at") or "") or datetime.date.today().isoformat(),
            "department": str(d.get("department") or "").strip(),
            "employee_id": d.get("employee_id") or "",
            "justification": str(d.get("justification") or "").strip(),
            "status": d.get("status") or "Черновик",
            "head_of_dept": str(d.get("head_of_dept") or "").strip(), "items": items}


def save(d):
    """Сохранить заявку и адресата бланка. Род. падеж отдела запоминается
    за подразделением (d["unit_id"]). Возвращает id."""
    rec = build(d)
    if not rec["department"] and not rec["items"]:
        raise ValueError("Заполните отдел и хотя бы одну позицию.")
    uid = d.get("unit_id")
    if uid and rec["department"]:
        db.set_dept_genitive(uid, rec["department"])
    rid = db.pr_save(rec)
    db.set_purchase_defaults(str(d.get("director_title") or ""), str(d.get("director") or ""))
    return rid


def export_docx(d, path):
    """Сохранить и выгрузить в Word по шаблону. Возвращает id заявки."""
    rec = build(d)
    if not rec["items"]:
        raise ValueError("Добавьте хотя бы одну позицию.")
    rid = save(d)
    emp = db.employee_by_id(rec["employee_id"])
    title, director = str(d.get("director_title") or ""), str(d.get("director") or "")
    context = {"number": rec["number"], "created_at": rec["created_at"],
               "department": rec["department"], "employee": emp["fio"] if emp else "",
               "justification": rec["justification"], "status": rec["status"],
               "director_title": title.strip() or "И.о. директора",
               "director": director.strip(), "items": rec["items"]}
    if rec["head_of_dept"]:
        context["head_of_dept"] = rec["head_of_dept"]
    try:
        exporter().render(context, path)
    except Exception as ex:
        raise ValueError(f"Ошибка экспорта: {ex}") from None
    return rid


def file_name(number):
    return f"Заявка_{number}.docx".replace(" ", "_")
