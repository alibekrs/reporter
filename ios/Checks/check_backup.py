"""Проверка Excel-бэкапа, собранного приложением (Checks/main.swift): открывается и читается."""
import json
import sys

import openpyxl

d = sys.argv[1]
wb = openpyxl.load_workbook(f"{d}/backup.xlsx")
assert wb.sheetnames == ["Отчёт", "Сотрудники и техника", "Картриджи"], wb.sheetnames

rep = [[c.value for c in r] for r in wb["Отчёт"].iter_rows()]
assert rep[0] == ["Дата", "Сотрудник / объект", "Описание", "Что сделано", "Результат"], rep[0]
assert rep[1] == ["02.11.2026", "Сидорова Мария", "Принтер <плохо> & печатает", "Заменил\nкартридж", "Печатает"], rep[1]
assert rep[2][:2] == ["03.11.2026", "Қайрат Әлиев"], rep[2]

st = [[c.value for c in r] for r in wb["Сотрудники и техника"].iter_rows()]
rows = {r[1]: dict(zip(st[0], r)) for r in st[1:]}
row = rows["Сидорова Мария Петровна"]
assert row["Подразделение"] == "АУП / Бухгалтерия", row
assert row["Руководитель"] == "да", row
assert row["Техника"] == ("ПК: Инв. номер: ИН-7 & <A>, Имя в сети: BUH-1, Куплен: 20.05.2019, Гарантия до: 20.05.2027\n"
                          "Принтер: Модель: HP LaserJet, Картридж: CF226"), row["Техника"]
assert row["Телефон"] == "+7 700 000 00 00" and row["Почта"] == "maria@example.com", row
assert row["День рождения"] == "15.03.1990" and row["Уволен"] is None, row
assert row["Мышь"] == "рабочее", row
assert row["Заметки"] == "строкас мусором", row["Заметки"]
assert rows["Петров Пётр"]["Уволен"] == "01.10.2026", rows["Петров Пётр"]
assert st[-1][1] == "Склад (без хозяина)" and "Монитор: Модель: Dell P2419H" in st[-1][11], st[-1]

ct = [[c.value for c in r] for r in wb["Картриджи"].iter_rows()]
assert ct[1] == ["05.11.2026", "Сидорова Мария Петровна", "АУП / Бухгалтерия", "HP 85A", "2", None], ct[1]

j = json.load(open(f"{d}/backup.json", encoding="utf-8"))
assert j["app"] == "REPORTER" and len(j["entries"]) == 2 and "описание" in j, list(j)
assert j["device_log"][0]["device"] == "d1" and j["storeroom"]["monitors"][0]["model"] == "Dell P2419H", list(j)
print("Excel и JSON бэкапа в порядке")
