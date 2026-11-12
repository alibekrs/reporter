import SwiftUI

/// Дата, которой может не быть: «указать» ставит сегодняшнюю, крестик убирает.
struct OptionalDateRow: View {
    let label: String
    @Binding var value: String

    var body: some View {
        if value.isEmpty {
            Button { value = Dates.text(Date()) } label: {
                LabeledContent(label) { Text("указать").foregroundStyle(Brand.blue) }
            }
            .tint(.primary)
            .accessibilityLabel("\(label): указать")
        } else {
            HStack {
                DatePicker(label, selection: Binding(get: { Dates.parse(value) }, set: { value = Dates.text($0) }),
                           displayedComponents: .date)
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                Button { value = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(label): убрать дату")
            }
        }
    }
}

/// «меньше года», «3 года», «7 лет» — сколько устройству.
func ageText(_ years: Int) -> String {
    years < 1 ? "меньше года" : "\(years) \(plural(years, "год", "года", "лет"))"
}

/// Гарантия кончилась — красным, осталось меньше месяца — оранжевым; иначе ничего.
struct WarrantyBadge: View {
    let days: Int?

    var body: some View {
        if let d = days, d <= 30 {
            let color = d < 0 ? Color.red : Color.orange
            Text(d < 0 ? "гарантия кончилась" : (d == 0 ? "гарантия: последний день" : "гарантия: \(d) дн."))
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
        }
    }
}

/// Строка устройства в списках склада.
struct DeviceLine: View {
    let d: DeviceRef
    @EnvironmentObject private var store: Store

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.deviceTitle(d)).lineLimit(1)
                if let y = Store.age(d.item, today: store.today) {
                    Text("куплен \(Readable.date(d.item["bought"]?.string ?? "")) · \(ageText(y))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            WarrantyBadge(days: Store.warrantyDays(d.item, today: store.today))
        }
    }
}

/// Карточка устройства: что это, у кого, гарантия и вся история — выдачи, передачи, ремонты из отчёта.
struct DeviceSheet: View {
    let deviceId: String

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var transferring = false
    @State private var repair: Entry?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Group {
                if let d = store.device(deviceId) {
                    content(d)
                } else {
                    ContentUnavailableView("Устройства больше нет", systemImage: "questionmark.square.dashed",
                                           description: Text("Его убрали из учёта — оно в корзине 30 дней."))
                }
            }
            .navigationTitle("Устройство")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
            .sheet(isPresented: $transferring) {
                TransferSheet(deviceId: deviceId) { toast = $0 }.presentationCornerRadius(24)
            }
            .sheet(item: $repair) { e in
                EntryEditor(entry: e) { text, _ in toast = text }.presentationCornerRadius(24)
            }
            .toast($toast)
        }
    }

    private func content(_ d: DeviceRef) -> some View {
        let spec = store.meta?.devices[d.group]
        let fields = (spec?.fields ?? []).filter { $0.kind != "check" }
            .compactMap { f -> (String, String)? in
                let v = d.item[f.key]?.string ?? ""
                return v.isEmpty ? nil : (f.label, v)
            }
        let lines = store.history(of: d.id)
        let bought = d.item["bought"]?.string ?? "", warranty = d.item["warranty"]?.string ?? ""
        let cartridge = d.item["cartridge"]?.string ?? ""
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.deviceTitle(d)).font(.headline)
                    Label(d.holder.isEmpty ? "На складе" : "У сотрудника: " + store.holderName(d.holder),
                          systemImage: d.holder.isEmpty ? "shippingbox.fill" : "person.fill")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(fields.indices, id: \.self) { i in LabeledContent(fields[i].0, value: fields[i].1) }
                if !cartridge.isEmpty { LabeledContent("Картридж", value: cartridge) }
                if !bought.isEmpty {
                    LabeledContent("Куплен", value: Readable.date(bought) + " · " + ageText(Store.age(d.item, today: store.today) ?? 0))
                }
                if !warranty.isEmpty {
                    LabeledContent("Гарантия до") {
                        HStack(spacing: 6) {
                            Text(Readable.date(warranty))
                            WarrantyBadge(days: Store.warrantyDays(d.item, today: store.today))
                        }
                    }
                }
            }
            Section {
                Button { transferring = true } label: {
                    Label("Передать", systemImage: "arrow.left.arrow.right")
                }
                Button {
                    let who = d.holder.isEmpty ? "" : (store.employee(d.holder).map { Store.fio($0) } ?? "")
                    repair = Entry(uid: "", date: Dates.text(Dates.workday(Date())), employee: who, device: d.id)
                } label: {
                    Label("Записать ремонт", systemImage: "wrench.and.screwdriver")
                }
            } footer: {
                Text("Ремонт записывается в отчёт и попадает в историю этого устройства.")
            }
            Section("История") {
                if lines.isEmpty {
                    Text("Пока пусто").foregroundStyle(.secondary)
                }
                ForEach(lines) { l in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: l.icon).foregroundStyle(Brand.blue).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.text)
                            if !l.detail.isEmpty { Text(l.detail).font(.caption).foregroundStyle(.secondary) }
                            Text(Readable.date(l.date)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Кому передать устройство: на склад или работающему сотруднику.
struct TransferSheet: View {
    let deviceId: String
    let onDone: (String) -> Void

    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var target: Target?
    @State private var error: String?

    struct Target: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        NavigationStack {
            List {
                let holder = store.device(deviceId)?.holder
                if holder != "" {
                    Section {
                        Button { target = Target(id: "", name: "Склад") } label: {
                            Label("На склад", systemImage: "shippingbox.fill")
                        }
                    }
                }
                Section("Сотрудники") {
                    ForEach(candidates(except: holder ?? ""), id: \.id) { p in
                        Button { target = Target(id: p.id, name: p.fio) } label: {
                            HStack(spacing: 10) {
                                Avatar(name: p.fio).scaleEffect(0.75).frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.fio)
                                    if !p.unit.isEmpty { Text(p.unit).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Кому передать")
            .navigationTitle("Передать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
            .confirmationDialog("Передать устройство?", isPresented: Binding(get: { target != nil },
                                                                           set: { if !$0 { target = nil } }),
                                titleVisibility: .visible, presenting: target) { t in
                Button("Передать: \(t.name)") { send(t) }
            }
            .errorAlert($error)
        }
    }

    private func candidates(except holder: String) -> [Person] {
        let tokens = query.lowercased().split(separator: " ")
        return store.people.filter { p in
            p.id != holder && tokens.allSatisfy { t in (p.fio + " " + p.unit).lowercased().contains(t) }
        }
    }

    private func send(_ t: Target) {
        do {
            try store.transfer(deviceId, to: t.id)
            onDone("Передано: \(t.name)")
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Склад: техника без хозяина — сданная уволенными или ещё не выданная.
struct StoreroomView: View {
    @EnvironmentObject private var store: Store
    @State private var open: DeviceRef?

    var body: some View {
        let devs = store.devices(of: "")
        List {
            ForEach(Store.deviceGroups, id: \.self) { g in
                let list = devs.filter { $0.group == g }
                if !list.isEmpty {
                    Section(store.meta?.devices[g]?.title ?? g) {
                        ForEach(list) { d in
                            Button { open = d } label: { DeviceLine(d: d) }.tint(.primary)
                        }
                    }
                }
            }
            if devs.isEmpty {
                ContentUnavailableView("Склад пуст", systemImage: "shippingbox",
                                       description: Text("Сюда попадает сданная техника: «Передать» → «На склад»."))
            }
        }
        .clearsBar()
        .navigationTitle("Склад")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $open) { d in DeviceSheet(deviceId: d.id).presentationCornerRadius(24) }
    }
}
