# -*- coding: utf-8 -*-
"""Проверки API для iPhone: токен, учёт, отчёт, заявки, картриджи.

Запуск: .venv/bin/python test_api.py — временная папка данных, свой порт на
127.0.0.1; настоящую базу и службу не трогает.
"""
import datetime
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request

TMP = tempfile.mkdtemp(prefix="ittool_api_test_")
os.environ["APPDATA"] = TMP
os.environ["ITTOOL_NO_LEGACY"] = "1"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import api   # noqa: E402
import db    # noqa: E402

assert str(db.DB_PATH).startswith(TMP), db.DB_PATH
SRV = api.make_server("127.0.0.1", 0)
threading.Thread(target=SRV.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{SRV.server_port}"
FAILS = []


def check(name, cond, info=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  ({info})" if info and not cond else ""))
    if not cond:
        FAILS.append(name)


def call(method, path, body=None, tok=None):
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + (SRV.token if tok is None else tok))
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as ex:
        return ex.code, json.loads(ex.read())


check("токен создаётся и не пустой", len(SRV.token) > 20)
check("токен с правами 600", (db.data_dir() / "api_token").stat().st_mode & 0o777 == 0o600)
check("чужой токен — 401", call("GET", "/api/meta", tok="x")[0] == 401)
check("неизвестный адрес — 404", call("GET", "/api/nope")[0] == 404)

code, m = call("GET", "/api/meta")
check("справочники", code == 200 and "pcs" in m["devices"] and m["conditions"][0] == "рабочее")

# учёт
code, r = call("POST", "/api/employees", {})
emp_id = r["id"]
code, e = call("PUT", f"/api/employees/{emp_id}",
               {"last_name": "Әлиев", "first_name": "Қайрат",
                "pcs": [{"inv": "123", "hostname": "pc-1", "condition": "неисправно"}]})
check("карточка сохраняется, казахские буквы целы",
      code == 200 and e["fio"] == "Әлиев Қайрат" and e["pcs"][0]["hostname"] == "pc-1", e)
code, st = call("GET", "/api/assets?q=" + urllib.request.quote("pc-1"))
check("поиск по технике", code == 200 and [x["id"] for x in st["employees"]] == [emp_id], st)
check("подразделения с путями", st["units"] and st["units"][0]["depth"] == 0)
code, r = call("PUT", f"/api/employees/{emp_id}", {"mouse": {"condition": "плохое"}})
check("неверное состояние — 400 с текстом", code == 400 and "не из списка" in r["error"], r)

# отчёт
monday = datetime.date.today() - datetime.timedelta(days=datetime.date.today().weekday())
code, r = call("POST", "/api/report", {"date": monday.isoformat(), "employee": "Әлиев",
                                       "description": "Не печатает"})
uid = r.get("uid")
code, w = call("GET", "/api/report?date=" + monday.isoformat())
check("запись в отчёте", code == 200 and [x["uid"] for x in w["entries"]] == [uid], w)
sat = monday + datetime.timedelta(days=5)
check("выходной — 400", call("POST", "/api/report", {"date": sat.isoformat(),
                                                     "description": "x"})[0] == 400)
call("DELETE", f"/api/report/{uid}")
check("запись удалена", call("GET", "/api/report?date=" + monday.isoformat())[1]["entries"] == [])

# заявки
code, new = call("GET", "/api/purchases/new")
new.update(department="Бухгалтерия", items=[{"name": "Мышь", "qty": "1,5", "unit": "шт."}])
code, r = call("POST", "/api/purchases", new)
rid = r.get("id")
code, got = call("GET", f"/api/purchases/{rid}")
check("заявка сохраняется", code == 200 and got["items"][0]["qty"] == 1.5, got)
check("пустая заявка — 400", call("POST", "/api/purchases", {"items": []})[0] == 400)
call("DELETE", f"/api/purchases/{rid}")
check("заявка удалена", call("GET", "/api/purchases")[1] == [])

# картриджи
today = datetime.date.today().isoformat()
code, r = call("POST", "/api/cartridges", {"date": today, "employee": "Әлиев", "model": "285"})
check("выдача по части имени", code == 200 and "Әлиев Қайрат" in r["text"], r)
code, r = call("POST", "/api/cartridges", {"date": today, "employee": "Кто-то", "model": "285"})
check("неизвестное имя — 409", code == 409 and r.get("unknown_person"), r)
code, r = call("POST", "/api/cartridges", {"date": today, "employee": "Кто-то", "model": "285",
                                           "allow_unknown": True})
check("неизвестное имя после подтверждения", code == 200, r)
code, c = call("GET", f"/api/cartridges?year={datetime.date.today().year}")
check("выдачи за год", code == 200 and len(c["items"]) == 2 and c["models"] == ["285"], c)
call("DELETE", f"/api/cartridges/{c['items'][0]['id']}")
check("выдача удалена", len(call("GET", "/api/cartridges")[1]["items"]) == 1)

# работа без сети: телефон присылает новые карточки и записи со своими id
code, e = call("PUT", "/api/employees/a1b2c3d4e5f6", {"last_name": "Нұрлан", "unit_id": "нет-такого"})
check("карточка с телефона создаётся со своим id", code == 200 and e["id"] == "a1b2c3d4e5f6", e)
code, r = call("POST", "/api/report", {"uid": "phone001", "date": monday.isoformat(), "description": "офлайн"})
check("запись с телефона создаётся со своим uid", code == 200 and r["uid"] == "phone001", r)
code, r = call("POST", "/api/report", {"uid": "phone001", "date": monday.isoformat(), "description": "правка"})
code, s = call("GET", "/api/sync")
check("снимок для телефона", code == 200 and {"meta", "assets", "entries", "cartridges", "backup"} <= set(s), s)
check("правка той же записи, без дубля",
      [x["description"] for x in s["entries"] if x["uid"] == "phone001"] == ["правка"], s.get("entries"))
check("в снимке нет ключей ИИ", "api_key" not in json.dumps(s))
check("в снимке настройки почты для телефона", set(s["mail"]) == {"branch", "responsible", "server", "port",
                                                                  "sender", "password", "recipient"}, s.get("mail"))
check("сотрудники в снимке", any(x["id"] == "a1b2c3d4e5f6" for x in s["assets"]["employees"]))

SRV.shutdown()
print("\nВСЁ ЗЕЛЁНОЕ" if not FAILS else f"\nПРОВАЛЕНО: {len(FAILS)}")
sys.exit(1 if FAILS else 0)
