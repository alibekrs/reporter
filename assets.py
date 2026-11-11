# -*- coding: utf-8 -*-
"""ITtool: сотрудники, подразделения и техника — модель, поиск, операции, выгрузки.

Данные — блоб «assets» в db.py ({units, employees}). Каждая операция берёт
свежие данные под блокировкой записи (db.blob_tx), меняет и сохраняет:
интерфейс и телеграм-бот могут работать одновременно.
"""
from __future__ import annotations

import datetime
import json
import uuid

import db

CONDITIONS = ["рабочее", "требует замены", "неисправно", "отсутствует"]
COND_RANK = {"неисправно": 3, "требует замены": 2, "рабочее": 1, "отсутствует": 0}

WINDOWS_OS_LIST = [
    "", "Windows XP", "Windows Vista", "Windows 7", "Windows 8", "Windows 8.1",
    "Windows 10", "Windows 11",
    "Windows Server 2008", "Windows Server 2008 R2", "Windows Server 2012",
    "Windows Server 2012 R2", "Windows Server 2016", "Windows Server 2019",
    "Windows Server 2022", "Windows Server 2025", "Другая",
]
OFFICE_LIST = [
    "", "Microsoft Office 2003", "Microsoft Office 2007", "Microsoft Office 2010",
    "Microsoft Office 2013", "Microsoft Office 2016", "Microsoft Office 2019",
    "Microsoft Office 2021", "Microsoft Office 2024", "Microsoft 365", "Нет",
]
DIAGONAL_LIST = [
    "", '11.6"', '13.3"', '14"', '15.6"', '16"', '17.3"',
    '18.5"', '19"', '19.5"', '20"', '21.5"', '22"', '23"', '23.8"', '24"',
    '25"', '27"', '28"', '30"', '31.5"', '32"', '34"', '38"', '43"',
]
RESOLUTION_LIST = [
    "", "1024x768", "1280x720", "1280x800", "1280x1024", "1366x768",
    "1440x900", "1536x864", "1600x900", "1680x1050",
    "1920x1080", "1920x1200", "2240x1400", "2560x1080", "2560x1440",
    "2560x1600", "2880x1800", "3440x1440", "3840x2160", "5120x1440",
]

# (ключ, подпись, тип, список значений)
DEVICE_SPECS = {
    "pcs": {
        "title": "Компьютеры", "singular": "ПК", "add_label": "ПК",
        "fields": [
            ("inv", "Инв. номер", "entry", None),
            ("hostname", "Имя в сети", "entry", None),
            ("mac", "MAC-адрес", "entry", None),
            ("ip", "IP-адрес", "entry", None),
            ("cpu", "Процессор", "choice", None),
            ("ram", "ОЗУ", "choice", None),
            ("storage", "Накопитель (SSD/HDD)", "choice", None),
            ("gpu", "Видеокарта", "choice", None),
            ("os", "ОС", "choice", WINDOWS_OS_LIST),
            ("office", "Офис", "choice", OFFICE_LIST),
            ("is_laptop", "Ноутбук / моноблок (встроенный экран)", "check", None),
            ("screen_diagonal", "Диагональ экрана", "choice", DIAGONAL_LIST),
            ("screen_resolution", "Разрешение экрана", "choice", RESOLUTION_LIST),
            ("condition", "Состояние", "combo", None),
        ],
    },
    "monitors": {
        "title": "Мониторы", "singular": "Монитор", "add_label": "монитор",
        "fields": [
            ("model", "Модель", "choice", None),
            ("diagonal", "Диагональ", "choice", DIAGONAL_LIST),
            ("resolution", "Разрешение", "choice", RESOLUTION_LIST),
            ("condition", "Состояние", "combo", None),
        ],
    },
    "phones": {
        "title": "Внутренние телефоны", "singular": "Телефон", "add_label": "телефон",
        "fields": [
            ("number", "Номер", "entry", None),
            ("model", "Модель", "entry", None),
            ("condition", "Состояние", "combo", None),
        ],
    },
    "printers": {
        "title": "Принтеры / МФУ", "singular": "Принтер", "add_label": "принтер / МФУ",
        "fields": [
            ("model", "Модель", "entry", None),
            ("inv", "Инв. номер", "entry", None),
            ("shared", "Общий (на кабинет/отдел)", "check", None),
            ("condition", "Состояние", "combo", None),
        ],
    },
}
DEVICE_GROUPS = list(DEVICE_SPECS.keys())


def _row_has_content(group, d):
    for key, _label, kind, _values in DEVICE_SPECS[group]["fields"]:
        val = d.get(key)
        if kind == "check" and val:
            return True
        if kind == "combo" and val and val != "рабочее":
            return True
        if kind in ("entry", "choice") and val:
            return True
    return False


# ---------------------------------------------------------------------------
# Модель: подразделения (дерево) + сотрудники
# ---------------------------------------------------------------------------
def new_unit(name, parent_id=None):
    return {"id": uuid.uuid4().hex, "name": name, "parent_id": parent_id,
            "order": 0}


def new_employee():
    return {
        "id": uuid.uuid4().hex,
        "last_name": "", "first_name": "", "middle_name": "",
        "position": "", "floor": "", "office": "", "building": "",
        "account": "",
        "unit_id": "", "is_head": False, "order": 0,
        "pcs": [], "monitors": [], "phones": [], "printers": [],
        "mouse": {"condition": "рабочее"},
        "keyboard": {"condition": "рабочее"},
        "notes": "", "updated": "",
    }


def migrate_employee(emp):
    emp.setdefault("mouse", {"condition": "рабочее"})
    emp.setdefault("keyboard", {"condition": "рабочее"})
    for k in ("last_name", "first_name", "middle_name", "position",
              "floor", "office", "building", "notes", "updated", "account"):
        emp.setdefault(k, "")
    emp.setdefault("unit_id", "")
    emp.setdefault("is_head", False)
    emp.setdefault("order", 0)

    if "pcs" not in emp:
        old = emp.get("pc")
        emp["pcs"] = []
        if old and any(old.get(x) for x in ("inv", "hostname", "specs")):
            emp["pcs"].append({
                "inv": old.get("inv", ""), "hostname": old.get("hostname", ""),
                "cpu": old.get("specs", ""), "ram": "", "storage": "", "gpu": "",
                "os": "", "office": "",
                "condition": old.get("condition", "рабочее")})
        emp.pop("pc", None)
    for pc in emp["pcs"]:
        pc.setdefault("os", "")
        pc.setdefault("office", "")
        pc.setdefault("is_laptop", False)
        pc.setdefault("screen_diagonal", "")
        pc.setdefault("screen_resolution", "")

    if "phones" not in emp:
        old = emp.get("phone")
        emp["phones"] = []
        if old and any(old.get(x) for x in ("number", "model")):
            emp["phones"].append({
                "number": old.get("number", ""), "model": old.get("model", ""),
                "condition": old.get("condition", "рабочее")})
        emp.pop("phone", None)

    if "printers" not in emp:
        old = emp.get("printer")
        emp["printers"] = []
        if old and any(old.get(x) for x in ("model", "inv")):
            emp["printers"].append({
                "model": old.get("model", ""), "inv": old.get("inv", ""),
                "shared": bool(old.get("shared", False)),
                "condition": old.get("condition", "рабочее")})
        emp.pop("printer", None)

    for m in emp.get("monitors", []):
        m.setdefault("model", "")
        m.setdefault("diagonal", "")
        m.setdefault("resolution", "")
        m.setdefault("condition", "рабочее")
    return emp


def blank_store():
    return {"units": [new_unit("Организация", None)], "employees": []}


def _normalize_order(units, emps):
    """Присваивает сквозной порядок 0..n-1 внутри каждого подразделения и
    каждой группы подотделов (сохраняя уже заданный ручной порядок)."""
    by_unit = {}
    for e in emps:
        by_unit.setdefault(e.get("unit_id"), []).append(e)
    for lst in by_unit.values():
        lst.sort(key=lambda e: (e.get("order", 0), fio(e).lower()))
        for i, e in enumerate(lst):
            e["order"] = i
    by_parent = {}
    for u in units:
        by_parent.setdefault(u.get("parent_id"), []).append(u)
    for lst in by_parent.values():
        lst.sort(key=lambda u: (u.get("order", 0), u["name"].lower()))
        for i, u in enumerate(lst):
            u["order"] = i


def normalize_store(raw):
    """Блоб «assets» в рабочем виде: корень, порядок, поля по умолчанию."""
    if raw is None:
        return blank_store()

    if isinstance(raw, list):  # старый плоский формат
        store = blank_store()
        root_id = store["units"][0]["id"]
        emps = [migrate_employee(e) for e in raw]
        for e in emps:
            e["unit_id"] = root_id
        _normalize_order(store["units"], emps)
        store["employees"] = emps
        return store

    units = raw.get("units") or []
    for u in units:
        u.setdefault("order", 0)
    emps = [migrate_employee(e) for e in raw.get("employees", [])]
    if not units:
        units = [new_unit("Организация", None)]
    if not any(not u.get("parent_id") for u in units):
        units.insert(0, new_unit("Организация", None))
    root_id = next(u["id"] for u in units if not u.get("parent_id"))
    valid = {u["id"] for u in units}
    for e in emps:
        if e.get("unit_id") not in valid:
            e["unit_id"] = root_id
    _normalize_order(units, emps)
    return {"units": units, "employees": emps}


def load_store(path=None):
    """Учёт целиком — для просмотра. Менять — через assets_tx()."""
    if path:
        return normalize_store(db.read_blob_from(path, "assets"))   # копия .db
    raw = db.get_assets_raw()
    if raw is None:                  # пустой учёт — сохранить, чтобы id корня не менялся
        with assets_tx() as st:
            return st
    return normalize_store(raw)


def assets_tx():
    """Свежий учёт под блокировкой записи; по выходу из блока — сохранён."""
    return db.blob_tx("assets", normalize_store)


DEFAULT_CONFIG = {
    "ai_base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
    "ai_model": "gemini-flash-latest",
    "ai_key": "",
}


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    stored = db.get_config()
    if isinstance(stored, dict):
        cfg.update(stored)
    return cfg


def save_config(cfg):
    db.put_config(cfg)



# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------
def fio(emp):
    parts = [emp.get("last_name", ""), emp.get("first_name", ""),
             emp.get("middle_name", "")]
    return " ".join(p for p in parts if p).strip() or "(без имени)"


# поля, не имеющие смысла для поиска (служебные идентификаторы)
_SEARCH_SKIP = {"id", "unit_id", "order", "updated"}
# булевы поля → человеческие слова, чтобы искалось «ноутбук» и «руководитель»
_SEARCH_FLAGS = {"is_laptop": "ноутбук моноблок", "is_head": "руководитель начальник"}


def search_text(emp: dict, units: list) -> str:
    """Все данные сотрудника одной строкой: ФИО, подразделение, техника, заметки.

    Собирается рекурсивно, поэтому любое новое поле карточки становится
    доступным для поиска автоматически.
    """
    parts = [fio(emp), unit_path(units, emp.get("unit_id"))]

    def walk(value, key=""):
        if isinstance(value, dict):
            for k, v in value.items():
                if k not in _SEARCH_SKIP:
                    walk(v, k)
        elif isinstance(value, list):
            for item in value:
                walk(item, key)
        elif isinstance(value, bool):
            if value:
                parts.append(_SEARCH_FLAGS.get(key, key))
        elif value not in (None, ""):
            parts.append(str(value))

    walk(emp)
    return " ".join(parts).lower()


def device_hint(emp: dict, tokens: list) -> str:
    """Короткая подсказка, какая именно техника подошла под запрос."""
    for group, label in (("pcs", "ПК"), ("monitors", "Монитор"),
                         ("phones", "Телефон"), ("printers", "Принтер")):
        for dev in emp.get(group) or []:
            text = " ".join(str(v) for v in dev.values()
                            if isinstance(v, str) and v).lower()
            if text and all(t in text for t in tokens):
                bits = [dev.get("inv"), dev.get("hostname"), dev.get("model"),
                        dev.get("cpu"), dev.get("number")]
                bits = [b for b in bits if b]
                return f"  ·  {label}: " + " / ".join(bits[:3]) if bits else ""
    return ""


# Промпт «Заполнить карточку из заметки» (им же пользуется окно Liquid Glass)
AI_FILL_PROMPT = (
    "Ты извлекаешь данные о сотруднике и его рабочем месте из "
    "свободного текста на русском. Верни ТОЛЬКО JSON без markdown. "
    "У сотрудника может быть НЕСКОЛЬКО ПК, мониторов, телефонов и "
    "принтеров — это массивы. Схема (заполняй только явно указанное):\n"
    '{"last_name":"","first_name":"","middle_name":"","position":"",'
    '"building":"","floor":"","office":"",'
    '"pcs":[{"inv":"","hostname":"","cpu":"","ram":"","storage":"",'
    '"gpu":"","os":"","office":"","is_laptop":false,'
    '"screen_diagonal":"","screen_resolution":"","condition":""}],'
    '"monitors":[{"model":"","diagonal":"","resolution":"","condition":""}],'
    '"phones":[{"number":"","model":"","condition":""}],'
    '"printers":[{"model":"","inv":"","shared":false,"condition":""}],'
    '"mouse":{"condition":""},"keyboard":{"condition":""},"notes":""}\n'
    "os — версия Windows; office — версия Microsoft Office. "
    "is_laptop=true если это ноутбук или моноблок; "
    "screen_diagonal и screen_resolution — диагональ (например "
    "15.6\") и разрешение (например 1920x1080) встроенного экрана. "
    "condition строго одно из: рабочее, требует замены, "
    "неисправно, отсутствует.")


def worst_condition(emp):
    conds = []
    for group in DEVICE_GROUPS:
        for dev in emp.get(group, []):
            conds.append(dev.get("condition", "рабочее"))
    conds.append(emp["mouse"]["condition"])
    conds.append(emp["keyboard"]["condition"])
    conds = [c for c in conds if c and c != "отсутствует"]
    if not conds:
        return "отсутствует"
    return max(conds, key=lambda c: COND_RANK.get(c, 0))


def unit_by_id(units, uid):
    return next((u for u in units if u["id"] == uid), None)


def unit_children(units, parent_id):
    return [u for u in units if u.get("parent_id") == parent_id]


def unit_root_id(units):
    for u in units:
        if not u.get("parent_id"):
            return u["id"]
    return units[0]["id"] if units else ""


def unit_path(units, uid):
    names, seen = [], set()
    cur = unit_by_id(units, uid)
    while cur and cur["id"] not in seen:
        seen.add(cur["id"])
        names.append(cur["name"])
        pid = cur.get("parent_id")
        cur = unit_by_id(units, pid) if pid else None
    return " / ".join(reversed(names))


def unit_flat(units):
    """[(id, name, depth)] в порядке дерева (для списков/экспорта)."""
    out = []

    def walk(parent_id, depth):
        for u in sorted(unit_children(units, parent_id),
                        key=lambda x: (x.get("order", 0), x["name"].lower())):
            out.append((u["id"], u["name"], depth))
            walk(u["id"], depth + 1)

    for r in sorted([u for u in units if not u.get("parent_id")],
                    key=lambda x: (x.get("order", 0), x["name"].lower())):
        out.append((r["id"], r["name"], 0))
        walk(r["id"], 1)
    return out


def _compact_device(dev):
    return {k: v for k, v in dev.items() if v not in ("", None, False)}


def fmt_pc_line(pc):
    parts = []
    if pc.get("inv"):
        parts.append("инв " + pc["inv"])
    if pc.get("hostname"):
        parts.append(pc["hostname"])
    specs = "/".join(x for x in (pc.get("cpu"), pc.get("ram"),
                                 pc.get("storage"), pc.get("gpu")) if x)
    if specs:
        parts.append(specs)
    if pc.get("os"):
        parts.append(pc["os"])
    if pc.get("office"):
        parts.append(pc["office"])
    if pc.get("is_laptop"):
        scr = " ".join(x for x in (pc.get("screen_diagonal"),
                                   pc.get("screen_resolution")) if x)
        parts.append("ноут/моноблок" + (" " + scr if scr else ""))
    head = " · ".join(parts) if parts else "ПК"
    c = pc.get("condition", "")
    return head + (f" — {c}" if c else "")


def fmt_monitor_line(m):
    parts = [x for x in (m.get("model"), m.get("diagonal"),
                         m.get("resolution")) if x]
    head = " ".join(parts) if parts else "монитор"
    c = m.get("condition", "")
    return head + (f" — {c}" if c else "")


def fmt_phone_line(ph):
    s = ph.get("model", "")
    if ph.get("number"):
        s = (s + f" (вн. {ph['number']})").strip()
    if not s:
        s = "телефон"
    c = ph.get("condition", "")
    return s + (f" — {c}" if c else "")


def fmt_printer_line(pr):
    parts = []
    if pr.get("model"):
        parts.append(pr["model"])
    if pr.get("inv"):
        parts.append("инв " + pr["inv"])
    if pr.get("shared"):
        parts.append("общий")
    head = " · ".join(parts) if parts else "принтер"
    c = pr.get("condition", "")
    return head + (f" — {c}" if c else "")


def fmt_devices(lst, fmt):
    return "\n".join(fmt(d) for d in lst)


def compact_employee(emp, units):
    out = {"фио": fio(emp), "должность": emp.get("position", "")}
    path = unit_path(units, emp.get("unit_id"))
    if path:
        out["подразделение"] = path
    if emp.get("is_head"):
        out["руководитель"] = True
    loc = []
    if emp.get("building"):
        loc.append(f"корпус {emp['building']}")
    if emp.get("floor"):
        loc.append(f"этаж {emp['floor']}")
    if emp.get("office"):
        loc.append(f"каб. {emp['office']}")
    if loc:
        out["расположение"] = ", ".join(loc)
    names = {"pcs": "пк", "monitors": "мониторы",
             "phones": "телефоны", "printers": "принтеры_мфу"}
    for group in DEVICE_GROUPS:
        devs = [_compact_device(d) for d in emp.get(group, [])]
        devs = [d for d in devs if d]
        if devs:
            out[names[group]] = devs
    out["мышь"] = emp["mouse"]["condition"]
    out["клавиатура"] = emp["keyboard"]["condition"]
    if emp.get("notes"):
        out["примечание"] = emp["notes"]
    return out


def ai_chat(config, messages, temperature=0.3, timeout=90):
    import requests
    base = config.get("ai_base_url", "").rstrip("/")
    if not base:
        raise RuntimeError("Не задан адрес ИИ-сервера (Настройки).")
    url = base + "/chat/completions"
    headers = {"Content-Type": "application/json"}
    key = config.get("ai_key", "")
    if key:
        headers["Authorization"] = "Bearer " + key
    payload = {"model": config.get("ai_model", ""),
               "messages": messages, "temperature": temperature}
    r = requests.post(url, headers=headers, data=json.dumps(payload), timeout=timeout)
    if r.status_code >= 400:
        raise RuntimeError(f"Сервер вернул {r.status_code}: {r.text[:400]}")
    return r.json()["choices"][0]["message"]["content"]


def _parse_json(raw):
    s = raw.strip()
    if s.startswith("```"):
        s = s.split("```", 2)[1]
        if s.lstrip().lower().startswith("json"):
            s = s.lstrip()[4:]
    s = s.strip().strip("`").strip()
    start, end = s.find("{"), s.rfind("}")
    if start != -1 and end != -1:
        s = s[start:end + 1]
    return json.loads(s)


# ---------------------------------------------------------------------------
# Порядок — как в дереве: руководитель первым, дальше ручной порядок
# ---------------------------------------------------------------------------
def emp_sort_key(e):
    return (not e.get("is_head"), e.get("order", 0), fio(e).lower())


def unit_sort_key(u):
    return (u.get("order", 0), u["name"].lower())


def find_employee(store, emp_id):
    return next((e for e in store["employees"] if e["id"] == emp_id), None)


def employees_in_tree_order(store):
    """Плоский список сотрудников в точном порядке дерева (для экспорта)."""
    units, emps, result = store["units"], store["employees"], []

    def walk(unit_id):
        result.extend(sorted((e for e in emps if e.get("unit_id") == unit_id),
                             key=emp_sort_key))
        for child in sorted(unit_children(units, unit_id), key=unit_sort_key):
            walk(child["id"])

    for root in sorted([u for u in units if not u.get("parent_id")], key=unit_sort_key):
        walk(root["id"])
    return result


def search(store, query):
    """Сотрудники, у которых в данных есть все слова запроса, с подсказкой —
    какая техника подошла."""
    tokens = str(query or "").lower().split()
    out = []
    for e in sorted(store["employees"], key=emp_sort_key):
        if all(t in search_text(e, store["units"]) for t in tokens):
            out.append((e, device_hint(e, tokens).strip(" ·") if tokens else ""))
    return out


# ---------------------------------------------------------------------------
# Операции (каждая — одна транзакция)
# ---------------------------------------------------------------------------
def add_employee(unit_id=None):
    """Новая пустая карточка в подразделении. Возвращает id."""
    with assets_tx() as st:
        if not unit_by_id(st["units"], unit_id):
            unit_id = unit_root_id(st["units"])
        emp = new_employee()
        emp["unit_id"] = unit_id
        sibs = [e for e in st["employees"] if e.get("unit_id") == unit_id]
        emp["order"] = max((e.get("order", 0) for e in sibs), default=-1) + 1
        st["employees"].append(emp)
    return emp["id"]


def save_employee(emp_id, d, create=False):
    """Сохранить карточку: поля, техника, один руководитель на подразделение.
    create — карточки с таким id нет (заведена на телефоне без сети): создать."""
    with assets_tx() as st:
        emp = find_employee(st, emp_id)
        if not emp and create:
            emp = new_employee()
            emp["id"] = emp_id
            emp["unit_id"] = d.get("unit_id") if unit_by_id(st["units"], d.get("unit_id"))                 else unit_root_id(st["units"])
            sibs = [e for e in st["employees"] if e.get("unit_id") == emp["unit_id"]]
            emp["order"] = max((e.get("order", 0) for e in sibs), default=-1) + 1
            st["employees"].append(emp)
        if not emp:
            raise ValueError("Сотрудник не найден — возможно, его уже удалили.")
        for k in ("last_name", "first_name", "middle_name", "position", "account",
                  "building", "floor", "office", "notes"):
            if k in d:
                emp[k] = str(d.get(k) or "").strip()
        if d.get("unit_id") and unit_by_id(st["units"], d["unit_id"]):
            emp["unit_id"] = d["unit_id"]
        for g, sp in DEVICE_SPECS.items():
            if g not in d:
                continue
            rows = []
            for dev in d.get(g) or []:
                row = {}
                for key, _label, kind, _vals in sp["fields"]:
                    v = dev.get(key)
                    row[key] = bool(v) if kind == "check" else str(v or "").strip()
                if row.get("condition") not in CONDITIONS:
                    row["condition"] = CONDITIONS[0]
                rows.append(row)
            emp[g] = rows
        for part in ("mouse", "keyboard"):
            c = (d.get(part) or {}).get("condition")
            if c is not None:
                if c not in CONDITIONS:
                    raise ValueError(f"Состояние «{c}» не из списка.")
                emp[part] = {"condition": c}
        emp["is_head"] = bool(d.get("is_head", emp.get("is_head")))
        if emp["is_head"]:
            for other in st["employees"]:
                if other is not emp and other.get("unit_id") == emp.get("unit_id"):
                    other["is_head"] = False
        migrate_employee(emp)
        emp["updated"] = datetime.datetime.now().strftime("%d.%m.%Y %H:%M")
    return emp_id


def delete_employee(emp_id):
    with assets_tx() as st:
        before = len(st["employees"])
        st["employees"] = [e for e in st["employees"] if e["id"] != emp_id]
        return len(st["employees"]) != before


def add_unit(parent_id, name):
    name = str(name or "").strip()
    if not name:
        raise ValueError("Введите название подразделения.")
    with assets_tx() as st:
        if not unit_by_id(st["units"], parent_id):
            parent_id = unit_root_id(st["units"])
        u = new_unit(name, parent_id)
        sibs = [x for x in st["units"] if x.get("parent_id") == parent_id]
        u["order"] = max((x.get("order", 0) for x in sibs), default=-1) + 1
        st["units"].append(u)
    return u["id"]


def rename_unit(unit_id, name):
    name = str(name or "").strip()
    if not name:
        raise ValueError("Введите новое название.")
    with assets_tx() as st:
        u = unit_by_id(st["units"], unit_id)
        if not u:
            raise ValueError("Подразделение не найдено.")
        u["name"] = name


def delete_unit(unit_id):
    """Сотрудники и подотделы удаляемого подразделения переходят на уровень выше."""
    with assets_tx() as st:
        u = unit_by_id(st["units"], unit_id)
        if not u:
            raise ValueError("Подразделение не найдено.")
        parent = u.get("parent_id")
        if not parent:
            raise ValueError("Корневую организацию удалить нельзя.")
        for e in st["employees"]:
            if e.get("unit_id") == unit_id:
                e["unit_id"] = parent
        for child in st["units"]:
            if child.get("parent_id") == unit_id:
                child["parent_id"] = parent
        st["units"] = [x for x in st["units"] if x["id"] != unit_id]
    return parent


def unit_has_content(store, unit_id):
    return (any(e.get("unit_id") == unit_id for e in store["employees"])
            or bool(unit_children(store["units"], unit_id)))


def move(kind, item_id, delta):
    """Сотрудника — внутри подразделения, подразделение — среди соседних.
    Руководитель закреплён первым. True — порядок поменялся."""
    with assets_tx() as st:
        if kind == "emp":
            emp = find_employee(st, item_id)
            if not emp or emp.get("is_head"):
                return False
            sibs = sorted((e for e in st["employees"]
                           if e.get("unit_id") == emp.get("unit_id") and not e.get("is_head")),
                          key=emp_sort_key)
        else:
            emp = unit_by_id(st["units"], item_id)
            if not emp:
                return False
            sibs = sorted((x for x in st["units"] if x.get("parent_id") == emp.get("parent_id")),
                          key=unit_sort_key)
        i = sibs.index(emp)
        j = i + delta
        if not 0 <= j < len(sibs):
            return False
        emp["order"], sibs[j]["order"] = sibs[j]["order"], emp["order"]
        return True


def set_unit_head(unit_id, emp_id):
    """Сделать сотрудника руководителем подразделения. Возвращает короткое ФИО."""
    with assets_tx() as st:
        target = find_employee(st, emp_id)
        if not target:
            raise ValueError("Сотрудник не найден.")
        for e in st["employees"]:
            if e.get("unit_id") == unit_id and e.get("is_head"):
                e["is_head"] = False
        target["unit_id"] = unit_id
        target["is_head"] = True
        return db.short_fio(target)


def apply_ai_fill(emp_id, data):
    """Разложить ответ ИИ («заполнить из заметки») по карточке."""
    with assets_tx() as st:
        emp = find_employee(st, emp_id)
        if not emp:
            raise ValueError("Сотрудник не найден.")
        for k in ("last_name", "first_name", "middle_name", "position",
                  "building", "floor", "office", "notes"):
            if data.get(k):
                emp[k] = str(data[k])
        for periph in ("mouse", "keyboard"):
            c = (data.get(periph) or {}).get("condition")
            if c in CONDITIONS:
                emp[periph] = {"condition": c}
        for group in DEVICE_GROUPS:
            clean = []
            for d in data.get(group) or []:
                if not isinstance(d, dict):
                    continue
                item = {}
                for key, _l, kind, _v in DEVICE_SPECS[group]["fields"]:
                    if kind == "check":
                        item[key] = bool(d.get(key, False))
                    elif kind == "combo":
                        item[key] = d.get(key) if d.get(key) in CONDITIONS else "рабочее"
                    else:
                        item[key] = str(d.get(key, "") or "")
                if _row_has_content(group, item):
                    clean.append(item)
            if clean:
                emp[group] = clean
        emp["updated"] = datetime.datetime.now().strftime("%d.%m.%Y %H:%M")


def import_scan_csv(path):
    """MAC и IP из CSV сканера сети (scan_net.ps1): по уже указанному MAC
    либо по имени компьютера. Заполняются только пустые поля.
    Возвращает (заполнено полей, записей в файле)."""
    import uchetki_export as ux
    scan = ux.import_from_scan(path)
    if not scan:
        raise ValueError("В файле не найдено MAC-адресов.")
    by_name = {}
    for mac, info in scan.items():
        nm = (info.get("name") or "").split(".")[0].strip().lower()
        if nm:
            by_name[nm] = (mac, info.get("ip", ""))
    filled = 0
    with assets_tx() as st:
        for emp in st["employees"]:
            for pc in emp.get("pcs") or []:
                mac = (pc.get("mac") or "").strip().upper().replace("-", ":")
                host = (pc.get("hostname") or "").strip().lower()
                if mac and mac in scan and not (pc.get("ip") or "").strip():
                    pc["ip"] = scan[mac]["ip"]
                    filled += 1
                elif host and host in by_name:
                    m, ip = by_name[host]
                    if not (pc.get("mac") or "").strip():
                        pc["mac"] = m
                        filled += 1
                    if ip and not (pc.get("ip") or "").strip():
                        pc["ip"] = ip
                        filled += 1
    return filled, len(scan)


# ---------------------------------------------------------------------------
# Статистика и выгрузки
# ---------------------------------------------------------------------------
def stats_text(store):
    emps, units = store["employees"], store["units"]
    lines = [f"Всего сотрудников: {len(emps)}",
             f"Подразделений: {len([u for u in units if u.get('parent_id')])}"]
    totals = {g: sum(len(e.get(g, [])) for e in emps) for g in DEVICE_GROUPS}
    lines.append(f"Единиц техники: ПК {totals['pcs']}, мониторов "
                 f"{totals['monitors']}, телефонов {totals['phones']}, "
                 f"принтеров {totals['printers']}\n")
    lines.append("По подразделениям:")
    for uid, name, depth in unit_flat(units):
        cnt = sum(1 for e in emps if e.get("unit_id") == uid)
        if cnt:
            lines.append(f"  {'  ' * depth}{name}: {cnt}")
    lines.append("")

    def group(getter, name):
        counts = {c: 0 for c in CONDITIONS}
        for e in emps:
            for cond in getter(e):
                counts[cond] = counts.get(cond, 0) + 1
        lines.append(f"{name}:")
        for c in CONDITIONS:
            lines.append(f"  {c}: {counts[c]}")
        lines.append("")

    group(lambda e: [d["condition"] for d in e.get("pcs", [])], "ПК")
    group(lambda e: [d["condition"] for d in e.get("monitors", [])], "Мониторы")
    group(lambda e: [d["condition"] for d in e.get("phones", [])], "Телефоны")
    group(lambda e: [d["condition"] for d in e.get("printers", [])], "Принтеры / МФУ")
    group(lambda e: [e["mouse"]["condition"]], "Мыши")
    group(lambda e: [e["keyboard"]["condition"]], "Клавиатуры")

    attention = [e for e in emps if worst_condition(e) in ("неисправно", "требует замены")]
    if attention:
        lines.append("Требует внимания:")
        for e in attention:
            lines.append(f"  • {fio(e)} (каб. {e.get('office') or '—'}) — {worst_condition(e)}")
    return "\n".join(lines)


def export_excel(store, path):
    """Учёт в Excel: «Сотрудники», «Техника» (строка на единицу), «Оргструктура»."""
    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.utils import get_column_letter

    units = store["units"]
    head_fill = PatternFill("solid", fgColor="1E66F5")
    head_font = Font(bold=True, color="FFFFFF", name="Calibri", size=11)
    thin = Side(style="thin", color="D0D0D0")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    cond_fill = {
        "рабочее": PatternFill("solid", fgColor="D5F5D0"),
        "требует замены": PatternFill("solid", fgColor="FFE9C7"),
        "неисправно": PatternFill("solid", fgColor="F9D0D8"),
        "отсутствует": PatternFill("solid", fgColor="E8E8E8"),
    }

    def style_header(ws):
        for c in ws[1]:
            c.fill = head_fill
            c.font = head_font
            c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
            c.border = border

    def put_row(ws, row, cond_col=None, wrap_cols=()):
        ws.append(row)
        r = ws.max_row
        maxlines = 1
        for ci in range(1, len(row) + 1):
            cell = ws.cell(row=r, column=ci)
            cell.border = border
            wrap = ci in wrap_cols
            cell.alignment = Alignment(vertical="center", wrap_text=wrap)
            if wrap and isinstance(row[ci - 1], str):
                maxlines = max(maxlines, row[ci - 1].count("\n") + 1)
        if cond_col:
            cv = ws.cell(row=r, column=cond_col).value
            if cv in cond_fill:
                ws.cell(row=r, column=cond_col).fill = cond_fill[cv]
        if maxlines > 1:
            ws.row_dimensions[r].height = 14 * maxlines

    ordered = employees_in_tree_order(store)
    wb = Workbook()

    ws = wb.active
    ws.title = "Сотрудники"
    ws.append(["ФИО", "Должность", "Подразделение", "Руководитель", "Корпус",
               "Этаж", "Кабинет", "Компьютеры", "Мониторы", "Телефоны",
               "Принтеры / МФУ", "Мышь", "Клавиатура", "Состояние",
               "Примечание", "Изменено"])
    style_header(ws)
    for e in ordered:
        mark = "★ " if e.get("is_head") else ""
        put_row(ws, [
            mark + fio(e), e.get("position", ""), unit_path(units, e.get("unit_id")),
            "да" if e.get("is_head") else "", e.get("building", ""),
            e.get("floor", ""), e.get("office", ""),
            fmt_devices(e.get("pcs", []), fmt_pc_line),
            fmt_devices(e.get("monitors", []), fmt_monitor_line),
            fmt_devices(e.get("phones", []), fmt_phone_line),
            fmt_devices(e.get("printers", []), fmt_printer_line),
            e["mouse"]["condition"], e["keyboard"]["condition"],
            worst_condition(e), e.get("notes", ""), e.get("updated", ""),
        ], cond_col=14, wrap_cols=(8, 9, 10, 11, 15))
    for i, w in enumerate([26, 20, 26, 12, 12, 6, 8, 40, 30, 20, 26, 14, 14,
                           16, 26, 15], start=1):
        ws.column_dimensions[get_column_letter(i)].width = w
    ws.freeze_panes = "B2"
    ws.auto_filter.ref = ws.dimensions

    ws2 = wb.create_sheet("Техника")
    ws2.append(["Тип", "Подразделение", "ФИО", "Должность", "Корпус", "Этаж",
                "Кабинет", "Инв. №", "Модель / Имя ПК", "Процессор", "ОЗУ",
                "Накопитель", "Видеокарта", "ОС", "Офис", "Ноутбук/моноблок",
                "Диагональ", "Разрешение", "Общий", "Состояние"])
    style_header(ws2)
    cc = 20
    for e in ordered:
        base = [unit_path(units, e.get("unit_id")), fio(e), e.get("position", ""),
                e.get("building", ""), e.get("floor", ""), e.get("office", "")]
        for pc in e.get("pcs", []):
            put_row(ws2, ["ПК"] + base + [
                pc.get("inv", ""), pc.get("hostname", ""), pc.get("cpu", ""),
                pc.get("ram", ""), pc.get("storage", ""), pc.get("gpu", ""),
                pc.get("os", ""), pc.get("office", ""), "да" if pc.get("is_laptop") else "",
                pc.get("screen_diagonal", ""), pc.get("screen_resolution", ""), "",
                pc.get("condition", "")], cc, (9, 10))
        for m in e.get("monitors", []):
            put_row(ws2, ["Монитор"] + base + ["", m.get("model", ""), "", "", "", "", "",
                                               "", "", m.get("diagonal", ""),
                                               m.get("resolution", ""), "",
                                               m.get("condition", "")], cc)
        for ph in e.get("phones", []):
            name = ph.get("model", "")
            if ph.get("number"):
                name = (name + f" (вн. {ph['number']})").strip()
            put_row(ws2, ["Телефон"] + base + ["", name] + [""] * 10
                    + [ph.get("condition", "")], cc)
        for pr in e.get("printers", []):
            put_row(ws2, ["Принтер / МФУ"] + base + [pr.get("inv", ""), pr.get("model", "")]
                    + [""] * 9 + ["да" if pr.get("shared") else "нет",
                                  pr.get("condition", "")], cc)
        put_row(ws2, ["Мышь"] + base + [""] * 12 + [e["mouse"]["condition"]], cc)
        put_row(ws2, ["Клавиатура"] + base + [""] * 12 + [e["keyboard"]["condition"]], cc)
    for i, w in enumerate([14, 26, 22, 16, 12, 6, 8, 12, 22, 18, 10, 16, 16,
                           16, 16, 15, 11, 13, 8, 14], start=1):
        ws2.column_dimensions[get_column_letter(i)].width = w
    ws2.freeze_panes = "A2"
    ws2.auto_filter.ref = ws2.dimensions

    ws3 = wb.create_sheet("Оргструктура")
    ws3.append(["Подразделение", "Руководитель", "Сотрудников"])
    style_header(ws3)
    for uid, name, depth in unit_flat(units):
        emps = [e for e in store["employees"] if e.get("unit_id") == uid]
        head = next((fio(e) for e in emps if e.get("is_head")), "")
        put_row(ws3, [("    " * depth) + name, head, len(emps)])
    for i, w in enumerate([46, 26, 14], start=1):
        ws3.column_dimensions[get_column_letter(i)].width = w
    ws3.freeze_panes = "A2"
    wb.save(path)
    return path


def export_uchetki(store, path, with_ip=False):
    """Таблица учётных записей: ФИО, учётка, MAC, инв. номер → Word.
    Возвращает (строк, из них с MAC)."""
    import uchetki_export as ux
    rows = ux.rows_from_store(store["employees"], store["units"])
    if not rows:
        raise ValueError("В учёте нет сотрудников.")
    ux.build_docx(path, rows, with_ip=with_ip)
    return len(rows), sum(1 for r in rows if r["mac"])


# ---------------------------------------------------------------------------
# ИИ-помощник учёта — те же промпты, что в окне
# ---------------------------------------------------------------------------
def ai_fill(cfg, text):
    if not text.strip():
        raise ValueError("Впиши заметку, например: «Петров Иван, инженер, 2 этаж каб 205, "
                         "ПК инв 4471 i5/16ГБ/512 SSD Windows 11, монитор Dell 24 дюйма».")
    raw = ai_chat(cfg, [{"role": "system", "content": AI_FILL_PROMPT},
                        {"role": "user", "content": text}])
    return _parse_json(raw)


def ai_analyze(cfg, store):
    if not store["employees"]:
        raise ValueError("Список пуст.")
    dataset = [compact_employee(e, store["units"]) for e in store["employees"]]
    sys_p = ("Ты ИТ-аналитик. По JSON с сотрудниками, подразделениями и "
             "техникой составь краткий отчёт на русском: сводка, "
             "перечень техники под замену/ремонт (с ФИО, подразделением "
             "и кабинетом) и рекомендации по приоритету закупок. "
             "По делу, без воды.")
    return ai_chat(cfg, [{"role": "system", "content": sys_p},
                         {"role": "user", "content": json.dumps(dataset, ensure_ascii=False)}],
                   temperature=0.4)


def ai_question(cfg, store, question):
    if not question.strip():
        raise ValueError("Впиши вопрос, например: «сколько ПК требуют замены в отделе метрологии?»")
    dataset = [compact_employee(e, store["units"]) for e in store["employees"]]
    sys_p = ("Ты помощник по базе учёта техники и оргструктуры. "
             "Отвечай на русском, опираясь только на переданный JSON. "
             "Если данных нет — так и скажи.")
    return ai_chat(cfg, [{"role": "system", "content": sys_p},
                         {"role": "user", "content": "Данные:\n" + json.dumps(dataset, ensure_ascii=False)
                          + "\n\nВопрос: " + question}])


# ---------------------------------------------------------------------------
# Анализ парка ПК (pc_audit): что под замену, что модернизировать
# ---------------------------------------------------------------------------
def audit(store):
    """(строки по ПК, сводка)."""
    import pc_audit as pa
    rows = pa.collect(store["employees"], store["units"], unit_path, fio)
    for r in rows:
        r["need"] = pa.need_label(r)
    return rows, pa.summarize(rows)


def audit_ai_text(cfg, store):
    import pc_audit as pa
    rows, summ = audit(store)
    text = ai_chat(cfg, [{"role": "system", "content": pa.AI_SYSTEM},
                         {"role": "user", "content": pa.ai_prompt(summ, rows)}])
    if not (text or "").strip():
        raise ValueError("ИИ вернул пустой ответ — записка будет по типовому тексту.")
    return text.strip()


def audit_memo(store, path, body_text=None):
    """Служебная записка о замене техники в Word."""
    import pc_audit as pa
    rows, summ = audit(store)
    if not rows:
        raise ValueError("В учёте нет компьютеров для анализа.")
    defaults = db.get_purchase_defaults() or {}
    org = db.get_org_profile()
    pa.build_memo_docx(path, branch=org.get("branch", ""), responsible=org.get("fio", ""),
                       director_title=defaults.get("director_title", "Директор"),
                       director=defaults.get("director", ""), summary=summ, rows=rows,
                       body_text=body_text or None, position=org.get("position", ""))
    return path
