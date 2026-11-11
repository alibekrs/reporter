"""Проверка Word и письма, собранных приложением (Checks/main.swift)."""
import email
import sys
from email import policy

import docx

d = sys.argv[1]
doc = docx.Document(f"{d}/week.docx")
heads = [p.text for p in doc.paragraphs][:3]
assert heads == ["Филиал: Северный филиал", "Дата: 02.11.2026-06.11.2026",
                 "Ответственный: Иванов Иван"], heads
rows = [[c.text for c in r.cells] for r in doc.tables[0].rows]
assert rows[0] == ["Дата", "№", "Сотрудник / объект", "Описание обращения",
                   "Выполненные действия", "Результат"], rows[0]
assert rows[1] == ["2 ноября", "1", "Сидорова Мария", "Принтер <плохо> & печатает",
                   "Заменил\nкартридж", "Печатает"], rows[1]
assert rows[2][:3] == ["3 ноября", "2", "Қайрат Әлиев"], rows[2]
assert rows[2][4] == "вставкаиз Word", rows[2]      # управляющий символ выброшен, файл открылся
assert len(rows) == 3, len(rows)

m = email.message_from_bytes(open(f"{d}/mail.eml", "rb").read(), policy=policy.default)
assert m["subject"] == "Отчёт о работе системного администратора (02.11–06.11.2026)", m["subject"]
assert m["to"] == "boss@example.kz"
assert "Здравствуйте" in m.get_body(("plain",)).get_content()
att = next(m.iter_attachments())
assert att.get_filename() == "Отчёт_02.11-06.11.2026.docx", att.get_filename()
assert att.get_content() == open(f"{d}/week.docx", "rb").read(), "вложение не совпадает с файлом"
print("Word и письмо в порядке")
