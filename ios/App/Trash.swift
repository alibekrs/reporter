import SwiftUI

/// Корзина: удалённое за 30 дней — записи, выдачи, сотрудники, техника, шаблоны, подразделения. «Вернуть» кладёт
/// на место; через 30 дней удалённое уходит насовсем.
struct TrashView: View {
    @EnvironmentObject private var store: Store
    @State private var toast: String?
    @State private var error: String?
    @State private var confirmEmpty = false

    private static let icons = ["entry": "list.bullet.clipboard", "employee": "person.fill", "cart": "printer.fill",
                                "template": "text.badge.plus", "unit": "building.2", "device": "desktopcomputer"]

    var body: some View {
        let items = store.state.trash.sorted { $0.deleted > $1.deleted }
        List {
            if items.isEmpty {
                ContentUnavailableView("Корзина пуста", systemImage: "trash",
                                       description: Text("Удалённое хранится здесь 30 дней — его можно вернуть."))
            }
            ForEach(items) { t in
                HStack(spacing: 12) {
                    Image(systemName: Self.icons[t.kind] ?? "doc").foregroundStyle(Brand.blue).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).lineLimit(2)
                        if !t.subtitle.isEmpty { Text(t.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Text(left(t.deleted)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button("Вернуть") { restore(t) }
                        .buttonStyle(.bordered)
                        .tint(Brand.blue)
                        .accessibilityLabel("Вернуть: \(t.title)")
                }
            }
        }
        .animation(.snappy, value: items)
        .navigationTitle("Корзина")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Очистить", role: .destructive) { confirmEmpty = true }.disabled(items.isEmpty)
            }
        }
        .confirmationDialog("Удалить всё из корзины насовсем?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Удалить насовсем", role: .destructive) { store.emptyTrash() }
        } message: {
            Text("Вернуть это будет уже нельзя.")
        }
        .toast($toast)
        .errorAlert($error)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM"
        return f
    }()

    /// «удалено 12.11 · ещё 29 дн.» — в одну строку
    private func left(_ deleted: Date) -> String {
        let gone = Calendar(identifier: .gregorian).dateComponents([.day], from: deleted, to: Date()).day ?? 0
        return "удалено \(Self.day.string(from: deleted)) · ещё \(max(0, 30 - gone)) дн."
    }

    private func restore(_ t: TrashItem) {
        do { toast = try store.restore(trash: t.id) } catch { self.error = error.localizedDescription }
    }
}
