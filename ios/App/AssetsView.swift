import SwiftUI

private let deviceGroups = ["pcs", "monitors", "phones", "printers"]
private let groupIcons = ["pcs": "desktopcomputer", "monitors": "display", "phones": "phone", "printers": "printer"]

/// 0 — всё рабочее, 1 — что-то требует замены, 2 — что-то неисправно.
func trouble(_ e: Dict) -> Int {
    var conds = deviceGroups.flatMap { g in (e[g]?.array ?? []).map { $0["condition"]?.string ?? "" } }
    conds += ["mouse", "keyboard"].map { e[$0]?["condition"]?.string ?? "" }
    if conds.contains("неисправно") { return 2 }
    return conds.contains("требует замены") ? 1 : 0
}

private func deviceCount(_ e: Dict) -> Int {
    deviceGroups.reduce(0) { $0 + (e[$1]?.array.count ?? 0) }
}

struct AssetsView: View {
    @EnvironmentObject private var store: Store
    @State private var query = ""
    @State private var path: [String] = []
    @State private var draft: Dict?
    @State private var toast: String?
    @State private var searching = false

    var body: some View {
        NavigationStack(path: $path) {
            list
            .navigationTitle("Учёт")
            // со строкой поиска заголовок сначала мелкий, а после первого поиска становился крупным
            // и сдвигал страницу — держим мелким всегда
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let start = store.employee(id) ?? draft, let meta = store.meta {
                    EmployeeView(initial: start, meta: meta) { toast = $0 }
                }
            }
            .toast($toast) { if store.undoDelete() { toast = "Возвращено" } }
        }
        .onChange(of: path) { _, p in store.lockPaging = !p.isEmpty }
        .onChange(of: store.restores) { _, _ in path = [] }     // данные заменили — карточка держала старые
    }

    private struct UnitGroup: Identifiable {
        let unit: Unit
        let emps: [Dict]
        var id: String { unit.id }
    }

    private var list: some View {
        // последней группой — сотрудники, чьего подразделения нет в списке: иначе их не видно и не открыть
        let lost = UnitGroup(unit: Unit(id: "", name: "Без подразделения", depth: 0, path: "Без подразделения"),
                             emps: store.strays(matching: query))
        let groups = (store.units.map { UnitGroup(unit: $0, emps: store.employees(in: $0.id, matching: query)) } + [lost])
            .filter { !$0.emps.isEmpty }
        let all = groups.flatMap(\.emps)
        return List {
            Section {
                HStack(spacing: 10) {
                    StatCard(title: plural(all.count, "сотрудник", "сотрудника", "сотрудников"),
                             value: all.count, icon: "person.2.fill", color: Brand.blue)
                    StatCard(title: "техники", value: all.reduce(0) { $0 + deviceCount($1) },
                             icon: "desktopcomputer", color: .teal)
                    StatCard(title: "с проблемой", value: all.filter { trouble($0) > 0 }.count,
                             icon: "exclamationmark.triangle.fill", color: .orange)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.emps, id: \.["id"]) { e in
                        NavigationLink(value: e["id"]?.string ?? "") { EmployeeRow(e: e) }
                    }
                } header: {
                    HStack {
                        Text(g.unit.path)
                        Spacer()
                        Text("\(g.emps.count)").monospacedDigit()
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Brand.blue.opacity(0.15), in: Capsule())
                    }
                }
            }
            if all.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("Учёт пуст", systemImage: "person.crop.rectangle.stack",
                                           description: Text("Добавьте первого сотрудника кнопкой «+»."))
                } else {
                    NothingFound()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .clearsBar(add: true)
        .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "ФИО, кабинет, IP, модель…")
        .scrollDismissesKeyboard(.immediately)
        .animation(.snappy, value: query)
        .task(id: store.action) {
            switch store.action {
            case .findEmployee:
                // вкладка успела появиться — открываем поиск; пришло другое действие — его не трогаем
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                store.action = nil
                path = []
                searching = true
            case .newEmployee:
                store.action = nil
                let d = store.newEmployee(unitId: store.rootUnit)
                draft = d
                path.append(d["id"]?.string ?? "")
            default:
                break
            }
        }
    }
}

struct Avatar: View {
    let name: String

    var body: some View {
        Text(initials)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Brand.gradient, in: Circle())
    }

    private var initials: String {
        guard !name.hasPrefix("(") else { return "?" }
        let s = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

struct EmployeeRow: View {
    let e: Dict

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: Store.fio(e))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(Store.fio(e)).lineLimit(1)
                    if e["is_head"]?.bool == true {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Brand.sun)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            let t = trouble(e)
            if t > 0 {
                Image(systemName: t == 2 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(t == 2 ? .red : .orange)
                    .symbolEffect(.pulse, options: .repeating, isActive: t == 2)
            }
            let n = deviceCount(e)
            if n > 0 {
                Label("\(n)", systemImage: "desktopcomputer")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let office = e["office"]?.string ?? ""
        let parts: [String] = [e["position"]?.string ?? "", office.isEmpty ? "" : "каб. " + office]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct EmployeeView: View {
    let meta: Meta
    let onSaved: (String) -> Void

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var emp: Dict
    @State private var confirmDelete = false

    init(initial: Dict, meta: Meta, onSaved: @escaping (String) -> Void) {
        _emp = State(initialValue: initial)
        self.meta = meta
        self.onSaved = onSaved
    }

    private var id: String { emp["id"]?.string ?? "" }
    private var isNew: Bool { store.employee(id) == nil }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Avatar(name: Store.fio(emp)).scaleEffect(1.4).padding(8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Store.fio(emp)).font(.headline).contentTransition(.opacity)
                        Text(store.units.first { $0.id == emp["unit_id"]?.string }?.path ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            if !isNew { history }
            Section("Сотрудник") {
                TextField("Фамилия", text: textBinding($emp, "last_name"))
                TextField("Имя", text: textBinding($emp, "first_name"))
                TextField("Отчество", text: textBinding($emp, "middle_name"))
                TextField("Должность", text: textBinding($emp, "position"))
                Picker("Подразделение", selection: textBinding($emp, "unit_id")) {
                    ForEach(store.units) { u in
                        Text(String(repeating: "  ", count: u.depth) + u.name).tag(u.id)
                    }
                }
                Toggle("Руководитель", isOn: Binding(get: { emp["is_head"]?.bool ?? false },
                                                    set: { emp["is_head"] = .bool($0) }))
            }
            Section("Место и учётка") {
                TextField("Здание", text: textBinding($emp, "building"))
                TextField("Этаж", text: textBinding($emp, "floor"))
                TextField("Кабинет", text: textBinding($emp, "office"))
                TextField("Учётная запись", text: textBinding($emp, "account"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            ForEach(meta.device_order, id: \.self) { group in
                if let spec = meta.devices[group] { devices(group, spec) }
            }
            Section("Мышь и клавиатура") {
                ChoicePicker(label: "Мышь", values: meta.conditions, selection: partBinding("mouse"))
                ChoicePicker(label: "Клавиатура", values: meta.conditions, selection: partBinding("keyboard"))
            }
            Section("Заметки") {
                TextField("Заметки", text: textBinding($emp, "notes"), axis: .vertical).lineLimit(2...8)
            }
            if let upd = emp["updated"]?.string, !upd.isEmpty {
                Section { Text("Изменено: " + upd).font(.caption).foregroundStyle(.secondary) }
            }
            if !isNew {
                Section {
                    Button("Удалить сотрудника", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .clearsBar()
        .keyboardDone()
        .navigationTitle(isNew ? "Новый сотрудник" : Store.fio(emp))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                hideKeyboard()                              // сохранили — клавиатура не нужна, панель возвращается
                let wasNew = isNew
                emp = store.saveEmployee(emp)
                onSaved(wasNew ? "Сотрудник добавлен" : "Сохранено")
            } label: { Text("Сохранить").bold() }
        }
        .confirmationDialog("Удалить сотрудника и всю его технику?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                store.deleteEmployee(id)
                onSaved(Toast.deleted)
                dismiss()
            }
        }
    }

    /// История сотрудника: какие картриджи он брал и какие заявки на него записаны. Считается по
    /// сохранённой карточке — по её ФИО сделаны записи отчёта.
    @ViewBuilder private var history: some View {
        let saved = store.employee(id) ?? emp
        let carts = store.cartHistory(of: saved), entries = store.entryHistory(Store.fio(saved))
        let issued = carts.reduce(0) { $0 + $1.qty }
        if !carts.isEmpty || !entries.isEmpty {
            Section {
                if !carts.isEmpty {
                    DisclosureGroup {
                        ForEach(carts.prefix(10), id: \.id) { c in
                            LabeledContent("\(c.model) × \(c.qty)") { Text(Readable.date(c.issued_at)) }
                        }
                    } label: {
                        Label("Картриджи: \(issued) шт.", systemImage: "printer.fill")
                    }
                }
                if !entries.isEmpty {
                    DisclosureGroup {
                        ForEach(entries.prefix(10)) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text([e.description, e.actions, e.result].compactMap { $0 }.first { !$0.isEmpty } ?? "—")
                                    .font(.callout)
                                Text(Readable.date(e.date)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        Label("Заявки: \(entries.count)", systemImage: "list.bullet.clipboard")
                    }
                }
            } header: { Text("История") } footer: {
                if carts.count > 10 || entries.count > 10 { Text("Показаны последние десять.") }
            }
        }
    }

    @ViewBuilder
    private func devices(_ group: String, _ spec: DeviceSpec) -> some View {
        let list = emp[group]?.array ?? []
        Section {
            ForEach(list.indices, id: \.self) { i in
                DisclosureGroup {
                    ForEach(spec.fields, id: \.self) { f in fieldView(f, devBinding(group, i, f.key)) }
                    Button("Убрать", role: .destructive) {
                        var arr = list
                        arr.remove(at: i)
                        withAnimation(.snappy) { emp[group] = .array(arr) }
                    }
                } label: {
                    HStack {
                        Circle().fill(condColor(list[i]["condition"]?.string ?? "")).frame(width: 8, height: 8)
                        Text("\(spec.singular) \(i + 1)" + summary(list[i], spec))
                    }
                }
            }
            Button {
                var row: Dict = [:]
                for f in spec.fields {
                    row[f.key] = f.kind == "check" ? .bool(false)
                        : .string(f.kind == "combo" ? meta.conditions.first ?? "" : "")
                }
                withAnimation(.snappy) { emp[group] = .array(list + [.object(row)]) }
            } label: {
                Label("Добавить: " + spec.singular.lowercased(), systemImage: "plus.circle.fill")
            }
        } header: {
            Label(spec.title, systemImage: groupIcons[group] ?? "shippingbox")
        }
    }

    private func condColor(_ c: String) -> Color {
        switch c {
        case "неисправно": return .red
        case "требует замены": return .orange
        case "отсутствует": return .gray
        default: return .green
        }
    }

    private func summary(_ dev: JSON, _ spec: DeviceSpec) -> String {
        let first = spec.fields.lazy.filter { $0.kind != "check" && $0.kind != "combo" }
            .map { dev[$0.key]?.string ?? "" }.first { !$0.isEmpty }
        return first.map { " · " + $0 } ?? ""
    }

    @ViewBuilder
    private func fieldView(_ f: Field, _ b: Binding<JSON>) -> some View {
        let str = Binding(get: { b.wrappedValue.string }, set: { b.wrappedValue = .string($0) })
        switch f.kind {
        case "check":
            Toggle(f.label, isOn: Binding(get: { b.wrappedValue.bool }, set: { b.wrappedValue = .bool($0) }))
        case "combo":
            ChoicePicker(label: f.label, values: meta.conditions, selection: str)
        default:
            if f.values.isEmpty {
                LabeledContent(f.label) {
                    TextField(f.label, text: str).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } else {
                ChoicePicker(label: f.label, values: f.values, selection: str)
            }
        }
    }

    private func devBinding(_ group: String, _ i: Int, _ key: String) -> Binding<JSON> {
        Binding(get: {
            let arr = emp[group]?.array ?? []
            return i < arr.count ? (arr[i][key] ?? .null) : .null
        }, set: { v in
            var arr = emp[group]?.array ?? []
            guard i < arr.count else { return }
            var row = arr[i].object
            row[key] = v
            arr[i] = .object(row)
            emp[group] = .array(arr)
        })
    }

    private func partBinding(_ part: String) -> Binding<String> {
        Binding(get: { emp[part]?["condition"]?.string ?? meta.conditions.first ?? "" },
                set: { emp[part] = .object(["condition": .string($0)]) })
    }
}
