import SwiftUI

struct CartridgesView: View {
    @EnvironmentObject private var store: Store
    @State private var year = Dates.yearMonth(Date()).year
    @State private var month = Dates.yearMonth(Date()).month   // 0 — весь год
    @State private var query = ""
    @State private var editing: CartItem?
    @State private var toast: String?
    @Namespace private var chips

    private static let months = ["Год", "Янв", "Фев", "Мар", "Апр", "Май", "Июн", "Июл", "Авг", "Сен", "Окт", "Ноя", "Дек"]

    var body: some View {
        NavigationStack {
            list
            .navigationTitle("Картриджи")
            // со строкой поиска заголовок сначала мелкий, а после первого поиска становился крупным
            // и сдвигал страницу — держим мелким всегда
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { it in
                CartEditor(item: it) { text, date in
                    toast = text
                    withAnimation(.snappy) { show(date) }      // выдача ушла в другой месяц — показываем его
                }
                .presentationCornerRadius(24)
            }
            .toast($toast) { if store.undoDelete() { toast = "Возвращено" } }
        }
    }

    /// Показать период, в который попадает день: его месяц, а если открыт «Год» — его год.
    private func show(_ d: Date) {
        let p = Dates.yearMonth(d)
        year = p.year
        if month != 0 { month = p.month }
    }

    private var list: some View {
        let data = store.carts(year: year, month: month, query: query)
        return List {
            Section {
                periodPicker
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)                  // иначе над карточкой торчит линия от «2026»
                summaryCard(data.items, label: data.label)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                // удаление — долгим нажатием: свайп по строке листает страницы
                ForEach(data.items) { it in
                    Button { editing = it } label: { CartRow(it: it) }.tint(.primary)
                        .contextMenu {
                            Button(role: .destructive) {
                                afterMenu {
                                    store.deleteCarts([it.id])
                                    toast = Toast.deleted
                                }
                            } label: { Label("Удалить", systemImage: "trash") }
                        }
                }
            }
            if data.items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Выдач нет" : "Ничего не найдено",
                                       systemImage: "printer.dotmatrix",
                                       description: Text("Отметьте выдачу кнопкой «+»."))
            }
        }
        .scrollContentBackground(.hidden)
        .clearsBar(add: true)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Сотрудник, отдел, модель")
        .scrollDismissesKeyboard(.immediately)
        .animation(.snappy, value: data.items)
        .task(id: store.action) {
            guard store.action == .newCart else { return }
            store.action = nil
            // форма уже открыта (быстрое действие с иконки) — не затираем то, что в ней набрано
            if editing == nil {
                editing = CartItem(id: 0, date: Dates.text(Date()), employee: "", unit: "", model: "", qty: 1, note: "")
            }
        }
        .onChange(of: store.today) { old, new in
            // наступил новый месяц (или год): кто смотрел текущий, остаётся на текущем
            let was = Dates.yearMonth(Dates.parse(old))
            if year == was.year, month == 0 || month == was.month { withAnimation(.snappy) { show(Dates.parse(new)) } }
        }
    }

    private var periodPicker: some View {
        VStack(spacing: 8) {
            HStack {
                Button { withAnimation(.snappy) { year -= 1 } } label: { Image(systemName: "chevron.left") }
                Text(String(year))
                    .font(.title3.bold().monospacedDigit())
                    .contentTransition(.numericText(value: Double(year)))
                    .frame(minWidth: 70)
                Button { withAnimation(.snappy) { year += 1 } } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<13, id: \.self) { m in
                            Text(Self.months[m])
                                .font(.subheadline.weight(month == m ? .bold : .regular))
                                .foregroundStyle(month == m ? .white : .primary)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background {
                                    if month == m {
                                        Capsule().fill(Brand.gradient).matchedGeometryEffect(id: "sel", in: chips)
                                    } else {
                                        Capsule().fill(Color(.secondarySystemFill))
                                    }
                                }
                                .id(m)
                                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { month = m } }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear { proxy.scrollTo(month, anchor: .center) }
                .onChange(of: month) { _, m in withAnimation(.snappy) { proxy.scrollTo(m, anchor: .center) } }
            }
            .sensoryFeedback(.selection, trigger: month)
        }
    }

    private func summaryCard(_ items: [CartItem], label: String) -> some View {
        let total = items.reduce(0) { $0 + $1.qty }
        let top = Dictionary(grouping: items, by: \.model)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.qty }) }
            .sorted { $0.1 > $1.1 }.prefix(3).map { "\($0.0) × \($0.1)" }
        return VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).opacity(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(total)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: Double(total)))
                Text(plural(total, "картридж выдан", "картриджа выдано", "картриджей выдано")).font(.headline).opacity(0.85)
            }
            if !top.isEmpty {
                HStack(spacing: 6) {
                    ForEach(top, id: \.self) { chip in
                        Text(chip)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.white.opacity(0.22), in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LinearGradient(colors: [Brand.blue, Brand.sky.opacity(0.9)], startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "printer.fill").font(.system(size: 64)).foregroundStyle(.white.opacity(0.12))
                .padding(12).allowsHitTesting(false)
        }
        .shadow(color: Brand.blue.opacity(0.3), radius: 12, y: 6)
    }
}

struct CartRow: View {
    let it: CartItem

    var body: some View {
        HStack(spacing: 12) {
            Text(it.model)
                .font(.subheadline.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 58, height: 40)
                .background(Brand.sun.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.employee).lineLimit(1)
                Text([Dates.short(it.date), it.unit, it.note].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("×\(it.qty)").font(.headline.monospacedDigit()).foregroundStyle(Brand.blue)
        }
        .padding(.vertical, 2)
    }
}

struct CartEditor: View {
    let item: CartItem
    /// Текст для плашки и день выдачи: список переходит на её месяц.
    let onSaved: (String, Date) -> Void

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var employee = ""
    @State private var model = ""
    @State private var qty = 1
    @State private var note = ""
    @State private var error: String?
    @State private var askUnknown: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Дата", selection: $date, in: ...Date(), displayedComponents: .date)
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                Section("Кто забрал") {
                    TextField("ФИО или часть имени", text: $employee)
                    Suggestions(text: employee, options: store.people.map(\.fio)) { pick($0) }
                    lastIssue
                }
                Section("Картридж") {
                    TextField("Модель, например 285", text: $model).autocorrectionDisabled()
                    printerHint
                    if !modelHints.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(modelHints, id: \.self) { m in
                                    Button(m) { withAnimation(.snappy) { model = m } }
                                        .buttonStyle(.bordered).tint(.orange)
                                }
                            }
                        }
                    }
                    Stepper(value: $qty, in: 1...999) {
                        HStack {
                            Text("Количество")
                            Spacer()
                            Text("\(qty)").font(.headline.monospacedDigit())
                                .contentTransition(.numericText(value: Double(qty)))
                                .animation(.snappy, value: qty)
                        }
                    }
                    .sensoryFeedback(.selection, trigger: qty)
                }
                TextField("Примечание", text: $note)
            }
            .animation(.snappy, value: employee)
            .keyboardDone()
            .navigationTitle(item.id == 0 ? "Выдача" : "Правка выдачи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button { save(false) } label: { Text("Сохранить").bold() } }
            }
            .onAppear {
                date = Dates.parse(item.date)
                employee = item.employee
                model = item.model
                qty = item.qty
                note = item.note
            }
            .confirmationDialog(askUnknown ?? "", isPresented: Binding(get: { askUnknown != nil },
                                                                     set: { if !$0 { askUnknown = nil } }),
                                titleVisibility: .visible) {
                Button("Записать на это имя") { save(true) }
            }
            .errorAlert($error)
        }
    }

    /// «В прошлый раз»: что этот человек брал. Нажатие подставляет ту же модель. Только в новой выдаче.
    @ViewBuilder private var lastIssue: some View {
        let history = item.id == 0 ? store.cartHistory(typed: employee) : []
        if let last = history.first {
            let year = String(store.today.prefix(4))
            let total = history.filter { $0.issued_at.hasPrefix(year) }.reduce(0) { $0 + $1.qty }
            Button { withAnimation(.snappy) { model = last.model } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.orange)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("В прошлый раз: \(last.model) × \(last.qty)").font(.callout).foregroundStyle(.primary)
                        Text((last.issued_at.hasPrefix(year) ? Dates.short(last.issued_at) : Readable.date(last.issued_at))
                             + (total > 0 ? " · за \(year) год — \(total) шт." : " · в этом году выдач не было"))
                            // Color.secondary — серый; просто .secondary внутри кнопки — бледно-синий, не читается
                            .font(.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 4)
                    if model == last.model {
                        Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.green)
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Картридж из карточки его принтера: нажатие подставляет модель. Только в новой выдаче.
    @ViewBuilder private var printerHint: some View {
        let own = item.id == 0 ? store.printerCartridges(typed: employee) : []
        if !own.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(own, id: \.self) { m in
                        Button { withAnimation(.snappy) { model = m } } label: {
                            Label("Его принтер: \(m)", systemImage: "printer.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Выбрали человека из подсказки — подставляем картридж его принтера, а нет — тот, что он брал в прошлый раз.
    private func pick(_ name: String) {
        employee = name
        guard item.id == 0, model.isEmpty else { return }
        if let own = store.printerCartridges(typed: name).first {
            model = own
        } else if let last = store.cartHistory(typed: name).first {
            model = last.model
        }
    }

    private var modelHints: [String] {
        let m = model.lowercased()
        return Array(store.models.filter { m.isEmpty || ($0.lowercased().contains(m) && $0 != model) }.prefix(8))
    }

    func save(_ allowUnknown: Bool) {
        do {
            let text = try store.saveCart(id: item.id, date: date, employee: employee, model: model, qty: qty,
                                          note: note, allowUnknown: allowUnknown)
            onSaved(text, date)
            dismiss()
        } catch let e as APIError where e.unknownPerson {
            askUnknown = e.message
        } catch { self.error = error.localizedDescription }
    }
}
