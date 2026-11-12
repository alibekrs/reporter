import SwiftUI

/// Подразделения: нажать — карточка отдела, «+» — новое, долгое нажатие — удалить пустое.
struct UnitsView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: Unit?
    @State private var opened: Unit?
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                ForEach(store.units) { u in
                    let staff = store.state.employees.filter { $0["unit_id"]?.string == u.id && !Store.isDismissed($0) }.count
                    Button { opened = u } label: {
                        HStack(spacing: 8) {
                            if u.depth > 0 {
                                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, CGFloat(u.depth - 1) * 16)
                            }
                            Text(u.name)
                            Spacer(minLength: 8)
                            Text("\(staff)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .contextMenu {
                        Button(role: .destructive) { delete(u) } label: { Label("Удалить", systemImage: "trash") }
                    }
                }
            } footer: {
                Text("Справа — сколько сотрудников в подразделении. Нажмите — карточка отдела: люди, техника, "
                     + "заявки и картриджи за месяц. Удалить можно только пустое подразделение — долгим нажатием.")
            }
        }
        .animation(.snappy, value: store.units)
        .navigationTitle("Подразделения")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // новое по умолчанию ложится внутрь первого: «Филиал / Бухгалтерия»
                Button { editing = Unit(id: "", name: "", depth: 0, path: "", parent: store.rootUnit) } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Новое подразделение")
            }
        }
        .navigationDestination(item: $editing) { UnitEditor(unit: $0) }
        .navigationDestination(item: $opened) { UnitCard(unitId: $0.id) }
        .errorAlert($error)
        .toast($toast) { if store.undoDelete() { toast = "Возвращено" } }
    }

    private func delete(_ u: Unit) {
        do {
            try store.deleteUnit(u.id)
            toast = Toast.deleted
        } catch { self.error = error.localizedDescription }
    }
}

/// Карточка отдела (с вложенными): сколько людей и техники, заявки и картриджи за месяц, кто работает.
struct UnitCard: View {
    let unitId: String

    @EnvironmentObject private var store: Store
    @State private var editing = false

    var body: some View {
        let unit = store.units.first { $0.id == unitId }
        let s = store.unitStats(unitId)
        let month = Dates.months[(Int(store.today.dropFirst(5).prefix(2)) ?? 1) - 1].lowercased()
        List {
            // путь — только у вложенного: у верхнего уровня он повторял заголовок
            if unit == nil || unit?.path != unit?.name {
                Section {
                    Text(unit?.path ?? "Подразделение удалено").font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                HStack(spacing: 10) {
                    StatCard(title: plural(s.people.count, "сотрудник", "сотрудника", "сотрудников"),
                             value: s.people.count, icon: "person.2.fill", color: Brand.blue)
                    StatCard(title: "техники", value: s.devices.reduce(0) { $0 + $1.count },
                             icon: "desktopcomputer", color: .teal)
                    StatCard(title: "с проблемой", value: s.withTrouble, icon: "exclamationmark.triangle.fill",
                             color: .orange)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section("За \(month)") {
                LabeledContent("Заявок в отчёте") { Text("\(s.entries)").monospacedDigit() }
                LabeledContent("Картриджей выдано") { Text("\(s.carts)").monospacedDigit() }
            }
            if !s.devices.isEmpty {
                Section {
                    ForEach(s.devices.indices, id: \.self) { i in
                        LabeledContent(s.devices[i].title) { Text("\(s.devices[i].count)").monospacedDigit() }
                    }
                    if s.old > 0 {
                        Label("Старше 5 лет: \(s.old)", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                } header: { Text("Техника") }
            }
            Section("Сотрудники") {
                if s.people.isEmpty {
                    Text("Пока никого").foregroundStyle(.secondary)
                }
                ForEach(s.people, id: \.["id"]) { e in EmployeeRow(e: e) }
            }
        }
        .navigationTitle(unit?.name ?? "Подразделение")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Изменить") { editing = true }.disabled(unit == nil)
            }
        }
        .navigationDestination(isPresented: $editing) {
            if let unit { UnitEditor(unit: unit) }
        }
    }
}

struct UnitEditor: View {
    let unit: Unit

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var parent: String
    @State private var error: String?

    init(unit: Unit) {
        self.unit = unit
        _name = State(initialValue: unit.name)
        _parent = State(initialValue: unit.parent)
    }

    var body: some View {
        Form {
            Section("Название") {
                TextField("Например, Бухгалтерия", text: $name)
            }
            Section {
                Picker("Входит в", selection: $parent) {
                    Text("— верхний уровень").tag("")
                    ForEach(store.parents(for: unit.id)) { u in
                        Text(String(repeating: "  ", count: u.depth) + u.name).tag(u.id)
                    }
                }
            } footer: {
                Text("В учёте подразделение показывается внутри выбранного: «Филиал / Бухгалтерия».")
            }
        }
        .keyboardDone()
        .navigationTitle(unit.id.isEmpty ? "Новое подразделение" : "Подразделение")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button { save() } label: { Text("Сохранить").bold() } }
        }
        .errorAlert($error)
    }

    private func save() {
        do {
            try store.saveUnit(id: unit.id, name: name, parent: parent)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
