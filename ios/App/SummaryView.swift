import SwiftUI

/// Сводка за месяц или год: сколько заявок и картриджей, кто и с чем обращается чаще.
struct SummaryView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var yearly = false
    @State private var day = Date()               // любой день показанного периода

    private static let letters = ["Я", "Ф", "М", "А", "М", "И", "И", "А", "С", "О", "Н", "Д"]

    var body: some View {
        let p = Dates.yearMonth(day)
        let s = store.summary(yearly ? String(format: "%04d", p.year) : String(format: "%04d-%02d", p.year, p.month))
        NavigationStack {
            List {
                Section {
                    Picker("Период", selection: $yearly) {
                        Text("Месяц").tag(false)
                        Text("Год").tag(true)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Button { shift(-1) } label: { Image(systemName: "chevron.left.circle.fill").font(.title2) }
                            .accessibilityLabel("Раньше")
                        Spacer()
                        Text(yearly ? "\(String(p.year)) год" : "\(Dates.months[p.month - 1]) \(String(p.year))")
                            .font(.headline.monospacedDigit())
                        Spacer()
                        Button { shift(1) } label: { Image(systemName: "chevron.right.circle.fill").font(.title2) }
                            .accessibilityLabel("Позже")
                    }
                    .buttonStyle(.borderless)
                }
                // цифры — отдельной группой: в одной с переключателем у его карточки пропадали нижние углы
                Section {
                    HStack(spacing: 10) {
                        StatCard(title: plural(s.entries, "заявка", "заявки", "заявок"), value: s.entries,
                                 icon: "list.bullet.clipboard", color: Brand.blue)
                        StatCard(title: plural(s.carts, "картридж", "картриджа", "картриджей"), value: s.carts,
                                 icon: "printer.fill", color: .orange)
                        StatCard(title: "обратились", value: s.people, icon: "person.2.fill", color: .teal)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if s.byMonth.count == 12, s.entries > 0 {
                    Section("Заявки по месяцам") { bars(s.byMonth) }
                }
                top("Кто обращается чаще", s.byPerson)
                top("С чем обращаются", s.byProblem)
                top("Картриджи по отделам", s.byUnit, suffix: " шт.")
                top("Картриджи по моделям", s.byModel, suffix: " шт.")
                if s.entries == 0, s.carts == 0 {
                    ContentUnavailableView("За этот период пусто", systemImage: "chart.bar.xaxis",
                                           description: Text("Нет ни заявок, ни выдач картриджей."))
                }
            }
            .navigationTitle("Сводка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
    }

    private func shift(_ n: Int) {
        let cal = Calendar(identifier: .gregorian)
        withAnimation(.snappy) { day = cal.date(byAdding: yearly ? .year : .month, value: n, to: day) ?? day }
    }

    /// Первые пять строк с полоской: длина — доля от самой большой.
    @ViewBuilder
    private func top(_ title: String, _ rows: [Summary.Top], suffix: String = "") -> some View {
        if let most = rows.first?.count, most > 0 {
            Section(title) {
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(r.name).lineLimit(2)
                            Spacer(minLength: 8)
                            Text("\(r.count)" + suffix).font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Brand.blue)
                        }
                        GeometryReader { g in
                            Capsule().fill(Brand.gradient)
                                .frame(width: max(g.size.width * CGFloat(r.count) / CGFloat(most), 6))
                        }
                        .frame(height: 5)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Двенадцать столбиков — заявки по месяцам года.
    private func bars(_ counts: [Int]) -> some View {
        let most = max(counts.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<12, id: \.self) { i in
                VStack(spacing: 3) {
                    Text(counts[i] > 0 ? "\(counts[i])" : " ").font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(counts[i] > 0 ? Brand.blue : Color(.tertiarySystemFill))
                        .frame(height: 4 + 56 * CGFloat(counts[i]) / CGFloat(most))
                    Text(Self.letters[i]).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 104, alignment: .bottom)
        .padding(.vertical, 4)
    }
}
