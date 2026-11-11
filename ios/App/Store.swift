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
    var lastBackup: Date?
    var backupToken = ""
    var backupChat = ""

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
        lastBackup = try c.decodeIfPresent(Date.self, forKey: .lastBackup)
        backupToken = try c.decodeIfPresent(String.self, forKey: .backupToken) ?? ""
        backupChat = try c.decodeIfPresent(String.self, forKey: .backupChat) ?? ""
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

/// Правила записи — как в модулях ITtool (assets.py, reports.py, cartridges.py).
@MainActor
final class Store: ObservableObject {
    @Published private(set) var state = LocalState()
    @Published var backupStatus: String?
    @Published private(set) var backingUp = false
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
        persist()
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
        }
        return true
    }

    var meta: Meta? { state.meta ?? Store.bundledMeta }

    /// Наступил новый день? Зовётся, когда приложение выходит на экран и в полночь.
    func refreshToday() {
        let t = Dates.text(Date())
        if t != today { today = t }
    }

    // ── учёт ────────────────────────────────────────────────────────────────
    static func fio(_ e: Dict) -> String { personName(e) }

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
            throw APIError(message: "В подразделении есть сотрудники. Сначала переведите их в другое.")
        }
        guard !state.units.contains(where: { parent($0) == id }) else {
            throw APIError(message: "Сначала удалите или перенесите вложенные подразделения.")
        }
        guard state.units.count > 1 else { throw APIError(message: "Должно остаться хотя бы одно подразделение.") }
        change(undoable: true) { s in s.units.removeAll { $0["id"]?.string == id } }
    }

    func employee(_ id: String) -> Dict? { state.employees.first { $0["id"]?.string == id } }

    /// Сотрудники подразделения: руководитель первым, дальше ручной порядок и ФИО.
    func employees(in unitId: String, matching query: String) -> [Dict] {
        let path = units.first { $0.id == unitId }?.path ?? ""
        return found(state.employees.filter { $0["unit_id"]?.string == unitId }, path, query)
    }

    /// Сотрудники, чьего подразделения нет в списке (чужой или старый бэкап). В учёте идут отдельной группой:
    /// иначе их не видно и карточку не открыть.
    func strays(matching query: String) -> [Dict] {
        let known = Set(units.map(\.id))
        return found(state.employees.filter { !known.contains($0["unit_id"]?.string ?? "") }, "", query)
    }

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

    private static let searchSkip: Set<String> = ["id", "unit_id", "order", "updated"]
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
         "pcs": .array([]), "monitors": .array([]), "phones": .array([]), "printers": .array([]),
         "mouse": .object(["condition": .string(meta?.conditions.first ?? "рабочее")]),
         "keyboard": .object(["condition": .string(meta?.conditions.first ?? "рабочее")]),
         "notes": .string(""), "updated": .string("")]
    }

    /// Сохранить карточку (новую или правку). Возвращает сохранённую.
    @discardableResult
    func saveEmployee(_ d: Dict) -> Dict {
        var emp = d
        for k in ["last_name", "first_name", "middle_name", "position", "account", "building", "floor", "office", "notes"] {
            emp[k] = .string((emp[k]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        emp["fio"] = nil
        emp["hint"] = nil
        emp["updated"] = .string(Dates.stamp.string(from: Date()))
        let id = emp["id"]?.string ?? ""
        let unit = emp["unit_id"]?.string ?? ""
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
        }
        return emp
    }

    func deleteEmployee(_ id: String) {
        change(undoable: true) { s in
            s.employees.removeAll { $0["id"]?.string == id }
        }
    }

    // ── отчёт ───────────────────────────────────────────────────────────────
    func entries(week monday: Date) -> [Entry] {
        let from = Dates.text(monday)
        let to = Dates.text(Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: monday)!)
        return state.entries.filter { $0.date >= from && $0.date <= to }
    }

    /// Подсказки для «Сотрудник / объект»: частые прошлые значения, потом сотрудники из учёта.
    var employeeSuggestions: [String] {
        var freq: [String: Int] = [:]
        for e in state.entries {
            let v = (e.employee ?? "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { freq[v, default: 0] += 1 }
        }
        var out = freq.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        var seen = Set(out)
        for e in state.employees {
            let f = Store.fio(e)
            if !f.hasPrefix("("), seen.insert(f).inserted { out.append(f) }
        }
        return out
    }

    func saveEntry(uid: String?, date: Date, employee: String, description: String,
                   actions: String, result: String) throws {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let f = [t(employee), t(description), t(actions), t(result)]
        guard f.contains(where: { !$0.isEmpty }) else { throw APIError(message: "Заполните хотя бы одно поле.") }
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: date)
        guard (2...6).contains(wd) else { throw APIError(message: "Выберите день с понедельника по пятницу.") }
        let id = uid ?? String(Store.newId().prefix(8))
        let entry = Entry(uid: id, date: Dates.text(date), employee: f[0], description: f[1], actions: f[2], result: f[3])
        change { s in
            if let i = s.entries.firstIndex(where: { $0.uid == id }) { s.entries[i] = entry } else { s.entries.append(entry) }
        }
    }

    func deleteEntries(_ uids: [String]) {
        change(undoable: true) { s in s.entries.removeAll { uids.contains($0.uid) } }
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
        let byId = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
        let list = templates.filter { !ids.contains($0.id) || $0.id == EntryTemplate.cartridgeId }
        change(undoable: true) { s in s.templates = list }
    }

    func moveTemplates(from: IndexSet, to: Int) {
        var list = templates
        list.move(fromOffsets: from, toOffset: to)
        change { s in s.templates = list }
    }

    /// Запись отчёта, которую выдача картриджа добавила сама, — по номеру выдачи.
    static func cartEntryId(_ cartId: Int) -> String { "cart\(cartId)" }

    // ── картриджи ───────────────────────────────────────────────────────────
    /// Сотрудники из учёта — по ним ведётся счёт выдач (как cartridges.people).
    var people: [Person] {
        let all = units
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // единственное подразделение верхнего уровня — сама организация, отделом её не называем;
        // если их несколько, каждое — отдел
        let org = all.filter { $0.depth == 0 }.count == 1
        return state.employees
            .filter { e in ["last_name", "first_name", "middle_name"].contains { !(e[$0]?.string ?? "").isEmpty } }
            .map { e in
                let u = byId[e["unit_id"]?.string ?? ""]
                let unit = u.map { org && $0.depth == 0 ? "" : $0.name } ?? ""
                return Person(id: e["id"]?.string ?? "", fio: Store.fio(e), unit: unit)
            }
            .sorted { $0.fio.lowercased() < $1.fio.lowercased() }
    }

    /// Модели, которые уже выдавались, — частые первыми.
    var models: [String] {
        var sum: [String: Int] = [:]
        for c in state.carts where !c.model.isEmpty { sum[c.model, default: 0] += c.qty }
        return sum.sorted { ($0.value, $1.key.lowercased()) > ($1.value, $0.key.lowercased()) }.map(\.key)
    }

    func carts(year: Int, month: Int, query: String) -> (items: [CartItem], label: String) {
        let prefix = month == 0 ? String(format: "%04d-", year) : String(format: "%04d-%02d-", year, month)
        let label = month == 0 ? "\(year) год" : "\(Dates.months[month - 1]) \(year)"
        let byId = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
        change(undoable: true) { s in
            s.carts.removeAll { ids.contains($0.id) }
            s.entries.removeAll { uids.contains($0.uid) }
        }
    }

    /// Записи недели в порядке отчёта: по дням, внутри дня — как добавлялись.
    func reportEntries(week monday: Date) -> [Entry] {
        entries(week: monday).enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
    }

    // ── бэкап в телеграм ────────────────────────────────────────────────────
    var backupDue: Bool {
        guard let last = state.lastBackup else { return true }
        return Date().timeIntervalSince(last) > 7 * 24 * 3600
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

    func backupFile() -> BackupFile {
        BackupFile(note: BackupFile.readme, app: "REPORTER", exported_at: Dates.stamp.string(from: Date()), meta: meta,
                   units: state.units, employees: state.employees, entries: state.entries, cartridges: state.carts,
                   templates: state.templates)
    }

    /// Раз в неделю при открытии (или по кнопке): Excel для чтения и JSON для восстановления — в группу.
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
        backingUp = true
        defer { backingUp = false }
        let b = backupFile()
        let day = Dates.text(Date())
        do {
            let json = try b.json()
            try await Telegram.send(token: state.backupToken, chat: state.backupChat, file: Readable.xlsx(b),
                                    name: "REPORTER_бэкап_\(day).xlsx",
                                    mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                    caption: "REPORTER · бэкап \(b.exported_at ?? day)\n\(b.stats)\n"
                                        + "Excel — чтобы читать, JSON — чтобы восстановить в приложении.")
            try await Telegram.send(token: state.backupToken, chat: state.backupChat, file: json,
                                    name: "REPORTER_бэкап_\(day).json", mime: "application/json", caption: nil)
            state.lastBackup = Date()
            persist()
            backupStatus = "Бэкап отправлен в группу"
        } catch {
            backupStatus = "Бэкап не отправлен: \(error.localizedDescription)"
        }
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
        }
        restores += 1
        backupStatus = "Восстановлено: \(b.stats)"
    }
}
