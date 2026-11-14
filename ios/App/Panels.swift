import AVFoundation
import LocalAuthentication
import Speech
import SwiftUI
import UniformTypeIdentifiers

// ── поиск по всему приложению ───────────────────────────────────────────────
/// Люди, техника, записи, картриджи, сеть — одним запросом. Сотрудник и запись открываются на своей вкладке.
struct GlobalSearchView: View {
    @Binding var tab: AppTab
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var device: DeviceRef?
    @State private var copied: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                let t = query.trimmingCharacters(in: .whitespaces).lowercased()
                if t.count >= 2 {
                    results(t)
                } else {
                    Text("Сотрудники, техника, записи, картриджи и сеть — всё сразу. Наберите хотя бы две буквы.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Найти везде")
            .searchFocused($focused)
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .sheet(item: $device) { d in DeviceSheet(deviceId: d.id).presentationCornerRadius(24) }
            .toast($copied)
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                focused = true
            }
        }
    }

    @ViewBuilder private func results(_ t: String) -> some View {
        let people = store.state.employees.filter { e in
            [Store.fio(e), e["position"]?.string ?? "", e["office"]?.string ?? "", e["phone"]?.string ?? "",
             e["email"]?.string ?? "", e["account"]?.string ?? ""].contains { $0.lowercased().contains(t) }
        }
        let devices = store.allDevices.filter { d in
            store.deviceTitle(d).lowercased().contains(t) || d.item.values.contains { $0.string.lowercased().contains(t) }
        }
        let entries = store.searchEntries(t)
        let carts = store.state.carts.filter { $0.model.lowercased().contains(t) || ($0.employee ?? "").lowercased().contains(t) }
        let net = store.state.network.filter { n in n.values.contains { $0.string.lowercased().contains(t) } }
        if people.isEmpty && devices.isEmpty && entries.isEmpty && carts.isEmpty && net.isEmpty { NothingFound() }
        if !people.isEmpty {
            Section("Сотрудники · \(people.count)") {
                ForEach(Array(people.prefix(20)), id: \.["id"]) { e in
                    Button {
                        store.action = .openEmployee(e["id"]?.string ?? "")
                        tab = .assets
                        dismiss()
                    } label: { EmployeeRow(e: e) }
                    .tint(.primary)
                }
            }
        }
        if !devices.isEmpty {
            Section("Техника · \(devices.count)") {
                ForEach(Array(devices.prefix(20))) { d in
                    Button { device = d } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.deviceTitle(d))
                            Text(store.holderName(d.holder)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
        if !entries.isEmpty {
            Section("Записи · \(entries.count)") {
                ForEach(Array(entries.prefix(20))) { e in
                    Button {
                        store.action = .openEntry(e.uid)
                        tab = .report
                        dismiss()
                    } label: { EntryRow(e: e, dated: true) }
                    .tint(.primary)
                }
            }
        }
        if !carts.isEmpty {
            Section("Картриджи · \(carts.count)") {
                ForEach(Array(carts.suffix(20).reversed()), id: \.id) { c in
                    LabeledContent(c.model + " ×\(c.qty)", value: [Readable.date(c.issued_at), c.employee ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
        }
        if !net.isEmpty {
            Section("Сеть · \(net.count)") {
                ForEach(net, id: \.["id"]) { n in
                    let ip = n["ip"]?.string ?? ""
                    Button {
                        UIPasteboard.general.string = ip
                        copied = "IP скопирован"
                    } label: {
                        LabeledContent(n["name"]?.string ?? "Без названия", value: ip)
                    }
                    .tint(.primary)
                    .disabled(ip.isEmpty)
                }
            }
        }
    }
}

// ── сеть: роутеры, коммутаторы, Wi-Fi, серверы, камеры ──────────────────────
enum NetKind: String, CaseIterable {
    case router = "Роутер", switcher = "Коммутатор", wifi = "Точка Wi-Fi", server = "Сервер", camera = "Камера",
         printer = "Принтер", other = "Другое"

    var icon: String {
        switch self {
        case .router: "wifi.router.fill"
        case .switcher: "rectangle.connected.to.line.below"
        case .wifi: "wifi"
        case .server: "server.rack"
        case .camera: "video.fill"
        case .printer: "printer.fill"
        case .other: "network"
        }
    }
}

/// Сеть — в «Учёте». IP и MAC копируются касанием; пароли — в связке ключей iPhone, в бэкап не идут.
struct NetworkView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: Dict?
    @State private var toast: String?

    var body: some View {
        List {
            if store.state.network.isEmpty {
                EmptyState("Сеть пока пуста", systemImage: "network",
                           description: Text("Добавьте роутер, коммутатор, точку Wi-Fi, сервер или камеру кнопкой «+» вверху."))
            }
            ForEach(store.state.network, id: \.["id"]) { n in
                let kind = NetKind(rawValue: n["kind"]?.string ?? "") ?? .other
                Button { editing = n } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.icon).foregroundStyle(Brand.blue).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n["name"]?.string ?? kind.rawValue)
                            Text([n["ip"]?.string ?? "", n["mac"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .contextMenu {
                    copy("IP", n["ip"]?.string ?? "")
                    copy("MAC", n["mac"]?.string ?? "")
                    copy("логин", n["login"]?.string ?? "")
                }
            }
        }
        .navigationTitle("Сеть")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = ["kind": .string(NetKind.router.rawValue)] } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить устройство сети")
            }
        }
        .sheet(item: Binding(get: { editing.map(NetItem.init) }, set: { if $0 == nil { editing = nil } })) { i in
            NetworkEditor(item: i.dict) { toast = $0 }.presentationCornerRadius(24)
        }
        .toast($toast)
    }

    @ViewBuilder private func copy(_ what: String, _ value: String) -> some View {
        if !value.isEmpty {
            Button {
                UIPasteboard.general.string = value
                toast = "Скопировано: \(what)"
            } label: { Label("Скопировать \(what)", systemImage: "doc.on.doc") }
        }
    }

    struct NetItem: Identifiable {
        let dict: Dict
        var id: String { dict["id"]?.string ?? "new" }
    }
}

struct NetworkEditor: View {
    let item: Dict
    let done: (String) -> Void
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var d: Dict
    @State private var password: String
    @State private var copied: String?

    init(item: Dict, done: @escaping (String) -> Void) {
        self.item = item
        self.done = done
        _d = State(initialValue: item)
        _password = State(initialValue: Keychain.get("net." + (item["id"]?.string ?? "")))
    }

    private var isNew: Bool { (item["id"]?.string ?? "").isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Что это", selection: textBinding($d, "kind")) {
                        ForEach(NetKind.allCases, id: \.self) { k in Label(k.rawValue, systemImage: k.icon).tag(k.rawValue) }
                    }
                    TextField("Название, например «Роутер 2 этаж»", text: textBinding($d, "name"))
                }
                Section("Адрес") {
                    copyable("IP-адрес", "ip", .numbersAndPunctuation)
                    copyable("MAC-адрес", "mac", .asciiCapable)
                }
                Section {
                    copyable("Логин", "login", .asciiCapable)
                    SecretField(title: "Пароль", text: $password)
                } header: { Text("Вход") } footer: {
                    Text("Пароль хранится только в связке ключей iPhone и в бэкап не попадает. Показать — по Face ID, сам спрячется "
                         + "через 10 секунд и при записи экрана.")
                }
                Section("Заметка") { TextField("Где стоит, кто провайдер…", text: textBinding($d, "note"), axis: .vertical) }
                if !isNew {
                    Section {
                        Button("Удалить", role: .destructive) {
                            store.deleteNetwork(item["id"]?.string ?? "")
                            done("Удалено")
                            dismiss()
                        }
                    }
                }
            }
            .keyboardDone()
            .navigationTitle(isNew ? "Новое в сети" : (d["name"]?.string ?? "Сеть"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        var x = d
                        if (x["id"]?.string ?? "").isEmpty { x["id"] = .string(Store.newId()) }
                        Keychain.set("net." + (x["id"]?.string ?? ""), password)
                        store.saveNetwork(x)
                        done("Сохранено")
                        dismiss()
                    } label: { Text("Сохранить").bold() }
                }
            }
            .toast($copied)
        }
    }

    private func copyable(_ title: String, _ key: String, _ kb: UIKeyboardType) -> some View {
        HStack {
            TextField(title, text: textBinding($d, key))
                .keyboardType(kb).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body.monospaced())
            if !(d[key]?.string ?? "").isEmpty {
                Button {
                    UIPasteboard.general.string = d[key]?.string ?? ""
                    copied = "Скопировано"
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Скопировать: \(title)")
            }
        }
    }
}

/// Пароль: закрыт точками, показывается по Face ID на 10 секунд; при записи экрана — всегда закрыт.
/// Скопированный пароль живёт в буфере минуту и только на этом iPhone.
struct SecretField: View {
    let title: String
    @Binding var text: String
    @State private var shown = false
    @State private var captured = UIScreen.main.isCaptured

    var body: some View {
        HStack {
            if shown && !captured {
                TextField(title, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
            } else {
                SecureField(title, text: $text)
            }
            Button { Task { await reveal() } } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .accessibilityLabel(shown ? "Скрыть пароль" : "Показать пароль")
            if !text.isEmpty {
                Button {
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                                  options: [.expirationDate: Date().addingTimeInterval(60), .localOnly: true])
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Скопировать пароль")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
        }
    }

    private func reveal() async {
        if shown {
            shown = false
            return
        }
        guard (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Показать пароль")) == true
        else { return }
        shown = true
        try? await Task.sleep(for: .seconds(10))
        shown = false
    }
}

// ── должности: свои значки и цвета ──────────────────────────────────────────
struct PositionsView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: Position?

    var body: some View {
        List {
            Section {
                ForEach(store.positions) { p in
                    Button { editing = p } label: {
                        HStack(spacing: 12) {
                            Image(systemName: p.icon).foregroundStyle(Color(hex: p.color))
                                .frame(width: 36, height: 36).background(Color(hex: p.color).opacity(0.2), in: Circle())
                            Text(p.name)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { idx in
                    var list = store.positions
                    list.remove(atOffsets: idx)
                    store.setPositions(list)
                }
            } footer: {
                Text("Значок должности — аватарка сотрудника в «Учёте». Должность, которой нет в списке, узнаётся по словам "
                     + "(«бухгалтер», «водитель»…); не узнана — серый человечек.")
            }
        }
        .navigationTitle("Должности")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = Position(id: "", name: "", icon: "person.fill", color: 0x3B82F6) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Новая должность")
            }
        }
        .sheet(item: $editing) { p in PositionEditor(position: p).presentationCornerRadius(24) }
    }
}

struct PositionEditor: View {
    let position: Position
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var p: Position

    static let icons = ["briefcase.fill", "briefcase", "banknote.fill", "banknote", "chart.line.uptrend.xyaxis", "desktopcomputer",
                        "laptopcomputer", "chevron.left.forwardslash.chevron.right", "building.columns.fill",
                        "person.text.rectangle.fill", "wrench.and.screwdriver.fill", "hammer.fill", "envelope.fill", "phone.fill",
                        "car.fill", "bus.fill", "shield.fill", "shippingbox.fill", "cart.fill", "stethoscope", "cross.case.fill",
                        "graduationcap.fill", "book.fill", "paintbrush.fill", "camera.fill", "fork.knife", "leaf.fill", "bolt.fill",
                        "star.fill", "person.fill"]
    static let colors: [UInt32] = [0xF59E0B, 0x10B981, 0x3B82F6, 0xA855F7, 0x14B8A6, 0xEAB308, 0xEC4899, 0x6B7280, 0xEF4444, 0xA16207]

    init(position: Position) {
        self.position = position
        _p = State(initialValue: position)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Image(systemName: p.icon).font(.system(size: 34)).foregroundStyle(Color(hex: p.color))
                            .frame(width: 76, height: 76).background(Color(hex: p.color).opacity(0.2), in: Circle())
                            .symbolEffect(.bounce, value: p.icon)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Название") { TextField("Например, Главный инженер", text: $p.name) }
                Section("Значок") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.icons, id: \.self) { i in
                            Image(systemName: i).font(.title3)
                                .frame(width: 42, height: 42)
                                .background(p.icon == i ? Color(hex: p.color).opacity(0.25) : .clear, in: Circle())
                                .onTapGesture { p.icon = i }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(i)
                        }
                    }
                }
                Section("Цвет") {
                    HStack {
                        ForEach(Self.colors, id: \.self) { c in
                            Circle().fill(Color(hex: c)).frame(width: 26, height: 26)
                                .overlay(Circle().stroke(.primary, lineWidth: p.color == c ? 2 : 0).padding(-3))
                                .frame(maxWidth: .infinity)
                                .onTapGesture { p.color = c }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
            }
            .navigationTitle(position.id.isEmpty ? "Новая должность" : "Должность")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        var list = store.positions
                        var x = p
                        x.name = x.name.trimmingCharacters(in: .whitespaces)
                        if x.id.isEmpty { x.id = Store.newId() }
                        if let i = list.firstIndex(where: { $0.id == x.id }) { list[i] = x } else { list.append(x) }
                        store.setPositions(list)
                        dismiss()
                    } label: { Text("Сохранить").bold() }
                    .disabled(p.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Поле «Должность» в карточке: можно выбрать из списка или вписать свою.
struct PositionField: View {
    @Binding var text: String
    @EnvironmentObject private var store: Store

    var body: some View {
        HStack {
            TextField("Должность", text: $text)
            Menu {
                ForEach(store.positions) { p in
                    Button { text = p.name } label: { Label(p.name, systemImage: p.icon) }
                }
            } label: { Image(systemName: "list.bullet.circle") }
            .accessibilityLabel("Выбрать должность из списка")
        }
    }
}

// ── импорт сотрудников из Excel ─────────────────────────────────────────────
struct ImportView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var rows: [Store.ImportRow] = []
    @State private var error: String?
    @State private var done: Int?

    private static let xlsx = UTType(filenameExtension: "xlsx") ?? .data

    var body: some View {
        NavigationStack {
            List {
                if let done {
                    EmptyState("Готово", systemImage: "checkmark", description: Text("Добавлено сотрудников: \(done)."))
                } else if rows.isEmpty {
                    Section {
                        Button { picking = true } label: { Label("Выбрать файл Excel", systemImage: "tablecells") }
                    } footer: {
                        Text("Первая строка — шапка. Узнаю столбцы: ФИО (или Фамилия, Имя, Отчество), Должность, Подразделение, "
                             + "Кабинет, Телефон, Почта, День рождения. Кто уже есть в учёте — пропускаю.")
                    }
                } else {
                    let fresh = rows.filter { !$0.exists }
                    Section {
                        Button { done = store.importEmployees(rows) } label: {
                            Label("Добавить: \(fresh.count)", systemImage: "person.badge.plus")
                        }
                        .disabled(fresh.isEmpty)
                    } footer: {
                        Text("Найдено \(rows.count), уже в учёте \(rows.count - fresh.count).")
                    }
                    Section("Сотрудники из файла") {
                        ForEach(rows) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Store.fio(r.emp))
                                    Text([r.emp["position"]?.string ?? "", r.unit].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if r.exists { Text("уже есть").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Импорт из Excel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [Self.xlsx]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    rows = try store.importPreview(Xlsx.read(Data(contentsOf: url)))
                    if rows.isEmpty { error = "В файле нет сотрудников под шапкой." }
                } catch { self.error = error.localizedDescription }
            }
            .errorAlert($error)
        }
    }
}

// ── проверка данных ─────────────────────────────────────────────────────────
struct AuditView: View {
    @Binding var tab: AppTab
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let issues = store.audit()
            List {
                if issues.isEmpty {
                    EmptyState("Всё в порядке", systemImage: "checkmark.seal",
                               description: Text("Двойников, людей без подразделения и техники без номера нет."))
                }
                ForEach(issues) { i in
                    Button {
                        guard let id = i.employee else { return }
                        store.action = .openEmployee(id)
                        tab = .assets
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.title)
                            Text(i.detail).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Проверка данных")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}

// ── профиль сисадмина и достижения ──────────────────────────────────────────
struct Achievement: Identifiable {
    let id: String
    let title: String
    let icon: String
    let done: Bool

    @MainActor static func all(_ s: Store) -> [Achievement] {
        let e = s.state.entries.count, c = s.state.carts.reduce(0) { $0 + $1.qty }
        let people = s.state.employees.filter { !Store.isDismissed($0) }.count
        return [
            Achievement(id: "first", title: "Первая заявка", icon: "1.circle.fill", done: e >= 1),
            Achievement(id: "e100", title: "100 заявок", icon: "flame.fill", done: e >= 100),
            Achievement(id: "e500", title: "500 заявок", icon: "crown.fill", done: e >= 500),
            Achievement(id: "c50", title: "50 картриджей", icon: "printer.fill", done: c >= 50),
            Achievement(id: "staff20", title: "20 сотрудников", icon: "person.3.fill", done: people >= 20),
            Achievement(id: "streak4", title: "Месяц без пропусков", icon: "calendar.badge.checkmark", done: Streak.count >= 4),
            Achievement(id: "backup", title: "Первый бэкап", icon: "paperplane.fill", done: s.state.lastBackup != nil),
            Achievement(id: "safe", title: "Под защитой", icon: "lock.shield.fill", done: AppLock.isOn && s.state.backupEncrypt),
            Achievement(id: "net", title: "Сеть под контролем", icon: "network", done: s.state.network.count >= 5),
            Achievement(id: "clean", title: "Порядок в данных", icon: "checkmark.seal.fill", done: people >= 5 && s.audit().isEmpty),
        ]
    }
}

struct ProfileView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ach.seen") private var seenRaw = ""

    var body: some View {
        NavigationStack {
            let list = Achievement.all(store)
            let name = UserDefaults.standard.string(forKey: "mail.responsible") ?? ""
            ScrollView {
                VStack(spacing: 18) {
                    PixelBot(mood: .happy).frame(width: 110, height: 110)
                    VStack(spacing: 4) {
                        Text(name.isEmpty ? "Сисадмин" : name).font(.title2.bold())
                        if let since = store.state.entries.map(\.date).min() {
                            Text("в ITdesk с \(Readable.date(since))").foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        let entries = store.state.entries.count, carts = store.state.carts.reduce(0) { $0 + $1.qty }
                        StatCard(title: plural(entries, "заявка", "заявки", "заявок"), value: entries,
                                 icon: "list.bullet.clipboard", color: Brand.blue)
                        StatCard(title: plural(carts, "картридж", "картриджа", "картриджей"), value: carts, icon: "printer.fill",
                                 color: .orange)
                        StatCard(title: "техники", value: store.allDevices.count, icon: "desktopcomputer", color: .teal)
                    }
                    Text("Достижения · \(list.filter(\.done).count) из \(list.count)").font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(list) { a in Medal(a: a, seen: seen.contains(a.id)) { see(a.id) } }
                    }
                }
                .padding(16)
            }
            .background(AppBackground())
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }

    private var seen: Set<String> { Set(seenRaw.split(separator: ",").map(String.init)) }

    private func see(_ id: String) {
        var s = seen
        s.insert(id)
        seenRaw = s.sorted().joined(separator: ",")
    }
}

/// Медаль: закрыта — серая с замком; новая — под фольгой, стираешь пальцем; открытая — с бликом.
private struct Medal: View {
    let a: Achievement
    let seen: Bool
    let onSeen: () -> Void
    @State private var revealed: Bool
    @State private var shine = false

    init(a: Achievement, seen: Bool, onSeen: @escaping () -> Void) {
        self.a = a
        self.seen = seen
        self.onSeen = onSeen
        _revealed = State(initialValue: seen || !a.done)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(a.done ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFDE68A), Color(hex: 0xF59E0B)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                 : AnyShapeStyle(Color.gray.opacity(0.25)))
                Image(systemName: a.done ? a.icon : "lock.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(a.done ? Color(hex: 0x78350F) : .secondary)
                if a.done {
                    // блик пробегает по медали, когда её открыли
                    LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 30)
                        .offset(x: shine ? 50 : -50)
                        .mask(Circle())
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            .modifier(Foil(revealed: $revealed))
            Text(a.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                .foregroundStyle(a.done ? .primary : .secondary)
        }
        .onChange(of: revealed) { _, r in
            guard r else { return }
            onSeen()
            withAnimation(.easeInOut(duration: 0.9)) { shine = true }
        }
        .onAppear {
            if revealed && a.done && !Motion.reduced { withAnimation(.easeInOut(duration: 0.9).delay(0.3)) { shine = true } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a.done ? "Достижение: \(a.title)" : "Пока закрыто: \(a.title)")
    }
}

// ── голосовой ввод заявки ───────────────────────────────────────────────────
/// Распознавание речи на iPhone (если умеет — без интернета) и уровень звука для волны.
@MainActor
final class Dictation: ObservableObject {
    @Published var text = ""
    @Published var levels: [CGFloat] = Array(repeating: 0.05, count: 28)
    @Published var running = false
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))

    func start() async {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else {
            error = "Разрешите распознавание речи: Настройки iPhone → ITdesk."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Разрешите микрофон: Настройки iPhone → ITdesk."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Распознавание речи сейчас недоступно."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // речь не уходит из телефона
            request = req
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
                req.append(buf)
                let lvl = Dictation.level(buf)
                Task { @MainActor in self?.push(lvl) }
            }
            engine.prepare()
            try engine.start()
            running = true
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                let t = result?.bestTranscription.formattedString
                let final = result?.isFinal == true || err != nil
                Task { @MainActor in
                    if let t { self?.text = t }
                    if final { self?.stop() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func push(_ l: CGFloat) {
        levels.removeFirst()
        levels.append(max(0.05, l))
    }

    nonisolated static func level(_ b: AVAudioPCMBuffer) -> CGFloat {
        guard let d = b.floatChannelData?[0], b.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(b.frameLength) { sum += d[i] * d[i] }
        return CGFloat(min(1, sqrt(sum / Float(b.frameLength)) * 14))
    }
}

/// Лист диктовки: волна, текст, «Готово» — текст уходит в заявку.
struct VoiceSheet: View {
    let done: (String) -> Void
    @StateObject private var d = Dictation()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text(d.running ? "Говорите…" : "Диктовка").font(.headline)
            HStack(alignment: .center, spacing: 3) {
                ForEach(d.levels.indices, id: \.self) { i in
                    Capsule().fill(Brand.blue.gradient)
                        .frame(width: 5, height: 6 + d.levels[i] * 60)
                }
            }
            .frame(height: 70)
            .animation(.easeOut(duration: 0.12), value: d.levels)
            Text(d.text.isEmpty ? "Например: «у Сидоровой не печатает принтер»" : d.text)
                .foregroundStyle(d.text.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 60)
            if let e = d.error { Text(e).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
            Button {
                d.stop()
                done(d.text)
                dismiss()
            } label: {
                Text("Готово").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(d.text.isEmpty)
        }
        .padding(24)
        .task { await d.start() }
        .onDisappear { d.stop() }
    }
}
