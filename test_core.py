# -*- coding: utf-8 -*-
"""Проверки ядра ITtool без интерфейса: учёт, отчёт, заявки, картриджи, настройки.

Запуск: .venv/bin/python test_core.py — берёт временную папку данных,
настоящую базу не трогает.
"""
import datetime
import os
import subprocess
import sys
import tempfile

TMP = tempfile.mkdtemp(prefix="ittool_test_")
os.environ["APPDATA"] = TMP
os.environ["ITTOOL_NO_LEGACY"] = "1"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import assets as ma          # noqa: E402
import cartridges as mc      # noqa: E402
import db                    # noqa: E402
import purchase as mp        # noqa: E402
import reports as mr         # noqa: E402
import settings              # noqa: E402

assert str(db.DB_PATH).startswith(TMP), db.DB_PATH
db.set_ui_prefs(export_dir=os.path.join(TMP, "out"))
FAILS = []


def check(name, cond, info=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  ({info})" if info and not cond else ""))
    if not cond:
        FAILS.append(name)


def raises(fn, *a, **k):
    try:
        fn(*a, **k)
    except ValueError as ex:
        return str(ex)
    return None


# ═══════════════════════ учёт ═══════════════════════
st = ma.load_store()
root = ma.unit_root_id(st["units"])
metr = ma.add_unit(root, "Метрология")
it = ma.add_unit(root, "ИТ")
check("пустое имя подразделения — отказ", raises(ma.add_unit, root, "  "))
e1 = ma.add_employee(metr)
ma.save_employee(e1, {"last_name": "Сәрсенбаев", "first_name": "Дәулет", "middle_name": "Нұрбекұлы",
                      "position": "Инженер", "office": "205", "is_head": True,
                      "pcs": [{"inv": "4471", "hostname": "metr-01", "cpu": "i5-4570",
                               "ram": "4Gb", "storage": "HDD 500Gb", "os": "Windows 7",
                               "condition": "требует замены"}],
                      "monitors": [{"model": "Dell P2419H", "condition": "рабочее"}],
                      "mouse": {"condition": "рабочее"}, "keyboard": {"condition": "неисправно"}})
e2 = ma.add_employee(metr)
ma.save_employee(e2, {"last_name": "Иванова", "first_name": "Анна", "is_head": True})
st = ma.load_store()
emp1 = ma.find_employee(st, e1)
check("казахские буквы сохранились", ma.fio(emp1) == "Сәрсенбаев Дәулет Нұрбекұлы", ma.fio(emp1))
check("руководитель в отделе один", not emp1["is_head"] and ma.find_employee(st, e2)["is_head"])
check("худшее состояние — неисправно", ma.worst_condition(emp1) == "неисправно")
check("поиск по инв. номеру", [e["id"] for e, _h in ma.search(st, "4471")] == [e1])
check("поиск по слову «руководитель»", [e["id"] for e, _h in ma.search(st, "руководитель")] == [e2])
check("неверное состояние — отказ",
      raises(ma.save_employee, e1, {"mouse": {"condition": "сломано"}}))
e3 = ma.add_employee(metr)
ma.save_employee(e3, {"last_name": "Петров"})
st = ma.load_store()
order = [e["id"] for e in ma.employees_in_tree_order(st) if e.get("unit_id") == metr]
check("руководитель первым", order[0] == e2, order)
check("порядок меняется", ma.move("emp", e3, -1))
st = ma.load_store()
order2 = [e["id"] for e in ma.employees_in_tree_order(st) if e.get("unit_id") == metr]
check("после сдвига Петров выше", order2.index(e3) < order2.index(e1), order2)
check("руководителя не двигают", not ma.move("emp", e2, 1))
ma.rename_unit(it, "Отдел ИТ")
check("переименование", ma.unit_by_id(ma.load_store()["units"], it)["name"] == "Отдел ИТ")
e4 = ma.add_employee(it)
ma.save_employee(e4, {"last_name": "Иванов"})
check("корень не удаляется", raises(ma.delete_unit, root))
ma.delete_unit(it)
st = ma.load_store()
check("сотрудник удалённого отдела — уровнем выше", ma.find_employee(st, e4)["unit_id"] == root)
check("удаление сотрудника", ma.delete_employee(e4) and not ma.find_employee(ma.load_store(), e4))
st = ma.load_store()
check("индекс сотрудников для заявок", any(r["id"] == e1 for r in db.employees_min()))
check("статистика", "Всего сотрудников: 3" in ma.stats_text(st))
x = ma.export_excel(st, settings.export_path("Учёт.xlsx"))
check("Excel учёта", os.path.getsize(x) > 3000)
n, with_mac = ma.export_uchetki(st, settings.export_path("Учетки.docx"))
check("учётки в Word", n == 3 and with_mac == 0, (n, with_mac))
csv = os.path.join(TMP, "scan.csv")
with open(csv, "w", encoding="utf-8") as fh:
    fh.write("IP;MAC;Имя\n10.0.0.5;aa-bb-cc-dd-ee-ff;METR-01.corp.local\n")
filled, total = ma.import_scan_csv(csv)
st = ma.load_store()
pc = ma.find_employee(st, e1)["pcs"][0]
check("импорт MAC/IP по имени ПК", (filled, total) == (2, 1) and pc["mac"] == "AA:BB:CC:DD:EE:FF"
      and pc["ip"] == "10.0.0.5", (filled, pc))
rows, summ = ma.audit(st)
check("анализ ПК: Windows 7 и 4 ГБ — под замену", summ["replace"] == 1, summ)
ma.audit_memo(st, settings.export_path("Записка.docx"))
check("служебная записка", os.path.exists(os.path.join(TMP, "out", "Записка.docx")))
ma.apply_ai_fill(e3, {"position": "Лаборант", "pcs": [{"inv": "77", "condition": "чушь"}]})
pc3 = ma.find_employee(ma.load_store(), e3)["pcs"][0]
check("ответ ИИ: чужое состояние → рабочее", pc3["condition"] == "рабочее" and pc3["inv"] == "77")

# ═══════════════════════ отчёт ═══════════════════════
mon = mr.monday_of(datetime.date(2026, 9, 21))
check("пустая запись — отказ", raises(mr.save_entry, mon.isoformat()))
check("суббота — отказ", raises(mr.save_entry, "2026-09-26", "x"))
u1 = mr.save_entry("2026-09-22", "Иванова Анна", "Не печатал принтер", "Переустановил драйвер",
                   "Печать работает")
u2 = mr.save_entry("2026-09-21", "Петров", "Нет сети")
data = mr.load_data()
check("записи недели по дате", [e["uid"] for e in mr.week_entries(data, mon)] == [u2, u1])
mr.save_entry("2026-09-29", "Петров", "Нет сети", uid=u2)
data = mr.load_data()
check("перенос записи на другую неделю",
      [e["uid"] for e in mr.week_entries(data, mon)] == [u1]
      and mr.find_entry(data, u2)[0] == "2026-09-28")
check("подсказки: сотрудники из учёта", "Сәрсенбаев Дәулет Нұрбекұлы" in mr.candidates(data))
p = mr.export_week(data, mon, settings.export_path(mr.week_file_name(mon)))
check("Word за неделю", os.path.getsize(p) > 5000)
p = mr.export_month(data, 9, 2026, settings.export_path("Отчёт_Сентябрь_2026.docx"))
check("Word за месяц", os.path.exists(p))
check("месяц без записей — отказ", raises(mr.export_month, data, 1, 2026, "/dev/null"))
check("ИИ без ключа — понятный отказ", raises(mr.polish_week, mon))
check("почта: не заполнено — отказ", raises(mr.send_week, mon, {"server": ""}))
check("почта: русский пароль — отказ",
      "раскладк" in (raises(mr.send_week, mon, {"server": "s", "port": "465", "sender": "a@b.c",
                                               "recipient": "d@e.f", "password": "пароль"}) or ""))
info = mr.bot_week_email(mon.isoformat())
check("бот: письмо без настроек почты — список, чего нет", not info["ok"] and "сервер" in info["error"])
check("удаление записи", mr.delete_entry(u1) and not mr.find_entry(mr.load_data(), u1)[1])

# бот и интерфейс — разные процессы: правки не затирают друг друга
BOT = ("import reports as r\nb = r.BotBridge()\n"
       "for i in range(15):\n    b.add_entry('2026-10-05', 'бот', description=f'бот {i}')\n")
procs = [subprocess.Popen([sys.executable, "-c", BOT], cwd=os.path.dirname(os.path.abspath(__file__)))
         for _ in range(2)]
for i in range(15):
    mr.save_entry("2026-10-06", "окно", f"окно {i}")
for pr in procs:
    pr.wait()
week = mr.week_entries(mr.load_data(), datetime.date(2026, 10, 5))
check("параллельная запись: ничего не потеряно", len(week) == 45, len(week))

# ═══════════════════════ заявки ═══════════════════════
d = mp.new_request()
check("номер заявки по году", d["number"].startswith(str(datetime.date.today().year)))
check("пустая заявка — отказ", raises(mp.save, d))
d.update(department="метрологии", unit_id=metr, employee_id=e1, director="Иванову И.И.",
         items=[{"name": "Картридж 285A", "qty": "2,5", "unit": ""}, {"name": " "}])
rid = mp.save(d)
rec = mp.get_request(rid)
check("позиции: «2,5» и шт. по умолчанию, пустые отброшены",
      rec["items"] == [{"name": "Картридж 285A", "qty": 2.5, "unit": "шт.", "ord": 0}], rec["items"])
check("род. падеж запомнен за отделом", db.get_dept_genitive(metr) == "метрологии")
check("адресат запомнен", db.get_purchase_defaults()["director"] == "Иванову И.И.")
d["id"] = rid
mp.export_docx(d, settings.export_path(mp.file_name(d["number"])))
check("заявка в Word по шаблону", os.path.exists(os.path.join(TMP, "out", mp.file_name(d["number"]))))

# ═══════════════════════ картриджи ═══════════════════════
people = mc.people(ma.load_store())
today = datetime.date.today()
rid, text = mc.save({"employee": "сәрс", "model": "285", "qty": "2", "date": today.isoformat()},
                    people)
check("выдача по началу имени", "Сәрсенбаев" in text, text)
try:
    mc.save({"employee": "Посторонний", "model": "285", "date": today.isoformat()}, people)
    unknown = False
except mc.UnknownPerson:
    unknown = True
check("незнакомое имя — спрашиваем", unknown)
mc.save({"employee": "Посторонний", "model": "285", "date": today.isoformat()}, people,
        allow_unknown=True)
check("будущая дата — отказ", raises(mc.save, {"employee": "Петров", "model": "1",
                                              "date": (today + datetime.timedelta(days=2)).isoformat()},
                                     people))
items, label = mc.items(today.year, 0, people)
summ = mc.summary(items)
check("сводка за год", summ["total"] == 3 and summ["by_model"][0]["model"] == "285", summ["total"])
items_f, _l = mc.items(today.year, 0, people, "посторон")
check("фильтр", len(items_f) == 1)
mc.export_xlsx(settings.export_path("Картриджи.xlsx"), items, summ)
check("Excel картриджей", os.path.exists(os.path.join(TMP, "out", "Картриджи.xlsx")))

# ═══════════════════════ настройки ═══════════════════════
s = settings.get_all()
s["ai"] = {"base_url": "https://x/v1", "model": "m", "api_key": "k"}
s["report"] = {"branch": "Северный", "responsible": "Иванов И."}
s["tg"]["allowed"] = "1, 2"
settings.save_all(s)
check("ИИ — в обе копии", ma.load_config()["ai_key"] == "k"
      and mr.load_data()["settings"]["ai"]["api_key"] == "k")
check("разрешённые chat ID списком", db.get_tg_config()["allowed"] == ["1", "2"])
check("шапка отчёта", mr.load_data()["settings"]["branch"] == "Северный")
check("свободное имя выгрузки", settings.export_path("Картриджи.xlsx").endswith("Картриджи (2).xlsx"))
settings.backup_now()
check("резервные копии есть", len(settings.backups()) >= 1)

print()
print("ВСЕ ПРОВЕРКИ ПРОШЛИ" if not FAILS else f"НЕ ПРОШЛО: {len(FAILS)} — " + ", ".join(FAILS))
sys.exit(1 if FAILS else 0)
