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
row = dict(zip(st[0], st[1]))
assert row["Подразделение"] == "АУП / Бухгалтерия", row
assert row["ФИО"] == "Сидорова Мария Петровна", row
assert row["Руководитель"] == "да", row
assert row["Техника"] == "ПК: Инв. номер: ИН-7 & <A>, Имя в сети: BUH-1", row["Техника"]
assert row["Мышь"] == "рабочее", row
assert row["Заметки"] == "строкас мусором", row["Заметки"]

ct = [[c.value for c in r] for r in wb["Картриджи"].iter_rows()]
assert ct[1] == ["05.11.2026", "Сидорова Мария Петровна", "АУП / Бухгалтерия", "HP 85A", "2", None], ct[1]

j = json.load(open(f"{d}/backup.json", encoding="utf-8"))
assert j["app"] == "REPORTER" and len(j["entries"]) == 2 and "описание" in j, list(j)
print("Excel и JSON бэкапа в порядке")
