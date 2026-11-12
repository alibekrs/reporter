import Foundation

/// Любое значение JSON: карточки учёта ходят как словари, чтобы не терять поля,
/// которых приложение не знает.
enum JSON: Codable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSON]), object([String: JSON]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        // целое — без «.0»: выдача из корзины читается обратно в Int
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "да" : "нет"
        default: return ""
        }
    }

    var bool: Bool {
        if case .bool(let b) = self { return b }
        return false
    }

    var array: [JSON] {
        if case .array(let a) = self { return a }
        return []
    }

    var object: [String: JSON] {
        if case .object(let o) = self { return o }
        return [:]
    }
}

typealias Dict = [String: JSON]

struct APIError: LocalizedError {
    let message: String
    var unknownPerson = false
    var errorDescription: String? { message }
}

/// ФИО одной строкой (как assets.fio в ITtool).
func personName(_ e: Dict) -> String {
    let s = ["last_name", "first_name", "middle_name"].map { e[$0]?.string ?? "" }
        .filter { !$0.isEmpty }.joined(separator: " ")
    return s.isEmpty ? "(без имени)" : s
}

// ── справочники ─────────────────────────────────────────────────────────────
struct Field: Codable, Hashable {
    let key: String, label: String, kind: String, values: [String]
}

struct DeviceSpec: Codable {
    let title: String, singular: String, fields: [Field]
}

struct Meta: Codable {
    let conditions: [String]
    let device_order: [String]
    let devices: [String: DeviceSpec]
}

// ── данные ──────────────────────────────────────────────────────────────────
struct Unit: Hashable, Identifiable {
    let id: String, name: String, depth: Int, path: String
    /// id подразделения уровнем выше; пусто — верхний уровень
    var parent = ""
}

struct Entry: Codable, Identifiable, Hashable {
    let uid: String
    var date: String
    var employee: String? = ""
    var description: String? = ""
    var actions: String? = ""
    var result: String? = ""
    /// id устройства, с которым была заявка: запись попадает в его историю
    var device: String? = nil
    var id: String { uid }
}

/// Событие в истории устройства: появилось у сотрудника, передано, владелец уволен, вернули из корзины.
struct DeviceEvent: Codable, Hashable, Identifiable {
    var id: String
    var device: String
    var date: String
    /// new — выдано, move — передано, fired — владелец уволен, back — вернули из корзины
    var kind: String
    var text: String
}

/// Удалённое: лежит в корзине 30 дней, пока его можно вернуть.
struct TrashItem: Codable, Hashable, Identifiable {
    var id: String
    /// entry, employee, cart, template, unit, device
    var kind: String
    var deleted: Date
    var title: String
    var subtitle: String
    var payload: JSON
    /// выдача — её заявка в отчёте; устройство — у кого и в какой группе оно было
    var extra: JSON?
}

/// Любое значение — в JSON и обратно (корзина хранит удалённое как есть).
func asJSON<T: Encodable>(_ value: T) -> JSON {
    (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSON.self, from: $0) } ?? .null
}

func fromJSON<T: Decodable>(_ json: JSON, as type: T.Type) -> T? {
    (try? JSONEncoder().encode(json)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
}

/// Шаблон заявки: заполняет «Что случилось», «Что сделано» и «Итог».
struct EntryTemplate: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var actions: String
    var result: String

    /// Этот шаблон сам ложится в отчёт при выдаче картриджа; удалить нельзя, править — можно.
    static let cartridgeId = "cartridge"

    static let defaults: [EntryTemplate] = [
        .init(cartridgeId, "Картридж", "Принтер плохо печатает", "Заменил картридж", "Принтер печатает в штатном режиме"),
        .init("paper", "Замятие бумаги", "Замятие бумаги в принтере", "Извлёк замятую бумагу, почистил ролики",
              "Принтер печатает в штатном режиме"),
        .init("noprint", "Принтер не печатает", "Принтер не печатает", "Очистил очередь печати, переустановил драйвер",
              "Печать восстановлена"),
        .init("scan", "Сканер", "Не работает сканирование", "Настроил сканирование в папку",
              "Сканер работает в штатном режиме"),
        .init("newprinter", "Новый принтер", "Подключение нового принтера", "Установил драйвер, подключил принтер к ПК",
              "Принтер работает в штатном режиме"),
        .init("internet", "Нет интернета", "Нет доступа в интернет",
              "Проверил кабель и сетевые настройки, перезагрузил оборудование", "Доступ в интернет восстановлен"),
        .init("wifi", "Wi-Fi", "Не подключается к Wi-Fi", "Переподключил к сети, обновил драйвер адаптера",
              "Подключение работает стабильно"),
        .init("power", "Компьютер не включается", "Компьютер не включается",
              "Проверил питание и кабели, устранил неисправность", "Компьютер работает в штатном режиме"),
        .init("slow", "Медленная работа", "Компьютер медленно работает",
              "Очистил автозагрузку и временные файлы, проверил диск", "Скорость работы восстановлена"),
        .init("virus", "Вирусы", "Подозрение на вирус", "Проверил антивирусом, удалил угрозы",
              "Угроз не обнаружено, ПК работает в штатном режиме"),
        .init("software", "Установка ПО", "Требуется установка программы", "Установил и настроил программу",
              "Программа работает в штатном режиме"),
        .init("update", "Обновление Windows", "Ошибка обновления Windows", "Установил обновления, перезагрузил ПК",
              "Система обновлена"),
        .init("mail", "Почта", "Не работает почта", "Проверил настройки учётной записи, перенастроил почтовый клиент",
              "Почта работает в штатном режиме"),
        .init("password", "Пароль", "Сотрудник забыл пароль", "Сбросил пароль, выдал временный", "Доступ восстановлен"),
        .init("newcomer", "Новый сотрудник", "Подготовка рабочего места для нового сотрудника",
              "Создал учётную запись, настроил ПК и почту", "Рабочее место готово"),
        .init("monitor", "Монитор", "Не работает монитор", "Проверил кабель и настройки изображения, заменил кабель",
              "Монитор работает в штатном режиме"),
        .init("input", "Клавиатура / мышь", "Не работает клавиатура или мышь", "Заменил на исправную",
              "Устройство работает в штатном режиме"),
        .init("phone", "Телефон", "Не работает IP-телефон", "Проверил подключение и настройки, перезагрузил",
              "Связь восстановлена"),
        .init("share", "Сетевая папка", "Нет доступа к сетевой папке", "Проверил права доступа, переподключил сетевой диск",
              "Доступ восстановлен"),
        .init("move", "Перенос рабочего места", "Перенос рабочего места", "Отключил, перенёс и подключил оборудование",
              "Рабочее место работает в штатном режиме"),
        .init("backup", "Резервная копия", "Требуется резервная копия данных", "Скопировал данные на внешний носитель",
              "Резервная копия создана"),
    ]
}

extension EntryTemplate {
    init(_ id: String, _ name: String, _ description: String, _ actions: String, _ result: String) {
        self.init(id: id, name: name, description: description, actions: actions, result: result)
    }
}

/// Выдача картриджа, как она лежит в данных.
struct CartRaw: Codable, Hashable {
    var id: Int
    var issued_at: String
    var employee_id: String?
    var employee: String?
    var model: String
    var qty: Int
    var note: String?
}

struct Person: Hashable {
    let id: String, fio: String, unit: String
}

/// Выдача для показа: ФИО и отдел — как в учёте сейчас.
struct CartItem: Identifiable, Hashable {
    let id: Int
    let date: String
    let employee: String
    let unit: String
    let model: String
    let qty: Int
    let note: String
}

// ── даты ────────────────────────────────────────────────────────────────────
enum Dates {
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let human: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()

    static let shortHuman: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    static let months = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь",
                         "Октябрь", "Ноябрь", "Декабрь"]

    /// Год и месяц дня — по григорианскому календарю, как записаны даты (а не по календарю телефона).
    static func yearMonth(_ d: Date) -> (year: Int, month: Int) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: d)
        return (c.year ?? 2000, c.month ?? 1)
    }

    static func parse(_ s: String) -> Date { iso.date(from: s) ?? Date() }
    static func text(_ d: Date) -> String { iso.string(from: d) }
    static func short(_ s: String) -> String { iso.date(from: s).map { shortHuman.string(from: $0) } ?? s }

    /// Понедельник недели, в которую попадает день (неделя — с понедельника).
    static func monday(_ d: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let wd = cal.component(.weekday, from: d)             // 1 — воскресенье
        return cal.date(byAdding: .day, value: -((wd + 5) % 7), to: cal.startOfDay(for: d))!
    }

    /// Рабочий день для отчёта: суббота и воскресенье — в пятницу этой недели.
    static func workday(_ d: Date) -> Date {
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: d)   // 1 — воскресенье
        let back = wd == 7 ? 1 : (wd == 1 ? 2 : 0)
        return Calendar.current.date(byAdding: .day, value: -back, to: d)!
    }
}
