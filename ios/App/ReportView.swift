import SwiftUI

struct ReportView: View {
    @EnvironmentObject private var store: Store
    @State private var day = Date()
    @State private var editing: Entry?
    @State private var toast: String?
    @State private var flips = 0
    @State private var mailing = false
    @State private var mailAsk: String?
    @State private var error: String?
    @State private var query = ""
    @State private var previewing: PreviewFile?
    @State private var templating: EntryTemplate?

    var body: some View {
        NavigationStack {
            list
            .navigationTitle("Отчёт")
            // со строкой поиска заголовок сначала мелкий, а после первого поиска становился крупным
            // и сдвигал страницу — держим мелким всегда
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { preview() } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .accessibilityLabel("Посмотреть отчёт")
                        .disabled(store.entries(week: monday).isEmpty)
                }
            }
            .sheet(item: $editing) { e in
                EntryEditor(entry: e) { text, date in
                    toast = text
                    if e.uid.isEmpty { query = "" }            // новая запись — из поиска обратно к неделе
                    withAnimation(.snappy) { day = date }      // запись ушла в другую неделю — показываем её
                }
                .presentationCornerRadius(24)
            }
            .sheet(item: $previewing) { ReportPreview(file: $0).presentationCornerRadius(24) }
            .sheet(item: $templating) { t in
                NavigationStack {
                    TemplateEditor(template: t) { toast = "Шаблон сохранён" }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { templating = nil } }
                        }
                }
                .presentationCornerRadius(24)
            }
            .confirmationDialog(mailAsk ?? "", isPresented: Binding(get: { mailAsk != nil },
                                                                  set: { if !$0 { mailAsk = nil } }),
                                titleVisibility: .visible) {
                Button("Отправить") { Task { await sendMail() } }
            }
            .errorAlert($error)
            .toast($toast) { if store.undoDelete() { toast = "Возвращено" } }
        }
    }

    /// Собрать Word за показанную неделю и открыть его: проверить перед отправкой и передать через «Поделиться».
    private func preview() {
        let s = MailSettings.load()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Docx.fileName(monday: monday))
        do {
            try Docx.week(branch: s.branch, responsible: s.responsible, monday: monday,
                          entries: store.reportEntries(week: monday)).write(to: url, options: .atomic)
            previewing = PreviewFile(url: url)
        } catch { self.error = error.localizedDescription }
    }

    /// Проверить, что и кому уйдёт, и спросить. Письмо уходит прямо с телефона.
    private func askMail() async {
        let s = MailSettings.load()
        guard s.missing.isEmpty else {
            error = "В настройках почты не заполнено: " + s.missing.joined(separator: ", ")
                + ".\nЗаполните: Настройки → «Почта для отчёта»."
            return
        }
        let n = store.reportEntries(week: monday).count
        mailAsk = "Отчёт за \(ReportMail.label(monday))\n\(n) \(plural(n, "запись", "записи", "записей")) → \(s.recipient.trimmed)"
    }

    private func sendMail() async {
        mailing = true
        defer { mailing = false }
        do {
            toast = try await ReportMail.send(MailSettings.load(), monday: monday, entries: store.reportEntries(week: monday))
            Reminder.sent(monday)                  // отчёт ушёл — пятничное напоминание за эту неделю не нужно
        } catch { self.error = error.localizedDescription }
    }

    private var monday: Date { Dates.monday(day) }

    /// Строка записи: нажатие — правка; долгое нажатие — в шаблоны или удалить (свайп по строке листает страницы).
    private func row(_ e: Entry, dated: Bool = false) -> some View {
        Button { editing = e } label: { EntryRow(e: e, dated: dated) }.tint(.primary)
            .contextMenu {
                Button {
                    templating = EntryTemplate("", "", e.description ?? "", e.actions ?? "", e.result ?? "")
                } label: { Label("Сохранить как шаблон", systemImage: "text.badge.plus") }
                Button(role: .destructive) {
                    store.deleteEntries([e.uid])
                    toast = Toast.deleted
                } label: { Label("Удалить", systemImage: "trash") }
            }
    }

    private var list: some View {
        let week = store.entries(week: monday)
        let searching = !query.trimmed.isEmpty
        // поиск идёт по всему отчёту, а не по показанной неделе
        let found = searching ? store.searchEntries(query) : []
        return List {
            if searching {
                Section {
                    ForEach(found.prefix(200)) { e in row(e, dated: true) }
                } header: {
                    Text("Найдено: \(found.count)" + (found.count > 200 ? " — показаны первые 200" : ""))
                }
                if found.isEmpty { NothingFound() }
            } else {
                Section {
                    weekCard(count: week.count)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                ForEach(days, id: \.self) { d in
                    let entries = week.filter { $0.date == d }
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries) { e in row(e) }
                        } header: {
                            dayHeader(d, count: entries.count)
                        }
                    }
                }
                if week.isEmpty {
                    ContentUnavailableView("Записей нет", systemImage: "tray",
                                           description: Text("За эту неделю пока ничего. Нажмите «+», чтобы добавить."))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .clearsBar(add: true)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск по всем записям")
        .scrollDismissesKeyboard(.immediately)
        .task(id: store.action) {
            switch store.action {
            case .newEntry:
                store.action = nil
                // форма уже открыта (быстрое действие с иконки) — не затираем то, что в ней набрано
                if editing == nil { editing = Entry(uid: "", date: Dates.text(Dates.workday(Date()))) }
            case .sendReport:
                store.action = nil
                withAnimation(.snappy) { day = Date() }
                await askMail()
            default:
                break
            }
        }
        .onChange(of: store.today) { old, _ in
            // наступил новый день: кто смотрел текущую неделю, остаётся на текущей
            if Dates.monday(Dates.parse(old)) == monday { withAnimation(.snappy) { day = Date() } }
        }
    }

    private var isThisWeek: Bool { Dates.monday(Date()) == monday }

    private func weekCard(count: Int) -> some View {
        let fri = Calendar(identifier: .gregorian).date(byAdding: .day, value: 4, to: monday)!
        return VStack(spacing: 10) {
            HStack {
                Button { shift(-7) } label: { Image(systemName: "chevron.left.circle.fill").font(.title) }
                Spacer()
                VStack(spacing: 2) {
                    Text(isThisWeek ? "ЭТА НЕДЕЛЯ" : "НЕДЕЛЯ").font(.caption2.weight(.bold)).opacity(0.8)
                    Text(Dates.short(Dates.text(monday)) + " – " + Dates.short(Dates.text(fri)))
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                }
                Spacer()
                Button { shift(7) } label: { Image(systemName: "chevron.right.circle.fill").font(.title) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(count)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: Double(count)))
                Text(plural(count, "запись", "записи", "записей")).font(.headline).opacity(0.85)
            }
            HStack(spacing: 8) {
                if !isThisWeek {
                    Button("К текущей неделе") { withAnimation(.snappy) { day = Date() } }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.22), in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
                if count > 0 {
                    Button { hideKeyboard(); Task { await askMail() } } label: {
                        HStack(spacing: 6) {
                            if mailing { ProgressView().tint(Brand.blue) } else { Image(systemName: "envelope.fill") }
                            Text("Отправить начальнику")
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.blue)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white, in: Capsule())
                    }
                    .disabled(mailing)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.borderless)
        .tint(.white)
        .padding(16)
        .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle().fill(Brand.sun.opacity(0.35)).frame(width: 70).blur(radius: 18).offset(x: -10, y: 6)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Brand.blue.opacity(0.3), radius: 12, y: 6)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -60 { shift(7) } else if v.translation.width > 60 { shift(-7) }
        })
        .sensoryFeedback(.selection, trigger: flips)
        .animation(.snappy, value: isThisWeek)
    }

    private func dayHeader(_ d: String, count: Int) -> some View {
        let today = d == Dates.text(Date())
        return HStack {
            Text(dayTitle(d)).foregroundStyle(today ? Brand.blue : .secondary)
            if today {
                Text("сегодня").font(.caption2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Brand.blue, in: Capsule())
            }
            Spacer()
            Text("\(count)").monospacedDigit()
        }
    }

    private var days: [String] {
        (0..<5).map { Dates.text(Calendar(identifier: .gregorian).date(byAdding: .day, value: $0, to: monday)!) }
    }

    func dayTitle(_ iso: String) -> String {
        let s = Dates.human.string(from: Dates.parse(iso))     // «понедельник, 2 ноября»
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    func shift(_ n: Int) {
        flips += 1
        withAnimation(.snappy) { day = Calendar.current.date(byAdding: .day, value: n, to: day)! }
    }
}

struct EntryRow: View {
    let e: Entry
    /// В результатах поиска записи из разных недель — у каждой показана дата.
    var dated = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinearGradient(colors: [Brand.sun, .orange], startPoint: .top, endPoint: .bottom))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                if dated {
                    Text(Readable.date(e.date)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let s = e.employee, !s.isEmpty {
                    Label(s, systemImage: "person.fill").font(.subheadline.bold()).foregroundStyle(Brand.blue)
                }
                if let s = e.description, !s.isEmpty { Text(s) }
                if let s = e.actions, !s.isEmpty {
                    Label(s, systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary)
                }
                if let s = e.result, !s.isEmpty {
                    Label(s, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct EntryEditor: View {
    let entry: Entry
    /// Текст для плашки и день сохранённой записи: список переходит на её неделю.
    let onSaved: (String, Date) -> Void

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var employee: String
    @State private var description: String
    @State private var actions: String
    @State private var result: String
    @State private var error: String?
    @State private var templatesOpen = false

    /// Поля заполняются один раз, при создании. В onAppear они заполнялись заново при возврате
    /// из «Изменить шаблоны», и всё набранное стиралось.
    init(entry: Entry, onSaved: @escaping (String, Date) -> Void) {
        self.entry = entry
        self.onSaved = onSaved
        _date = State(initialValue: Dates.parse(entry.date))
        _employee = State(initialValue: entry.employee ?? "")
        _description = State(initialValue: entry.description ?? "")
        _actions = State(initialValue: entry.actions ?? "")
        _result = State(initialValue: entry.result ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Menu {
                        ForEach(store.templates) { t in
                            Button(t.name) { apply(t) }
                        }
                        Divider()
                        Button { templatesOpen = true } label: { Label("Изменить шаблоны", systemImage: "pencil") }
                    } label: {
                        Label("Заполнить по шаблону", systemImage: "text.badge.plus")
                    }
                }
                Section {
                    DatePicker("День", selection: $date, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                    TextField("Сотрудник / объект", text: $employee)
                    Suggestions(text: employee, options: store.employeeSuggestions) { employee = $0 }
                }
                Section("Что случилось") {
                    TextField("Описание", text: $description, axis: .vertical).lineLimit(2...6)
                }
                Section("Что сделано") {
                    TextField("Действия", text: $actions, axis: .vertical).lineLimit(2...6)
                }
                Section("Итог") {
                    TextField("Результат", text: $result, axis: .vertical).lineLimit(1...4)
                }
            }
            .animation(.snappy, value: employee)
            .keyboardDone()
            .navigationDestination(isPresented: $templatesOpen) { TemplatesView() }
            .navigationTitle(entry.uid.isEmpty ? "Новая запись" : "Запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button { save() } label: { Text("Сохранить").bold() } }
            }
            .errorAlert($error)
        }
    }

    func save() {
        do {
            try store.saveEntry(uid: entry.uid.isEmpty ? nil : entry.uid, date: date, employee: employee,
                                description: description, actions: actions, result: result)
            onSaved(entry.uid.isEmpty ? "Запись добавлена" : "Сохранено", date)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func apply(_ t: EntryTemplate) {
        withAnimation(.snappy) {
            description = t.description
            actions = t.actions
            result = t.result
        }
    }
}

/// Шаблоны заявок: нажать — поправить, «+» — новый, «Порядок» — перетащить или удалить.
struct TemplatesView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: EntryTemplate?
    @State private var mode: EditMode = .inactive
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                ForEach(store.templates) { t in
                    let fixed = t.id == EntryTemplate.cartridgeId
                    Button { editing = t } label: { TemplateRow(t: t) }.tint(.primary)
                        .deleteDisabled(fixed)
                        .contextMenu {
                            if !fixed {
                                Button(role: .destructive) { delete([t.id]) } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                }
                .onDelete { idx in delete(Set(idx.map { store.templates[$0].id })) }
                .onMove { store.moveTemplates(from: $0, to: $1) }
            } footer: {
                Text("Шаблон заполняет запись отчёта: что случилось, что сделано и итог. «Картридж» сам добавляется "
                     + "в отчёт при каждой выдаче картриджа — его можно поправить, но не удалить. Удалить шаблон — "
                     + "долгим нажатием или кнопкой «Порядок».")
            }
        }
        .environment(\.editMode, $mode)
        .animation(.snappy, value: store.templates)
        .navigationTitle("Шаблоны")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(mode.isEditing ? "Готово" : "Порядок") {
                    withAnimation { mode = mode.isEditing ? .inactive : .active }
                }
                Button { editing = EntryTemplate("", "", "", "", "") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Новый шаблон")
            }
        }
        .navigationDestination(item: $editing) { TemplateEditor(template: $0) }
        .toast($toast) { if store.undoDelete() { toast = "Возвращено" } }
    }

    private func delete(_ ids: Set<String>) {
        store.deleteTemplates(ids)
        toast = Toast.deleted
    }
}

struct TemplateRow: View {
    let t: EntryTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(t.name).font(.headline)
                if t.id == EntryTemplate.cartridgeId {
                    HStack(spacing: 4) {
                        Image(systemName: "printer.fill")
                        Text("при выдаче картриджа")
                    }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Brand.sun.opacity(0.22), in: Capsule())
                }
            }
            Text([t.description, t.actions, t.result].filter { !$0.isEmpty }.joined(separator: " → "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct TemplateEditor: View {
    let template: EntryTemplate
    /// Зовётся после сохранения — когда шаблон делают из записи отчёта, там показывают плашку.
    var onSaved: (() -> Void)?

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var t = EntryTemplate("", "", "", "", "")
    @State private var error: String?

    var body: some View {
        Form {
            Section("Название в списке") {
                TextField("Например, Замятие бумаги", text: $t.name)
            }
            Section("Что случилось") {
                TextField("Описание проблемы", text: $t.description, axis: .vertical).lineLimit(2...6)
            }
            Section("Что сделано") {
                TextField("Что сделали", text: $t.actions, axis: .vertical).lineLimit(2...6)
            }
            Section {
                TextField("Чем закончилось", text: $t.result, axis: .vertical).lineLimit(1...4)
            } header: { Text("Итог") } footer: {
                if template.id == EntryTemplate.cartridgeId {
                    Text("Этот шаблон сам добавляется в отчёт при каждой выдаче картриджа.")
                }
            }
        }
        .keyboardDone()
        .navigationTitle(template.id.isEmpty ? "Новый шаблон" : "Шаблон")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button { save() } label: { Text("Сохранить").bold() } }
        }
        .onAppear { t = template }
        .errorAlert($error)
    }

    func save() {
        do {
            try store.saveTemplate(t)
            onSaved?()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
