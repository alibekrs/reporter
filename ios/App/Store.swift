import Foundation
import SwiftUI

/// Всё, что лежит в телефоне: данные и отметки о бэкапе. Других копий нет — только бэкап в Telegram.
struct LocalState: Codable {
    var meta: Meta?
    var units: [Dict] = []
    var employees: [Dict] = []
    var entries: [Entry] = []
    var carts: [CartRaw] = []
    /// nil — шаблоны заявок не меняли, берутся стандартные
    var templates: [EntryTemplate]?
    /// техника без хозяина: те же группы, что у сотрудника (pcs, monitors, phones, printers)
    var storeroom: Dict = [:]
    var deviceLog: [DeviceEvent] = []
    var trash: [TrashItem] = []
    /// nil — чек-лист нового сотрудника не меняли, берётся стандартный
    var checklist: [String]?
    var lastBackup: Date?
    var backupToken = ""
    var backupChat = ""
    /// week — раз в неделю, day — каждый день, change — после изменений
    var backupEvery = "week"
    var backupEncrypt = false
    /// когда данные меняли последний раз — для бэкапа «после изменений»
    var changedAt: Date?
    /// последний отправленный бэкап: file_id в Telegram и что в нём было — для проверки
    var backupFileId = ""
    var backupSent = ""
    var lastCheck: Date?
    var checkResult = ""
    var checkOK = false

    init() {}

    // поля, которых нет в файле (старые версии писали другие), берём по умолчанию, а не падаем
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decodeIfPresent(Meta.self, forKey: .meta)
        units = try c.decodeIfPresent([Dict].self, forKey: .units) ?? []
        employees = try c.decodeIfPresent([Dict].self, forKey: .employees) ?? []
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        carts = try c.decodeIfPresent([CartRaw].self, forKey: .carts) ?? []
        templates = try c.decodeIfPresent([EntryTemplate].self, forKey: .templates)
        storeroom = try c.decodeIfPresent(Dict.self, forKey: .storeroom) ?? [:]
        deviceLog = try c.decodeIfPresent([DeviceEvent].self, forKey: .deviceLog) ?? []
        trash = try c.decodeIfPresent([TrashItem].self, forKey: .trash) ?? []
        checklist = try c.decodeIfPresent([String].self, forKey: .checklist)
        lastBackup = try c.decodeIfPresent(Date.self, forKey: .lastBackup)
        backupToken = try c.decodeIfPresent(String.self, forKey: .backupToken) ?? ""
        backupChat = try c.decodeIfPresent(String.self, forKey: .backupChat) ?? ""
        backupEvery = try c.decodeIfPresent(String.self, forKey: .backupEvery) ?? "week"
        backupEncrypt = try c.decodeIfPresent(Bool.self, forKey: .backupEncrypt) ?? false
        changedAt = try c.decodeIfPresent(Date.self, forKey: .changedAt)
        backupFileId = try c.decodeIfPresent(String.self, forKey: .backupFileId) ?? ""
        backupSent = try c.decodeIfPresent(String.self, forKey: .backupSent) ?? ""
        lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        checkResult = try c.decodeIfPresent(String.self, forKey: .checkResult) ?? ""
        checkOK = try c.decodeIfPresent(Bool.self, forKey: .checkOK) ?? false
    }
}

/// Быстрые кнопки главной и «+» над панелью: что сделать на странице.
enum QuickAction: Equatable {
    case newEntry, newCart, findEmployee, sendReport, newEmployee
}

/// Сводка за месяц или год: сколько заявок и картриджей, кто и с чем обращается чаще.
struct Summary {
    var entries = 0
    var carts = 0
    var people = 0
    var byPerson: [Top] = []
    var byProblem: [Top] = []
    var byUnit: [Top] = []
    var byModel: [Top] = []
    /// заявки по месяцам — только в сводке за год
    var byMonth: [Int] = []

    struct Top: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }
}

/// Устройство, где бы оно ни было: у сотрудника (holder — его id) или на складе (holder пустой).
struct DeviceRef: Identifiable, Hashable {
    let id: String
    let group: String
    let holder: String
    let item: Dict
}

/// Строка истории устройства: событие или заявка из отчёта.
struct HistoryLine: Identifiable, Hashable {
    let id: String
    let date: String
    let icon: String
    let text: String
    var detail = ""
}

/// Карточка подразделения (вместе с вложенными): люди, техника, заявки и картриджи за месяц.
struct UnitStats {
    var people: [Dict] = []
    var devices: [(title: String, count: Int)] = []
    var withTrouble = 0
    var old = 0
    var entries = 0
    var carts = 0
}

/// Возраст парка по дате покупки.
struct FleetAge {
    var young = 0, middle = 0, old = 0, unknown = 0
    var oldest: [DeviceRef] = []
}

struct Birthday: Identifiable {
    let id: String
    let fio: String
    let day: Date
    /// 0 — сегодня
    let days: Int
}

/// Правила записи — как в модулях ITtool (assets.py, reports.py, cartridges.py).
@MainActor
final class Store: ObservableObject {
    @Published private(set) var state = LocalState()
    @Published var backupStatus: String?
    @Published private(set) var backingUp = false
    @Published private(set) var checking = false
    @Published var action: QuickAction?
    /// Открыта вложенная карточка — листание страниц выключено, чтобы свайп «назад» работал как обычно.
    @Published var lockPaging = false
    /// Сегодняшний день («2026-11-10»). Приложение живёт в памяти сутками, и страницы, открытые на «этой
    /// неделе» и «этом месяце», переходят на новые вслед за ним — иначе новая запись не видна в списке.
    @Published private(set) var today = Dates.text(Date())
    /// Что сказать при запуске, если файл данных не прочитался.
    @Published var loadError: String?
    /// Растёт при восстановлении из бэкапа: «Учёт» закрывает карточку со старыми данными.
    @Published private(set) var restores = 0
    /// Растёт при каждом удалении: плашка «Удалено» отсчитывает своё время заново, даже если уже висит.
    @Published private(set) var deletions = 0
    /// Файл не прочитался, и отложить его копию не вышло — поверх не пишем: это единственная копия данных.
    private var frozen = false
    /// Данные до последнего удаления — для кнопки «Вернуть» на плашке.
    private var beforeDelete: LocalState?

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ittool.json")
    }()

    /// Справочник полей техники, зашитый в приложение (снят с ITtool), — для первого запуска.
    static let bundledMeta: Meta? = Bundle.main.url(forResource: "meta", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }

    static let deviceGroups = ["pcs", "monitors", "phones", "printers"]

    init() {
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                state = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: file))
            } catch {
                // не прочитался — откладываем копию, чтобы первое же сохранение не затёрло данные
                let copy = file.deletingLastPathComponent()
                    .appendingPathComponent("ittool-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                do {
                    try FileManager.default.copyItem(at: file, to: copy)
                    loadError = "Файл с данными не прочитался, его копия отложена. Восстановите данные из бэкапа: "
                        + "Настройки → «Восстановить из бэкапа»."
                } catch {
                    frozen = true
                    loadError = "Данные не прочитались. Закройте приложение полностью и откройте снова. "
                        + "До тех пор изменения не сохраняются, чтобы не затереть данные."
                }
            }
        }
        if state.meta == nil { state.meta = Store.bundledMeta }
        if state.units.isEmpty { state.units = Store.firstUnit }   // чистая установка: есть куда добавлять сотрудников
        // техника из версий до 5.1 — без id: даём, иначе ни истории, ни передачи
        var fresh = false
        for i in state.employees.indices {
            if Store.giveIds(&state.employees[i]) { fresh = true }
        }
        if Store.giveIds(&state.storeroom) { fresh = true }
        if fresh { persist() }
        purgeTrash()
        syncReminders()
    }

    static func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    private static var firstUnit: [Dict] {
        [["id": .string(newId()), "name": .string("Филиал"), "parent_id": .null, "order": .number(0)]]
    }

    private func persist() {
        guard !frozen else { return }
        // данные — только в телефоне, поэтому пишем атомарно, чтобы сбой не оставил пол-файла
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }

    /// undoable — удаление: данные до него запоминаются для кнопки «Вернуть». Любая другая правка их забывает.
    private func change(undoable: Bool = false, _ apply: (inout LocalState) -> Void) {
        beforeDelete = undoable ? state : nil
        if undoable { deletions += 1 }
        withAnimation(.snappy) { apply(&state) }
        state.changedAt = Date()
        persist()
        syncReminders()
    }

    /// Вернуть то, что удалили последним. false — возвращать уже нечего.
    func undoDelete() -> Bool {
        guard let old = beforeDelete else { return false }
        change { s in
            s.units = old.units
            s.employees = old.employees
            s.entries = old.entries
            s.carts = old.carts
            s.templates = old.templates
            s.storeroom = old.storeroom
            s.deviceLog = old.deviceLog
            s.trash = old.trash                     // из корзины уходит то, что вернули
        }
        return true
    }

    var meta: Meta? { state.meta ?? Store.bundledMeta }

    /// Наступил новый день? Зовётся, когда приложение выходит на экран и в полночь.
    func refreshToday() {
        let t = Dates.text(Date())
        if t != today {
            today = t
            purgeTrash()
        }
    }

    /// Дни рождения и концы гарантии — в напоминания (сами уведомления включаются в настройках).
    func syncReminders() {
        Reminder.planned = plannedReminders()
        Reminder.refresh()
    }

    // ── учёт ────────────────────────────────────────────────────────────────
    static func fio(_ e: Dict) -> String { personName(e) }

    /// «Иванов Иван Петрович» → «Иванов И. П.»; не буквы («Тестов 01») не сокращаются.
    static func short(_ fio: String) -> String {
        let p = fio.split(separator: " ")
        guard p.count > 1, !fio.hasPrefix("(") else { return fio }
        let rest = p.dropFirst().map { w in w.first?.isLetter == true ? "\(w.prefix(1))." : String(w) }
        return ([String(p[0])] + rest).joined(separator: " ")
    }

    static func isDismissed(_ e: Dict) -> Bool { !(e["dismissed"]?.string ?? "").isEmpty }

    private func parent(_ u: Dict) -> String { u["parent_id"]?.string ?? "" }

    private func sortedUnits(_ list: [Dict]) -> [Dict] {
        list.sorted {
            let a = ($0["order"]?.string ?? "0", ($0["name"]?.string ?? "").lowercased())
            let b = ($1["order"]?.string ?? "0", ($1["name"]?.string ?? "").lowercased())
            return (Int(a.0) ?? 0, a.1) < (Int(b.0) ?? 0, b.1)
        }
    }

    /// Подразделения в порядке дерева, с путём «АУП / Отдел …».
    var units: [Unit] {
        let all = state.units
        let ids = Set(all.compactMap { $0["id"]?.string })
        var out: [Unit] = []
        func walk(_ pid: String, _ depth: Int, _ path: String) {
            for u in sortedUnits(all.filter { parent($0) == pid }) {
                let id = u["id"]?.string ?? "", name = u["name"]?.string ?? ""
                let p = path.isEmpty ? name : path + " / " + name
                out.append(Unit(id: id, name: name, depth: depth, path: p, parent: pid))
                walk(id, depth + 1, p)
            }
        }
        for root in sortedUnits(all.filter { !ids.contains(parent($0)) }) {
            let id = root["id"]?.string ?? "", name = root["name"]?.string ?? ""
            out.append(Unit(id: id, name: name, depth: 0, path: name))
            walk(id, 1, name)
        }
        return out
    }

    var rootUnit: String { units.first?.id ?? "" }

    /// Куда можно вложить подразделение: все, кроме него самого и вложенных в него (новому — любое).
    func parents(for id: String) -> [Unit] {
        let all = units
        guard let i = all.firstIndex(where: { $0.id == id }) else { return all }
        // units идут в порядке дерева: вложенные стоят сразу за подразделением и глубже него
        let end = all[(i + 1)...].firstIndex { $0.depth <= all[i].depth } ?? all.count
        return Array(all[..<i]) + Array(all[end...])
    }

    /// Подразделение и все вложенные в него.
    private func unitTree(_ id: String) -> Set<String> {
        let all = units
        guard let i = all.firstIndex(where: { $0.id == id }) else { return [id] }
        let end = all[(i + 1)...].firstIndex { $0.depth <= all[i].depth } ?? all.count
        return Set(all[i..<end].map(\.id))
    }

    /// Сохранить подразделение: новое (id пустой), переименование или перенос (parent пуст — верхний уровень).
    func saveUnit(id: String, name rawName: String, parent: String) throws {
        let name = rawName.split(separator: " ").joined(separator: " ")
        guard !name.isEmpty else { throw APIError(message: "Укажите название подразделения.") }
        guard parent.isEmpty || parents(for: id).contains(where: { $0.id == parent }) else {
            throw APIError(message: "Подразделение нельзя вложить в само себя или в то, что в него входит.")
        }
        change { s in
            let siblings = s.units.filter { ($0["parent_id"]?.string ?? "") == parent && $0["id"]?.string != id }
            let last = Double((siblings.compactMap { Int($0["order"]?.string ?? "") }.max() ?? -1) + 1)
            let pid: JSON = parent.isEmpty ? .null : .string(parent)
            if let i = s.units.firstIndex(where: { $0["id"]?.string == id }) {
                if (s.units[i]["parent_id"]?.string ?? "") != parent {      // перенесли — встаёт в конец нового места
                    s.units[i]["parent_id"] = pid
                    s.units[i]["order"] = .number(last)
                }
                s.units[i]["name"] = .string(name)
            } else {
                s.units.append(["id": .string(Store.newId()), "name": .string(name), "parent_id": pid,
                                "order": .number(last)])
            }
        }
    }

    /// Удалить можно только пустое подразделение: без сотрудников и без вложенных.
    func deleteUnit(_ id: String) throws {
        guard !state.employees.contains(where: { $0["unit_id"]?.string == id }) else {
            throw APIError(message: "В подразделении есть сотрудники (может быть, уволенные). Сначала переведите их в другое.")
        }
        guard !state.units.contains(where: { parent($0) == id }) else {
            throw APIError(message: "Сначала удалите или перенесите вложенные подразделения.")
        }
        guard state.units.count > 1 else { throw APIError(message: "Должно остаться хотя бы одно подразделение.") }
        guard let u = state.units.first(where: { $0["id"]?.string == id }) else { return }
        let item = trashed("unit", u["name"]?.string ?? "", "подразделение", .object(u))
        change(undoable: true) { s in
            s.units.removeAll { $0["id"]?.string == id }
            s.trash.append(item)
        }
    }

    /// Карточка подразделения: считаются и вложенные; уволенные — нет.
    func unitStats(_ unitId: String) -> UnitStats {
        let ids = unitTree(unitId)
        let staff = state.employees.filter { ids.contains($0["unit_id"]?.string ?? "") && !Store.isDismissed($0) }
        var s = UnitStats()
        s.people = staff.sorted { Store.fio($0).lowercased() < Store.fio($1).lowercased() }
        let devs = staff.flatMap { devices(in: $0, holder: $0["id"]?.string ?? "") }
        for g in meta?.device_order ?? Store.deviceGroups {
            let n = devs.filter { $0.group == g }.count
            if n > 0 { s.devices.append((title: meta?.devices[g]?.title ?? g, count: n)) }
        }
        s.withTrouble = staff.filter { trouble($0) > 0 }.count
        s.old = devs.filter { (Store.age($0.item, today: today) ?? 0) >= 5 }.count
        let month = String(today.prefix(7))
        let names = Set(staff.map { Store.fio($0).lowercased() })
        s.entries = state.entries.filter { $0.date.hasPrefix(month) && names.contains(($0.employee ?? "").lowercased()) }.count
        let people = Set(staff.compactMap { $0["id"]?.string })
        s.carts = state.carts.filter { $0.issued_at.hasPrefix(month) && people.contains($0.employee_id ?? "") }
            .reduce(0) { $0 + $1.qty }
        return s
    }

    func employee(_ id: String) -> Dict? { state.employees.first { $0["id"]?.string == id } }

    /// Работающие сотрудники подразделения: руководитель первым, дальше ручной порядок и ФИО.
    func employees(in unitId: String, matching query: String) -> [Dict] {
        let path = units.first { $0.id == unitId }?.path ?? ""
        return found(state.employees.filter { $0["unit_id"]?.string == unitId && !Store.isDismissed($0) }, path, query)
    }

    /// Сотрудники, чьего подразделения нет в списке (чужой или старый бэкап). В учёте идут отдельной группой:
    /// иначе их не видно и карточку не открыть.
    func strays(matching query: String) -> [Dict] {
        let known = Set(units.map(\.id))
        return found(state.employees.filter { !known.contains($0["unit_id"]?.string ?? "") && !Store.isDismissed($0) },
                     "", query)
    }

    /// Уволенные — в архиве учёта, свежие увольнения первыми.
    func dismissed(matching query: String) -> [Dict] {
        found(state.employees.filter { Store.isDismissed($0) }, "", query)
            .sorted { ($0["dismissed"]?.string ?? "") > ($1["dismissed"]?.string ?? "") }
    }

    var activeCount: Int { state.employees.filter { !Store.isDismissed($0) }.count }

    private func found(_ list: [Dict], _ path: String, _ query: String) -> [Dict] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        return list
            .filter { e in
                guard !tokens.isEmpty else { return true }
                let hay = (Store.fio(e) + " " + path + " " + Store.searchText(.object(e))).lowercased()
                return tokens.allSatisfy { hay.contains($0) }
            }
            .sorted {
                let a = ($0["is_head"]?.bool == true ? 0 : 1, Int($0["order"]?.string ?? "0") ?? 0, Store.fio($0).lowercased())
                let b = ($1["is_head"]?.bool == true ? 0 : 1, Int($1["order"]?.string ?? "0") ?? 0, Store.fio($1).lowercased())
                return a < b
            }
    }

    private static let searchSkip: Set<String> = ["id", "unit_id", "order", "updated", "onboarding"]
    private static let searchFlags = ["is_laptop": "ноутбук моноблок", "is_head": "руководитель начальник"]

    /// Все данные карточки одной строкой — как assets.search_text на сервере.
    static func searchText(_ v: JSON, key: String = "") -> String {
        switch v {
        case .object(let o): return o.filter { !searchSkip.contains($0.key) }
            .map { searchText($0.value, key: $0.key) }.joined(separator: " ")
        case .array(let a): return a.map { searchText($0, key: key) }.joined(separator: " ")
        case .bool(let b): return b ? (searchFlags[key] ?? key) : ""
        case .null: return ""
        default: return v.string
        }
    }

    func newEmployee(unitId: String) -> Dict {
        ["id": .string(Store.newId()),
         "last_name": .string(""), "first_name": .string(""), "middle_name": .string(""),
         "position": .string(""), "floor": .string(""), "office": .string(""), "building": .string(""),
         "account": .string(""), "unit_id": .string(unitId.isEmpty ? rootUnit : unitId), "is_head": .bool(false),
         "phone": .string(""), "email": .string(""), "birthday": .string(""),
         "pcs": .array([]), "monitors": .array([]), "phones": .array([]), "printers": .array([]),
         "mouse": .object(["condition": .string(meta?.conditions.first ?? "рабочее")]),
         "keyboard": .object(["condition": .string(meta?.conditions.first ?? "рабочее")]),
         "onboarding": .array(checklist.map { JSON.object(["step": .string($0), "done": .bool(false)]) }),
         "notes": .string(""), "updated": .string("")]
    }

    /// Сохранить карточку (новую или правку). Возвращает сохранённую. Новая техника попадает в историю,
    /// убранная из карточки — в корзину.
    @discardableResult
    func saveEmployee(_ d: Dict) -> Dict {
        var emp = d
        for k in ["last_name", "first_name", "middle_name", "position", "account", "building", "floor", "office", "notes",
                  "phone", "email"] where emp[k] != nil {
            emp[k] = .string((emp[k]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        emp["fio"] = nil
        emp["hint"] = nil
        emp["updated"] = .string(Dates.stamp.string(from: Date()))
        let id = emp["id"]?.string ?? ""
        let unit = emp["unit_id"]?.string ?? ""
        Store.giveIds(&emp)
        // устройство, которое уже у другого (карточка открыта со старыми данными), здесь не сохраняем — без двойников
        let elsewhere = Set(allDevices.filter { $0.holder != id }.map(\.id))
        for g in Store.deviceGroups {
            if let list = emp[g]?.array { emp[g] = .array(list.filter { !elsewhere.contains($0["id"]?.string ?? "") }) }
        }
        let before = employee(id).map { devices(in: $0, holder: id) } ?? []
        let after = devices(in: emp, holder: id)
        let beforeIds = Set(before.map(\.id)), afterIds = Set(after.map(\.id))
        let fio = Store.fio(emp), day = Dates.text(Date())
        let added = after.filter { !beforeIds.contains($0.id) }
            .map { DeviceEvent(id: Store.newId(), device: $0.id, date: day, kind: "new", text: "Выдан: " + fio) }
        let removed = before.filter { !afterIds.contains($0.id) }.map { d in
            trashed("device", deviceTitle(d), "у " + Store.short(fio), .object(d.item),
                    extra: .object(["holder": .string(id), "group": .string(d.group)]))
        }
        change { s in
            if emp["is_head"]?.bool == true {           // один руководитель на подразделение
                for i in s.employees.indices where s.employees[i]["unit_id"]?.string == unit
                    && s.employees[i]["id"]?.string != id {
                    s.employees[i]["is_head"] = .bool(false)
                }
            }
            if let i = s.employees.firstIndex(where: { $0["id"]?.string == id }) {
                s.employees[i] = emp
            } else {
                var e = emp
                let sibs = s.employees.filter { $0["unit_id"]?.string == unit }
                e["order"] = .number(Double((sibs.compactMap { Int($0["order"]?.string ?? "") }.max() ?? -1) + 1))
                s.employees.append(e)
            }
            s.deviceLog.append(contentsOf: added)
            s.trash.append(contentsOf: removed)
        }
        return emp
    }

    func deleteEmployee(_ id: String) {
        guard let e = employee(id) else { return }
        let n = devices(of: id).count
        let unit = units.first { $0.id == e["unit_id"]?.string }?.path ?? ""
        let item = trashed("employee", Store.fio(e),
                           [unit, n > 0 ? "техника: \(n)" : ""].filter { !$0.isEmpty }.joined(separator: " · "), .object(e))
        change(undoable: true) { s in
            s.employees.removeAll { $0["id"]?.string == id }
            s.trash.append(item)
        }
    }

    /// Уволить: сотрудник уходит в архив учёта, его техника ждёт возврата, история остаётся.
    func dismiss(_ id: String, on date: Date) {
        guard let e = employee(id) else { return }
        let devs = devices(of: id), fio = Store.fio(e), day = Dates.text(date)
        change { s in
            guard let i = s.employees.firstIndex(where: { $0["id"]?.string == id }) else { return }
            s.employees[i]["dismissed"] = .string(day)
            s.employees[i]["is_head"] = .bool(false)
            s.employees[i]["onboarding"] = nil
            s.employees[i]["updated"] = .string(Dates.stamp.string(from: Date()))
            s.deviceLog.append(contentsOf: devs.map {
                DeviceEvent(id: Store.newId(), device: $0.id, date: day, kind: "fired",
                            text: "Владелец уволен: \(fio) — вернуть технику")
            })
        }
    }

    /// Отметки чек-листа нового сотрудника сохраняются сразу — это список дел, а не правка карточки.
    func setOnboarding(_ id: String, _ steps: [JSON]) {
        change { s in
            guard let i = s.employees.firstIndex(where: { $0["id"]?.string == id }) else { return }
            s.employees[i]["onboarding"] = .array(steps)
        }
    }

    /// Вернуть уволенного на работу.
    func rehire(_ id: String) {
        change { s in
            guard let i = s.employees.firstIndex(where: { $0["id"]?.string == id }) else { return }
            s.employees[i]["dismissed"] = nil
            s.employees[i]["updated"] = .string(Dates.stamp.string(from: Date()))
        }
    }

    // ── техника ─────────────────────────────────────────────────────────────
    /// Каждому устройству — свой id: по нему ведутся история, передача и корзина. true — что-то добавили.
    @discardableResult
    static func giveIds(_ holder: inout Dict) -> Bool {
        var changed = false
        for g in deviceGroups {
            var list = holder[g]?.array ?? []
            var touched = false
            for i in list.indices {
                guard case .object(var o) = list[i], (o["id"]?.string ?? "").isEmpty else { continue }
                o["id"] = .string(newId())
                list[i] = .object(o)
                touched = true
            }
            if touched {
                holder[g] = .array(list)
                changed = true
            }
        }
        return changed
    }

    private func devices(in holder: Dict, holder holderId: String) -> [DeviceRef] {
        Store.deviceGroups.flatMap { g in
            (holder[g]?.array ?? []).compactMap { j -> DeviceRef? in
                let o = j.object
                guard let id = o["id"]?.string, !id.isEmpty else { return nil }
                return DeviceRef(id: id, group: g, holder: holderId, item: o)
            }
        }
    }

    /// Вся техника: у сотрудников (и уволенных — пока не сдали) и на складе.
    var allDevices: [DeviceRef] {
        state.employees.flatMap { devices(in: $0, holder: $0["id"]?.string ?? "") }
            + devices(in: state.storeroom, holder: "")
    }

    /// Техника сотрудника или склада (holder пустой).
    func devices(of holder: String) -> [DeviceRef] {
        if holder.isEmpty { return devices(in: state.storeroom, holder: "") }
        return employee(holder).map { devices(in: $0, holder: holder) } ?? []
    }

    func device(_ id: String) -> DeviceRef? { allDevices.first { $0.id == id } }

    func holderName(_ holder: String) -> String {
        holder.isEmpty ? "Склад" : (employee(holder).map { Store.short(Store.fio($0)) } ?? "удалённый сотрудник")
    }

    /// «Принтер · HP LaserJet»
    func deviceTitle(_ d: DeviceRef) -> String {
        let spec = meta?.devices[d.group]
        return (spec?.singular ?? d.group) + Store.deviceSummary(d.item, spec)
    }

    /// « · HP LaserJet»: первое заполненное текстовое поле устройства.
    static func deviceSummary(_ item: Dict, _ spec: DeviceSpec?) -> String {
        guard let spec else { return "" }
        let first = spec.fields.lazy.filter { $0.kind != "check" && $0.kind != "combo" }
            .map { item[$0.key]?.string ?? "" }.first { !$0.isEmpty }
        return first.map { " · " + $0 } ?? ""
    }

    /// Сколько дней до конца гарантии (меньше нуля — кончилась); nil — дата не указана.
    static func warrantyDays(_ item: Dict, today: String) -> Int? {
        guard let end = Dates.iso.date(from: item["warranty"]?.string ?? ""), let now = Dates.iso.date(from: today) else {
            return nil
        }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: now, to: end).day
    }

    /// Полных лет с покупки; nil — дата не указана.
    static func age(_ item: Dict, today: String) -> Int? {
        guard let b = Dates.iso.date(from: item["bought"]?.string ?? ""), let now = Dates.iso.date(from: today) else {
            return nil
        }
        return Calendar(identifier: .gregorian).dateComponents([.year], from: b, to: now).year
    }

    /// История устройства: события и заявки отчёта по нему, свежие первыми.
    func history(of id: String) -> [HistoryLine] {
        let icons = ["new": "plus.circle.fill", "move": "arrow.left.arrow.right.circle.fill",
                     "fired": "person.crop.circle.badge.xmark", "back": "arrow.uturn.backward.circle.fill"]
        let events = state.deviceLog.filter { $0.device == id }.map {
            HistoryLine(id: $0.id, date: $0.date, icon: icons[$0.kind] ?? "circle.fill", text: $0.text)
        }
        let repairs = state.entries.filter { $0.device == id }.map { e in
            HistoryLine(id: e.uid, date: e.date, icon: "wrench.and.screwdriver.fill", text: Store.entryTitle(e),
                        detail: [e.actions, e.result].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " → "))
        }
        return (events + repairs).enumerated()
            .sorted { ($0.element.date, $0.offset) > ($1.element.date, $1.offset) }
            .map(\.element)
    }

    /// Передать устройство сотруднику или на склад (holder пустой). В истории — отметка, от кого к кому.
    func transfer(_ id: String, to holder: String) throws {
        guard let d = device(id) else { throw APIError(message: "Устройство не найдено — возможно, его уже удалили.") }
        guard d.holder != holder else { return }
        if !holder.isEmpty {
            guard let e = employee(holder) else { throw APIError(message: "Сотрудник не найден.") }
            guard !Store.isDismissed(e) else {
                throw APIError(message: "Этот сотрудник уволен — передайте технику другому или на склад.")
            }
        }
        let text = "Передан: " + holderName(d.holder) + " → " + holderName(holder)
        let stamp = Dates.stamp.string(from: Date())
        change { s in
            Store.take(id, from: &s, holder: d.holder)
            Store.put(.object(d.item), group: d.group, into: &s, holder: holder)
            for h in [d.holder, holder] where !h.isEmpty {
                if let i = s.employees.firstIndex(where: { $0["id"]?.string == h }) { s.employees[i]["updated"] = .string(stamp) }
            }
            s.deviceLog.append(DeviceEvent(id: Store.newId(), device: id, date: Dates.text(Date()), kind: "move", text: text))
        }
    }

    /// Уволенный сдал технику: вся она — на склад.
    func returnAll(_ holder: String) {
        for d in devices(of: holder) { try? transfer(d.id, to: "") }
    }

    private static func take(_ id: String, from s: inout LocalState, holder: String) {
        func strip(_ h: inout Dict) {
            for g in deviceGroups {
                let list = h[g]?.array ?? []
                let kept = list.filter { $0["id"]?.string != id }
                if kept.count != list.count { h[g] = .array(kept) }
            }
        }
        if holder.isEmpty {
            strip(&s.storeroom)
        } else if let i = s.employees.firstIndex(where: { $0["id"]?.string == holder }) {
            strip(&s.employees[i])
        }
    }

    /// Положить устройство к владельцу; владельца нет — на склад.
    private static func put(_ item: JSON, group: String, into s: inout LocalState, holder: String) {
        if !holder.isEmpty, let i = s.employees.firstIndex(where: { $0["id"]?.string == holder }) {
            s.employees[i][group] = .array((s.employees[i][group]?.array ?? []) + [item])
        } else {
            s.storeroom[group] = .array((s.storeroom[group]?.array ?? []) + [item])
        }
    }

    /// Техника того, на кого записана заявка (если ФИО совпало ровно с одним сотрудником).
    func devices(forFio fio: String) -> [DeviceRef] {
        let want = fio.split(separator: " ").joined(separator: " ").lowercased()
        guard !want.isEmpty else { return [] }
        let match = state.employees.filter { Store.fio($0).lowercased() == want }
        guard match.count == 1, let id = match[0]["id"]?.string else { return [] }
        return devices(of: id)
    }

    /// Возраст парка по дате покупки: вся техника, и на складе тоже.
    func fleetAge() -> FleetAge {
        var f = FleetAge()
        let all = allDevices
        for d in all {
            switch Store.age(d.item, today: today) {
            case nil: f.unknown += 1
            case let y? where y < 3: f.young += 1
            case let y? where y < 5: f.middle += 1
            default: f.old += 1
            }
        }
        f.oldest = Array(all.filter { (Store.age($0.item, today: today) ?? 0) >= 5 }
            .sorted { ($0.item["bought"]?.string ?? "") < ($1.item["bought"]?.string ?? "") }
            .prefix(5))
        return f
    }

    // ── дни рождения и напоминания ──────────────────────────────────────────
    /// Ближайший такой же день (месяц и число) начиная с сегодня. 29 февраля в обычный год — 1 марта.
    private static func nextDay(_ md: DateComponents, from today: Date, _ cal: Calendar) -> Date? {
        var c = DateComponents()
        c.month = md.month
        c.day = md.day
        if cal.date(today, matchesComponents: c) { return today }
        return cal.nextDate(after: today, matching: c, matchingPolicy: .nextTimePreservingSmallerComponents)
    }

    /// Дни рождения в ближайшие days дней (0 — только сегодня), у работающих.
    func birthdays(within days: Int) -> [Birthday] {
        let cal = Calendar(identifier: .gregorian), start = cal.startOfDay(for: Date())
        return state.employees.filter { !Store.isDismissed($0) }.compactMap { e -> Birthday? in
            guard let b = Dates.iso.date(from: e["birthday"]?.string ?? ""),
                  let day = Store.nextDay(cal.dateComponents([.month, .day], from: b), from: start, cal) else { return nil }
            let left = cal.dateComponents([.day], from: start, to: day).day ?? 0
            return left <= days ? Birthday(id: e["id"]?.string ?? "", fio: Store.fio(e), day: day, days: left) : nil
        }
        .sorted { ($0.days, $0.fio) < ($1.days, $1.fio) }
    }

    private func plannedReminders() -> [Reminder.Planned] {
        let cal = Calendar(identifier: .gregorian), start = cal.startOfDay(for: Date())
        var out: [Reminder.Planned] = []
        for e in state.employees where !Store.isDismissed(e) {
            guard let b = Dates.iso.date(from: e["birthday"]?.string ?? ""),
                  let day = Store.nextDay(cal.dateComponents([.month, .day], from: b), from: start, cal),
                  let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { continue }
            out.append(Reminder.Planned(id: "birthday-" + (e["id"]?.string ?? ""), fire: fire, kind: .birthday,
                                        title: "День рождения", body: "Сегодня день рождения: \(Store.fio(e))"))
        }
        for d in allDevices {
            let w = d.item["warranty"]?.string ?? ""
            guard let end = Dates.iso.date(from: w), let before = cal.date(byAdding: .day, value: -30, to: end),
                  let fire = cal.date(bySettingHour: 10, minute: 0, second: 0, of: before) else { continue }
            out.append(Reminder.Planned(id: "warranty-" + d.id, fire: fire, kind: .warranty,
                                        title: "Через месяц кончается гарантия",
                                        body: "\(deviceTitle(d)) — \(holderName(d.holder)). Гарантия до \(Readable.date(w))."))
        }
        return out
    }

    // ── чек-лист нового сотрудника ──────────────────────────────────────────
    static let defaultChecklist = ["Создать учётную запись и почту", "Выдать и настроить компьютер", "Подключить принтер",
                                   "Добавить в группы и сетевые папки"]

    var checklist: [String] { state.checklist ?? Store.defaultChecklist }

    func setChecklist(_ list: [String]) {
        let clean = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard clean != checklist else { return }
        change { s in s.checklist = clean }
    }

    /// Чек-лист закрыт: отмеченное уходит в отчёт одной заявкой, чек-лист из карточки убирается.
    @discardableResult
    func finishOnboarding(_ e: Dict) throws -> Dict {
        let done = (e["onboarding"]?.array ?? []).filter { $0["done"]?.bool == true }
            .map { $0["step"]?.string ?? "" }.filter { !$0.isEmpty }
        guard !done.isEmpty else { throw APIError(message: "Отметьте хотя бы один пункт чек-листа.") }
        var emp = e
        emp["onboarding"] = nil
        let saved = saveEmployee(emp)
        try saveEntry(uid: nil, date: Dates.workday(Date()), employee: Store.fio(saved),
                      description: "Подготовка рабочего места для нового сотрудника",
                      actions: done.joined(separator: "; "), result: "Рабочее место готово")
        return saved
    }

    // ── отчёт ───────────────────────────────────────────────────────────────
    func entries(week monday: Date) -> [Entry] {
        let from = Dates.text(monday)
        let to = Dates.text(Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: monday)!)
        return state.entries.filter { $0.date >= from && $0.date <= to }
    }

    static func entryTitle(_ e: Entry) -> String {
        [e.description, e.actions, e.result].compactMap { $0 }.first { !$0.isEmpty } ?? "Запись без текста"
    }

    /// Подсказки для «Сотрудник / объект»: частые прошлые значения, потом работающие сотрудники из учёта.
    var employeeSuggestions: [String] {
        var freq: [String: Int] = [:]
        for e in state.entries {
            let v = (e.employee ?? "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { freq[v, default: 0] += 1 }
        }
        var out = freq.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        var seen = Set(out)
        for e in state.employees where !Store.isDismissed(e) {
            let f = Store.fio(e)
            if !f.hasPrefix("("), seen.insert(f).inserted { out.append(f) }
        }
        return out
    }

    func saveEntry(uid: String?, date: Date, employee: String, description: String,
                   actions: String, result: String, device: String = "") throws {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let f = [t(employee), t(description), t(actions), t(result)]
        guard f.contains(where: { !$0.isEmpty }) else { throw APIError(message: "Заполните хотя бы одно поле.") }
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: date)
        guard (2...6).contains(wd) else { throw APIError(message: "Выберите день с понедельника по пятницу.") }
        let id = uid ?? String(Store.newId().prefix(8))
        let entry = Entry(uid: id, date: Dates.text(date), employee: f[0], description: f[1], actions: f[2], result: f[3],
                          device: device.isEmpty ? nil : device)
        change { s in
            if let i = s.entries.firstIndex(where: { $0.uid == id }) { s.entries[i] = entry } else { s.entries.append(entry) }
        }
    }

    func deleteEntries(_ uids: [String]) {
        let items = state.entries.filter { uids.contains($0.uid) }.map { e in
            trashed("entry", Store.entryTitle(e),
                    [Readable.date(e.date), e.employee ?? ""].filter { !$0.isEmpty }.joined(separator: " · "), asJSON(e))
        }
        change(undoable: true) { s in
            s.entries.removeAll { uids.contains($0.uid) }
            s.trash.append(contentsOf: items)
        }
    }

    /// Поиск по всему отчёту: в записи должны встретиться все слова запроса (дата — как «05.11.2026»).
    /// Свежие первыми.
    func searchEntries(_ query: String) -> [Entry] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        return state.entries
            .filter { e in
                let hay = [e.employee, e.description, e.actions, e.result, Readable.date(e.date)]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                return tokens.allSatisfy { hay.contains($0) }
            }
            .sorted { $0.date > $1.date }
    }

    /// Заявки отчёта на этого человека (по ФИО, как оно записано в отчёте), свежие первыми.
    func entryHistory(_ fio: String) -> [Entry] {
        let name = fio.lowercased()
        return state.entries.filter { ($0.employee ?? "").lowercased() == name }.sorted { $0.date > $1.date }
    }

    /// Сводка за период: prefix — «2026» или «2026-11», как начинаются даты записей и выдач.
    func summary(_ prefix: String) -> Summary {
        func top(_ counts: [String: Int]) -> [Summary.Top] {
            counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)
                .map { Summary.Top(name: $0.key, count: $0.value) }
        }
        let entries = state.entries.filter { $0.date.hasPrefix(prefix) }
        let carts = state.carts.filter { $0.issued_at.hasPrefix(prefix) }
        var who: [String: Int] = [:], what: [String: Int] = [:], units: [String: Int] = [:], models: [String: Int] = [:]
        for e in entries {
            let person = (e.employee ?? "").trimmingCharacters(in: .whitespaces)
            let problem = (e.description ?? "").trimmingCharacters(in: .whitespaces)
            if !person.isEmpty { who[person, default: 0] += 1 }
            if !problem.isEmpty { what[problem, default: 0] += 1 }
        }
        let byId = Dictionary(everyone.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in carts {
            let unit = byId[c.employee_id ?? ""]?.unit ?? ""
            units[unit.isEmpty ? "Без отдела" : unit, default: 0] += c.qty
            models[c.model, default: 0] += c.qty
        }
        var s = Summary(entries: entries.count, carts: carts.reduce(0) { $0 + $1.qty }, people: who.count,
                        byPerson: top(who), byProblem: top(what), byUnit: top(units), byModel: top(models))
        if prefix.count == 4 {                             // год: заявки по месяцам
            s.byMonth = (1...12).map { m in
                entries.filter { $0.date.dropFirst(5).hasPrefix(String(format: "%02d", m)) }.count
            }
        }
        return s
    }

    // ── шаблоны заявок ──────────────────────────────────────────────────────
    var templates: [EntryTemplate] { state.templates ?? EntryTemplate.defaults }

    /// Сохранить шаблон (новый — id пустой). Без названия называется по описанию.
    func saveTemplate(_ t: EntryTemplate) throws {
        let c = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var tpl = EntryTemplate(id: t.id.isEmpty ? Store.newId() : t.id, name: c(t.name),
                                description: c(t.description), actions: c(t.actions), result: c(t.result))
        guard [tpl.description, tpl.actions, tpl.result].contains(where: { !$0.isEmpty }) else {
            throw APIError(message: "Заполните хотя бы одно поле: что случилось, что сделано или итог.")
        }
        if tpl.name.isEmpty {
            tpl.name = String([tpl.description, tpl.actions, tpl.result].first { !$0.isEmpty }!.prefix(40))
        }
        var list = templates
        // новый — сверху: свои шаблоны нужнее, и в меню записи их не надо искать внизу
        if let i = list.firstIndex(where: { $0.id == tpl.id }) { list[i] = tpl } else { list.insert(tpl, at: 0) }
        change { s in s.templates = list }
    }

    /// Шаблон картриджа не удаляется: по нему выдача сама пишет запись в отчёт.
    func deleteTemplates(_ ids: Set<String>) {
        let items = templates.filter { ids.contains($0.id) && $0.id != EntryTemplate.cartridgeId }
            .map { trashed("template", $0.name, "шаблон заявки", asJSON($0)) }
        let list = templates.filter { !ids.contains($0.id) || $0.id == EntryTemplate.cartridgeId }
        change(undoable: true) { s in
            s.templates = list
            s.trash.append(contentsOf: items)
        }
    }

    func moveTemplates(from: IndexSet, to: Int) {
        var list = templates
        list.move(fromOffsets: from, toOffset: to)
        change { s in s.templates = list }
    }

    /// Запись отчёта, которую выдача картриджа добавила сама, — по номеру выдачи.
    static func cartEntryId(_ cartId: Int) -> String { "cart\(cartId)" }

    // ── картриджи ───────────────────────────────────────────────────────────
    private func persons(_ list: [Dict]) -> [Person] {
        let all = units
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // единственное подразделение верхнего уровня — сама организация, отделом её не называем;
        // если их несколько, каждое — отдел
        let org = all.filter { $0.depth == 0 }.count == 1
        return list
            .filter { e in ["last_name", "first_name", "middle_name"].contains { !(e[$0]?.string ?? "").isEmpty } }
            .map { e in
                let u = byId[e["unit_id"]?.string ?? ""]
                let unit = u.map { org && $0.depth == 0 ? "" : $0.name } ?? ""
                return Person(id: e["id"]?.string ?? "", fio: Store.fio(e), unit: unit)
            }
            .sorted { $0.fio.lowercased() < $1.fio.lowercased() }
    }

    /// Работающие сотрудники — им выдают картриджи (как cartridges.people).
    var people: [Person] { persons(state.employees.filter { !Store.isDismissed($0) }) }

    /// Все из учёта, и уволенные: по ним показываются прошлые выдачи.
    private var everyone: [Person] { persons(state.employees) }

    /// Модели, которые уже выдавались, — частые первыми.
    var models: [String] {
        var sum: [String: Int] = [:]
        for c in state.carts where !c.model.isEmpty { sum[c.model, default: 0] += c.qty }
        return sum.sorted { ($0.value, $1.key.lowercased()) > ($1.value, $0.key.lowercased()) }.map(\.key)
    }

    func carts(year: Int, month: Int, query: String) -> (items: [CartItem], label: String) {
        let prefix = month == 0 ? String(format: "%04d-", year) : String(format: "%04d-%02d-", year, month)
        let label = month == 0 ? "\(year) год" : "\(Dates.months[month - 1]) \(year)"
        let byId = Dictionary(everyone.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        let items = state.carts
            .filter { $0.issued_at.hasPrefix(prefix) }
            .sorted { ($0.issued_at, $0.id) > ($1.issued_at, $1.id) }
            .map { r -> CartItem in
                let p = byId[r.employee_id ?? ""]
                return CartItem(id: r.id, date: r.issued_at, employee: p?.fio ?? (r.employee ?? ""),
                                unit: p?.unit ?? "", model: r.model, qty: r.qty, note: r.note ?? "")
            }
            .filter { it in
                let hay = [it.employee, it.unit, it.model, it.note].joined(separator: " ").lowercased()
                return tokens.allSatisfy { hay.contains($0) }
            }
        return (items, label)
    }

    /// Кого имели в виду (как cartridges.find_people): полное ФИО — точно, иначе по началам слов.
    func findPeople(_ text: String) -> [Person] {
        let want = text.split(separator: " ").joined(separator: " ").lowercased()
        guard !want.isEmpty else { return [] }
        let all = people
        let exact = all.filter { $0.fio.lowercased() == want }
        if !exact.isEmpty { return exact }
        let tokens = want.split(separator: " ")
        return all.filter { p in
            let words = p.fio.lowercased().split(separator: " ")
            return tokens.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }
    }

    /// Что этот человек брал раньше, свежие выдачи первыми: по сотруднику из учёта, а выдачи, записанные
    /// просто на имя, — по имени.
    private func cartHistory(id: String, name: String) -> [CartRaw] {
        let n = name.lowercased()
        return state.carts
            .filter { c in
                let cid = c.employee_id ?? ""
                return cid.isEmpty ? (c.employee ?? "").lowercased() == n : cid == id
            }
            .sorted { ($0.issued_at, $0.id) > ($1.issued_at, $1.id) }
    }

    /// Для формы выдачи — по тому, что набрано в «Кто забрал». Пусто, пока под набранное подходят
    /// несколько человек: чей картридж, ещё неясно.
    func cartHistory(typed who: String) -> [CartRaw] {
        let name = who.split(separator: " ").joined(separator: " ")
        let people = findPeople(name)
        guard !name.isEmpty, Set(people.map(\.id)).count <= 1 else { return [] }
        return cartHistory(id: people.first?.id ?? "", name: people.first?.fio ?? name)
    }

    /// Картриджи принтеров того, кто набран в «Кто забрал» (если под набранное подходит один человек).
    func printerCartridges(typed who: String) -> [String] {
        let found = findPeople(who)
        guard Set(found.map(\.id)).count == 1, let p = found.first else { return [] }
        var seen = Set<String>()
        return devices(of: p.id).filter { $0.group == "printers" }.compactMap { d -> String? in
            let c = (d.item["cartridge"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            return c.isEmpty || !seen.insert(c.lowercased()).inserted ? nil : c
        }
    }

    /// Для карточки сотрудника.
    func cartHistory(of e: Dict) -> [CartRaw] { cartHistory(id: e["id"]?.string ?? "", name: Store.fio(e)) }

    /// Отметить выдачу или поправить (id ≠ 0). Возвращает текст для плашки.
    func saveCart(id: Int, date: Date, employee: String, model rawModel: String, qty: Int, note: String,
                  allowUnknown: Bool) throws -> String {
        let old = id != 0 ? state.carts.first(where: { $0.id == id }) : nil
        if id != 0 && old == nil { throw APIError(message: "Запись не найдена — возможно, её уже удалили.") }
        let who = employee.split(separator: " ").joined(separator: " ")
        guard !who.isEmpty else { throw APIError(message: "Укажите, кто забрал картридж.") }
        guard Dates.text(date) <= Dates.text(Date()) else {
            throw APIError(message: "Дата выдачи ещё не наступила — проверьте дату.")
        }
        var model = rawModel.split(separator: " ").joined(separator: " ")
        guard !model.isEmpty else { throw APIError(message: "Укажите картридж, например «285».") }
        guard (1...999).contains(qty) else { throw APIError(message: "Количество — целое число от 1.") }
        let found = findPeople(who)
        if Set(found.map { $0.fio.lowercased() }).count > 1 {
            let names = found.prefix(5).map(\.fio).joined(separator: ", ") + (found.count > 5 ? "…" : "")
            throw APIError(message: "По «\(who)» нашлось несколько сотрудников: \(names). Уточните имя.")
        }
        var empId = "", empName = who
        if let p = found.first {
            empId = p.id; empName = p.fio
        } else if let old, (old.employee ?? "").lowercased() == who.lowercased() {
            empId = old.employee_id ?? ""; empName = old.employee ?? who
        } else if !allowUnknown {
            throw APIError(message: "«\(who)» нет в списке сотрудников.\nЗаписать выдачу на это имя?", unknownPerson: true)
        }
        if id == 0, let known = models.first(where: { $0.lowercased() == model.lowercased() }) {
            model = known                                  // «ce285a» и «CE285A» — одна модель
        }
        let newId = id != 0 ? id : (state.carts.map(\.id).max() ?? 0) + 1
        let rec = CartRaw(id: newId, issued_at: Dates.text(date), employee_id: empId, employee: empName,
                          model: model, qty: qty, note: note.split(separator: " ").joined(separator: " "))
        // выдача — законченная заявка в отчёте на того же сотрудника
        let uid = Store.cartEntryId(newId), day = Dates.text(Dates.workday(date))
        let t = templates.first { $0.id == EntryTemplate.cartridgeId } ?? EntryTemplate.defaults[0]
        change { s in
            if let i = s.carts.firstIndex(where: { $0.id == newId }) { s.carts[i] = rec } else { s.carts.append(rec) }
            let i = s.entries.firstIndex { $0.uid == uid }
            if let old {
                // правка выдачи двигает заявку только за тем, что в выдаче поменяли: день или сотрудника.
                // Иначе правка количества возвращала бы на место заявку, которую поправили в отчёте руками.
                if let i {
                    if old.issued_at != rec.issued_at { s.entries[i].date = day }
                    if old.employee != rec.employee { s.entries[i].employee = empName }
                }
            } else {
                let e = Entry(uid: uid, date: day, employee: empName, description: t.description,
                              actions: t.actions, result: t.result)
                if let i { s.entries[i] = e } else { s.entries.append(e) }
            }
        }
        return "\(empName) — \(model), \(qty) шт." + (id == 0 ? "\nЗаявка добавлена в отчёт" : "")
    }

    /// Вместе с выдачей уходит и заявка, которую она добавила в отчёт.
    func deleteCarts(_ ids: [Int]) {
        let uids = ids.map { Store.cartEntryId($0) }
        let byId = Dictionary(everyone.map { ($0.id, $0.fio) }, uniquingKeysWith: { a, _ in a })
        let items = state.carts.filter { ids.contains($0.id) }.map { c -> TrashItem in
            let auto = state.entries.first { $0.uid == Store.cartEntryId(c.id) }
            let who = byId[c.employee_id ?? ""] ?? (c.employee ?? "")
            return trashed("cart", "\(c.model) × \(c.qty)",
                           [who, Readable.date(c.issued_at)].filter { !$0.isEmpty }.joined(separator: " · "),
                           asJSON(c), extra: auto.map { asJSON($0) })
        }
        change(undoable: true) { s in
            s.carts.removeAll { ids.contains($0.id) }
            s.entries.removeAll { uids.contains($0.uid) }
            s.trash.append(contentsOf: items)
        }
    }

    /// Записи недели в порядке отчёта: по дням, внутри дня — как добавлялись.
    func reportEntries(week monday: Date) -> [Entry] {
        entries(week: monday).enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
    }

    // ── корзина ─────────────────────────────────────────────────────────────
    private func trashed(_ kind: String, _ title: String, _ subtitle: String, _ payload: JSON,
                         extra: JSON? = nil) -> TrashItem {
        TrashItem(id: Store.newId(), kind: kind, deleted: Date(), title: title.isEmpty ? "Без названия" : title,
                  subtitle: subtitle, payload: payload, extra: extra)
    }

    /// Удалённое старше 30 дней уходит насовсем.
    private func purgeTrash() {
        let limit = Date().addingTimeInterval(-30 * 24 * 3600)
        guard state.trash.contains(where: { $0.deleted < limit }) else { return }
        state.trash.removeAll { $0.deleted < limit }
        persist()
    }

    func emptyTrash() {
        change { s in s.trash = [] }
    }

    /// Вернуть из корзины. Возвращает текст для плашки.
    func restore(trash id: String) throws -> String {
        guard let t = state.trash.first(where: { $0.id == id }) else { throw APIError(message: "В корзине этого уже нет.") }
        let broken = APIError(message: "Это в корзине повреждено — вернуть не получится.")
        switch t.kind {
        case "entry":
            guard let e = fromJSON(t.payload, as: Entry.self) else { throw broken }
            guard !state.entries.contains(where: { $0.uid == e.uid }) else {
                throw APIError(message: "Эта запись уже есть в отчёте.")
            }
            change { s in
                s.entries.append(e)
                s.trash.removeAll { $0.id == id }
            }
            return "Запись вернулась в отчёт"
        case "employee":
            var e = t.payload.object
            guard let eid = e["id"]?.string, !eid.isEmpty else { throw broken }
            guard employee(eid) == nil else { throw APIError(message: "Этот сотрудник уже есть в учёте.") }
            // его технику за это время могли вернуть отдельно — без двойников
            let taken = Set(allDevices.map(\.id))
            for g in Store.deviceGroups {
                if let list = e[g]?.array { e[g] = .array(list.filter { !taken.contains($0["id"]?.string ?? "") }) }
            }
            Store.giveIds(&e)
            change { s in
                s.employees.append(e)
                s.trash.removeAll { $0.id == id }
            }
            return "Сотрудник вернулся в учёт"
        case "cart":
            guard var c = fromJSON(t.payload, as: CartRaw.self) else { throw broken }
            var auto = t.extra.flatMap { fromJSON($0, as: Entry.self) }
            if state.carts.contains(where: { $0.id == c.id }) {       // номер успели занять — даём новый
                c.id = (state.carts.map(\.id).max() ?? 0) + 1
                if let a = auto {
                    auto = Entry(uid: Store.cartEntryId(c.id), date: a.date, employee: a.employee,
                                 description: a.description, actions: a.actions, result: a.result, device: a.device)
                }
            }
            change { s in
                s.carts.append(c)
                if let a = auto, !s.entries.contains(where: { $0.uid == a.uid }) { s.entries.append(a) }
                s.trash.removeAll { $0.id == id }
            }
            return "Выдача вернулась"
        case "template":
            guard let tpl = fromJSON(t.payload, as: EntryTemplate.self) else { throw broken }
            var list = templates
            if !list.contains(where: { $0.id == tpl.id }) { list.insert(tpl, at: 0) }
            change { s in
                s.templates = list
                s.trash.removeAll { $0.id == id }
            }
            return "Шаблон вернулся"
        case "unit":
            let u = t.payload.object
            guard let uid = u["id"]?.string, !uid.isEmpty else { throw broken }
            change { s in
                if !s.units.contains(where: { $0["id"]?.string == uid }) { s.units.append(u) }
                s.trash.removeAll { $0.id == id }
            }
            return "Подразделение вернулось"
        case "device":
            let did = t.payload["id"]?.string ?? ""
            guard !did.isEmpty else { throw broken }
            guard device(did) == nil else { throw APIError(message: "Это устройство уже есть в учёте.") }
            let group = t.extra?["group"]?.string ?? "pcs"
            var holder = t.extra?["holder"]?.string ?? ""
            // владельца удалили или уволили — устройство возвращается на склад
            if !holder.isEmpty, employee(holder).map({ Store.isDismissed($0) }) ?? true { holder = "" }
            let name = holderName(holder)
            change { s in
                Store.put(t.payload, group: group, into: &s, holder: holder)
                s.deviceLog.append(DeviceEvent(id: Store.newId(), device: did, date: Dates.text(Date()), kind: "back",
                                               text: "Вернули из корзины: \(name)"))
                s.trash.removeAll { $0.id == id }
            }
            return holder.isEmpty ? "Устройство вернулось на склад" : "Устройство вернулось: \(name)"
        default:
            throw broken
        }
    }

    // ── бэкап в телеграм ────────────────────────────────────────────────────
    var backupDue: Bool {
        guard let last = state.lastBackup else { return true }
        switch state.backupEvery {
        case "day": return Dates.text(last) != Dates.text(Date())
        // после изменений, но не чаще раза в 10 минут: иначе каждое сворачивание приложения слало бы файл
        case "change": return (state.changedAt ?? .distantPast) > last && Date().timeIntervalSince(last) > 10 * 60
        default: return Date().timeIntervalSince(last) > 7 * 24 * 3600
        }
    }

    /// Пора проверить, что последний бэкап в группе читается: раз в месяц.
    var checkDue: Bool {
        guard !state.backupFileId.isEmpty else { return false }
        guard let last = state.lastCheck else { return true }
        return Date().timeIntervalSince(last) > 30 * 24 * 3600
    }

    var isEmpty: Bool { state.employees.isEmpty && state.entries.isEmpty && state.carts.isEmpty }

    func setBackup(token: String, chat: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != state.backupToken || c != state.backupChat else { return }     // без перемен файл не трогаем
        state.backupToken = t
        state.backupChat = c
        persist()
    }

    func setBackupEvery(_ every: String) {
        guard every != state.backupEvery else { return }
        state.backupEvery = every
        persist()
    }

    func setBackupEncrypt(_ on: Bool) {
        guard on != state.backupEncrypt else { return }
        state.backupEncrypt = on
        persist()
    }

    func backupFile() -> BackupFile {
        BackupFile(note: BackupFile.readme, app: "REPORTER", exported_at: Dates.stamp.string(from: Date()), meta: meta,
                   units: state.units, employees: state.employees, entries: state.entries, cartridges: state.carts,
                   templates: state.templates, storeroom: state.storeroom, device_log: state.deviceLog,
                   checklist: state.checklist)
    }

    /// По расписанию при открытии и сворачивании (или по кнопке): Excel для чтения и JSON для восстановления —
    /// в группу. С шифрованием — один зашифрованный файл: Excel без пароля прочитал бы любой в группе.
    func backup(force: Bool = false) async {
        guard !backingUp, force || backupDue else { return }
        guard !state.backupToken.isEmpty, !state.backupChat.isEmpty else {
            if force { backupStatus = "Укажите токен бота и ID группы." }
            return
        }
        guard !isEmpty else {
            if force { backupStatus = "Пока нечего сохранять — данных нет." }
            return
        }
        let password = Keychain.get(BackupCrypto.passwordKey)
        if state.backupEncrypt && password.count < 8 {
            backupStatus = "Бэкап не отправлен: шифрование включено, а пароль бэкапа короче 8 знаков."
            return
        }
        backingUp = true
        defer { backingUp = false }
        let b = backupFile()
        let day = Dates.text(Date())
        do {
            let json = try b.json()
            let fileId: String
            if state.backupEncrypt {
                // замки паролем и ключом из письма: PBKDF2 на каждый — не в главном потоке, экран не замирает
                let secrets = [password, Keychain.get(RecoveryKey.keychain)]
                let sealed = try await Task.detached { try BackupCrypto.encrypt(json, secrets: secrets) }.value
                fileId = try await Telegram.send(token: state.backupToken, chat: state.backupChat, file: sealed,
                                                 name: "REPORTER_бэкап_\(day).reporter", mime: "application/octet-stream",
                                                 caption: "REPORTER · бэкап \(b.exported_at ?? day), зашифрован\n\(b.stats)\n"
                                                    + "Восстановить: Настройки → «Восстановить из бэкапа», нужен пароль "
                                                    + "бэкапа или ключ восстановления из письма.")
            } else {
                try await Telegram.send(token: state.backupToken, chat: state.backupChat, file: Readable.xlsx(b),
                                        name: "REPORTER_бэкап_\(day).xlsx",
                                        mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                        caption: "REPORTER · бэкап \(b.exported_at ?? day)\n\(b.stats)\n"
                                            + "Excel — чтобы читать, JSON — чтобы восстановить в приложении.")
                fileId = try await Telegram.send(token: state.backupToken, chat: state.backupChat, file: json,
                                                 name: "REPORTER_бэкап_\(day).json", mime: "application/json", caption: nil)
            }
            state.lastBackup = Date()
            state.backupFileId = fileId
            state.backupSent = b.stats
            persist()
            backupStatus = "Бэкап отправлен в группу"
        } catch {
            backupStatus = "Бэкап не отправлен: \(error.localizedDescription)"
        }
    }

    /// Скачать последний бэкап из группы и прочитать его, как при восстановлении: раз в месяц или по кнопке.
    func verifyBackup(force: Bool = false) async {
        guard !checking, !backingUp, force || checkDue else { return }
        guard !state.backupToken.isEmpty, !state.backupFileId.isEmpty else {
            if force { backupStatus = "Проверять пока нечего: сначала отправьте бэкап." }
            return
        }
        checking = true
        defer { checking = false }
        let expected = state.backupSent
        do {
            var data = try await Telegram.download(token: state.backupToken, fileId: state.backupFileId)
            if BackupCrypto.isEncrypted(data) {
                let sealed = data, secrets = [Keychain.get(BackupCrypto.passwordKey), Keychain.get(RecoveryKey.keychain)]
                data = try await Task.detached { try BackupCrypto.decrypt(sealed, secrets: secrets) }.value
            }
            let b = try BackupFile.read(data)
            state.checkOK = expected.isEmpty || b.stats == expected
            state.checkResult = state.checkOK ? "Бэкап от \(b.exported_at ?? "?") читается: \(b.stats)"
                : "Бэкап читается, но в нём не всё: \(b.stats), а отправляли \(expected)"
        } catch is URLError {
            // нет связи — это не про бэкап: проверим в следующий раз
            if force { backupStatus = "Нет связи с Telegram — проверьте интернет и попробуйте ещё раз." }
            return
        } catch {
            state.checkOK = false
            state.checkResult = "Бэкап не прочитался: \(error.localizedDescription)"
        }
        state.lastCheck = Date()
        persist()
        if force { backupStatus = state.checkResult }
    }

    /// Заменить все данные в телефоне данными из бэкапа. Настройки бота остаются.
    func restore(_ b: BackupFile) {
        frozen = false                 // данные заменяют целиком — беречь непрочитанный файл больше незачем
        change { s in
            if let m = b.meta { s.meta = m }
            s.units = b.units.isEmpty ? Store.firstUnit : b.units
            s.employees = b.employees
            s.entries = b.entries
            s.carts = b.cartridges
            if let t = b.templates { s.templates = t }      // в старых бэкапах шаблонов нет — остаются свои
            s.storeroom = b.storeroom ?? [:]
            s.deviceLog = b.device_log ?? []
            if let c = b.checklist { s.checklist = c }
            for i in s.employees.indices { Store.giveIds(&s.employees[i]) }
            Store.giveIds(&s.storeroom)
        }
        restores += 1
        backupStatus = "Восстановлено: \(b.stats)"
    }
}
