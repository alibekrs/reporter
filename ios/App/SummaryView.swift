import Charts
import SwiftUI

/// Сводка за месяц или год: сколько заявок и картриджей, кто и с чем обращается чаще.
struct SummaryView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var yearly = false
    @State private var day = Date()               // любой день показанного периода
    @State private var grown = false              // столбики графиков вырастают при открытии

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
                    Section("Заявки по месяцам") { bars(s.byMonth, Brand.blue) }
                }
                if s.cartsByMonth.count == 12, s.carts > 0 {
                    Section("Картриджи по месяцам") { bars(s.cartsByMonth, .orange) }
                }
                if !s.byProblem.isEmpty || !s.byUnit.isEmpty || !s.byEntryUnit.isEmpty || !s.byDevice.isEmpty {
                    Section("Графики") {
                        chart("С чем обращаются", Array(s.byProblem.prefix(5)), Brand.blue)
                        chart("Заявки по отделам", s.byEntryUnit, .teal)
                        chart("Проблемные устройства", s.byDevice, .red)
                        chart("Картриджи по отделам", Array(s.byUnit.prefix(5)), .orange)
                    }
                }
                top("Кто обращается чаще", s.byPerson)
                top("С чем обращаются", s.byProblem)
                top("Картриджи по отделам", s.byUnit, suffix: " шт.")
                top("Картриджи по моделям", s.byModel, suffix: " шт.")
                if s.entries == 0, s.carts == 0 {
                    EmptyState("За этот период пусто", systemImage: "chart.bar.xaxis",
                                           description: Text("Нет ни заявок, ни выдач картриджей."))
                }
                fleet
            }
            .onAppear {
                if Motion.reduced { grown = true } else {
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.25)) { grown = true }
                }
            }
            .navigationTitle("Сводка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
    }

    /// Возраст парка — на сегодня, от периода не зависит: сколько техники новой, средней и старше пяти лет.
    @ViewBuilder private var fleet: some View {
        let f = store.fleetAge()
        let total = f.young + f.middle + f.old + f.unknown
        if total > 0 {
            Section {
                let rows = [("до 3 лет", f.young, Color.green), ("3–5 лет", f.middle, Color.orange),
                            ("5 лет и старше", f.old, Color.red), ("дата покупки не указана", f.unknown, Color.gray)]
                ForEach(rows.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(rows[i].0)
                            Spacer()
                            Text("\(rows[i].1)").font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(rows[i].2)
                        }
                        GeometryReader { g in
                            // ноль — без полоски: точка у пустой строки выглядела как «чуть-чуть»
                            Capsule().fill(rows[i].2.opacity(0.8))
                                .frame(width: rows[i].1 > 0 ? max(g.size.width * CGFloat(rows[i].1) / CGFloat(total), 6) : 0)
                        }
                        .frame(height: 5)
                    }
                    .padding(.vertical, 2)
                }
                ForEach(f.oldest) { d in
                    LabeledContent(store.deviceTitle(d)) {
                        Text(store.holderName(d.holder) + " · " + String((d.item["bought"]?.string ?? "").prefix(4)))
                    }
                    .font(.footnote)
                }
            } header: {
                Text("Возраст техники сейчас")
            } footer: {
                Text("По дате покупки в карточках техники."
                     + (f.oldest.isEmpty ? "" : " Под полосками — самая старая: её пора менять."))
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

    /// Двенадцать столбиков — заявки или картриджи по месяцам года.
    private func bars(_ counts: [Int], _ color: Color) -> some View {
        let most = max(counts.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<12, id: \.self) { i in
                VStack(spacing: 3) {
                    Text(counts[i] > 0 ? "\(counts[i])" : " ").font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(counts[i] > 0 ? color : Color(.tertiarySystemFill))
                        .frame(height: 4 + 56 * CGFloat(counts[i]) / CGFloat(most))
                    Text(Self.letters[i]).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 104, alignment: .bottom)
        .padding(.vertical, 4)
    }

    /// Горизонтальные столбики: название над столбиком, столбик вырастает слева направо, справа — число.
    /// Подписи оси наезжали на столбики и перечёркивались сеткой — ось спрятана, название стоит над столбиком.
    @ViewBuilder private func chart(_ title: String, _ items: [Summary.Top], _ color: Color) -> some View {
        if !items.isEmpty {
            // grown читаем здесь, а не в замыкании Chart: оно считается вне body, и экран не замечал смену grown —
            // столбики оставались нулевыми, пока экран не перестроится (например, переключением на «Год»)
            let full = grown
            let most = max(items.map(\.count).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Chart(items) { t in
                    BarMark(x: .value("Сколько", full ? t.count : 0), y: .value("Что", t.name), height: .fixed(12))
                        .foregroundStyle(color.gradient)
                        .cornerRadius(6)
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text(t.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .annotation(position: .trailing) { Text("\(t.count)").font(.caption2).foregroundStyle(.secondary) }
                }
                // ноль слева с первого кадра (у нулевых столбиков шкала ставила ноль посередине, и подписи ехали влево);
                // справа место под число у самого длинного столбика
                .chartXScale(domain: 0...most, range: .plotDimension(endPadding: 24))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: CGFloat(items.count) * 48)
            }
            .padding(.vertical, 4)
        }
    }
}
