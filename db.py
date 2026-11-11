# -*- coding: utf-8 -*-
"""
db.py — единое хранилище ITtool на SQLite (~/.local/share/ITtool/itmanager.db).

Стратегия объединения:
  • Данные бывших программ (отчёты, учёт техники) хранятся как JSON-блобы — это
    гарантирует 100% сохранность их структуры и всех наработанных фиксов: модули
    продолжают читать/писать привычные словари, меняется только физический слой.
  • Заявки на закуп — нормализованные таблицы (ссылаются на id сотрудника из
    учёта техники), т.к. это новый модуль и ему нужна реляционность.
  • При первом запуске переносим старые JSON (report_data.json, employees_data.json,
    config.json) из прежних папок — данные пользователя не теряются.
"""
from __future__ import annotations

import os
import sys
import json
import time
import sqlite3
import shutil
import datetime
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Optional

APP_NAME = "ITtool"


# ─────────────────────────────────────────────────────────────────────────────
#  Пути
# ─────────────────────────────────────────────────────────────────────────────
def app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(os.path.dirname(sys.executable))
    return Path(os.path.dirname(os.path.abspath(__file__)))


def data_dir() -> Path:
    base = os.environ.get("APPDATA")
    if not base:
        base = os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_DATA_HOME") \
            or os.path.expanduser("~/.local/share")
    d = Path(base) / APP_NAME
    d.mkdir(parents=True, exist_ok=True)
    return d


DB_PATH = data_dir() / "itmanager.db"


def _open() -> sqlite3.Connection:
    con = sqlite3.connect(str(DB_PATH), timeout=15)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


@contextmanager
def _connect():
    """Транзакция и закрытие соединения. `with sqlite3.connect()` само не закрывает:
    у бота за сутки копились сотни открытых файлов базы, и он падал (лимит 1024)."""
    con = _open()
    try:
        with con:
            yield con
    finally:
        con.close()


# ─────────────────────────────────────────────────────────────────────────────
#  Схема + инициализация
# ─────────────────────────────────────────────────────────────────────────────
_SCHEMA = """
CREATE TABLE IF NOT EXISTS blobs (
    name TEXT PRIMARY KEY,
    json TEXT NOT NULL,
    updated TEXT
);

CREATE TABLE IF NOT EXISTS employees_index (
    id        TEXT PRIMARY KEY,
    fio       TEXT,
    position  TEXT,
    unit_path TEXT
);

CREATE TABLE IF NOT EXISTS purchase_requests (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    number       TEXT,
    created_at   TEXT,
    department   TEXT,
    employee_id  TEXT,
    justification TEXT,
    status       TEXT DEFAULT 'Черновик',
    notes        TEXT,
    director      TEXT,
    accountant    TEXT,
    head_of_dept  TEXT,
    sysadmin      TEXT,
    approver      TEXT,
    approved_date TEXT
);

CREATE TABLE IF NOT EXISTS purchase_items (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id INTEGER NOT NULL REFERENCES purchase_requests(id) ON DELETE CASCADE,
    name TEXT,
    qty  REAL DEFAULT 1,
    unit TEXT DEFAULT 'шт.',
    ord  INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS cartridge_issues (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    issued_at   TEXT,
    employee_id TEXT,
    employee    TEXT,
    model       TEXT,
    qty         INTEGER DEFAULT 1,
    note        TEXT
);
"""


def _migrate_from_itmanager() -> None:
    """Одноразовый перенос данных из %APPDATA%\\ITManager (старое имя) в новую
    папку приложения, если новой базы ещё нет. Копирует базу, бэкапы, шаблоны."""
    if os.environ.get("ITTOOL_NO_LEGACY"):        # тесты: только своя временная база
        return
    try:
        new_dir = data_dir()
        new_db = new_dir / "itmanager.db"
        if new_db.exists():
            return
        for env in ("APPDATA", "LOCALAPPDATA"):
            base = os.environ.get(env)
            if not base:
                continue
            old_dir = Path(base) / "ITManager"
            old_db = old_dir / "itmanager.db"
            if not old_db.exists():
                continue
            new_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(old_db), str(new_db))
            for sub in ("backups", "templates"):
                src = old_dir / sub
                if src.is_dir():
                    (new_dir / sub).mkdir(exist_ok=True)
                    for f in src.glob("*"):
                        if f.is_file():
                            try:
                                shutil.copy2(str(f), str(new_dir / sub / f.name))
                            except Exception:
                                pass
            return
    except Exception:
        pass


def init_db() -> None:
    _migrate_from_itmanager()
    with _connect() as con:
        con.executescript(_SCHEMA)
        # миграция: в employees_index добавить unit_id, если его ещё нет
        cols = [r[1] for r in con.execute(
            "PRAGMA table_info(employees_index)").fetchall()]
        if "unit_id" not in cols:
            con.execute("ALTER TABLE employees_index ADD COLUMN unit_id TEXT")
    _import_legacy_if_empty()
    # держим индекс сотрудников актуальным (в т.ч. заполнить unit_id)
    store = get_assets_raw()
    if store:
        _reindex_employees(store)


# ─────────────────────────────────────────────────────────────────────────────
#  Низкоуровневые блобы
# ─────────────────────────────────────────────────────────────────────────────
def _get_blob(name: str) -> Optional[dict]:
    with _connect() as con:
        row = con.execute("SELECT json FROM blobs WHERE name=?", (name,)).fetchone()
    if not row:
        return None
    try:
        return json.loads(row["json"])
    except Exception:
        return None


def read_blob_from(dbfile: str, name: str) -> Optional[dict]:
    """Читает блоб из ДРУГОГО файла БД (для восстановления из резервной копии)."""
    try:
        con = sqlite3.connect(str(dbfile))
        con.row_factory = sqlite3.Row
        row = con.execute("SELECT json FROM blobs WHERE name=?", (name,)).fetchone()
        con.close()
        return json.loads(row["json"]) if row else None
    except Exception:
        return None


def _put_blob(name: str, obj: Any) -> None:
    payload = json.dumps(obj, ensure_ascii=False)
    now = datetime.datetime.now().isoformat(timespec="seconds")
    with _connect() as con:
        con.execute(
            "INSERT INTO blobs(name, json, updated) VALUES(?,?,?) "
            "ON CONFLICT(name) DO UPDATE SET json=excluded.json, updated=excluded.updated",
            (name, payload, now))
    make_backup()


@contextmanager
def blob_tx(name: str, prepare=None):
    """Прочитать блоб, изменить и записать одной транзакцией.

    Интерфейс и телеграм-бот — разные процессы: каждый меняет свежие данные
    под блокировкой записи, поэтому правки одного не затирают правки другого.
    prepare(сырое значение или None) → рабочий объект (дефолты, миграции).
    Исключение внутри блока — ничего не записано."""
    con = _open()
    con.isolation_level = None
    try:
        con.execute("BEGIN IMMEDIATE")
        row = con.execute("SELECT json FROM blobs WHERE name=?", (name,)).fetchone()
        obj = None
        if row:
            try:
                obj = json.loads(row["json"])
            except Exception:
                obj = None
        if prepare is not None:
            obj = prepare(obj)
        try:
            yield obj
        except BaseException:
            con.execute("ROLLBACK")
            raise
        now = datetime.datetime.now().isoformat(timespec="seconds")
        con.execute(
            "INSERT INTO blobs(name, json, updated) VALUES(?,?,?) "
            "ON CONFLICT(name) DO UPDATE SET json=excluded.json, updated=excluded.updated",
            (name, json.dumps(obj, ensure_ascii=False), now))
        con.execute("COMMIT")
    finally:
        con.close()
    if name == "assets":
        _reindex_employees(obj)
    make_backup()


# ─────────────────────────────────────────────────────────────────────────────
#  Отчёты (модуль mod_reports) — словарь {settings, weeks}
# ─────────────────────────────────────────────────────────────────────────────
def get_report_raw() -> Optional[dict]:
    return _get_blob("report")


def put_report_raw(data: dict) -> None:
    _put_blob("report", data)


# ─────────────────────────────────────────────────────────────────────────────
#  Учёт техники (модуль mod_assets) — словарь {units, employees}
# ─────────────────────────────────────────────────────────────────────────────
def get_assets_raw() -> Optional[dict]:
    return _get_blob("assets")


def put_assets_raw(store: dict) -> None:
    _put_blob("assets", store)
    _reindex_employees(store)


def get_config() -> Optional[dict]:
    return _get_blob("assets_config")


def put_config(cfg: dict) -> None:
    _put_blob("assets_config", cfg)


# ─────────────────────────────────────────────────────────────────────────────
#  Индекс сотрудников (для выпадающих списков в заявках)
# ─────────────────────────────────────────────────────────────────────────────
def _fio(emp: dict) -> str:
    parts = [emp.get("last_name", ""), emp.get("first_name", ""),
             emp.get("middle_name", "")]
    return " ".join(p for p in parts if p).strip()


def _unit_path(units_by_id: dict, uid: str) -> str:
    names, seen = [], set()
    while uid and uid in units_by_id and uid not in seen:
        seen.add(uid)
        u = units_by_id[uid]
        names.append(u.get("name", ""))
        uid = u.get("parent_id")
    return " / ".join(reversed(names))


def _reindex_employees(store: dict) -> None:
    units_by_id = {u["id"]: u for u in store.get("units", [])}
    rows = []
    for e in store.get("employees", []):
        rows.append((e.get("id"), _fio(e), e.get("position", ""),
                     e.get("unit_id", ""),
                     _unit_path(units_by_id, e.get("unit_id"))))
    with _connect() as con:
        con.execute("DELETE FROM employees_index")
        con.executemany(
            "INSERT INTO employees_index(id, fio, position, unit_id, unit_path) "
            "VALUES(?,?,?,?,?)", rows)


def employees_min() -> list[dict]:
    """[{id, fio, position, unit_id, unit_path}] — по ФИО, для списков заявок."""
    with _connect() as con:
        rows = con.execute(
            "SELECT id, fio, position, unit_id, unit_path FROM employees_index "
            "WHERE fio <> '' ORDER BY fio COLLATE NOCASE").fetchall()
    return [dict(r) for r in rows]


def employee_by_id(emp_id: str) -> Optional[dict]:
    if not emp_id:
        return None
    with _connect() as con:
        r = con.execute("SELECT id, fio, position, unit_id, unit_path "
                        "FROM employees_index WHERE id=?", (emp_id,)).fetchone()
    return dict(r) if r else None


# ─────────────────────────────────────────────────────────────────────────────
#  Интеграция учёта техники → отчёты и заявки
# ─────────────────────────────────────────────────────────────────────────────
def short_fio(emp: Optional[dict]) -> str:
    """«А. Иванова» — инициал имени + фамилия (как в бланке)."""
    if not emp:
        return ""
    last = (emp.get("last_name") or "").strip()
    first = (emp.get("first_name") or "").strip()
    return (first[:1] + ". " + last).strip(". ").strip() if first else last


def _device_labels(emp: dict) -> list[str]:
    """Короткие подписи техники сотрудника — для меню позиций и подсказок."""
    out = []
    for pc in emp.get("pcs", []) or []:
        out.append(("ПК " + (pc.get("hostname") or pc.get("inv") or "")).strip())
    for m in emp.get("monitors", []) or []:
        out.append(("Монитор " + (m.get("model") or "")).strip())
    for ph in emp.get("phones", []) or []:
        out.append(("Телефон " + (ph.get("model") or ph.get("number") or "")).strip())
    for pr in emp.get("printers", []) or []:
        out.append(("Принтер " + (pr.get("model") or pr.get("inv") or "")).strip())
    return [x for x in out if x and x not in ("ПК", "Монитор", "Телефон", "Принтер")]


def employee_devices(emp_id: str) -> list[str]:
    if not emp_id:
        return []
    store = get_assets_raw() or {}
    emp = next((e for e in store.get("employees", []) if e.get("id") == emp_id), None)
    return _device_labels(emp) if emp else []


def assets_suggest_names() -> list[str]:
    """Сотрудники (ФИО) + объекты (техника) из учёта — для автоподсказок отчётов."""
    store = get_assets_raw() or {}
    seen, out = set(), []
    for e in store.get("employees", []):
        f = _fio(e)
        if f and f not in seen:
            seen.add(f)
            out.append(f)
    for e in store.get("employees", []):
        for lbl in _device_labels(e):
            if lbl not in seen:
                seen.add(lbl)
                out.append(lbl)
    return out


def departments() -> list[dict]:
    """Отделы из оргструктуры (кроме корня) с начальником и род. падежом.
    [{id, name, path, head_id, head_short, genitive}]."""
    store = get_assets_raw() or {"units": [], "employees": []}
    units = store.get("units", [])
    by_id = {u["id"]: u for u in units}
    heads = {}
    for e in store.get("employees", []):
        if e.get("is_head") and e.get("unit_id"):
            heads[e["unit_id"]] = e
    gen = _get_blob("dept_genitive") or {}
    out = []
    for u in units:
        if u.get("parent_id") is None:      # корень «Организация» пропускаем
            continue
        h = heads.get(u["id"])
        out.append({
            "id": u["id"],
            "name": u.get("name", ""),
            "path": _unit_path(by_id, u["id"]),
            "head_id": h.get("id") if h else None,
            "head_short": short_fio(h) if h else "",
            "genitive": gen.get(u["id"], ""),
        })
    out.sort(key=lambda d: d["path"].lower())
    return out


def unit_head_short(unit_id: str) -> str:
    store = get_assets_raw() or {}
    for e in store.get("employees", []):
        if e.get("is_head") and e.get("unit_id") == unit_id:
            return short_fio(e)
    return ""


def get_dept_genitive(unit_id: str) -> str:
    return (_get_blob("dept_genitive") or {}).get(unit_id, "")


def set_dept_genitive(unit_id: str, text: str) -> None:
    g = _get_blob("dept_genitive") or {}
    g[unit_id] = text
    _put_blob("dept_genitive", g)


def get_purchase_defaults() -> dict:
    """Адресат бланка заявки: титул и имя директора (дат. падеж)."""
    d = _get_blob("purchase_defaults") or {}
    return {
        "director_title": d.get("director_title", "Директор"),
        "director": d.get("director", ""),
    }


def set_purchase_defaults(director_title: str, director: str) -> None:
    _put_blob("purchase_defaults", {
        "director_title": (director_title or "").strip() or "И.о. директора",
        "director": (director or "").strip(),
    })


def set_unit_head(unit_id, emp_id=None, last="", first="", middle="") -> str:
    """Назначает начальника подразделения прямо в блобе учёта (запасной путь,
    когда вкладка учёта не запущена). Возвращает короткое ФИО.
    В приложении вместо этого вызывается колбэк, идущий через вкладку учёта,
    чтобы её память тоже обновилась."""
    import uuid as _uuid
    store = get_assets_raw() or {"units": [], "employees": []}
    emps = store.setdefault("employees", [])
    # снять флаг с прежнего начальника этого отдела
    for e in emps:
        if e.get("unit_id") == unit_id and e.get("is_head"):
            e["is_head"] = False
    target = None
    if emp_id:
        target = next((e for e in emps if e.get("id") == emp_id), None)
    if target is None:
        target = {
            "id": _uuid.uuid4().hex,
            "last_name": last, "first_name": first, "middle_name": middle,
            "position": "Начальник отдела", "floor": "", "office": "",
            "building": "", "unit_id": unit_id, "is_head": True, "order": 0,
            "pcs": [], "monitors": [], "phones": [], "printers": [],
            "mouse": {"condition": "рабочее"}, "keyboard": {"condition": "рабочее"},
            "notes": "", "updated": "",
        }
        emps.append(target)
    else:
        target["unit_id"] = unit_id
        target["is_head"] = True
        if last:
            target["last_name"] = last
        if first:
            target["first_name"] = first
        if middle:
            target["middle_name"] = middle
    put_assets_raw(store)
    return short_fio(target)


# ─────────────────────────────────────────────────────────────────────────────
#  Заявки на закуп (нормализованно)
# ─────────────────────────────────────────────────────────────────────────────
_PR_FIELDS = ("number", "created_at", "department", "employee_id", "justification",
              "status", "notes", "director", "accountant", "head_of_dept",
              "sysadmin", "approver", "approved_date")


def pr_list() -> list[dict]:
    with _connect() as con:
        rows = con.execute(
            "SELECT r.id, r.number, r.created_at, r.department, r.status, "
            "       COALESCE(i.cnt,0) AS items_count "
            "FROM purchase_requests r "
            "LEFT JOIN (SELECT request_id, COUNT(*) cnt FROM purchase_items "
            "           GROUP BY request_id) i ON i.request_id = r.id "
            "ORDER BY r.id DESC").fetchall()
    return [dict(r) for r in rows]


def pr_get(req_id: int) -> Optional[dict]:
    with _connect() as con:
        r = con.execute("SELECT * FROM purchase_requests WHERE id=?", (req_id,)).fetchone()
        if not r:
            return None
        items = con.execute(
            "SELECT name, qty, unit, ord FROM purchase_items "
            "WHERE request_id=? ORDER BY ord, id", (req_id,)).fetchall()
    rec = dict(r)
    rec["items"] = [dict(it) for it in items]
    return rec


def pr_save(rec: dict) -> int:
    """Создаёт/обновляет заявку c позициями. Возвращает id."""
    fields = {k: rec.get(k) for k in _PR_FIELDS}
    items = rec.get("items") or []
    req_id = rec.get("id")
    with _connect() as con:
        if req_id:
            sets = ", ".join(f"{k}=?" for k in _PR_FIELDS)
            con.execute(f"UPDATE purchase_requests SET {sets} WHERE id=?",
                        (*[fields[k] for k in _PR_FIELDS], req_id))
            con.execute("DELETE FROM purchase_items WHERE request_id=?", (req_id,))
        else:
            cols = ", ".join(_PR_FIELDS)
            ph = ", ".join("?" for _ in _PR_FIELDS)
            cur = con.execute(f"INSERT INTO purchase_requests({cols}) VALUES({ph})",
                              tuple(fields[k] for k in _PR_FIELDS))
            req_id = cur.lastrowid
        for i, it in enumerate(items):
            con.execute(
                "INSERT INTO purchase_items(request_id, name, qty, unit, ord) "
                "VALUES(?,?,?,?,?)",
                (req_id, it.get("name", ""), _num(it.get("qty"), 1),
                 it.get("unit", "шт."), i))
    make_backup()
    return req_id


def pr_delete(req_id: int) -> None:
    with _connect() as con:
        con.execute("DELETE FROM purchase_requests WHERE id=?", (req_id,))
    make_backup()


def next_pr_number() -> str:
    """Автономер вида 2026-001 (год + порядковый в пределах года)."""
    year = datetime.date.today().year
    with _connect() as con:
        row = con.execute(
            "SELECT COUNT(*) c FROM purchase_requests WHERE created_at LIKE ?",
            (f"{year}%",)).fetchone()
    return f"{year}-{(row['c'] + 1):03d}"


# ─────────────────────────────────────────────────────────────────────────────
#  Выдача картриджей: кто, когда, какой и сколько забрал
# ─────────────────────────────────────────────────────────────────────────────
#  employee_id — id сотрудника из учёта техники; employee — ФИО на день выдачи:
#  оно остаётся в отчётах, даже если сотрудника потом удалят из учёта.
_CART_FIELDS = ("issued_at", "employee_id", "employee", "model", "qty", "note")


def cart_list(date_from: str = "", date_to: str = "") -> list[dict]:
    """Выдачи за период (даты ГГГГ-ММ-ДД включительно), новые сверху."""
    cond, args = [], []
    if date_from:
        cond.append("issued_at >= ?")
        args.append(date_from)
    if date_to:
        cond.append("issued_at <= ?")
        args.append(date_to)
    where = (" WHERE " + " AND ".join(cond)) if cond else ""
    with _connect() as con:
        rows = con.execute(
            "SELECT id, issued_at, employee_id, employee, model, qty, note "
            f"FROM cartridge_issues{where} ORDER BY issued_at DESC, id DESC",
            args).fetchall()
    return [dict(r) for r in rows]


def cart_get(issue_id: int) -> Optional[dict]:
    with _connect() as con:
        r = con.execute("SELECT * FROM cartridge_issues WHERE id=?",
                        (issue_id,)).fetchone()
    return dict(r) if r else None


def cart_save(rec: dict) -> int:
    """Создаёт/обновляет запись о выдаче. Возвращает id."""
    vals = [rec.get(k) for k in _CART_FIELDS]
    issue_id = rec.get("id")
    with _connect() as con:
        if issue_id:
            sets = ", ".join(f"{k}=?" for k in _CART_FIELDS)
            con.execute(f"UPDATE cartridge_issues SET {sets} WHERE id=?",
                        (*vals, issue_id))
        else:
            cols = ", ".join(_CART_FIELDS)
            ph = ", ".join("?" for _ in _CART_FIELDS)
            cur = con.execute(f"INSERT INTO cartridge_issues({cols}) VALUES({ph})",
                              vals)
            issue_id = cur.lastrowid
    make_backup()
    return issue_id


def cart_delete(issue_id: int) -> None:
    with _connect() as con:
        con.execute("DELETE FROM cartridge_issues WHERE id=?", (issue_id,))
    make_backup()


def cart_models() -> list[str]:
    """Модели картриджей, которые уже выдавались, — частые первыми (подсказки)."""
    with _connect() as con:
        rows = con.execute(
            "SELECT model FROM cartridge_issues WHERE model <> '' "
            "GROUP BY model ORDER BY SUM(qty) DESC, model COLLATE NOCASE").fetchall()
    return [r["model"] for r in rows]


def cart_last_models() -> dict:
    """{id сотрудника: что он брал в последний раз} — подсказка при вводе."""
    with _connect() as con:
        rows = con.execute(
            "SELECT employee_id, model FROM cartridge_issues "
            "WHERE employee_id <> '' ORDER BY issued_at, id").fetchall()
    return {r["employee_id"]: r["model"] for r in rows}


# ─────────────────────────────────────────────────────────────────────────────
#  Бэкапы .db (снимок после каждого сохранения, без дублей, с прореживанием)
# ─────────────────────────────────────────────────────────────────────────────
def backups_dir() -> Path:
    d = data_dir() / "backups"
    d.mkdir(parents=True, exist_ok=True)
    return d


def make_backup(throttle_sec: int = 300, keep: int = 200) -> None:
    try:
        if not DB_PATH.exists():
            return
        bdir = backups_dir()
        cur = DB_PATH.read_bytes()
        files = sorted(bdir.glob("itmanager_*.db"))
        if files:
            latest = files[-1]
            try:
                if latest.read_bytes() == cur:
                    return
            except Exception:
                pass
            if time.time() - latest.stat().st_mtime < throttle_sec:
                shutil.copy2(DB_PATH, latest)
                return
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        dst = bdir / f"itmanager_{stamp}.db"
        i = 1
        while dst.exists():
            dst = bdir / f"itmanager_{stamp}_{i}.db"
            i += 1
        shutil.copy2(DB_PATH, dst)
        for old in sorted(bdir.glob("itmanager_*.db"))[:-keep]:
            try:
                old.unlink()
            except Exception:
                pass
    except Exception:
        pass


def list_backups() -> list[tuple]:
    out = []
    for f in sorted(backups_dir().glob("itmanager_*.db"), reverse=True):
        try:
            out.append((str(f), f.stat().st_mtime, f.stat().st_size))
        except Exception:
            pass
    return out


def restore_backup(path: str) -> bool:
    """Восстановить БД из копии. Перед заменой делает бэкап текущей.
    После вызова приложение нужно перезапустить (данные в памяти вкладок
    не должны перезаписать восстановленную базу)."""
    from pathlib import Path as _P
    src = _P(path)
    if not src.exists():
        return False
    try:
        make_backup(throttle_sec=0)
        shutil.copy2(str(src), str(DB_PATH))
        return True
    except Exception:
        return False


_UI_DEFAULTS = {
    "theme": "AMETHYST",
    "font": "Segoe UI",
    "density": 1.0,
    "export_dir": "",
    "autostart": False,
    "setup_done": False,      # мастер первого запуска пройден
    "tray": True,             # закрытие окна — в трей
    "anim_icon": True,        # анимированная иконка окна и трея
    "coucou": False,          # показывать дела ITtool у Моти (Coucou)
}


_TG_DEFAULTS = {"token": "", "allowed": [], "enabled": False,
                "backup_chat": ""}   # группа для бэкапа из приложения на iPhone


def get_tg_config() -> dict:
    """Настройки телеграм-бота: токен, разрешённые ID, включён ли."""
    d = _get_blob("telegram") or {}
    out = dict(_TG_DEFAULTS)
    out["allowed"] = list(_TG_DEFAULTS["allowed"])
    for k in out:
        if k in d and d[k] is not None:
            out[k] = d[k]
    out["enabled"] = bool(out["enabled"])
    if isinstance(out["allowed"], str):
        out["allowed"] = [x.strip() for x in out["allowed"].replace(",", " ").split()]
    return out


def set_tg_config(**kw) -> None:
    d = _get_blob("telegram") or {}
    for k, v in kw.items():
        if k in _TG_DEFAULTS:
            d[k] = v
    _put_blob("telegram", d)


_ORG_DEFAULTS = {
    "org_name": "",          # полное наименование организации
    "branch": "",            # филиал / подразделение (им. падеж)
    "branch_gen": "",        # то же в родительном падеже — для бланка заявки
    "fio": "",               # ФИО ответственного (подпись в документах)
    "position": "",          # должность ответственного
    "accountant": "",        # главный бухгалтер (для бланка заявки)
}


def get_org_profile() -> dict:
    d = _get_blob("org") or {}
    out = dict(_ORG_DEFAULTS)
    for k in out:
        if isinstance(d.get(k), str):
            out[k] = d[k]
    return out


def set_org_profile(**kw) -> None:
    d = _get_blob("org") or {}
    for k, v in kw.items():
        if k in _ORG_DEFAULTS:
            d[k] = (v or "").strip()
    _put_blob("org", d)


def get_ui_prefs() -> dict:
    d = _get_blob("ui_prefs") or {}
    out = dict(_UI_DEFAULTS)
    for k in out:
        if k in d and d[k] is not None:
            out[k] = d[k]
    try:
        out["density"] = float(out["density"])
    except Exception:
        out["density"] = 1.0
    for k in ("autostart", "setup_done", "tray", "anim_icon", "coucou"):
        out[k] = bool(out[k])
    return out


def set_ui_prefs(**kw) -> None:
    d = _get_blob("ui_prefs") or {}
    for k, v in kw.items():
        if k in _UI_DEFAULTS:
            d[k] = v
    _put_blob("ui_prefs", d)


# ─────────────────────────────────────────────────────────────────────────────
#  Перенос старых JSON при первом запуске
# ─────────────────────────────────────────────────────────────────────────────
def _legacy_candidates(filename: str, old_subdirs: tuple) -> list[Path]:
    paths = [app_dir() / filename]
    for env in ("LOCALAPPDATA", "APPDATA"):
        base = os.environ.get(env)
        if base:
            for sub in old_subdirs:
                paths.append(Path(base) / sub / filename)
    return paths


def _read_json(path: Path):
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        pass
    return None


def _import_legacy_if_empty() -> None:
    if os.environ.get("ITTOOL_NO_LEGACY"):        # тесты: только своя временная база
        return
    # отчёты
    if get_report_raw() is None:
        for p in _legacy_candidates("report_data.json", ("ОтчётСисадмина",)):
            data = _read_json(p)
            if isinstance(data, dict):
                put_report_raw(data)
                break
    # учёт техники
    if get_assets_raw() is None:
        for p in _legacy_candidates("employees_data.json", ("УчётТехники",)):
            data = _read_json(p)
            if data is not None:
                # старый плоский список тоже примем — модуль сам нормализует
                put_assets_raw(data if isinstance(data, dict)
                               else {"units": [], "employees": data})
                break
    # конфиг ИИ учёта техники
    if get_config() is None:
        for p in _legacy_candidates("config.json", ("УчётТехники",)):
            data = _read_json(p)
            if isinstance(data, dict):
                put_config(data)
                break


# ─────────────────────────────────────────────────────────────────────────────
def _num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


init_db()
