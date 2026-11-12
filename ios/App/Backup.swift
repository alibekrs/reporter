import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Файл бэкапа (JSON). Его же читает «Восстановить из бэкапа». Поля — как в базе ITtool,
/// чтобы данные можно было перенести куда угодно.
struct BackupFile: Codable {
    var note: String? = nil
    var app: String? = nil
    var exported_at: String? = nil
    var meta: Meta? = nil
    var units: [Dict]
    var employees: [Dict]
    var entries: [Entry]
    var cartridges: [CartRaw]
    var templates: [EntryTemplate]? = nil
    /// в бэкапах до 5.1 этих полей нет
    var storeroom: Dict? = nil
    var device_log: [DeviceEvent]? = nil
    var checklist: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case note = "описание", app, exported_at, meta, units, employees, entries, cartridges, templates, storeroom,
             device_log, checklist
    }

    static let readme = "Бэкап приложения REPORTER (раньше ITtool). units — подразделения, employees — сотрудники и их техника "
        + "(pcs — компьютеры, monitors — мониторы, phones — телефоны, printers — принтеры; dismissed — дата увольнения), "
        + "storeroom — техника на складе, device_log — история техники, entries — записи "
        + "еженедельного отчёта, cartridges — выдачи картриджей, templates — шаблоны заявок (если их меняли), "
        + "checklist — чек-лист нового сотрудника, meta — справочник полей техники. "
        + "Excel-файл с тем же названием — те же данные в виде таблиц для чтения."

    var stats: String {
        "\(employees.count) сотр., \(entries.count) \(plural(entries.count, "запись", "записи", "записей")), "
            + "\(cartridges.count) \(plural(cartridges.count, "выдача", "выдачи", "выдач"))"
    }

    func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    static func read(_ data: Data) throws -> BackupFile {
        do {
            return try JSONDecoder().decode(BackupFile.self, from: data)
        } catch {
            throw APIError(message: "Это не файл бэкапа REPORTER или он повреждён. Выберите файл .json, "
                           + "который присылает бот.")
        }
    }
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

/// Те же данные таблицами: Excel открывается на любом компьютере и телефоне.
enum Readable {
    static func xlsx(_ b: BackupFile) -> Data {
        Xlsx.workbook([report(b), staff(b), carts(b)])
    }

    /// 2026-11-05 → 05.11.2026
    static func date(_ iso: String) -> String {
        let p = iso.split(separator: "-")
        return p.count == 3 ? "\(p[2]).\(p[1]).\(p[0])" : iso
    }

    /// id подразделения → «АУП / Отдел …».
    static func unitPaths(_ units: [Dict]) -> [String: String] {
        var byId: [String: Dict] = [:]
        for u in units { if let id = u["id"]?.string, !id.isEmpty { byId[id] = u } }
        var out: [String: String] = [:]
        for id in byId.keys {
            var names: [String] = [], cur = id, seen = Set<String>()
            while let u = byId[cur], seen.insert(cur).inserted {      // seen — защита от петли в дереве
                names.insert(u["name"]?.string ?? "", at: 0)
                cur = u["parent_id"]?.string ?? ""
            }
            out[id] = names.joined(separator: " / ")
        }
        return out
    }

    static func report(_ b: BackupFile) -> Xlsx.Sheet {
        let rows = b.entries.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map { e -> [String] in
                let x = e.element
                return [date(x.date), x.employee ?? "", x.description ?? "", x.actions ?? "", x.result ?? ""]
            }
        return Xlsx.Sheet(name: "Отчёт", header: ["Дата", "Сотрудник / объект", "Описание", "Что сделано", "Результат"],
                          widths: [12, 28, 40, 40, 28], rows: rows)
    }

    /// Поля техники вне справочника: картридж принтера и даты покупки и гарантии.
    private static let deviceExtras = [("cartridge", "Картридж"), ("bought", "Куплен"), ("warranty", "Гарантия до")]

    /// Техника одного владельца (сотрудника или склада) — по строке на устройство.
    static func devices(_ holder: Dict, meta: Meta?) -> [String] {
        let order = meta?.device_order ?? ["pcs", "monitors", "phones", "printers"]
        return order.flatMap { g -> [String] in
            let spec = meta?.devices[g]
            return (holder[g]?.array ?? []).map { item -> String in
                let o = item.object
                var parts: [String]
                if let spec {
                    parts = spec.fields.compactMap { value(o[$0.key], label: $0.label) }
                } else {
                    let skip = Set(["id"] + deviceExtras.map { $0.0 })
                    parts = o.keys.sorted().filter { !skip.contains($0) }.compactMap { value(o[$0], label: $0) }
                }
                for (k, label) in deviceExtras {
                    let v = o[k]?.string ?? ""
                    if !v.isEmpty { parts.append("\(label): \(k == "cartridge" ? v : date(v))") }
                }
                return (spec?.singular ?? g) + ": " + parts.joined(separator: ", ")
            }
        }
    }

    static func staff(_ b: BackupFile) -> Xlsx.Sheet {
        let paths = unitPaths(b.units)
        var rows = b.employees.map { e -> [String] in
            func text(_ k: String) -> String { e[k]?.string ?? "" }
            func condition(_ k: String) -> String { e[k]?["condition"]?.string ?? "" }
            let unit: String = paths[text("unit_id")] ?? ""
            let head: String = e["is_head"]?.bool == true ? "да" : ""
            let tech: String = devices(e, meta: b.meta).joined(separator: "\n")
            let birthday = text("birthday"), fired = text("dismissed")
            return [unit, personName(e), text("position"), head, text("building"), text("floor"), text("office"),
                    text("account"), text("phone"), text("email"), birthday.isEmpty ? "" : date(birthday),
                    tech, condition("mouse"), condition("keyboard"), text("notes"), fired.isEmpty ? "" : date(fired)]
        }
        .sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
        // техника без хозяина — отдельной строкой в конце
        let stock = devices(b.storeroom ?? [:], meta: b.meta)
        if !stock.isEmpty {
            rows.append(["", "Склад (без хозяина)", "", "", "", "", "", "", "", "", "", stock.joined(separator: "\n"),
                         "", "", "", ""])
        }
        return Xlsx.Sheet(name: "Сотрудники и техника",
                          header: ["Подразделение", "ФИО", "Должность", "Руководитель", "Здание", "Этаж", "Кабинет",
                                   "Учётная запись", "Телефон", "Почта", "День рождения", "Техника", "Мышь",
                                   "Клавиатура", "Заметки", "Уволен"],
                          widths: [30, 32, 26, 12, 12, 8, 10, 18, 18, 26, 14, 60, 16, 16, 30, 12], rows: rows)
    }

    static func carts(_ b: BackupFile) -> Xlsx.Sheet {
        let paths = unitPaths(b.units)
        var byId: [String: Dict] = [:]
        for e in b.employees { if let id = e["id"]?.string, !id.isEmpty { byId[id] = e } }
        let rows = b.cartridges.sorted { ($0.issued_at, $0.id) < ($1.issued_at, $1.id) }.map { c -> [String] in
            let emp: Dict? = byId[c.employee_id ?? ""]
            let who: String = emp.map { personName($0) } ?? (c.employee ?? "")
            let unitId: String = emp?["unit_id"]?.string ?? ""
            let unit: String = emp == nil ? "" : (paths[unitId] ?? "")
            return [date(c.issued_at), who, unit, c.model, String(c.qty), c.note ?? ""]
        }
        return Xlsx.Sheet(name: "Картриджи", header: ["Дата", "Сотрудник", "Подразделение", "Модель", "Кол-во", "Примечание"],
                          widths: [12, 32, 30, 16, 8, 30], rows: rows)
    }

    /// «Инв. номер: 123»; галочка — просто её название; пустое — пропускаем.
    private static func value(_ v: JSON?, label: String) -> String? {
        guard let v else { return nil }
        if case .bool(let on) = v { return on ? label : nil }
        let s = v.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : "\(label): \(s)"
    }
}

/// Книга Excel (.xlsx) вручную: XML-листы в ZIP, текст — прямо в ячейках (inlineStr).
enum Xlsx {
    struct Sheet {
        let name: String
        let header: [String]
        let widths: [Double]
        let rows: [[String]]
    }

    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static func workbook(_ sheets: [Sheet]) -> Data {
        let n = sheets.count
        var types = head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for i in 1...n {
            types += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        types += "</Types>"
        let rootRels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        var book = head + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets>"
        var bookRels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for (i, s) in sheets.enumerated() {
            book += "<sheet name=\"\(esc(String(s.name.prefix(31))))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            bookRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        book += "</sheets></workbook>"
        bookRels += "<Relationship Id=\"rId\(n + 1)\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>"
        var files: [(String, Data)] = [("[Content_Types].xml", types), ("_rels/.rels", rootRels),
                                       ("xl/workbook.xml", book), ("xl/_rels/workbook.xml.rels", bookRels),
                                       ("xl/styles.xml", styles)].map { ($0.0, Data($0.1.utf8)) }
        for (i, s) in sheets.enumerated() { files.append(("xl/worksheets/sheet\(i + 1).xml", Data(sheet(s).utf8))) }
        return Zip.stored(files)
    }

    // стиль 1 — шапка (белый жирный на синем, как в Word-отчёте), стиль 2 — перенос строк, текст сверху
    private static let styles = head + "<styleSheet xmlns=\"\(main)\">"
        + "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font>"
        + "<font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/></font></fonts>"
        + "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
        + "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF4472C4\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>"
        + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        + "<cellXfs count=\"3\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyAlignment=\"1\"><alignment vertical=\"center\" wrapText=\"1\"/></xf>"
        + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf></cellXfs>"
        + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"

    private static func sheet(_ s: Sheet) -> String {
        var x = head + "<worksheet xmlns=\"\(main)\"><sheetViews><sheetView workbookViewId=\"0\">"
            + "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols>"
        for (i, w) in s.widths.enumerated() { x += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(w)\" customWidth=\"1\"/>" }
        x += "</cols><sheetData>"
        for (r, row) in ([s.header] + s.rows).enumerated() {
            x += "<row r=\"\(r + 1)\">"
            for (c, v) in row.enumerated() where !v.isEmpty {
                x += "<c r=\"\(column(c))\(r + 1)\" t=\"inlineStr\" s=\"\(r == 0 ? 1 : 2)\"><is><t xml:space=\"preserve\">\(esc(v))</t></is></c>"
            }
            x += "</row>"
        }
        return x + "</sheetData></worksheet>"
    }

    /// 0 → A, 25 → Z, 26 → AA
    static func column(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(Character(UnicodeScalar(UInt8(65 + r)))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// Спецсимволы XML и управляющие символы, которых Excel не терпит (перевод строки оставляем).
    static func esc(_ s: String) -> String {
        let clean = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }))
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Шифрование бэкапа паролем: AES-GCM, ключ из пароля через PBKDF2. Расшифровать может только приложение
/// (или тот, кто знает пароль и формат): в начале файла — метка, соль и число раундов, дальше шифротекст.
enum BackupCrypto {
    static let passwordKey = "backup.password"
    private static let magic = Data("REPORTER-ENC1\n".utf8)
    private static let rounds: UInt32 = 200_000

    static func isEncrypted(_ data: Data) -> Bool { data.starts(with: magic) }

    static func encrypt(_ plain: Data, password: String) throws -> Data {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw APIError(message: "Не получилось зашифровать бэкап.")
        }
        let key = try derive(password, Data(salt), rounds)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else {
            throw APIError(message: "Не получилось зашифровать бэкап.")
        }
        var out = magic
        out.append(contentsOf: salt)
        withUnsafeBytes(of: rounds.bigEndian) { out.append(contentsOf: $0) }
        out.append(sealed)
        return out
    }

    static func decrypt(_ input: Data, password: String) throws -> Data {
        let data = Data(input)                    // индексы с нуля, даже если пришёл кусок другого Data
        let head = magic.count, body = head + 16 + 4
        guard isEncrypted(data), data.count > body + 28 else {
            throw APIError(message: "Файл бэкапа повреждён.")
        }
        let salt = data.subdata(in: head..<(head + 16))
        let r = data.subdata(in: (head + 16)..<body).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        do {
            let box = try AES.GCM.SealedBox(combined: data.subdata(in: body..<data.count))
            return try AES.GCM.open(box, using: derive(password, salt, r))
        } catch {
            throw APIError(message: "Пароль бэкапа не подходит, или файл повреждён.")
        }
    }

    private static func derive(_ password: String, _ salt: Data, _ rounds: UInt32) throws -> SymmetricKey {
        guard !password.isEmpty, rounds > 0 else { throw APIError(message: "Пароль бэкапа не задан.") }
        var key = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8).map { CChar(bitPattern: $0) }
        let status = key.withUnsafeMutableBufferPointer { k in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, k.baseAddress, k.count)
            }
        }
        guard status == Int32(kCCSuccess) else { throw APIError(message: "Не получилось подготовить ключ бэкапа.") }
        return SymmetricKey(data: key)
    }
}

/// Отправка файла в телеграм-группу через бота (Bot API sendDocument) и чтение его обратно (getFile).
enum Telegram {
    /// Возвращает file_id отправленного файла — по нему бэкап потом скачивается для проверки.
    @discardableResult
    static func send(token: String, chat: String, file: Data, name: String, mime: String,
                     caption: String?) async throws -> String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let url = URL(string: "https://api.telegram.org/bot\(t)/sendDocument") else {
            throw APIError(message: "Неверный токен бота.")
        }
        let boundary = "qyran-\(UUID().uuidString)"
        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("chat_id", chat.trimmingCharacters(in: .whitespacesAndNewlines))
        if let caption { field("caption", caption) }
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"document\"; filename=\"\(name)\"\r\n"
                          + "Content-Type: \(mime)\r\n\r\n").utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = try check(data, resp)
        return j["result"]?["document"]?["file_id"]?.string ?? ""
    }

    /// Скачать файл, который бот отправлял раньше (до 20 МБ — бэкап намного меньше).
    static func download(token: String, fileId: String) async throws -> Data {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var c = URLComponents(string: "https://api.telegram.org/bot\(t)/getFile")
        c?.queryItems = [URLQueryItem(name: "file_id", value: fileId)]
        guard !t.isEmpty, let url = c?.url else { throw APIError(message: "Неверный токен бота.") }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 60))
        let path = try check(data, resp)["result"]?["file_path"]?.string ?? ""
        guard !path.isEmpty, let file = URL(string: "https://api.telegram.org/file/bot\(t)/\(path)") else {
            throw APIError(message: "Телеграм не отдал файл бэкапа.")
        }
        let (body, r2) = try await URLSession.shared.data(for: URLRequest(url: file, timeoutInterval: 60))
        guard (r2 as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(message: "Телеграм не отдал файл бэкапа.") }
        return body
    }

    /// Ответ Bot API: ошибки — понятным текстом.
    private static func check(_ data: Data, _ resp: URLResponse) throws -> JSON {
        let j = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let d = j["description"]?.string ?? "Телеграм ответил ошибкой."
            if d.contains("chat not found") {
                throw APIError(message: "Группа не найдена. ID группы начинается с -100…, а бот должен быть в этой группе.")
            }
            if d.contains("Unauthorized") || d.contains("Not Found") {
                throw APIError(message: "Телеграм не принял токен бота — проверьте его в настройках.")
            }
            throw APIError(message: d)
        }
        return j
    }
}
