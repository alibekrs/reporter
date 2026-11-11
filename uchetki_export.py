# -*- coding: utf-8 -*-
"""Таблица «Учётки»: ФИО, учётная запись, MAC, инвентарный номер.

Данные берутся из карточек сотрудников и их компьютеров."""
import json
import re
import sqlite3

BRANCH = None          # берётся из данных организации
DOMAIN = ""            # домен почты, если нужен транслит-логин
# единое название персональной учётной записи для всех сотрудников
# (пусто → генерировать транслитом вида Фамилия.и@домен)
ACCOUNT_LABEL = "Интернет"

# транслитерация: русский + казахские буквы (образец: Ахметов → Akhmetov)
TRANS = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    # казахские
    "ә": "a", "ғ": "g", "қ": "k", "ң": "ng", "ө": "o", "ұ": "u", "ү": "u",
    "һ": "h", "і": "i",
}


def translit(text: str) -> str:
    out = []
    for ch in (text or ""):
        low = ch.lower()
        rep = TRANS.get(low, low if low.isascii() else "")
        out.append(rep.capitalize() if ch.isupper() and rep else rep)
    return "".join(out)


def short_fio(emp: dict) -> str:
    """'Ахметов Асхат Асанович' → 'Ахметов А.А.'"""
    last = (emp.get("last_name") or "").strip()
    first = (emp.get("first_name") or "").strip()
    mid = (emp.get("middle_name") or "").strip()
    initials = ""
    if first:
        initials += first[0].upper() + "."
    if mid:
        initials += mid[0].upper() + "."
    return f"{last} {initials}".strip()


def account(emp: dict) -> str:
    """'Ахметов Асхат' → 'Akhmetov.a' (+ @домен, если задан)."""
    last = translit((emp.get("last_name") or "").strip())
    first = translit((emp.get("first_name") or "").strip())
    last = re.sub(r"[^A-Za-z\-]", "", last)
    if not last:
        return ""
    initial = first[:1].lower() if first else ""
    login = f"{last}.{initial}" if initial else last
    return f"{login}@{DOMAIN}" if DOMAIN else login


def default_branch() -> str:
    """Филиал из данных организации: «Северный филиал» → «Северный»."""
    try:
        import db
        b = db.get_org_profile().get("branch", "").strip()
    except Exception:
        b = ""
    words = b.split()
    if len(words) >= 2 and words[-1].lower() == "филиал":
        return " ".join(words[:-1])
    return b


def rows_from_store(employees: list, units: list, branch: str = None) -> list:
    """Строит строки таблицы прямо из данных вкладки «Сотрудники и техника»."""
    um = {u["id"]: u for u in units}

    def unit_name(uid):
        return (um.get(uid) or {}).get("name", "")

    emps = sorted(employees, key=lambda e: (unit_name(e.get("unit_id")),
                                            e.get("order", 0),
                                            (e.get("last_name") or "")))
    rows = []
    for e in emps:
        if not (e.get("last_name") or "").strip():
            continue
        fio = short_fio(e)
        acc = (e.get("account") or "").strip() or ACCOUNT_LABEL or account(e)
        pcs = e.get("pcs") or []
        if not pcs:
            rows.append({"fio": fio, "account": acc, "inv": "", "mac": "",
                         "ip": "", "unit": unit_name(e.get("unit_id"))})
            continue
        for pc in pcs:
            rows.append({"fio": fio, "account": acc,
                         "inv": (pc.get("inv") or "").strip(),
                         "mac": (pc.get("mac") or "").strip().upper(),
                         "ip": (pc.get("ip") or "").strip(),
                         "unit": unit_name(e.get("unit_id")),
                         "hostname": (pc.get("hostname") or "").strip()})
    return rows


def build_docx(out_path, rows: list, branch: str = None, with_ip: bool = False):
    """Создаёт документ с таблицей учётных записей (бланк не требуется)."""
    if branch is None:
        branch = default_branch()
    from docx import Document
    from docx.shared import Pt, Mm
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.enum.table import WD_ALIGN_VERTICAL

    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Mm(210), Mm(297)
    sec.top_margin, sec.bottom_margin = Mm(20), Mm(20)
    sec.left_margin, sec.right_margin = Mm(20), Mm(15)

    normal = doc.styles["Normal"]
    normal.font.name = "Times New Roman"
    normal.font.size = Pt(11)

    headers = ["№", "Филиал", "Ф.И.О. работника", "Персональная учетная запись",
               "MAC-адрес"]
    widths = [9, 27, 45, 26, 38]
    if with_ip:
        headers.append("IP-адрес")
        widths.append(28)
    headers.append("Инвентарный №")
    widths.append(20 if not with_ip else 18)
    if with_ip:                      # ужимаем, чтобы влезть в ширину листа
        widths = [8, 26, 38, 24, 34, 26, 16]

    table = doc.add_table(rows=1, cols=len(headers))
    table.style = "Table Grid"
    table.autofit = False
    for i, h in enumerate(headers):
        cell = table.rows[0].cells[i]
        cell.text = ""
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(0)
        run = p.add_run(h)
        run.bold = True
        run.font.size = Pt(10)

    for n, r in enumerate(rows, 1):
        cells = table.add_row().cells
        vals = [str(n), branch, r["fio"], r["account"], r.get("mac", "")]
        if with_ip:
            vals.append(r.get("ip", ""))
        vals.append(r.get("inv", ""))
        for i, v in enumerate(vals):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            p.paragraph_format.space_after = Pt(0)
            run = p.add_run(str(v or ""))
            run.font.size = Pt(10)
            cells[i].vertical_alignment = WD_ALIGN_VERTICAL.CENTER

    from docx.oxml.ns import qn
    for row in table.rows:
        for i, c in enumerate(row.cells):
            c.width = Mm(widths[i])
    grid = table._tbl.find(qn("w:tblGrid"))
    if grid is not None:
        for gc, w in zip(grid.findall(qn("w:gridCol")), widths):
            gc.set(qn("w:w"), str(int(Mm(w).twips)))

    doc.save(str(out_path))
    return str(out_path)


# ── импорт MAC/IP из внешних выгрузок ───────────────────────────────────────
def import_from_scan(csv_path: str) -> dict:
    """CSV сканера сети (scan_net.ps1): {MAC: {'ip':…, 'name':…}}."""
    import csv
    out = {}
    for enc in ("utf-8-sig", "cp1251"):
        try:
            with open(csv_path, encoding=enc, newline="") as fh:
                sample = fh.read(4096)
                fh.seek(0)
                delim = ";" if sample.count(";") >= sample.count(",") else ","
                for row in csv.DictReader(fh, delimiter=delim):
                    keys = {k.lower().strip(): (v or "").strip()
                            for k, v in row.items() if k}
                    mac = keys.get("mac") or keys.get("mac-адрес") or ""
                    if not mac:
                        continue
                    out[mac.upper().replace("-", ":")] = {
                        "ip": keys.get("ip") or keys.get("ip-адрес") or "",
                        "name": keys.get("имя") or keys.get("name") or "",
                    }
            break
        except UnicodeDecodeError:
            continue
    return out


def apply_network_data(employees: list, mac_by_emp: dict,
                       scan: dict = None) -> int:
    """Проставляет MAC (и IP из данных сканера) в карточки компьютеров.

    mac_by_emp: {id сотрудника: [MAC, …]} — например, результат сопоставления
    с выгрузкой интернет-шлюза. Заполняются только пустые поля.
    """
    scan = scan or {}
    changed = 0
    for emp in employees:
        macs = list(mac_by_emp.get(emp.get("id")) or [])
        if not macs:
            continue
        for idx, pc in enumerate(emp.get("pcs") or []):
            if idx >= len(macs):
                break
            mac = macs[idx].upper().replace("-", ":")
            if not (pc.get("mac") or "").strip():
                pc["mac"] = mac
                changed += 1
            info = scan.get(mac)
            if info and info.get("ip") and not (pc.get("ip") or "").strip():
                pc["ip"] = info["ip"]
    return changed
