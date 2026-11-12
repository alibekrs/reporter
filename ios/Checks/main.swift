// Самопроверка на macOS-раннере: настоящие Docx.swift и Mail.swift собирают Word за неделю
// и письмо; check_mail.py открывает их python-docx и email-парсером.
import Foundation

let dir = CommandLine.arguments[1]
let monday = Dates.parse("2026-11-02")
let entries = [
    Entry(uid: "a", date: "2026-11-02", employee: "Сидорова Мария", description: "Принтер <плохо> & печатает",
          actions: "Заменил\nкартридж", result: "Печатает"),
    // U+000B — «мягкий перенос» из Word: в XML запрещён, отчёт должен его выбросить, а не сломаться
    Entry(uid: "b", date: "2026-11-03", employee: "Қайрат Әлиев", description: ".точка в начале",
          actions: "вставка\u{B}из Word"),
]
let docx = Docx.week(branch: "Северный филиал", responsible: "Иванов Иван", monday: monday, entries: entries)
try docx.write(to: URL(fileURLWithPath: dir + "/week.docx"))
let mail = MIME.message(from: "me@example.kz", to: "boss@example.kz",
                        subject: "Отчёт о работе системного администратора (\(ReportMail.label(monday)))",
                        text: "Здравствуйте!\n.точка в начале строки", attachment: docx,
                        fileName: Docx.fileName(monday: monday))
try Data(mail.utf8).write(to: URL(fileURLWithPath: dir + "/mail.eml"))
print("собрано: week.docx, mail.eml")

// ── бэкап: JSON туда-обратно и Excel для чтения ─────────────────────────────
let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: URL(fileURLWithPath: "App/meta.json")))
let backup = BackupFile(
    note: BackupFile.readme, app: "REPORTER", exported_at: "06.11.2026 09:41", meta: meta,
    units: [["id": .string("u1"), "name": .string("АУП"), "parent_id": .null, "order": .number(0)],
            ["id": .string("u2"), "name": .string("Бухгалтерия"), "parent_id": .string("u1"), "order": .number(1)]],
    employees: [["id": .string("e1"), "unit_id": .string("u2"), "last_name": .string("Сидорова"),
                 "first_name": .string("Мария"), "middle_name": .string("Петровна"), "is_head": .bool(true),
                 "office": .string("12"), "phone": .string("+7 700 000 00 00"), "email": .string("maria@example.com"),
                 "birthday": .string("1990-03-15"),
                 "pcs": .array([.object(["id": .string("d1"), "inv": .string("ИН-7 & <A>"), "hostname": .string("BUH-1"),
                                         "bought": .string("2019-05-20"), "warranty": .string("2027-05-20")])]),
                 "printers": .array([.object(["id": .string("d2"), "model": .string("HP LaserJet"),
                                              "cartridge": .string("CF226")])]),
                 "mouse": .object(["condition": .string("рабочее")]), "notes": .string("строка\u{1}с мусором")],
                ["id": .string("e2"), "unit_id": .string("u1"), "last_name": .string("Петров"),
                 "first_name": .string("Пётр"), "dismissed": .string("2026-10-01")]],
    entries: entries,
    cartridges: [CartRaw(id: 1, issued_at: "2026-11-05", employee_id: "e1", employee: "Сидорова Мария", model: "HP 85A",
                         qty: 2, note: nil)],
    storeroom: ["monitors": .array([.object(["id": .string("d3"), "model": .string("Dell P2419H")])])],
    device_log: [DeviceEvent(id: "v1", device: "d1", date: "2026-11-02", kind: "new", text: "Выдан: Сидорова Мария Петровна")])
let json = try backup.json()
let back = try BackupFile.read(json)
precondition(back.employees.count == 2 && back.entries.count == 2 && back.cartridges.count == 1 && back.meta != nil,
             "бэкап не прочитался обратно")
precondition(back.storeroom?["monitors"]?.array.count == 1 && back.device_log?.first?.device == "d1",
             "склад и история техники не прочитались обратно")
precondition(String(decoding: json, as: UTF8.self).contains("Сидорова"), "кириллица в JSON экранирована")
precondition((try? BackupFile.read(Data("{\"x\":1}".utf8))) == nil, "чужой файл принят за бэкап")
// бэкап старой версии (ITtool 1.x): без meta и описания, с очередью unsynced
let old = try BackupFile.read(Data("{\"exported_at\":\"1\",\"units\":[],\"employees\":[],\"entries\":[],\"cartridges\":[],\"unsynced\":[]}".utf8))
precondition(old.meta == nil && old.employees.isEmpty, "старый бэкап не читается")
precondition(Xlsx.column(0) == "A" && Xlsx.column(25) == "Z" && Xlsx.column(26) == "AA", "буквы колонок")
// ── шифрование бэкапа: туда-обратно, чужой пароль и порча не проходят ───────
let sealed = try BackupCrypto.encrypt(json, password: "пароль-бэкапа 1")
precondition(BackupCrypto.isEncrypted(sealed) && !BackupCrypto.isEncrypted(json), "метка шифрования")
let opened = try BackupCrypto.decrypt(sealed, password: "пароль-бэкапа 1")
precondition(opened == json, "расшифровка вернула не то")
precondition((try? BackupCrypto.decrypt(sealed, password: "пароль-бэкапа 2")) == nil, "чужой пароль подошёл")
var spoiled = sealed
spoiled[spoiled.count - 1] ^= 0x01
precondition((try? BackupCrypto.decrypt(spoiled, password: "пароль-бэкапа 1")) == nil, "испорченный файл прочитался")
let again = try BackupCrypto.encrypt(json, password: "пароль-бэкапа 1")
precondition(again != sealed, "соль не случайная")
precondition(!String(decoding: sealed, as: UTF8.self).contains("Сидорова"), "в зашифрованном видны данные")
print("шифрование бэкапа в порядке")
// выдача из корзины: JSON-обёртка возвращает целые числа целыми
let cartBack = fromJSON(asJSON(CartRaw(id: 7, issued_at: "2026-11-05", employee_id: "e1", employee: "Сидорова Мария",
                                       model: "285", qty: 3, note: nil)), as: CartRaw.self)
precondition(cartBack?.id == 7 && cartBack?.qty == 3, "выдача из корзины не прочиталась")
try json.write(to: URL(fileURLWithPath: dir + "/backup.json"))
try Readable.xlsx(backup).write(to: URL(fileURLWithPath: dir + "/backup.xlsx"))
print("собрано: backup.json, backup.xlsx")
