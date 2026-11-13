import SwiftUI

// как Store.deviceGroups; своя копия — глобальная константа не может читать Store, он живёт на главном потоке
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
    /// Строка «Склад» в навигации учёта — не id сотрудника.
    static let storeroomPath = "storeroom"

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
                if id == AssetsView.storeroomPath {
                    StoreroomView()
                } else if let start = store.employee(id) ?? draft, let meta = store.meta {
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
        let stock = store.devices(of: "").count
        let fired = store.dismissed(matching: query)
        return List {
            Section {
                HStack(spacing: 10) {
                    StatCard(title: plural(all.count, "сотрудник", "сотрудника", "сотрудников"),
                             value: all.count, icon: "person.2.fill", color: Brand.blue)
                    StatCard(title: "техники", value: all.reduce(stock) { $0 + deviceCount($1) },
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
            if stock > 0 && query.isEmpty {
                Section {
                    NavigationLink(value: AssetsView.storeroomPath) {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill").font(.title3).foregroundStyle(.brown)
                                .frame(width: 40, height: 40)
                            Text("Склад")
                            Spacer()
                            Text("\(stock)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Техника без хозяина: сданная уволенными или ещё не выданная.")
                }
            }
            if !fired.isEmpty {
                Section("Уволенные") {
                    ForEach(fired, id: \.["id"]) { e in
                        NavigationLink(value: e["id"]?.string ?? "") { EmployeeRow(e: e) }
                    }
                }
            }
            if all.isEmpty && fired.isEmpty {
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

/// Сотрудник — значок его должности в цветном кружке; без должности (подсказки, выбор) — инициалы.
struct Avatar: View {
    let name: String
    var position: String? = nil

    var body: some View {
        if let position {
            let r = Self.role(position)
            Image(systemName: r.icon)
                .font(.system(size: 17))
                .foregroundStyle(r.color)
                .frame(width: 40, height: 40)
                .background(r.color.opacity(0.2), in: Circle())
                .accessibilityLabel(name)
        } else {
            Text(initials)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Brand.gradient, in: Circle())
        }
    }

    /// По словам в должности; порядок важен: «главный бухгалтер» — бухгалтер, а не руководитель.
    static func role(_ position: String) -> (icon: String, color: Color) {
        let p = position.lowercased()
        let rules: [([String], String, Color)] = [
            (["бухгалт", "кассир", "финанс", "экономист"], "banknote.fill", .green),
            (["админ", "программ", "системн", "айти", "it-", "it ", "1с"], "desktopcomputer", .blue),
            (["юрист", "юрисконсульт", "правов"], "building.columns.fill", .purple),
            (["кадр", "hr", "персонал"], "person.text.rectangle.fill", .teal),
            (["водител"], "car.fill", .gray),
            (["инженер", "механик", "электрик", "мастер", "техник"], "wrench.and.screwdriver.fill", .yellow),
            (["секретар", "делопроизв", "офис"], "envelope.fill", .pink),
            (["охран", "сторож"], "shield.fill", .red),
            (["склад", "кладовщ", "снабжен", "завхоз"], "shippingbox.fill", .brown),
            (["директор", "руковод", "начальник", "заведующ", "заместител", "глав"], "briefcase.fill", .orange),
        ]
        for (words, icon, color) in rules where words.contains(where: { p.contains($0) }) { return (icon, color) }
        return ("person.fill", .gray)
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
            Avatar(name: Store.fio(e), position: e["position"]?.string ?? "").opacity(Store.isDismissed(e) ? 0.45 : 1)
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
        if Store.isDismissed(e) {
            let n = deviceCount(e)
            return "уволен \(Readable.date(e["dismissed"]?.string ?? ""))" + (n > 0 ? " · техника не сдана" : "")
        }
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
    @State private var confirmDismiss = false
    @State private var opened: DeviceRef?
    @State private var error: String?

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
                    Avatar(name: Store.fio(emp), position: emp["position"]?.string ?? "").scaleEffect(1.4).padding(8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Store.fio(emp)).font(.headline).contentTransition(.opacity)
                        Text(store.units.first { $0.id == emp["unit_id"]?.string }?.path ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                        if Store.isDismissed(emp) {
                            Text("Уволен \(Readable.date(emp["dismissed"]?.string ?? ""))")
                                .font(.caption.weight(.bold)).foregroundStyle(.orange)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            onboarding
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
                OptionalDateRow(label: "День рождения", value: textBinding($emp, "birthday"))
            }
            Section("Связь") {
                HStack {
                    TextField("Телефон", text: textBinding($emp, "phone")).keyboardType(.phonePad)
                    if let url = telURL {
                        Link(destination: url) { Image(systemName: "phone.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Позвонить")
                    }
                }
                HStack {
                    TextField("Почта", text: textBinding($emp, "email"))
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let url = mailURL {
                        Link(destination: url) { Image(systemName: "envelope.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Написать письмо")
                    }
                }
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
            if !isNew { actions }
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
        } message: {
            Text("Карточка полежит в корзине 30 дней. Если человек просто ушёл — лучше «Уволить»: история останется.")
        }
        .confirmationDialog("Уволить сотрудника?", isPresented: $confirmDismiss, titleVisibility: .visible) {
            let has = !store.devices(of: id).isEmpty || deviceCount(emp) > 0
            if has {
                Button("Уволить, техника — на склад") {
                    commit("Уволен, техника на складе") {
                        store.dismiss(id, on: Date())
                        store.returnAll(id)
                    }
                }
            }
            Button(has ? "Уволить, техника пока за ним" : "Да, уволить") {
                commit("Уволен — карточка в «Уволенных»") { store.dismiss(id, on: Date()) }
            }
        } message: {
            Text("Карточка уйдёт в «Уволенные» внизу учёта, история останется.")
        }
        .sheet(item: $opened, onDismiss: { emp = store.employee(id) ?? emp }) { d in
            DeviceSheet(deviceId: d.id).presentationCornerRadius(24)
        }
        .errorAlert($error)
    }

    // ── чек-лист нового сотрудника ──────────────────────────────────────────
    @ViewBuilder private var onboarding: some View {
        let steps = emp["onboarding"]?.array ?? []
        if !isNew, !steps.isEmpty {
            Section {
                ForEach(steps.indices, id: \.self) { i in
                    let done = steps[i]["done"]?.bool ?? false
                    Button { toggleStep(i) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(done ? Color.green : Color.secondary)
                            Text(steps[i]["step"]?.string ?? "")
                                .strikethrough(done)
                                .foregroundStyle(done ? Color.secondary : Color.primary)
                        }
                    }
                    .tint(.primary)
                    .accessibilityValue(done ? "сделано" : "не сделано")
                }
                Button { finishOnboarding() } label: {
                    Label("Готово — записать в отчёт", systemImage: "checkmark.seal.fill").bold()
                }
                .disabled(!steps.contains { $0["done"]?.bool == true })
            } header: {
                Text("Чек-лист нового сотрудника")
            } footer: {
                Text("Отметки сохраняются сразу. «Готово» записывает сделанное в отчёт и убирает чек-лист из карточки.")
            }
        }
    }

    private func toggleStep(_ i: Int) {
        var steps = emp["onboarding"]?.array ?? []
        guard i < steps.count else { return }
        var o = steps[i].object
        o["done"] = .bool(!(o["done"]?.bool ?? false))
        steps[i] = .object(o)
        withAnimation(.snappy) { emp["onboarding"] = .array(steps) }
        store.setOnboarding(id, steps)
    }

    private func finishOnboarding() {
        hideKeyboard()
        do {
            emp = try store.finishOnboarding(emp)
            onSaved("Чек-лист записан в отчёт")
        } catch { self.error = error.localizedDescription }
    }

    // ── уволить, вернуть, удалить ───────────────────────────────────────────
    @ViewBuilder private var actions: some View {
        Section {
            if Store.isDismissed(emp) {
                if deviceCount(emp) > 0 {
                    Button {
                        commit("Техника — на складе") { store.returnAll(id) }
                    } label: { Label("Технику сдали — всё на склад", systemImage: "shippingbox.and.arrow.backward") }
                }
                Button {
                    commit("Снова в штате") { store.rehire(id) }
                } label: { Label("Вернуть на работу", systemImage: "person.badge.plus") }
            } else {
                Button { confirmDismiss = true } label: { Label("Уволить", systemImage: "person.fill.xmark") }
                    .tint(.orange)
            }
            Button("Удалить сотрудника", role: .destructive) { confirmDelete = true }
        } footer: {
            if Store.isDismissed(emp) {
                Text("Уволенный хранится в архиве учёта вместе с историей. Пока техника не сдана, она числится за ним.")
            }
        }
    }

    /// Сначала сохраняем правки карточки, потом действие над сохранённой — и показываем, что вышло.
    private func commit(_ toast: String, _ op: () -> Void) {
        hideKeyboard()
        emp = store.saveEmployee(emp)
        op()
        emp = store.employee(id) ?? emp
        onSaved(toast)
    }

    private var telURL: URL? {
        let digits = (emp["phone"]?.string ?? "").filter { $0.isNumber || $0 == "+" }
        return digits.count >= 3 ? URL(string: "tel:" + digits) : nil
    }

    private var mailURL: URL? {
        let m = (emp["email"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        return m.contains("@") ? URL(string: "mailto:" + m) : nil
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
                                Text(Store.entryTitle(e)).font(.callout)
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
                    if group == "printers" {
                        LabeledContent("Картридж") {
                            TextField("Например, CF226", text: devText(group, i, "cartridge"))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        }
                    }
                    OptionalDateRow(label: "Куплен", value: devText(group, i, "bought"))
                    OptionalDateRow(label: "Гарантия до", value: devText(group, i, "warranty"))
                    if !isNew, let did = list[i]["id"]?.string, !did.isEmpty {
                        Button { openDevice(did) } label: {
                            Label("История и передача", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    Button("Убрать", role: .destructive) {
                        var arr = list
                        arr.remove(at: i)
                        withAnimation(.snappy) { emp[group] = .array(arr) }
                    }
                } label: {
                    HStack {
                        Circle().fill(condColor(list[i]["condition"]?.string ?? "")).frame(width: 8, height: 8)
                        Text("\(spec.singular) \(i + 1)" + Store.deviceSummary(list[i].object, spec))
                        Spacer(minLength: 4)
                        WarrantyBadge(days: Store.warrantyDays(list[i].object, today: store.today))
                    }
                }
            }
            Button {
                var row: Dict = ["id": .string(Store.newId())]
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

    /// История и передача работают с сохранённым: правки карточки сначала уходят в учёт.
    private func openDevice(_ deviceId: String) {
        hideKeyboard()
        emp = store.saveEmployee(emp)
        opened = store.device(deviceId)
    }

    private func condColor(_ c: String) -> Color {
        switch c {
        case "неисправно": return .red
        case "требует замены": return .orange
        case "отсутствует": return .gray
        default: return .green
        }
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

    private func devText(_ group: String, _ i: Int, _ key: String) -> Binding<String> {
        let b = devBinding(group, i, key)
        return Binding(get: { b.wrappedValue.string }, set: { b.wrappedValue = .string($0) })
    }

    private func partBinding(_ part: String) -> Binding<String> {
        Binding(get: { emp[part]?["condition"]?.string ?? meta.conditions.first ?? "" },
                set: { emp[part] = .object(["condition": .string($0)]) })
    }
}

/// Чек-лист нового сотрудника в настройках: пункты правятся, переставляются и удаляются.
struct ChecklistView: View {
    @EnvironmentObject private var store: Store
    @State private var steps: [Step] = []
    @State private var fresh = ""

    struct Step: Identifiable {
        let id = UUID()
        var text: String
    }

    var body: some View {
        List {
            Section {
                ForEach($steps) { $s in
                    TextField("Пункт", text: $s.text)
                }
                .onDelete { steps.remove(atOffsets: $0) }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("Новый пункт", text: $fresh).onSubmit(add)
                    Button(action: add) { Image(systemName: "plus.circle.fill").font(.title3) }
                        .buttonStyle(.borderless)
                        .disabled(fresh.trimmed.isEmpty)
                        .accessibilityLabel("Добавить пункт")
                }
            } footer: {
                Text("Этот список появляется в карточке каждого нового сотрудника. Сделанное уходит в отчёт одной записью.")
            }
            Section {
                Button("Вернуть стандартный список") {
                    withAnimation(.snappy) { steps = Store.defaultChecklist.map { Step(text: $0) } }
                }
            }
        }
        .navigationTitle("Чек-лист")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .keyboardDone()
        .onAppear { if steps.isEmpty { steps = store.checklist.map { Step(text: $0) } } }
        .onDisappear { store.setChecklist(steps.map(\.text)) }
    }

    private func add() {
        let t = fresh.trimmed
        guard !t.isEmpty else { return }
        withAnimation(.snappy) { steps.append(Step(text: t)) }
        fresh = ""
    }
}
