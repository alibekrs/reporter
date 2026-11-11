# -*- coding: utf-8 -*-
"""Проверки интерфейса ITtool в терминале: нажатия клавиш и формы на настоящем
приложении (Textual pilot, без экрана). Временная папка данных.

Запуск: .venv/bin/python test_tui.py
"""
import asyncio
import datetime
import os
import sys
import tempfile

TMP = tempfile.mkdtemp(prefix="ittool_tui_")
os.environ["APPDATA"] = TMP
os.environ["ITTOOL_NO_LEGACY"] = "1"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import assets as ma          # noqa: E402
import db                    # noqa: E402
import reports as mr         # noqa: E402
import ittool                # noqa: E402
from textual.widgets import Input, TabbedContent, TextArea, Tree  # noqa: E402

assert str(db.DB_PATH).startswith(TMP)
db.set_ui_prefs(export_dir=os.path.join(TMP, "out"), setup_done=True)
db.set_org_profile(fio="Иванов Иван")
root = ma.unit_root_id(ma.load_store()["units"])
metr = ma.add_unit(root, "Метрология")
emp = ma.add_employee(metr)
ma.save_employee(emp, {"last_name": "Сәрсенбаев", "first_name": "Дәулет", "position": "Инженер"})
FAILS = []


def check(name, cond, info=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  ({info})" if info and not cond else ""))
    if not cond:
        FAILS.append(name)


async def type_into(pilot, app, selector, text):
    w = app.screen.query_one(selector)
    if isinstance(w, TextArea):
        w.text = text
    else:
        w.value = text
    await pilot.pause()


async def main():
    app = ittool.ITtool()
    async with app.run_test(size=(140, 45)) as pilot:
        await pilot.pause(0.3)
        tabs = app.query_one(TabbedContent)
        check("старт — учёт, фокус в дереве", tabs.active == "assets"
              and isinstance(app.focused, Tree), app.focused)

        # ---- учёт: поиск и новый сотрудник ----
        await pilot.press("slash", *"сәрс")
        await pilot.pause(0.3)
        tree = app.query_one(Tree)
        check("поиск по казахскому имени", len(tree.root.children) == 1)
        await pilot.press("escape")
        app.query_one("#search", Input).value = ""
        await pilot.pause(0.2)
        await pilot.press("ф")                              # «a» в русской раскладке
        await pilot.pause(0.5)
        check("новый сотрудник — открылась карточка", type(app.screen).__name__ == "EmployeeEdit",
              type(app.screen).__name__)
        await type_into(pilot, app, "#last_name", "Иванова")
        await type_into(pilot, app, "#office", "205")
        await pilot.press("ctrl+s")
        await pilot.pause(0.5)
        st = ma.load_store()
        check("карточка сохранена", any(e["last_name"] == "Иванова" and e["office"] == "205"
                                        for e in st["employees"]))

        # ---- отчёт: запись ----
        await pilot.press("f2")
        await pilot.pause(0.4)
        check("F2 — отчёт", tabs.active == "reports", tabs.active)
        await pilot.press("a")
        await pilot.pause(0.4)
        check("новая запись — форма", type(app.screen).__name__ == "EntryEdit")
        await type_into(pilot, app, "#employee", "Иванова")
        await type_into(pilot, app, "#description", "Не печатал принтер")
        await pilot.press("ctrl+s")
        await pilot.pause(0.4)
        week = mr.week_entries(mr.load_data(), datetime.date.today())
        today = datetime.date.today()
        if today.weekday() <= 4:
            check("запись в текущей неделе", any(e["description"] == "Не печатал принтер"
                                                  for e in week))
        await pilot.press("comma")
        await pilot.pause(0.2)
        check("прошлая неделя", app.query_one("#tab_reports").monday
              == mr.monday_of(today) - datetime.timedelta(days=7))
        await pilot.press("t")
        await pilot.press("a")
        await pilot.pause(0.3)
        await pilot.press("ctrl+s")                         # пустая — отказ, форма остаётся
        await pilot.pause(0.3)
        check("пустая запись — форма не закрылась", type(app.screen).__name__ == "EntryEdit")
        await pilot.press("escape")

        # ---- картриджи: незнакомое имя ----
        await pilot.press("f4")
        await pilot.pause(0.4)
        await pilot.press("a")
        await pilot.pause(0.3)
        await type_into(pilot, app, "#employee", "Посторонний")
        await type_into(pilot, app, "#model", "285")
        await pilot.press("ctrl+s")
        await pilot.pause(0.4)
        check("незнакомое имя — вопрос", type(app.screen).__name__ == "Confirm",
              type(app.screen).__name__)
        await pilot.press("y")
        await pilot.pause(0.4)
        check("выдача записана после «да»", any(r["employee"] == "Посторонний"
                                                for r in db.cart_list()))
        await pilot.press("x")
        await pilot.pause(1.5)

        # ---- заявки ----
        await pilot.press("f3")
        await pilot.pause(0.4)
        await pilot.press("a")
        await pilot.pause(0.4)
        await type_into(pilot, app, "#department", "метрологии")
        await type_into(pilot, app, "#items", "Картридж 285A ; 2 ; шт.\nМышь")
        await pilot.press("ctrl+w")
        await pilot.pause(1.5)
        pr = db.pr_list()
        check("заявка сохранена и выгружена", len(pr) == 1 and pr[0]["items_count"] == 2, pr)

        # ---- настройки ----
        await pilot.press("f5")
        await pilot.pause(0.4)
        await type_into(pilot, app, "#rep_branch", "Северный филиал")
        await pilot.press("ctrl+s")
        await pilot.pause(0.3)
        check("настройки сохранены", mr.load_data()["settings"]["branch"] == "Северный филиал")
        await pilot.press("f1")
        await pilot.pause(0.3)
        check("F1 — снова учёт", tabs.active == "assets")

    out = sorted(os.listdir(os.path.join(TMP, "out")))
    check("выгрузки в папке", any(f.startswith("Картриджи") for f in out)
          and any(f.startswith("Заявка") for f in out), out)


asyncio.run(main())
print()
print("ВСЕ ПРОВЕРКИ ПРОШЛИ" if not FAILS else f"НЕ ПРОШЛО: {len(FAILS)} — " + ", ".join(FAILS))
sys.exit(1 if FAILS else 0)
