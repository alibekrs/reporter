# -*- coding: utf-8 -*-
"""ITtool: недельный отчёт сисадмина — записи, Word, почта, ИИ.

Данные — блоб «report» в db.py ({settings, weeks: {понедельник: [записи]}}).
Каждая правка — одна транзакция (db.blob_tx): интерфейс и телеграм-бот
пишут в одну базу, не затирая друг друга.
"""
from __future__ import annotations

import os
import tempfile
import uuid
from datetime import date, timedelta

import db

DEFAULT_BRANCH = ""
DEFAULT_RESP = ""

# Колонки таблицы (как в шаблоне)
COLS = ["Дата", "№", "Сотрудник / объект", "Описание обращения",
        "Выполненные действия", "Результат"]
# Ширины колонок в твипах (из вашего .docx: 796,490,1934,2030,2058,2042)
COL_WIDTHS_TWIPS = [796, 490, 1934, 2030, 2058, 2042]

# Цвета таблицы Word (Grid Table 4 - Accent 1)
HEX_ACCENT = "4472C4"   # заливка шапки
HEX_BAND = "D9E2F3"     # заливка чётных строк
HEX_BORDER = "8EAADB"   # линии сетки

RU_MONTHS_GEN = {1: "января", 2: "февраля", 3: "марта", 4: "апреля",
                 5: "мая", 6: "июня", 7: "июля", 8: "августа",
                 9: "сентября", 10: "октября", 11: "ноября", 12: "декабря"}
RU_MONTHS_NOM = {1: "Январь", 2: "Февраль", 3: "Март", 4: "Апрель",
                 5: "Май", 6: "Июнь", 7: "Июль", 8: "Август",
                 9: "Сентябрь", 10: "Октябрь", 11: "Ноябрь", 12: "Декабрь"}
WEEKDAYS_SHORT = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]


# ----------------------------------------------------------------------------
#  Работа с датами
# ----------------------------------------------------------------------------
def monday_of(d: date) -> date:
    return d - timedelta(days=d.weekday())


def week_key(d: date) -> str:
    return monday_of(d).isoformat()


def week_range_str(monday: date) -> str:
    fri = monday + timedelta(days=4)
    return f"{monday:%d.%m.%Y}-{fri:%d.%m.%Y}"


def ru_date_cell(d: date) -> str:
    return f"{d.day} {RU_MONTHS_GEN[d.month]}"


# ----------------------------------------------------------------------------
#  Хранилище данных
# ----------------------------------------------------------------------------
def normalize(data) -> dict:
    """Блоб «report» в рабочем виде: настройки по умолчанию, uid у записей."""
    data = data if isinstance(data, dict) else {}
    data.setdefault("settings", {})
    data["settings"].setdefault("branch", DEFAULT_BRANCH)
    data["settings"].setdefault("responsible", DEFAULT_RESP)
    # настройки почты (вводятся один раз, потом подставляются)
    email = data["settings"].setdefault("email", {})
    email.setdefault("server", "")
    email.setdefault("port", "465")
    email.setdefault("security", "SSL")
    email.setdefault("sender", "")
    email.setdefault("password", "")
    email.setdefault("remember_password", True)
    email.setdefault("recipient", "")
    # настройки ИИ (OpenAI-совместимый API)
    ai = data["settings"].setdefault("ai", {})
    ai.setdefault("base_url", "https://generativelanguage.googleapis.com/v1beta/openai")
    ai.setdefault("api_key", "")
    ai.setdefault("model", "gemini-3.1-flash-lite")
    data.setdefault("weeks", {})
    # миграция: гарантируем uid у каждой записи, без пустых и задвоенных
    seen = set()
    for _wk, entries in data["weeks"].items():
        for e in entries:
            if not e.get("uid") or e["uid"] in seen:
                e["uid"] = uuid.uuid4().hex[:8]
            seen.add(e["uid"])
    return data


def load_data() -> dict:
    """Отчёт целиком — для просмотра. Менять — через report_tx()."""
    return normalize(db.get_report_raw())


def report_tx():
    """Свежий отчёт под блокировкой записи; по выходу из блока — сохранён."""
    return db.blob_tx("report", normalize)


# ----------------------------------------------------------------------------
#  Экспорт в Word (python-docx)  —  вынесено отдельно для переиспользования
# ----------------------------------------------------------------------------
def _oxml(tag):
    from docx.oxml import OxmlElement
    return OxmlElement(tag)


def _qn(tag):
    from docx.oxml.ns import qn
    return qn(tag)


def _cell_bg(cell, hex_color):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = _oxml("w:shd")
    shd.set(_qn("w:val"), "clear")
    shd.set(_qn("w:color"), "auto")
    shd.set(_qn("w:fill"), hex_color)
    tcPr.append(shd)


def _table_borders(table, color, sz=4):
    tblPr = table._tbl.tblPr
    borders = _oxml("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        el = _oxml("w:" + edge)
        el.set(_qn("w:val"), "single")
        el.set(_qn("w:sz"), str(sz))
        el.set(_qn("w:space"), "0")
        el.set(_qn("w:color"), color)
        borders.append(el)
    tblPr.append(borders)


def _fixed_layout(table):
    layout = _oxml("w:tblLayout")
    layout.set(_qn("w:type"), "fixed")
    table._tbl.tblPr.append(layout)


def _repeat_header(row):
    trPr = row._tr.get_or_add_trPr()
    th = _oxml("w:tblHeader")
    th.set(_qn("w:val"), "true")
    trPr.append(th)


def _no_space(paragraph):
    from docx.shared import Pt
    paragraph.paragraph_format.space_before = Pt(0)
    paragraph.paragraph_format.space_after = Pt(0)


def build_docx(branch, responsible, weeks_data, out_path):
    """weeks_data: список кортежей (monday: date, entries: list[dict] отсортированы)."""
    from docx import Document
    from docx.shared import Pt, Mm, RGBColor, Twips
    from docx.enum.table import WD_ALIGN_VERTICAL
    from docx.enum.text import WD_ALIGN_PARAGRAPH

    doc = Document()

    sec = doc.sections[0]
    sec.page_width, sec.page_height = Mm(210), Mm(297)          # A4
    sec.top_margin, sec.bottom_margin = Mm(20), Mm(20)
    sec.left_margin, sec.right_margin = Mm(30), Mm(15)

    normal = doc.styles["Normal"]
    normal.font.name = "Calibri"
    normal.font.size = Pt(12)

    for wi, (monday, entries) in enumerate(weeks_data):
        if wi > 0:
            doc.add_page_break()

        # --- шапка ---
        def line(label, value):
            p = doc.add_paragraph()
            _no_space(p)
            r1 = p.add_run(label)
            r1.bold = True
            p.add_run(value)

        line("Филиал: ", branch)
        line("Дата: ", week_range_str(monday))
        line("Ответственный: ", responsible)
        _no_space(doc.add_paragraph())  # отступ перед таблицей

        # --- таблица ---
        table = doc.add_table(rows=1, cols=6)
        table.autofit = False
        _fixed_layout(table)
        _table_borders(table, HEX_BORDER, 4)

        _repeat_header(table.rows[0])
        hdr = table.rows[0].cells
        for i, h in enumerate(COLS):
            p = hdr[i].paragraphs[0]
            _no_space(p)
            run = p.add_run(h)
            run.bold = True
            run.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)
            if i == 1:
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            _cell_bg(hdr[i], HEX_ACCENT)
            hdr[i].vertical_alignment = WD_ALIGN_VERTICAL.CENTER

        for idx, e in enumerate(entries, start=1):
            cells = table.add_row().cells
            d = date.fromisoformat(e["date"])
            values = [ru_date_cell(d), str(idx), e.get("employee", ""),
                      e.get("description", ""), e.get("actions", ""),
                      e.get("result", "")]
            band = (idx % 2 == 0)
            for i, v in enumerate(values):
                p = cells[i].paragraphs[0]
                _no_space(p)
                p.add_run(v or "")
                if i == 1:
                    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                cells[i].vertical_alignment = WD_ALIGN_VERTICAL.CENTER
                if band:
                    _cell_bg(cells[i], HEX_BAND)

        # ширины колонок (после добавления всех строк)
        for i, w in enumerate(COL_WIDTHS_TWIPS):
            for cell in table.columns[i].cells:
                cell.width = Twips(w)

    doc.save(out_path)


# ----------------------------------------------------------------------------
#  Отправка почты (smtplib, стандартная библиотека)
# ----------------------------------------------------------------------------
def send_email(cfg, recipient, subject, body, attachment_path):
    """cfg: dict с ключами server, port, security, sender, password.
       Кидает исключение при ошибке — вызывающий ловит и показывает текст."""
    import smtplib
    import ssl
    from email.message import EmailMessage

    msg = EmailMessage()
    msg["From"] = cfg["sender"]
    msg["To"] = recipient
    msg["Subject"] = subject
    msg.set_content(body)

    with open(attachment_path, "rb") as f:
        data = f.read()
    msg.add_attachment(
        data, maintype="application",
        subtype="vnd.openxmlformats-officedocument.wordprocessingml.document",
        filename=os.path.basename(attachment_path))

    server = cfg["server"].strip()
    port = int(str(cfg["port"]).strip() or 0)
    security = cfg.get("security", "SSL")
    sender = cfg["sender"].strip()
    password = cfg["password"]

    if security == "SSL":
        ctx = ssl.create_default_context()
        with smtplib.SMTP_SSL(server, port, timeout=25, context=ctx) as s:
            s.login(sender, password)
            s.send_message(msg)
    else:  # STARTTLS или без шифрования
        with smtplib.SMTP(server, port, timeout=25) as s:
            s.ehlo()
            if security == "STARTTLS":
                s.starttls(context=ssl.create_default_context())
                s.ehlo()
            if password:
                s.login(sender, password)
            s.send_message(msg)


# ----------------------------------------------------------------------------
#  ИИ: дополнение записи из короткой заметки (OpenAI-совместимый API)
# ----------------------------------------------------------------------------
def ai_expand(cfg, note, employee="", history=""):
    """Возвращает dict {description, actions, result}. Кидает исключение
       с понятным текстом при ошибке — вызывающий ловит и показывает."""
    import json as _json
    import urllib.request
    import urllib.error

    base = cfg.get("base_url", "").strip().rstrip("/")
    url = base + "/chat/completions"
    key = cfg.get("api_key", "").strip()
    model = cfg.get("model", "").strip()

    sys_prompt = (
        "Ты помощник системного администратора. По короткой заметке об ИТ-инциденте "
        "составь три поля отчёта на русском языке: описание обращения, выполненные "
        "действия и результат. Пиши официально и кратко, по 1–2 предложения на поле, "
        "в прошедшем времени. Если даны примеры прошлых записей — придерживайся их "
        "стиля и терминологии, а для похожих обращений используй те же формулировки. "
        "Не выдумывай деталей сверх заметки. Верни СТРОГО "
        "JSON-объект без markdown и пояснений, ровно в формате: "
        '{"description": "...", "actions": "...", "result": "..."}')
    user = note if not employee else f"Сотрудник/объект: {employee}\nЗаметка: {note}"
    if history:
        user += ("\n\nПримеры прошлых записей (стиль и формулировки для похожих "
                 "обращений):\n" + history)

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user},
        ],
        "temperature": 0.3,
    }
    req = urllib.request.Request(
        url, data=_json.dumps(payload).encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + key)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:600]
        raise RuntimeError(f"Сервер вернул ошибку HTTP {e.code}.\n{body}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Нет связи с сервером ИИ: {e.reason}")

    obj = _json.loads(raw)
    content = obj["choices"][0]["message"]["content"].strip()

    # вычистить возможные markdown-ограждения ```json ... ```
    if content.startswith("```"):
        content = content.strip("`")
        nl = content.find("\n")
        if nl != -1 and content[:nl].strip().lower() in ("json", ""):
            content = content[nl + 1:]
    s, e = content.find("{"), content.rfind("}")
    if s != -1 and e != -1:
        content = content[s:e + 1]

    try:
        result = _json.loads(content)
    except Exception:
        raise RuntimeError("Модель вернула ответ не в формате JSON:\n" + content[:300])

    return {
        "description": str(result.get("description", "")).strip(),
        "actions": str(result.get("actions", "")).strip(),
        "result": str(result.get("result", "")).strip(),
    }


def _strip_code_fence(content):
    if content.startswith("```"):
        content = content.strip("`")
        nl = content.find("\n")
        if nl != -1 and content[:nl].strip().lower() in ("json", ""):
            content = content[nl + 1:]
    return content


def ai_chat(cfg, system, user, temperature=0.4, timeout=90):
    """Универсальный запрос к OpenAI-совместимому API. Возвращает текст ответа."""
    import json as _json
    import urllib.request
    import urllib.error

    base = cfg.get("base_url", "").strip().rstrip("/")
    url = base + "/chat/completions"
    key = cfg.get("api_key", "").strip()
    model = cfg.get("model", "").strip()

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": temperature,
    }
    req = urllib.request.Request(
        url, data=_json.dumps(payload).encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + key)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:600]
        raise RuntimeError(f"Сервер вернул ошибку HTTP {e.code}.\n{body}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Нет связи с сервером ИИ: {e.reason}")
    obj = _json.loads(raw)
    return obj["choices"][0]["message"]["content"].strip()


def _extract_json(content, opener, closer):
    content = _strip_code_fence(content)
    s, e = content.find(opener), content.rfind(closer)
    if s != -1 and e != -1:
        content = content[s:e + 1]
    import json as _json
    try:
        return _json.loads(content)
    except Exception:
        raise RuntimeError("Модель вернула ответ не в формате JSON:\n" + content[:300])


def ai_polish(cfg, entries):
    """Причёсывает список записей: стиль, орфография, единые термины. -> list."""
    import json as _json
    system = (
        "Ты редактор отчётов системного администратора. Перепиши каждую запись в едином "
        "официальном деловом стиле на русском: исправь орфографию и пунктуацию, приведи "
        "термины к единому виду (Wi-Fi, ЭЦП, Microsoft Office, IP-телефон, NCALayer и т.п.), "
        "сделай формулировки краткими и однородными, в прошедшем времени. Не меняй смысл и "
        "не выдумывай фактов. Верни СТРОГО JSON-массив тех же объектов с теми же uid, формат: "
        '[{"uid":"...","description":"...","actions":"...","result":"..."}]')
    user = "Записи:\n" + _json.dumps(entries, ensure_ascii=False)
    content = ai_chat(cfg, system, user, temperature=0.2, timeout=120)
    return _extract_json(content, "[", "]")


def ai_categorize(cfg, items):
    """Категоризация обращений. items: [{uid,text}]. -> {uid: category}."""
    import json as _json
    cats = ("Принтеры/оргтехника, Сеть/интернет, Почта, ЭЦП/NCALayer, Телефония, "
            "Оборудование/железо, ПО/программы, Учётные записи/доступы, Прочее")
    system = (
        "Ты классификатор ИТ-обращений. Отнеси каждое обращение ровно к ОДНОЙ категории из "
        f"списка: {cats}. Верни СТРОГО JSON-объект вида {{\"<uid>\":\"<категория>\"}} без "
        "пояснений и markdown.")
    user = "Обращения:\n" + _json.dumps(items, ensure_ascii=False)
    content = ai_chat(cfg, system, user, temperature=0.0, timeout=90)
    return _extract_json(content, "{", "}")


def ai_month_text(cfg, kind, month_name, year, items):
    """kind='insights' — выводы для руководства; 'narrative' — связный отчёт."""
    import json as _json
    if kind == "insights":
        system = (
            "Ты аналитик ИТ-поддержки. По списку обращений за месяц сделай краткую сводку "
            "для руководства: общее число обращений, основные категории проблем с их долей, "
            "повторяющиеся/системные проблемы и 2–4 практические рекомендации (что закупить, "
            "заменить, наладить). Деловито, по-русски, маркированным списком. Без выдумок "
            "сверх данных.")
    else:
        system = (
            "Ты составляешь месячный отчёт о работе системного администратора для руководства. "
            "По списку обращений напиши связный официальный текст (3–5 абзацев): чем занимался "
            "отдел за месяц, основные направления работ, объём (число обращений) и итоги. "
            "Связным текстом со статистикой, а не таблицей. По-русски, без выдумок.")
    user = (f"Месяц: {month_name} {year}. Обращения:\n"
            + _json.dumps(items, ensure_ascii=False))
    return ai_chat(cfg, system, user, temperature=0.5, timeout=120)


def ai_email_body(cfg, mon_str, fri_str, items, responsible):
    """Короткое тело письма руководителю с недельным отчётом."""
    import json as _json
    system = (
        "Ты пишешь короткое деловое письмо руководителю с недельным отчётом системного "
        "администратора. 2–4 предложения: приветствие, краткая суть проделанного за неделю "
        "(число обращений и основные темы), упоминание вложения с полным отчётом, подпись. "
        "По-русски, официально. Без выдумок сверх данных.")
    user = (f"Неделя {mon_str}–{fri_str}. Подпись: {responsible}. Обращения:\n"
            + _json.dumps(items, ensure_ascii=False))
    return ai_chat(cfg, system, user, temperature=0.5, timeout=90)


# ----------------------------------------------------------------------------
#  Записи
# ----------------------------------------------------------------------------
def sorted_entries(entries):
    return sorted(entries, key=lambda e: (e.get("date", ""), entries.index(e)))


def week_entries(data, any_day: date):
    return sorted_entries(data["weeks"].get(week_key(any_day), []))


def find_entry(data, uid):
    for wk, entries in data["weeks"].items():
        for e in entries:
            if e.get("uid") == uid:
                return wk, e
    return None, None


def save_entry(day_iso, employee="", description="", actions="", result="", uid=None,
               create_missing=False):
    """Новая запись или правка существующей (uid). Перенос на другой день
    другой недели — тоже здесь. create_missing — записи с таким uid нет (создана
    на телефоне без сети): создать с этим uid. Возвращает uid."""
    fields = {"employee": str(employee or "").strip(),
              "description": str(description or "").strip(),
              "actions": str(actions or "").strip(),
              "result": str(result or "").strip()}
    if not any(fields.values()):
        raise ValueError("Заполните хотя бы одно поле.")
    day = date.fromisoformat(day_iso)
    if day.weekday() > 4:
        raise ValueError("Выберите день с понедельника по пятницу.")
    with report_tx() as data:
        wk, e = find_entry(data, uid) if uid else (None, None)
        if uid and not e and not create_missing:
            raise ValueError("Запись не найдена — возможно, её уже удалили.")
        if e:
            e.update(fields, date=day.isoformat())
            new_wk = week_key(day)
            if new_wk != wk:
                data["weeks"][wk].remove(e)
                data["weeks"].setdefault(new_wk, []).append(e)
            return uid
        uid = uid or uuid.uuid4().hex[:8]
        data["weeks"].setdefault(week_key(day), []).append(
            dict(uid=uid, date=day.isoformat(), **fields))
        return uid


def update_entry(uid, **fields):
    """Частичная правка (бот): только переданные поля; date — перенос."""
    with report_tx() as data:
        wk, e = find_entry(data, uid)
        if not e:
            return False
        for k in ("employee", "description", "actions", "result", "date"):
            if fields.get(k) is not None:
                e[k] = fields[k]
        if fields.get("date"):
            new_wk = week_key(date.fromisoformat(fields["date"]))
            if new_wk != wk:
                data["weeks"][wk].remove(e)
                data["weeks"].setdefault(new_wk, []).append(e)
        return True


def delete_entry(uid):
    with report_tx() as data:
        wk, e = find_entry(data, uid)
        if not e:
            return False
        data["weeks"][wk].remove(e)
        return True


def save_header(branch, responsible):
    with report_tx() as data:
        data["settings"]["branch"] = str(branch or "").strip()
        data["settings"]["responsible"] = str(responsible or "").strip()


def candidates(data, field="employee"):
    """Подсказки для поля: частые прошлые значения, для «Сотрудник / объект» —
    ещё сотрудники и техника из учёта."""
    freq = {}
    for _wk, entries in data["weeks"].items():
        for e in entries:
            v = (e.get(field) or "").strip()
            if v:
                freq[v] = freq.get(v, 0) + 1
    ordered = [v for v, _ in sorted(freq.items(), key=lambda kv: (-kv[1], kv[0]))]
    if field == "employee":
        seen = set(ordered)
        try:
            for n in db.assets_suggest_names():
                if n not in seen:
                    seen.add(n)
                    ordered.append(n)
        except Exception:
            pass
    return ordered


def gather_history(data, limit=25):
    """Последние записи — примеры стиля для ИИ."""
    rows = []
    for _wk, entries in data["weeks"].items():
        for e in entries:
            if e.get("description") or e.get("actions") or e.get("result"):
                rows.append((e.get("date", ""), e))
    rows.sort(key=lambda r: r[0], reverse=True)
    lines = []
    for _, e in rows[:limit]:
        d = (e.get("description", "") or "").replace("\n", " ").strip()
        a = (e.get("actions", "") or "").replace("\n", " ").strip()
        r = (e.get("result", "") or "").replace("\n", " ").strip()
        lines.append(f"- Обращение: {d} | Действия: {a} | Результат: {r}")
    return "\n".join(lines)


def ai_config(data):
    """Настройки ИИ отчёта; нет ключа — понятный отказ."""
    cfg = dict(data["settings"].get("ai") or {})
    if not cfg.get("api_key"):
        raise ValueError("Не задан API-ключ ИИ — укажите его в настройках (раздел «ИИ»).")
    return cfg


# ----------------------------------------------------------------------------
#  Выгрузки
# ----------------------------------------------------------------------------
def week_file_name(monday: date) -> str:
    fri = monday + timedelta(days=4)
    return f"Отчёт_{monday:%d.%m}-{fri:%d.%m.%Y}.docx"


def month_weeks(data, month, year):
    """[(понедельник, записи)] недель, начавшихся в этом месяце."""
    out = []
    for wk, entries in data["weeks"].items():
        mon = date.fromisoformat(wk)
        if entries and mon.month == month and mon.year == year:
            out.append((mon, sorted_entries(entries)))
    return sorted(out, key=lambda x: x[0])


def export_week(data, any_day: date, path):
    entries = week_entries(data, any_day)
    if not entries:
        raise ValueError("За эту неделю нет записей.")
    st = data["settings"]
    build_docx(st.get("branch", ""), st.get("responsible", ""),
               [(monday_of(any_day), entries)], path)
    return path


def export_month(data, month, year, path):
    weeks = month_weeks(data, month, year)
    if not weeks:
        raise ValueError(f"За {RU_MONTHS_NOM[month]} {year} нет записей.")
    st = data["settings"]
    build_docx(st.get("branch", ""), st.get("responsible", ""), weeks, path)
    return path


def save_text_docx(title, text, path):
    """Текст ИИ (выводы, месячный отчёт) — в Word."""
    from docx import Document
    from docx.shared import Pt, Mm
    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Mm(210), Mm(297)
    sec.left_margin, sec.right_margin = Mm(25), Mm(15)
    doc.styles["Normal"].font.name = "Calibri"
    doc.styles["Normal"].font.size = Pt(12)
    doc.add_heading(title, level=1)
    for para in text.split("\n"):
        doc.add_paragraph(para)
    doc.save(path)
    return path


# ----------------------------------------------------------------------------
#  Почта
# ----------------------------------------------------------------------------
def email_draft(data, any_day: date):
    """Что подставить в форму письма за неделю."""
    mon = monday_of(any_day)
    fri = mon + timedelta(days=4)
    em = data["settings"].get("email") or {}
    resp = data["settings"].get("responsible", "")
    return {
        "server": em.get("server", ""), "port": str(em.get("port", "465")),
        "security": em.get("security", "SSL"), "sender": em.get("sender", ""),
        "password": em.get("password", "") if em.get("remember_password", True) else "",
        "remember": bool(em.get("remember_password", True)),
        "recipient": em.get("recipient", ""),
        "subject": f"Отчёт о работе системного администратора ({mon:%d.%m}–{fri:%d.%m.%Y})",
        "body": (f"Здравствуйте!\n\nВо вложении — отчёт о работе системного администратора "
                 f"за неделю {mon:%d.%m}–{fri:%d.%m.%Y}.\n\nС уважением,\n{resp}"),
    }


def send_week(any_day: date, d):
    """Отправить отчёт за неделю: те же проверки и тексты, что в окне.
    Настройки почты запоминаются. Возвращает текст итога."""
    server, port = str(d.get("server", "")).strip(), str(d.get("port", "")).strip()
    sender, recipient = str(d.get("sender", "")).strip(), str(d.get("recipient", "")).strip()
    password = str(d.get("password", ""))
    if not (server and port and sender and recipient):
        raise ValueError("Заполните сервер, порт, «От кого» и «Кому».")
    try:
        (sender + password).encode("ascii")
    except UnicodeEncodeError:
        raise ValueError("Адрес или пароль содержат нелатинские (русские) символы. Скорее "
                         "всего пароль введён при русской раскладке. Очистите поле «Пароль» "
                         "и введите его заново на английской раскладке. Пароль приложения "
                         "Gmail состоит только из латинских букв.") from None
    security = d.get("security") or "SSL"
    with report_tx() as data:
        cfg = data["settings"]["email"]
        cfg.update(server=server, port=port, security=security,
                   sender=sender, recipient=recipient)
        cfg["remember_password"] = bool(d.get("remember", True))
        cfg["password"] = password if cfg["remember_password"] else ""
    if not week_entries(data, any_day):
        raise ValueError("За эту неделю нет записей.")
    path = os.path.join(tempfile.gettempdir(), week_file_name(monday_of(any_day)))
    export_week(data, any_day, path)
    try:
        send_email({"server": server, "port": port, "security": security,
                    "sender": sender, "password": password},
                   recipient, str(d.get("subject", "")), str(d.get("body", "")), path)
    except Exception as exc:
        raise ValueError(f"Не удалось отправить письмо:\n{exc}") from None
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    return f"Отчёт отправлен на {recipient}."


def bot_week_email(date_iso, recipient=None, build=False):
    """Письмо с отчётом за неделю для бота: проверка настроек и (build) файл."""
    data = load_data()
    mon = monday_of(date.fromisoformat(date_iso))
    fri = mon + timedelta(days=4)
    label = f"{mon:%d.%m}–{fri:%d.%m.%Y}"
    entries = week_entries(data, mon)
    if not entries:
        return {"ok": False, "label": label, "error": f"За неделю {label} нет записей."}
    em = data["settings"].get("email") or {}
    to = (recipient or em.get("recipient") or "").strip()
    need = [name for name, key in (("сервер", "server"), ("порт", "port"),
                                   ("отправитель", "sender"))
            if not str(em.get(key, "")).strip()]
    if not to:
        need.append("получатель")
    if not em.get("password"):
        need.append("пароль")
    if need:
        return {"ok": False, "label": label,
                "error": "В настройках почты не заполнено: " + ", ".join(need) + "."}
    resp = data["settings"].get("responsible", "")
    info = {
        "ok": True, "label": label, "count": len(entries), "to": to,
        "subject": f"Отчёт о работе системного администратора ({label})",
        "body": (f"Здравствуйте!\n\nВо вложении — отчёт о работе системного "
                 f"администратора за неделю {label}.\n\nС уважением,\n{resp}"),
        "smtp": {"server": str(em.get("server", "")).strip(),
                 "port": str(em.get("port", "")).strip(),
                 "security": em.get("security", "SSL"),
                 "sender": str(em.get("sender", "")).strip(),
                 "password": em.get("password", "")},
    }
    if build:
        path = os.path.join(tempfile.gettempdir(), week_file_name(mon))
        export_week(data, mon, path)
        info["path"] = path
    return info



# ----------------------------------------------------------------------------
#  ИИ над неделей и месяцем
# ----------------------------------------------------------------------------
def polish_week(any_day: date):
    """Причесать записи недели. Возвращает, сколько обновлено."""
    data = load_data()
    cfg = ai_config(data)
    entries = week_entries(data, any_day)
    if not entries:
        raise ValueError("За эту неделю нет записей.")
    payload = [{"uid": e["uid"], "description": e.get("description", ""),
                "actions": e.get("actions", ""), "result": e.get("result", "")}
               for e in entries]
    cleaned = ai_polish(cfg, payload)
    by_uid = {c.get("uid"): c for c in cleaned if isinstance(c, dict)}
    n = 0
    with report_tx() as data:
        for e in data["weeks"].get(week_key(any_day), []):
            c = by_uid.get(e["uid"])
            if c:
                e["description"] = str(c.get("description", e.get("description", ""))).strip()
                e["actions"] = str(c.get("actions", e.get("actions", ""))).strip()
                e["result"] = str(c.get("result", e.get("result", ""))).strip()
                n += 1
    return n


def categorize_week(any_day: date):
    """Категории обращений недели. Возвращает {категория: сколько}."""
    data = load_data()
    cfg = ai_config(data)
    entries = week_entries(data, any_day)
    if not entries:
        raise ValueError("За эту неделю нет записей.")
    payload = [{"uid": e["uid"],
                "text": (e.get("description", "") + " " + e.get("actions", "")).strip()}
               for e in entries]
    cats = ai_categorize(cfg, payload)
    counts = {}
    with report_tx() as data:
        for e in data["weeks"].get(week_key(any_day), []):
            c = cats.get(e["uid"]) if isinstance(cats, dict) else None
            if c:
                e["category"] = c
                counts[c] = counts.get(c, 0) + 1
    if not counts:
        raise ValueError("Не удалось определить категории.")
    return dict(sorted(counts.items(), key=lambda x: -x[1]))


def month_text(kind, month, year):
    """«insights» — выводы для руководства, «narrative» — месячный отчёт.
    Возвращает (заголовок, текст)."""
    data = load_data()
    cfg = ai_config(data)
    entries = []
    for wk, es in data["weeks"].items():
        mon = date.fromisoformat(wk)
        if mon.month == month and mon.year == year:
            entries += es
    if not entries:
        raise ValueError(f"За {RU_MONTHS_NOM[month]} {year} нет записей.")
    items = [{"date": e.get("date", ""), "description": e.get("description", ""),
              "actions": e.get("actions", ""), "result": e.get("result", ""),
              "category": e.get("category", "")} for e in entries]
    mname = RU_MONTHS_NOM[month]
    title = ("Выводы для руководства" if kind == "insights" else "Месячный отчёт") \
        + f" — {mname} {year}"
    return title, ai_month_text(cfg, kind, mname, year, items)


class BotBridge:
    """Мост телеграм-бота к отчёту (интерфейс ReportBot.ui)."""

    def add_entry(self, date_iso, employee="", **f):
        d = date.fromisoformat(date_iso)
        uid = uuid.uuid4().hex[:8]
        with report_tx() as data:
            data["weeks"].setdefault(week_key(d), []).append(
                {"uid": uid, "date": d.isoformat(), "employee": employee,
                 "description": f.get("description", ""), "actions": f.get("actions", ""),
                 "result": f.get("result", "")})
        return uid

    def get_entry(self, uid):
        _wk, e = find_entry(load_data(), uid)
        return dict(e) if e else None

    def update_entry(self, uid, **fields):
        return update_entry(uid, **fields)

    def delete_entry(self, uid):
        return delete_entry(uid)

    def week_entries(self, date_iso):
        data = load_data()
        return [dict(e) for e in data["weeks"].get(week_key(date.fromisoformat(date_iso)), [])]

    def ai_config(self):
        return dict(load_data()["settings"].get("ai") or {})

    def history(self):
        return gather_history(load_data())

    def week_email(self, date_iso, to=None, build=False):
        return bot_week_email(date_iso, to, build)
