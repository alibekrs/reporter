import Foundation
import Network
import Security

/// Настройки почты для отчёта: всё в UserDefaults, пароль — в Keychain.
struct MailSettings: Equatable {
    var branch = "", responsible = "", server = "", port = "465", sender = "", password = "", recipient = ""

    static func load() -> MailSettings {
        let d = UserDefaults.standard
        var s = MailSettings()
        s.branch = d.string(forKey: "mail.branch") ?? ""
        s.responsible = d.string(forKey: "mail.responsible") ?? ""
        s.server = d.string(forKey: "mail.server") ?? ""
        s.port = d.string(forKey: "mail.port") ?? "465"
        s.sender = d.string(forKey: "mail.sender") ?? ""
        s.recipient = d.string(forKey: "mail.recipient") ?? ""
        s.password = Keychain.get("mail.password")
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(branch, forKey: "mail.branch")
        d.set(responsible, forKey: "mail.responsible")
        d.set(server, forKey: "mail.server")
        d.set(port, forKey: "mail.port")
        d.set(sender, forKey: "mail.sender")
        d.set(recipient, forKey: "mail.recipient")
        Keychain.set("mail.password", password)
    }

    /// Что не заполнено — как проверка bot_week_email на сервере.
    var missing: [String] {
        var out: [String] = []
        if server.trimmingCharacters(in: .whitespaces).isEmpty { out.append("сервер") }
        if Int(port.trimmingCharacters(in: .whitespaces)) == nil { out.append("порт") }
        if sender.trimmingCharacters(in: .whitespaces).isEmpty { out.append("отправитель") }
        if recipient.trimmingCharacters(in: .whitespaces).isEmpty { out.append("получатель") }
        if password.isEmpty { out.append("пароль") }
        return out
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ittool",
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ key: String, _ value: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Письмо с отчётом за неделю: тема и текст — как на сервере (reports.bot_week_email).
enum ReportMail {
    static func label(_ monday: Date) -> String {
        let fri = Calendar(identifier: .gregorian).date(byAdding: .day, value: 4, to: monday)!
        let a = DateFormatter(), b = DateFormatter()
        a.locale = Locale(identifier: "en_US_POSIX"); a.dateFormat = "dd.MM"
        b.locale = Locale(identifier: "en_US_POSIX"); b.dateFormat = "dd.MM.yyyy"
        return "\(a.string(from: monday))–\(b.string(from: fri))"
    }

    static func send(_ s: MailSettings, monday: Date, entries: [Entry]) async throws -> String {
        if !s.missing.isEmpty {
            throw APIError(message: "В настройках почты не заполнено: " + s.missing.joined(separator: ", ") + ".")
        }
        guard !entries.isEmpty else { throw APIError(message: "За неделю \(label(monday)) нет записей.") }
        guard (s.sender + s.password).canBeConverted(to: .ascii) else {
            throw APIError(message: "Адрес или пароль содержат русские буквы. Скорее всего пароль введён в русской "
                           + "раскладке — введите его заново на английской. Пароль приложения Gmail — только латиница.")
        }
        let lbl = label(monday)
        let docx = Docx.week(branch: s.branch, responsible: s.responsible, monday: monday, entries: entries)
        let text = "Здравствуйте!\n\nВо вложении — отчёт о работе системного администратора за неделю \(lbl)."
            + "\n\nС уважением,\n\(s.responsible)"
        let message = MIME.message(from: s.sender.trimmed, to: s.recipient.trimmed,
                                   subject: "Отчёт о работе системного администратора (\(lbl))", text: text,
                                   attachment: docx, fileName: Docx.fileName(monday: monday))
        try await SMTP.send(host: s.server.trimmed, port: Int(s.port.trimmed) ?? 465, user: s.sender.trimmed,
                            password: s.password, from: s.sender.trimmed, to: s.recipient.trimmed, message: message)
        return "Отчёт за \(lbl) отправлен на \(s.recipient.trimmed)."
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Письмо с ключом восстановления (PIN-код и зашифрованный бэкап): уходит с почты для отчёта.
enum KeyMail {
    static let subject = "REPORTER: ключ восстановления"

    static func message(from: String, to: String, key: String) -> String {
        let text = "Ключ восстановления REPORTER:\n\n" + RecoveryKey.pretty(key) + "\n\n"
            + "Он нужен, если забудете PIN-код входа: на экране входа нажмите «Забыли PIN-код?» и введите ключ.\n"
            + "Этот же ключ открывает зашифрованный бэкап вместо пароля — например, на новом телефоне.\n\n"
            + "Сохраните это письмо и никому его не пересылайте. Если вы не включали защиту в REPORTER, удалите его."
        return MIME.message(from: from, to: to, subject: subject, text: text)
    }
}

enum MIME {
    /// Без вложения — одна текстовая часть.
    static func message(from: String, to: String, subject: String, text: String, attachment: Data? = nil,
                        fileName: String = "") -> String {
        let boundary = "ittool-\(UUID().uuidString)"
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        // RFC 2231: в заголовке только ASCII, кириллица — %XX (.alphanumerics пропустил бы её как есть)
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: ascii) ?? "report.docx"
        let docType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        var m = ""
        m += "From: \(from)\r\nTo: \(to)\r\n"
        m += "Subject: =?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?=\r\n"
        m += "Date: \(date.string(from: Date()))\r\n"
        m += "Message-ID: <\(UUID().uuidString)@ittool.ios>\r\n"
        m += "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        m += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        m += Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        guard let attachment else { return m + "\r\n--\(boundary)--\r\n" }
        m += "\r\n--\(boundary)\r\n"
        m += "Content-Type: \(docType); name*=UTF-8''\(encodedName)\r\n"
        m += "Content-Disposition: attachment; filename*=UTF-8''\(encodedName)\r\n"
        m += "Content-Transfer-Encoding: base64\r\n\r\n"
        m += attachment.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        m += "\r\n--\(boundary)--\r\n"
        return m
    }
}

/// Отправка письма по SMTP через TLS с первого байта (порт 465 — так у Gmail в ITtool).
// shortcut: только SSL/465, без STARTTLS (587); понадобится другой почтовый сервер — добавить STARTTLS.
final class SMTP {
    private static let queue = DispatchQueue(label: "ittool.smtp")
    private let conn: NWConnection
    private var buffer = Data()

    private init(host: String, port: Int) {
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)),
                            using: .tls)
    }

    static func send(host: String, port: Int, user: String, password: String, from: String, to: String,
                     message: String) async throws {
        guard port == 465 else {
            throw APIError(message: "Поддерживается порт 465 (SSL), как у Gmail. Укажите порт 465.")
        }
        let s = SMTP(host: host, port: port)
        let watchdog = Task { try await Task.sleep(for: .seconds(40)); s.conn.cancel() }   // не висеть вечно
        defer { watchdog.cancel(); s.conn.cancel() }
        do {
            try await s.open()
            try await s.expect(220)
            try await s.command("EHLO ittool.ios", 250)
            try await s.command("AUTH LOGIN", 334)
            try await s.command(Data(user.utf8).base64EncodedString(), 334)
            do {
                try await s.command(Data(password.utf8).base64EncodedString(), 235)
            } catch {
                throw APIError(message: "Почта не приняла логин или пароль. Для Gmail нужен пароль приложения "
                               + "(16 латинских букв), а не обычный пароль от почты.")
            }
            try await s.command("MAIL FROM:<\(from)>", 250)
            try await s.command("RCPT TO:<\(to)>", 250)
            try await s.command("DATA", 354)
            // строки, начинающиеся с точки, удваиваем (RFC 5321); base64 и заголовки с точки не начинаются
            let body = message.replacingOccurrences(of: "\r\n.", with: "\r\n..")
            try await s.command(body + "\r\n.", 250)
            try? await s.write("QUIT\r\n")
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError(message: "Не удалось отправить письмо: \(error.localizedDescription)")
        }
    }

    private func open() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; cont.resume()
                case .failed(let e), .waiting(let e): done = true; cont.resume(throwing: e)
                case .cancelled: done = true; cont.resume(throwing: APIError(message: "Почтовый сервер не ответил."))
                default: break
                }
            }
            conn.start(queue: SMTP.queue)        // последовательная очередь: done меняется по одному
        }
    }

    private func write(_ s: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(s.utf8), completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<r.upperBound)
                return line
            }
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, e in
                    if let e { cont.resume(throwing: e) }
                    else if let data, !data.isEmpty { cont.resume(returning: data) }
                    else if complete { cont.resume(throwing: APIError(message: "Почтовый сервер закрыл соединение.")) }
                    else { cont.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
    }

    /// Ответ сервера (бывает в несколько строк «250-…», последняя — «250 …»).
    private func expect(_ code: Int) async throws {
        var line = try await readLine()
        while line.count > 3, line[line.index(line.startIndex, offsetBy: 3)] == "-" { line = try await readLine() }
        guard line.hasPrefix(String(code)) else {
            throw APIError(message: "Почтовый сервер ответил: \(line)")
        }
    }

    private func command(_ s: String, _ code: Int) async throws {
        try await write(s + "\r\n")
        try await expect(code)
    }
}
