import SwiftUI

/// Подразделения: нажать — переименовать или перенести, «+» — новое, долгое нажатие — удалить пустое.
struct UnitsView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: Unit?
    @State private var error: String?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                ForEach(store.units) { u in
                    let staff = store.state.employees.filter { $0["unit_id"]?.string == u.id }.count
                    Button { editing = u } label: {
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
                Text("Справа — сколько сотрудников в подразделении. Нажмите, чтобы переименовать или перенести. "
                     + "Удалить можно только пустое подразделение — долгим нажатием.")
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
