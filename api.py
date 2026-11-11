# -*- coding: utf-8 -*-
"""ITtool: HTTP API для приложения на iPhone — JSON, вход по токену.

Служба ittool-api (systemd --user, deploy/ittool-api.service). Слушает адрес
Tailscale: трафик шифрует WireGuard, а в офисную сеть API не выходит.
Токен — файл api_token в папке данных, создаётся при первом запуске;
показать: `ittool api token`.

Всё делают те же функции логики, что и интерфейс с ботом, — каждая правка
одной транзакцией, поэтому все три процесса могут работать одновременно.
"""
from __future__ import annotations

import datetime
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import assets as ma
import cartridges as mc
import db
import purchase as mp
import reports as mr

HOST = os.environ.get("ITTOOL_API_HOST", "")   # пусто — свой адрес в Tailscale
PORT = int(os.environ.get("ITTOOL_API_PORT", "8780"))
MAX_BODY = 1_000_000


def tailscale_ip() -> str:
    """Свой адрес в Tailscale; без Tailscale — 127.0.0.1: в офисную сеть API не выходит."""
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5).stdout.split()
    except (OSError, subprocess.SubprocessError):
        out = []
    return out[0] if out else "127.0.0.1"


def token() -> str:
    path = db.data_dir() / "api_token"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(secrets.token_urlsafe(24))
    except FileExistsError:
        pass
    return path.read_text().strip()


def _day(text):
    return datetime.date.fromisoformat(text) if text else datetime.date.today()


def _int(text, default=0):
    try:
        return int(text)
    except (TypeError, ValueError):
        raise ValueError(f"Ожидалось число, а пришло «{text}».") from None


# ── справочники ─────────────────────────────────────────────────────────────
def meta(q, b):
    return {
        "conditions": ma.CONDITIONS,
        "device_order": ma.DEVICE_GROUPS,
        "devices": {g: {"title": sp["title"], "singular": sp["singular"],
                        "fields": [{"key": k, "label": label, "kind": kind, "values": vals or []}
                                   for k, label, kind, vals in sp["fields"]]}
                    for g, sp in ma.DEVICE_SPECS.items()},
        "purchase_statuses": mp.STATUSES,
        "purchase_units": mp.UNITS,
        "director_titles": mp.DIRECTOR_TITLES,
    }


# ── учёт ────────────────────────────────────────────────────────────────────
def assets_get(q, b):
    st = ma.load_store()
    if q.get("q"):
        found = [dict(e, fio=ma.fio(e), hint=hint) for e, hint in ma.search(st, q["q"])]
    else:
        found = [dict(e, fio=ma.fio(e), hint="") for e in ma.employees_in_tree_order(st)]
    units = [{"id": uid, "name": name, "depth": depth, "path": ma.unit_path(st["units"], uid)}
             for uid, name, depth in ma.unit_flat(st["units"])]
    return {"units": units, "employees": found}


def employee_get(emp_id, q, b):
    emp = ma.find_employee(ma.load_store(), emp_id)
    if not emp:
        raise ValueError("Сотрудник не найден — возможно, его уже удалили.")
    return dict(emp, fio=ma.fio(emp))


def employee_add(q, b):
    return {"id": ma.add_employee(b.get("unit_id"))}


def employee_save(emp_id, q, b):
    ma.save_employee(emp_id, b, create=True)      # новая карточка с телефона — со своим id
    return employee_get(emp_id, q, b)


def employee_delete(emp_id, q, b):
    return {"deleted": ma.delete_employee(emp_id)}


# ── недельный отчёт ─────────────────────────────────────────────────────────
def report_get(q, b):
    day = _day(q.get("date"))
    monday = mr.monday_of(day)
    return {"monday": monday.isoformat(), "range": mr.week_range_str(monday),
            "entries": mr.week_entries(mr.load_data(), day)}


def report_save(q, b):
    uid = mr.save_entry(str(b.get("date") or ""), b.get("employee"), b.get("description"),
                        b.get("actions"), b.get("result"), uid=b.get("uid") or None,
                        create_missing=True)      # запись с телефона — со своим uid
    return {"uid": uid}


def report_delete(uid, q, b):
    return {"deleted": mr.delete_entry(uid)}


# ── заявки на закуп ─────────────────────────────────────────────────────────
def purchase_list(q, b):
    return db.pr_list()


def purchase_new(q, b):
    return mp.new_request()


def purchase_get(rid, q, b):
    return mp.get_request(rid)


def purchase_save(q, b):
    return {"id": mp.save(b)}


def purchase_delete(rid, q, b):
    db.pr_delete(int(rid))
    return {"deleted": True}


# ── картриджи ───────────────────────────────────────────────────────────────
def _people():
    return mc.people(ma.load_store())


def cart_get(q, b):
    today = datetime.date.today()
    year, month = _int(q.get("year") or today.year), _int(q.get("month") or 0)
    plist = _people()
    items, label = mc.items(year, month, plist, q.get("q", ""))
    return {"label": label, "items": items, "people": plist, "models": db.cart_models()}


def cart_save(q, b):
    rid, text = mc.save(b, _people(), allow_unknown=bool(b.get("allow_unknown")))
    return {"id": rid, "text": text}


def cart_delete(rid, q, b):
    db.cart_delete(int(rid))
    return {"deleted": True}


# ── синхронизация с телефоном ───────────────────────────────────────────────
def sync(q, b):
    """Всё, что телефону нужно для работы без сети. Правки телефон присылает
    обычными запросами выше, а потом забирает этот снимок целиком."""
    data = mr.load_data()
    tg = db.get_tg_config()
    st, em = data["settings"], data["settings"].get("email") or {}
    return {
        "meta": meta(q, b),
        "assets": ma.load_store(),
        "entries": [e for week in data["weeks"].values() for e in week],
        "cartridges": db.cart_list(),
        # токен бота нужен телефону, чтобы самому слать бэкап в группу
        "backup": {"token": tg["token"], "chat_id": str(tg.get("backup_chat") or "")},
        # почта для отчёта: телефон шлёт письмо сам и подставляет это в пустые поля (ключи ИИ не отдаём)
        "mail": {"branch": st.get("branch", ""), "responsible": st.get("responsible", ""),
                 "server": str(em.get("server", "")), "port": str(em.get("port", "")),
                 "sender": str(em.get("sender", "")), "password": str(em.get("password", "")),
                 "recipient": str(em.get("recipient", ""))},
    }


ID = r"([0-9A-Za-z]+)"
ROUTES = [
    ("GET", r"/api/sync", sync),
    ("GET", r"/api/meta", meta),
    ("GET", r"/api/assets", assets_get),
    ("POST", r"/api/employees", employee_add),
    ("GET", rf"/api/employees/{ID}", employee_get),
    ("PUT", rf"/api/employees/{ID}", employee_save),
    ("DELETE", rf"/api/employees/{ID}", employee_delete),
    ("GET", r"/api/report", report_get),
    ("POST", r"/api/report", report_save),
    ("DELETE", rf"/api/report/{ID}", report_delete),
    ("GET", r"/api/purchases", purchase_list),
    ("GET", r"/api/purchases/new", purchase_new),
    ("POST", r"/api/purchases", purchase_save),
    ("GET", r"/api/purchases/(\d+)", purchase_get),
    ("DELETE", r"/api/purchases/(\d+)", purchase_delete),
    ("GET", r"/api/cartridges", cart_get),
    ("POST", r"/api/cartridges", cart_save),
    ("DELETE", r"/api/cartridges/(\d+)", cart_delete),
]


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "ITtool"

    def log_message(self, fmt, *args):
        log(fmt % args)

    def _send(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _handle(self):
        given = self.headers.get("Authorization", "").encode("utf-8", "replace")
        if not hmac.compare_digest(given, ("Bearer " + self.server.token).encode()):
            return self._send(401, {"error": "Неверный токен — проверьте настройки приложения."})
        url = urlparse(self.path)
        for method, pattern, fn in ROUTES:
            m = re.fullmatch(pattern, url.path)
            if m and method == self.command:
                break
        else:
            return self._send(404, {"error": "Нет такого адреса."})
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
            return self._send(413, {"error": "Слишком большой запрос."})
        try:
            body = json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
            if not isinstance(body, dict):
                raise ValueError("Ожидался JSON-объект.")
            q = {k: v[-1] for k, v in parse_qs(url.query).items()}
            self._send(200, fn(*m.groups(), q, body))
        except mc.UnknownPerson as ex:          # приложение переспросит и пришлёт allow_unknown
            self._send(409, {"error": str(ex), "unknown_person": True})
        except ValueError as ex:
            self._send(400, {"error": str(ex)})
        except Exception as ex:                 # noqa: BLE001 — служба не должна падать
            log(f"ошибка {self.command} {url.path}: {ex!r}")
            self._send(500, {"error": "Ошибка на сервере, подробности — в журнале службы."})

    do_GET = do_POST = do_PUT = do_DELETE = _handle


def make_server(host=None, port=PORT):
    db.init_db()
    srv = ThreadingHTTPServer((host or HOST or tailscale_ip(), port), Handler)
    srv.token = token()
    return srv


def main():
    if sys.argv[1:] == ["token"]:
        print(token())
        return
    srv = make_server()
    log(f"API слушает http://{srv.server_address[0]}:{srv.server_address[1]}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
