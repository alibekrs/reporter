# -*- coding: utf-8 -*-
"""Аудит парка компьютеров: что под замену, что модернизировать.

Логика вердикта (по решению заказчика):
  ЗАМЕНА       — процессор не тянет Windows 10 Pro (или техника неисправна).
  МОДЕРНИЗАЦИЯ — процессор тянет, но не хватает ОЗУ и/или стоит HDD вместо SSD.
  НОРМА        — соответствует минимуму; отдельно отмечается готовность к Windows 11.

Пороговые значения вынесены в константы — при смене политики правятся здесь.
"""
from __future__ import annotations

import re
from datetime import date

# ── пороги (правятся при смене политики организации) ────────────────────────
RAM_MIN_GB = 4.0            # минимум для Windows 10 Pro на практике
RAM_COMFORT_GB = 8.0        # комфортный минимум для офисной работы
INTEL_CORE_GEN_WIN10 = 2    # Intel Core i3/i5/i7 от 2-го поколения тянут Win 10
INTEL_CORE_GEN_WIN11 = 8    # официальное требование Windows 11
RYZEN_GEN_WIN11 = 2000      # Ryzen 2000-й серии и новее

# ОС, снятые с поддержки полностью
DEAD_OS = ("Windows XP", "Windows Vista", "Windows 7", "Windows 8", "Windows 8.1")

VERDICT_REPLACE = "Замена"
VERDICT_UPGRADE = "Модернизация"
VERDICT_OK = "Норма"


# ── разбор характеристик (поля заполняются вручную, поэтому терпимо к формату) ─
def parse_ram_gb(text: str) -> float | None:
    """'8 ГБ' / '8Gb' / '8192 МБ' / '16' → число гигабайт."""
    if not text:
        return None
    s = str(text).lower().replace(",", ".")
    m = re.search(r"(\d+(?:\.\d+)?)\s*(гб|gb|g|мб|mb|m)?", s)
    if not m:
        return None
    try:
        val = float(m.group(1))
    except ValueError:
        return None
    unit = (m.group(2) or "").strip()
    if unit in ("мб", "mb", "m"):
        return round(val / 1024.0, 1)
    if val > 128:                     # похоже, указали мегабайты без единицы
        return round(val / 1024.0, 1)
    return val


def parse_storage(text: str) -> dict:
    """Определяет тип накопителя и объём: {'kind': 'SSD'|'HDD'|'', 'gb': float|None}."""
    s = (text or "").lower()
    kind = ""
    if "ssd" in s or "nvme" in s or "m.2" in s or "твердотел" in s:
        kind = "SSD"
    elif "hdd" in s or "жёстк" in s or "жестк" in s or "sata" in s or "гибрид" in s:
        kind = "HDD"
    gb = None
    m = re.search(r"(\d+(?:[.,]\d+)?)\s*(тб|tb|гб|gb)", s)
    if m:
        try:
            v = float(m.group(1).replace(",", "."))
            gb = v * 1024 if m.group(2) in ("тб", "tb") else v
        except ValueError:
            pass
    return {"kind": kind, "gb": gb}


def parse_cpu(text: str) -> dict:
    """Классификация процессора.

    Возвращает {'ok_win10': bool|None, 'ok_win11': bool|None, 'note': str}.
    None означает «не удалось определить» — такие машины отмечаются отдельно.
    """
    s = (text or "").strip()
    if not s:
        return {"ok_win10": None, "ok_win11": None, "note": "процессор не указан"}
    low = s.lower().replace("®", "").replace("™", "")

    # заведомо устаревшие семейства — не тянут Windows 10 Pro на практике
    ancient = [
        ("core 2", "Core 2 (2006–2008 гг.)"),
        ("core2", "Core 2 (2006–2008 гг.)"),
        ("pentium 4", "Pentium 4 (2000-е гг.)"),
        ("pentium d", "Pentium D (2000-е гг.)"),
        ("pentium dual", "Pentium Dual-Core (2000-е гг.)"),
        ("celeron d", "Celeron D (2000-е гг.)"),
        ("atom", "Intel Atom (нетбучный, крайне слабый)"),
        ("sempron", "AMD Sempron (2000-е гг.)"),
        ("athlon 64", "AMD Athlon 64 (2000-е гг.)"),
        ("athlon x2", "AMD Athlon X2 (2000-е гг.)"),
        ("phenom", "AMD Phenom (2007–2010 гг.)"),
        ("xeon 3", "устаревший Xeon"),
    ]
    for key, note in ancient:
        if key in low:
            return {"ok_win10": False, "ok_win11": False, "note": note}

    # Intel Core iX-NNNN / iX NNNN
    m = re.search(r"\bi([3579])[\s\-]?(\d{3,5})", low)
    if m:
        num = m.group(2)
        gen = int(num[:2]) if len(num) >= 5 else (
            int(num[0]) if len(num) == 4 else 1)      # 3 цифры → 1-е поколение
        note = f"Intel Core i{m.group(1)}, {gen}-е поколение"
        if gen < INTEL_CORE_GEN_WIN10:
            return {"ok_win10": False, "ok_win11": False,
                    "note": note + " (2008–2010 гг.)"}
        return {"ok_win10": True, "ok_win11": gen >= INTEL_CORE_GEN_WIN11,
                "note": note}

    # Intel Core Ultra — заведомо новые
    if "core ultra" in low:
        return {"ok_win10": True, "ok_win11": True, "note": "Intel Core Ultra"}

    # AMD Ryzen N XXXX
    m = re.search(r"ryzen\s*([3579])?\s*(\d{4})", low)
    if m:
        series = int(m.group(2))
        note = f"AMD Ryzen {m.group(1) or ''} {m.group(2)}".replace("  ", " ").strip()
        return {"ok_win10": True, "ok_win11": series >= RYZEN_GEN_WIN11, "note": note}

    # Pentium / Celeron с 4-значным номером (Gxxxx, Nxxxx, Jxxxx)
    m = re.search(r"(pentium|celeron)(?:\s+(?:gold|silver))?\s*[gnj]?\s*(\d{4})", low)
    if m:
        num = int(m.group(2))
        fam = m.group(1).capitalize()
        # G2xxx и новее — Sandy Bridge+, тянут Win 10, но слабы и не идут на Win 11
        if num < 2000:
            return {"ok_win10": False, "ok_win11": False,
                    "note": f"{fam} {num} (устаревшая платформа)"}
        return {"ok_win10": True, "ok_win11": False,
                "note": f"{fam} {num} (бюджетный, для Windows 11 не подходит)"}

    m = re.search(r"(pentium|celeron)(?:\s+(?:gold|silver))?\s*[gnj]?\s*(\d{3})\b", low)
    if m:
        fam = m.group(1).capitalize()
        return {"ok_win10": True, "ok_win11": False,
                "note": f"{fam} {m.group(2)} (бюджетный, платформа 2011–2012 гг.)"}

    if "ryzen" in low:
        return {"ok_win10": True, "ok_win11": None, "note": s}
    return {"ok_win10": None, "ok_win11": None, "note": s}


# ── вердикт по одной машине ─────────────────────────────────────────────────
def analyze_pc(pc: dict) -> dict:
    """pc — словарь ПК из учёта. Возвращает вердикт, причины и рекомендации."""
    cpu = parse_cpu(pc.get("cpu", ""))
    ram = parse_ram_gb(pc.get("ram", ""))
    stor = parse_storage(pc.get("storage", ""))
    os_name = (pc.get("os", "") or "").strip()
    cond = (pc.get("condition", "") or "").strip().lower()

    reasons: list[str] = []
    actions: list[str] = []

    # 1) неисправность или прямая отметка — сразу замена
    if cond in ("неисправно", "требует замены"):
        reasons.append(f"состояние: {cond}")

    # 2) процессор — главный критерий
    if cpu["ok_win10"] is False:
        reasons.append(f"процессор не тянет Windows 10 Pro — {cpu['note']}")
    elif cpu["ok_win10"] is None:
        reasons.append("модель процессора не распознана — требуется проверка")

    # 3) ОЗУ и накопитель — критерии модернизации
    if ram is not None:
        if ram < RAM_MIN_GB:
            reasons.append(f"ОЗУ {ram:g} ГБ — ниже минимума {RAM_MIN_GB:g} ГБ")
            actions.append(f"увеличить ОЗУ до {RAM_COMFORT_GB:g} ГБ")
        elif ram < RAM_COMFORT_GB:
            actions.append(f"увеличить ОЗУ с {ram:g} до {RAM_COMFORT_GB:g} ГБ")
    if stor["kind"] == "HDD":
        actions.append("заменить жёсткий диск (HDD) на SSD")

    # 4) операционная система
    if os_name in DEAD_OS:
        reasons.append(f"{os_name} снята с поддержки")
    elif os_name.startswith("Windows 10"):
        reasons.append("Windows 10 снята с поддержки 14.10.2025")

    # ── итоговый вердикт ────────────────────────────────────────────────────
    if cond in ("неисправно", "требует замены") or cpu["ok_win10"] is False:
        verdict = VERDICT_REPLACE
        actions = ["заменить компьютер на новый"]
    elif actions:
        verdict = VERDICT_UPGRADE
    else:
        verdict = VERDICT_OK

    return {
        "verdict": verdict,
        "cpu_note": cpu["note"],
        "win11_ready": bool(cpu["ok_win11"]) and (ram or 0) >= RAM_MIN_GB,
        "win11_unknown": cpu["ok_win11"] is None,
        "ram_gb": ram,
        "storage_info": stor,
        "os": os_name,
        "reasons": reasons,
        "actions": actions,
    }


def collect(employees: list, units: list, unit_path_fn, fio_fn) -> list[dict]:
    """Обходит сотрудников и собирает строки по всем компьютерам/ноутбукам."""
    rows = []
    for emp in employees or []:
        who = fio_fn(emp) or "—"
        dept = ""
        try:
            dept = unit_path_fn(units, emp.get("unit_id")) or ""
        except Exception:
            dept = ""
        for pc in emp.get("pcs", []) or []:
            res = analyze_pc(pc)
            rows.append({
                "employee": who,
                "dept": dept,
                "is_laptop": bool(pc.get("is_laptop")),
                "kind": "Ноутбук/моноблок" if pc.get("is_laptop") else "ПК",
                "inv": pc.get("inv", "") or "",
                "hostname": pc.get("hostname", "") or "",
                "cpu": pc.get("cpu", "") or "",
                "ram": pc.get("ram", "") or "",
                "storage": pc.get("storage", "") or "",
                "os": pc.get("os", "") or "",
                "condition": pc.get("condition", "") or "",
                **res,
            })
    return rows


def summarize(rows: list[dict]) -> dict:
    """Сводные показатели по парку."""
    total = len(rows)
    repl = [r for r in rows if r["verdict"] == VERDICT_REPLACE]
    upgr = [r for r in rows if r["verdict"] == VERDICT_UPGRADE]
    ok = [r for r in rows if r["verdict"] == VERDICT_OK]
    by_dept: dict[str, dict] = {}
    for r in rows:
        d = by_dept.setdefault(r["dept"] or "—",
                               {"total": 0, "replace": 0, "upgrade": 0, "ok": 0})
        d["total"] += 1
        if r["verdict"] == VERDICT_REPLACE:
            d["replace"] += 1
        elif r["verdict"] == VERDICT_UPGRADE:
            d["upgrade"] += 1
        else:
            d["ok"] += 1
    return {
        "total": total,
        "replace": len(repl),
        "upgrade": len(upgr),
        "ok": len(ok),
        "laptops_replace": sum(1 for r in repl if r["is_laptop"]),
        "pcs_replace": sum(1 for r in repl if not r["is_laptop"]),
        "win11_ready": sum(1 for r in rows if r["win11_ready"]),
        "need_ram": sum(1 for r in rows
                        if any("ОЗУ" in a for a in r["actions"])),
        "need_ssd": sum(1 for r in rows
                        if any("SSD" in a for a in r["actions"])),
        "dead_os": sum(1 for r in rows if r["os"] in DEAD_OS),
        "by_dept": by_dept,
    }


def need_label(row: dict) -> str:
    """Короткая формулировка «что требуется» для строки таблицы."""
    if row["verdict"] == VERDICT_REPLACE:
        return "Замена компьютера"
    if row["actions"]:
        parts = []
        for a in row["actions"]:
            if "ОЗУ" in a:
                parts.append(f"ОЗУ до {RAM_COMFORT_GB:g} ГБ")
            elif "SSD" in a:
                parts.append("SSD взамен HDD")
            else:
                parts.append(a)
        return "; ".join(parts)
    return "—"


def budget_items(rows: list[dict]) -> list[dict]:
    """Сводная потребность в технике и комплектующих для планирования бюджета."""
    repl = [r for r in rows if r["verdict"] == VERDICT_REPLACE]
    pcs_new = sum(1 for r in repl if not r["is_laptop"])
    nb_new = sum(1 for r in repl if r["is_laptop"])
    ram_rows = [r for r in rows if r["verdict"] == VERDICT_UPGRADE
                and any("ОЗУ" in a for a in r["actions"])]
    ssd_rows = [r for r in rows if r["verdict"] == VERDICT_UPGRADE
                and any("SSD" in a for a in r["actions"])]

    items = []
    if pcs_new:
        items.append({
            "name": "Персональный компьютер в сборе (системный блок)",
            "spec": f"процессор не ниже Intel Core i3 актуального поколения, "
                    f"ОЗУ от {RAM_COMFORT_GB:g} ГБ, SSD от 240 ГБ, Windows 11 Pro",
            "qty": pcs_new, "unit": "шт.",
            "purpose": "замена морально устаревших ПК"})
    if nb_new:
        items.append({
            "name": "Ноутбук / моноблок",
            "spec": f"процессор не ниже Intel Core i3 актуального поколения, "
                    f"ОЗУ от {RAM_COMFORT_GB:g} ГБ, SSD от 240 ГБ, Windows 11 Pro",
            "qty": nb_new, "unit": "шт.",
            "purpose": "замена морально устаревшей техники"})
    if ram_rows:
        items.append({
            "name": "Модуль оперативной памяти",
            "spec": f"{RAM_COMFORT_GB:g} ГБ, тип (DDR3/DDR4) — по факту "
                    f"установленной материнской платы",
            "qty": len(ram_rows), "unit": "шт.",
            "purpose": "модернизация эксплуатируемых ПК"})
    if ssd_rows:
        items.append({
            "name": "Твердотельный накопитель SSD",
            "spec": "объёмом от 240 ГБ, интерфейс SATA III / M.2 — по факту "
                    "установленной материнской платы",
            "qty": len(ssd_rows), "unit": "шт.",
            "purpose": "замена жёстких дисков (HDD)"})
    return items


# ── текст служебной записки (запасной вариант без ИИ) ───────────────────────
def default_body(summary: dict) -> str:
    s = summary
    lines = [
        f"По состоянию на {date.today().strftime('%d.%m.%Y')} на балансе организации "
        f"числится {s['total']} ед. компьютерной техники (персональные компьютеры "
        f"и ноутбуки), находящейся в эксплуатации у сотрудников.",
        "",
        "В результате проведённой инвентаризации технического состояния установлено "
        "следующее.",
        "",
        f"1. {s['replace']} ед. техники морально и физически устарели и подлежат "
        f"замене (из них персональных компьютеров — {s['pcs_replace']}, "
        f"ноутбуков и моноблоков — {s['laptops_replace']}). Установленные в них "
        "процессоры не обеспечивают работу операционной системы Windows 10 Pro: "
        "они выпущены до 2011 года, не поддерживают современные наборы инструкций "
        "и не обладают производительностью, достаточной для штатной работы "
        "прикладного программного обеспечения. Модернизация данной техники "
        "экономически нецелесообразна — замене подлежат материнская плата, "
        "процессор и оперативная память, то есть фактически весь компьютер.",
        "",
        f"2. {s['upgrade']} ед. техники пригодны к дальнейшей эксплуатации при "
        "условии модернизации: требуется увеличение объёма оперативной памяти "
        f"({s['need_ram']} ед.) и замена жёстких дисков на твердотельные "
        f"накопители SSD ({s['need_ssd']} ед.).",
        "",
        "3. Поддержка операционной системы Windows 10 прекращена компанией "
        "Microsoft 14 октября 2025 года: обновления безопасности для неё более не "
        "выпускаются, что создаёт риски информационной безопасности. Программа "
        "платных расширенных обновлений (ESU) для организаций носит временный "
        "характер и действует не далее октября 2028 года.",
        "",
        "4. Переход на актуальную операционную систему Windows 11 Pro требует "
        "наличия аппаратного модуля доверенной платформы TPM 2.0, режима загрузки "
        "UEFI с безопасной загрузкой и процессора не ниже 8-го поколения Intel "
        "Core (либо AMD Ryzen 2000-й серии). Указанная в пункте 1 техника этим "
        f"требованиям не соответствует. В настоящее время требованиям Windows 11 "
        f"отвечает {s['win11_ready']} ед. техники.",
        "",
        "На основании изложенного прошу рассмотреть вопрос о выделении средств на "
        "приобретение новой компьютерной техники взамен морально устаревшей, а "
        "также комплектующих (модулей оперативной памяти и твердотельных "
        "накопителей) для модернизации техники, указанной в пункте 2.",
        "",
        "Перечень техники с указанием инвентарных номеров и технических "
        "характеристик приведён в приложении к настоящей записке.",
    ]
    return "\n".join(lines)


AI_SYSTEM = (
    "Ты — помощник системного администратора организации. "
    "Пишешь официальные служебные записки на русском языке: "
    "деловой стиль, без канцелярских штампов-паразитов, без markdown, без "
    "заголовков, только связный текст абзацами. Не выдумывай цифры — используй "
    "только те, что даны."
)


def ai_prompt(summary: dict, rows: list[dict]) -> str:
    s = summary
    dept_lines = "\n".join(
        f"  - {d}: всего {v['total']}, под замену {v['replace']}, "
        f"модернизация {v['upgrade']}"
        for d, v in sorted(s["by_dept"].items()))
    causes = {}
    for r in rows:
        if r["verdict"] == VERDICT_REPLACE:
            for reason in r["reasons"]:
                causes[reason] = causes.get(reason, 0) + 1
    cause_lines = "\n".join(f"  - {k} — {v} ед." for k, v in
                            sorted(causes.items(), key=lambda t: -t[1])[:8])
    return (
        "Напиши основную часть служебной записки на имя руководителя о замене "
        "морально устаревшей компьютерной техники. Данные инвентаризации:\n\n"
        f"Всего техники: {s['total']} ед.\n"
        f"Подлежит замене: {s['replace']} ед. "
        f"(ПК — {s['pcs_replace']}, ноутбуков/моноблоков — {s['laptops_replace']})\n"
        f"Подлежит модернизации: {s['upgrade']} ед. "
        f"(нарастить ОЗУ — {s['need_ram']}, поставить SSD — {s['need_ssd']})\n"
        f"Соответствует требованиям Windows 11: {s['win11_ready']} ед.\n"
        f"Работает на снятых с поддержки ОС: {s['dead_os']} ед.\n\n"
        f"По подразделениям:\n{dept_lines or '  - нет данных'}\n\n"
        f"Основные причины замены:\n{cause_lines or '  - нет данных'}\n\n"
        "Обязательно укажи факты: поддержка Windows 10 прекращена 14.10.2025, "
        "платные обновления ESU для организаций действуют не далее октября 2028 "
        "года; Windows 11 Pro требует TPM 2.0, UEFI Secure Boot и процессор не ниже "
        "8-го поколения Intel Core (AMD Ryzen 2000+); модернизация техники из "
        "пункта о замене экономически нецелесообразна. Заверши просьбой "
        "рассмотреть вопрос о выделении средств. Упомяни, что перечень техники "
        "приведён в приложении. Объём — 4–6 абзацев."
    )


# ── формирование служебной записки (Word) ───────────────────────────────────
def build_memo_docx(out_path, *, branch, responsible, director_title, director,
                    summary, rows, body_text=None, doc_number="",
                    position=""):
    """Служебная записка: шапка, сводный текст, приложение-таблица.

    body_text — готовый текст (например, причёсанный ИИ); если не задан,
    используется default_body(summary).
    """
    from docx import Document
    from docx.shared import Pt, Mm, RGBColor
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.enum.table import WD_ALIGN_VERTICAL

    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Mm(210), Mm(297)
    sec.top_margin, sec.bottom_margin = Mm(20), Mm(20)
    sec.left_margin, sec.right_margin = Mm(30), Mm(15)

    normal = doc.styles["Normal"]
    normal.font.name = "Calibri"
    normal.font.size = Pt(12)

    def para(text="", *, bold=False, align=None, size=None, space_after=6):
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(space_after)
        p.paragraph_format.space_before = Pt(0)
        if align is not None:
            p.alignment = align
        if text:
            r = p.add_run(text)
            r.bold = bold
            if size:
                r.font.size = Pt(size)
        return p

    # ── шапка: кому / от кого ───────────────────────────────────────────────
    addressee = f"{director_title} {branch}".strip() if branch else director_title
    para(addressee, align=WD_ALIGN_PARAGRAPH.RIGHT, space_after=0)
    if director:
        para(director, align=WD_ALIGN_PARAGRAPH.RIGHT, space_after=0)
    if responsible:
        para(f"от {responsible}", align=WD_ALIGN_PARAGRAPH.RIGHT, space_after=12)

    # ── заголовок ───────────────────────────────────────────────────────────
    para("СЛУЖЕБНАЯ ЗАПИСКА", bold=True, align=WD_ALIGN_PARAGRAPH.CENTER, size=14)
    today = date.today().strftime("%d.%m.%Y")
    num_line = f"№ {doc_number} от {today}" if doc_number else f"от {today}"
    para(num_line, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=12)
    para("О замене морально устаревшей компьютерной техники",
         bold=True, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=12)

    # ── основной текст ──────────────────────────────────────────────────────
    for chunk in (body_text or default_body(summary)).split("\n"):
        chunk = chunk.strip()
        if not chunk:
            continue
        p = para(chunk, align=WD_ALIGN_PARAGRAPH.JUSTIFY, space_after=3)
        p.paragraph_format.first_line_indent = Mm(12.5)

    # ── подпись ─────────────────────────────────────────────────────────────
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(0)
    p.add_run((position or "Системный администратор") + " " * 24)
    p.add_run(responsible or "")

    # ── приложение 1: перечень техники (альбомная ориентация) ──────────────
    from docx.enum.section import WD_ORIENT, WD_SECTION
    sec2 = doc.add_section(WD_SECTION.NEW_PAGE)
    sec2.orientation = WD_ORIENT.LANDSCAPE
    sec2.page_width, sec2.page_height = Mm(297), Mm(210)
    sec2.top_margin, sec2.bottom_margin = Mm(15), Mm(15)
    sec2.left_margin, sec2.right_margin = Mm(15), Mm(10)

    para("Приложение 1", bold=True, align=WD_ALIGN_PARAGRAPH.RIGHT, space_after=6)
    para("Перечень компьютерной техники по результатам инвентаризации",
         bold=True, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=10)

    headers = ["№", "Инв. номер", "Подразделение", "Пользователь", "Тип",
               "Процессор", "ОЗУ", "Накопитель", "ОС", "Вывод", "Что требуется"]
    widths = [8, 20, 42, 38, 22, 30, 14, 24, 22, 24, 42]
    table = doc.add_table(rows=1, cols=len(headers))
    table.style = "Table Grid"
    hdr = table.rows[0].cells
    for i, h in enumerate(headers):
        hdr[i].text = ""
        pr = hdr[i].paragraphs[0]
        pr.alignment = WD_ALIGN_PARAGRAPH.CENTER
        pr.paragraph_format.space_after = Pt(0)
        run = pr.add_run(h)
        run.bold = True
        run.font.size = Pt(7.5)

    order = {VERDICT_REPLACE: 0, VERDICT_UPGRADE: 1, VERDICT_OK: 2}
    ordered = sorted(rows, key=lambda x: (order.get(x["verdict"], 9),
                                          x["dept"], x["employee"]))
    for n, r in enumerate(ordered, 1):
        cells = table.add_row().cells
        vals = [str(n), r["inv"], r["dept"], r["employee"], r["kind"],
                r["cpu"], r["ram"], r["storage"], r["os"], r["verdict"],
                need_label(r)]
        for i, v in enumerate(vals):
            cells[i].text = ""
            pr = cells[i].paragraphs[0]
            pr.paragraph_format.space_after = Pt(0)
            run = pr.add_run(str(v or "—"))
            run.font.size = Pt(7.5)
            if i in (9, 10) and r["verdict"] == VERDICT_REPLACE:
                run.bold = True
                run.font.color.rgb = RGBColor(0xC0, 0x00, 0x00)
        for c in cells:
            c.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
    for row in table.rows:
        for i, c in enumerate(row.cells):
            c.width = Mm(widths[i])

    s = summary
    para(space_after=4)
    para(f"Итого: {s['total']} ед.; подлежит замене — {s['replace']} ед.; "
         f"подлежит модернизации — {s['upgrade']} ед.; "
         f"соответствует требованиям Windows 11 — {s['win11_ready']} ед.",
         bold=True)

    # ── приложение 2: что заложить в бюджет ────────────────────────────────
    repl_rows = [r for r in ordered if r["verdict"] == VERDICT_REPLACE]
    items = budget_items(rows)
    if repl_rows or items:
        doc.add_page_break()
        para("Приложение 2", bold=True, align=WD_ALIGN_PARAGRAPH.RIGHT, space_after=6)
        para("Потребность в компьютерной технике и комплектующих "
             "для планирования бюджета",
             bold=True, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=10)

    # 2.1 перечень техники под замену
    if repl_rows:
        para("1. Компьютерная техника, подлежащая замене", bold=True, space_after=6)
        t2 = doc.add_table(rows=1, cols=6)
        t2.style = "Table Grid"
        h2 = ["№", "Инв. номер", "Подразделение", "Пользователь", "Тип",
              "Основание для замены"]
        w2 = [10, 24, 60, 50, 26, 105]
        for i, h in enumerate(h2):
            c = t2.rows[0].cells[i]
            c.text = ""
            pr = c.paragraphs[0]
            pr.alignment = WD_ALIGN_PARAGRAPH.CENTER
            pr.paragraph_format.space_after = Pt(0)
            run = pr.add_run(h)
            run.bold = True
            run.font.size = Pt(8)
        for n, r in enumerate(repl_rows, 1):
            reason = "; ".join(r["reasons"]) or r["cpu_note"]
            cells = t2.add_row().cells
            for i, v in enumerate([str(n), r["inv"], r["dept"], r["employee"],
                                   r["kind"], reason]):
                cells[i].text = ""
                pr = cells[i].paragraphs[0]
                pr.paragraph_format.space_after = Pt(0)
                run = pr.add_run(str(v or "—"))
                run.font.size = Pt(8)
        for row in t2.rows:
            for i, c in enumerate(row.cells):
                c.width = Mm(w2[i])
        para(space_after=8)

    # 2.2 сводная спецификация комплектующих
    if items:
        para("2. Сводная потребность в технике и комплектующих",
             bold=True, space_after=6)
        t3 = doc.add_table(rows=1, cols=5)
        t3.style = "Table Grid"
        h3 = ["№", "Наименование", "Требуемые характеристики", "Кол-во",
              "Назначение"]
        w3 = [10, 55, 105, 20, 85]
        for i, h in enumerate(h3):
            c = t3.rows[0].cells[i]
            c.text = ""
            pr = c.paragraphs[0]
            pr.alignment = WD_ALIGN_PARAGRAPH.CENTER
            pr.paragraph_format.space_after = Pt(0)
            run = pr.add_run(h)
            run.bold = True
            run.font.size = Pt(8)
        for n, it in enumerate(items, 1):
            cells = t3.add_row().cells
            vals = [str(n), it["name"], it["spec"],
                    f"{it['qty']} {it['unit']}", it["purpose"]]
            for i, v in enumerate(vals):
                cells[i].text = ""
                pr = cells[i].paragraphs[0]
                pr.paragraph_format.space_after = Pt(0)
                run = pr.add_run(str(v))
                run.font.size = Pt(8)
                if i == 3:
                    run.bold = True
                    pr.alignment = WD_ALIGN_PARAGRAPH.CENTER
        for row in t3.rows:
            for i, c in enumerate(row.cells):
                c.width = Mm(w3[i])
        para(space_after=6)
        para("Примечание: тип модулей оперативной памяти (DDR3/DDR4) и "
             "интерфейс накопителей (SATA III / M.2) уточняются по факту "
             "установленного оборудования при закупе.", space_after=0)

    doc.save(str(out_path))
    return str(out_path)
