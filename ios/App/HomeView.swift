import SwiftUI

/// Главная: цитата дня, неделя отчёта, картриджи и сотрудники, быстрые кнопки.
/// Стекло здесь без .interactive(): страницы лежат в одной ленте, и интерактивное стекло главной забирало
/// короткие касания на других страницах в тех же местах экрана (переключатели настроек не нажимались).
struct HomeView: View {
    @EnvironmentObject private var store: Store
    @Binding var tab: AppTab
    /// Заставка раскрывается — пора выезжать карточкам.
    let ready: Bool

    @State private var shown = false
    @State private var grow = false
    @State private var quote = Quotes.todayIndex
    @State private var summaryOpen = false
    @State private var searchOpen = false
    @State private var auditOpen = false
    @State private var issues = 0                    // неточности в данных — считаются при открытии главной
    @State private var bubble: String?               // пузырёк сверху: день рождения, гарантия
    @AppStorage("bubble.day") private var bubbleDay = ""
    @State private var pull = Pull()                 // «потяни вниз»: робот появляется и крутится
    @State private var tilting = false               // датчик наклона включён главной
    @AppStorage(Weather.cityKey) private var city = ""
    @State private var cityAsk = false
    @State private var cityDraft = ""
    @State private var weatherTick = 0               // значок погоды оживает: появился, обновили
    @ObservedObject private var weather = Weather.shared
    @Environment(\.openURL) private var openURL

    private static let monthName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL"
        return f
    }()

    var body: some View {
        // дни рождения считаем один раз на перерисовку: расчёт по календарю для каждого сотрудника — не быстрый
        let soon = store.birthdays(within: 7)
        let party = soon.filter { $0.days == 0 }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(today).font(.subheadline).foregroundStyle(.secondary)
                        Text(greeting).font(.headline)
                    }
                    .rise(shown, 0)
                    weatherChip.rise(shown, 0.01)
                    holiday.rise(shown, 0.02)
                    birthdays(soon).rise(shown, 0.03)
                    congrats(party).rise(shown, 0.04)
                    inWorkCard.rise(shown, 0.04)
                    weekSummary.rise(shown, 0.05)
                    quoteCard.overlay(alignment: .bottomTrailing) { quoteShare }
                        .modifier(Parallax(amount: 6)).rise(shown, 0.05)
                    weekCard.modifier(Parallax(amount: 10)).rise(shown, 0.12)
                    tiles.rise(shown, 0.19)
                    summaryButton.rise(shown, 0.23)
                    actions.rise(shown, 0.28)
                    auditCard.rise(shown, 0.3)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .clearsBar(add: true)          // талисман стоит и на главной
            // «потяни вниз»: робот показывается, отпустили — крутится, погода и мысль дня обновляются.
            // Следим только за оттягиванием выше начала (меньше нуля): обычная прокрутка главную не трогает
            .onScrollGeometryChange(for: CGFloat.self) { min(0, $0.contentOffset.y + $0.contentInsets.top) } action: { _, y in pulled(y) }
            .overlay(alignment: .top) { PullBot(pull: pull) }
            // день рождения сегодня — шарики; Наурыз — тюльпаны; иначе — по сезону
            .overlay(alignment: .top) {
                Fall(emoji: party.isEmpty ? Fall.season : ["🎈", "🎉"], on: shown, day: store.today)
                    .frame(height: 420).allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if let bubble {
                    Text(bubble).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.trailing, 12).padding(.top, 4)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .navigationTitle("ITdesk")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { searchOpen = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Поиск по всему")
                }
            }
            .sheet(isPresented: $summaryOpen) { SummaryView().presentationCornerRadius(24) }
            .sheet(isPresented: $searchOpen) { GlobalSearchView(tab: $tab).presentationCornerRadius(24) }
            .sheet(isPresented: $auditOpen) { AuditView(tab: $tab).presentationCornerRadius(24) }
            .alert("Город для погоды", isPresented: $cityAsk) {
                TextField("Например, Актобе", text: $cityDraft)
                Button("Сохранить") {
                    city = cityDraft.trimmed
                    Task { await weather.load(force: true) }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("По нему на главной показывается погода. Сменить город — в настройках, раздел «Оформление».")
            }
            .task {
                await weather.load()
                issues = store.audit().count
            }
            // пузырёк — когда главная уже видна: при запуске её закрывает заставка или окно входа
            .task(id: shown) { if shown { await showBubble() } }
            .onChange(of: store.state.changedAt) { _, _ in issues = store.audit().count }   // данные поправили
            .onChange(of: tab, initial: true) { _, t in tilt(t == .home) }
            .onDisappear { tilt(false) }          // смена темы пересоздаёт страницу — датчик за старой не оставляем
        }
        .onAppear { if ready { start() } }
        .onChange(of: ready) { _, r in if r { start() } }
        .onChange(of: store.today) { _, _ in quote = Quotes.todayIndex }     // новый день — новая мысль дня
    }

    // ── дни рождения ────────────────────────────────────────────────────────
    /// Сегодня и в ближайшую неделю; нажатие — к сотрудникам.
    @ViewBuilder private func birthdays(_ list: [Birthday]) -> some View {
        if !list.isEmpty {
            Button { tab = .assets } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "gift.fill").font(.title2).foregroundStyle(Brand.sun)
                        .symbolEffect(.bounce, value: shown)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(list[0].days == 0 ? "ДЕНЬ РОЖДЕНИЯ СЕГОДНЯ" : "СКОРО ДЕНЬ РОЖДЕНИЯ")
                            .font(.caption2.weight(.bold)).foregroundStyle(Brand.gold)
                        ForEach(list.prefix(3)) { b in
                            Text("\(b.fio) — " + (b.days == 0 ? "сегодня" : Dates.shortHuman.string(from: b.day)))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
    }

    // ── сводка ──────────────────────────────────────────────────────────────
    private var summaryButton: some View {
        Button { summaryOpen = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").font(.headline).foregroundStyle(Brand.blue)
                Text("Сводка за месяц и год").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Сводка за месяц и год")
    }

    private func start() {
        guard !shown else { return }
        shown = true
        grow = true
    }

    /// Датчик наклона — только пока главная на экране; свой счёт, чтобы не выключить его у открытой карточки.
    private func tilt(_ on: Bool) {
        guard on != tilting else { return }
        tilting = on
        if on { Tilt.shared.start() } else { Tilt.shared.stop() }
    }

    /// «Доброе утро, Иван»: имя — из «Ответственный» в почте для отчёта (Фамилия Имя — берём имя).
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let hello = h < 5 ? "Доброй ночи" : h < 12 ? "Доброе утро" : h < 18 ? "Добрый день" : h < 23 ? "Добрый вечер" : "Доброй ночи"
        let fio = (UserDefaults.standard.string(forKey: "mail.responsible") ?? "").split(separator: " ")
        let name = fio.count > 1 ? fio[1] : fio.first
        return name.map { "\(hello), \($0)" } ?? hello
    }

    /// После 20:00 вместо мысли дня — пожелание отдохнуть (талисман в это время тоже спит).
    private var evening: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 20 || h < 6
    }

    private var today: String {
        let s = Dates.human.string(from: Date())
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // ── цитата дня ──────────────────────────────────────────────────────────
    private var quoteCard: some View {
        let q = evening ? Quote(text: "Рабочий день окончен — отдыхай 🌙", who: "ITdesk", about: "до завтра")
            : Quotes.all[quote % Quotes.all.count]
        return Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { quote += 1 }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label("МЫСЛЬ ДНЯ", systemImage: "sparkles")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Brand.gold)
                VStack(alignment: .leading, spacing: 6) {
                    Text("«\(q.text)»")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(Text(q.who).fontWeight(.semibold).foregroundStyle(.primary)) · \(q.about)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .id(quote)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "quote.closing")
                    .font(.system(size: 40, weight: .black))
                    .foregroundStyle(Brand.sun.opacity(0.35))
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .feel(.selection, trigger: quote)
        .accessibilityHint("Следующая цитата")
    }

    // ── неделя отчёта ───────────────────────────────────────────────────────
    private var weekCard: some View {
        let cal = Calendar(identifier: .gregorian)
        let monday = Dates.monday(Date())
        let week = store.entries(week: monday)
        let days = (0..<5).map { Dates.text(cal.date(byAdding: .day, value: $0, to: monday)!) }
        let counts = days.map { d in week.filter { $0.date == d }.count }
        let top = max(counts.max() ?? 0, 1)
        let wd = cal.component(.weekday, from: Date())         // 1 — воскресенье, 6 — пятница
        let late = wd == 6 || wd == 7 || wd == 1
        let names = ["Пн", "Вт", "Ср", "Чт", "Пт"]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Отчёт за " + Dates.short(days[0]) + " – " + Dates.short(days[4]))
                .font(.caption.weight(.semibold)).opacity(0.85)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // число «докручивается» от нуля, когда главная открылась, и подпрыгивает при новой записи
                Text("\(shown ? week.count : 0)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: Double(shown ? week.count : 0)))
                    .animation(Motion.reduced ? nil : Animation.snappy(duration: 0.9).delay(0.3), value: shown)
                    .modifier(Bump(value: week.count))
                Text(plural(week.count, "запись", "записи", "записей")).font(.headline).opacity(0.85)
                Spacer()
                let streak = Streak.count
                if streak >= 2 {
                    Text("🔥 \(streak) \(plural(streak, "неделя", "недели", "недель")) подряд")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.2), in: Capsule())
                        .accessibilityLabel("Отчёт вовремя \(streak) \(plural(streak, "неделю", "недели", "недель")) подряд")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<5, id: \.self) { i in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(counts[i] > 0 ? 0.9 : 0.3))
                            .frame(height: 6 + 34 * CGFloat(counts[i]) / CGFloat(top))
                            .scaleEffect(x: 1, y: grow ? 1 : 0.05, anchor: .bottom)
                            .animation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.35 + Double(i) * 0.07),
                                       value: grow)
                        Text(names[i]).font(.caption2).opacity(0.85)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 58, alignment: .bottom)
            Button {
                store.action = week.isEmpty ? .newEntry : .sendReport
                tab = .report
            } label: {
                HStack {
                    Text(week.isEmpty ? "Добавить первую запись" : (late ? "Неделя кончается — пора отправить" : "Отправить начальнику"))
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: week.isEmpty ? "plus" : "envelope.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Brand.ink)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Brand.sun, in: Capsule())
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Brand.gradient)
        .overlay(alignment: .topTrailing) {
            Circle().fill(Brand.sun.opacity(0.45)).frame(width: 110).blur(radius: 26)
                .offset(x: -10, y: 8)        // неподвижно: размытое пятно в вечной анимации грузило главную
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Brand.blue.opacity(0.3), radius: 12, y: 6)
    }

    // ── плитки ──────────────────────────────────────────────────────────────
    private var tiles: some View {
        let month = String(Dates.text(Date()).prefix(7))                      // 2026-11
        let weekAgo = Dates.text(Calendar.current.date(byAdding: .day, value: -6, to: Date())!)
        let monthQty = store.state.carts.filter { $0.issued_at.hasPrefix(month) }.reduce(0) { $0 + $1.qty }
        let weekQty = store.state.carts.filter { $0.issued_at >= weekAgo }.reduce(0) { $0 + $1.qty }
        let working = store.state.employees.filter { !Store.isDismissed($0) }
        let staff = working.count
        let bad = working.filter { trouble($0) > 0 }.count
        return HStack(spacing: 12) {
            HomeTile(title: "Картриджи · " + HomeView.monthName.string(from: Date()), value: monthQty, counted: shown,
                     chip: weekQty > 0 ? "+\(weekQty) за неделю" : "за неделю 0", good: true) { tab = .carts }
            HomeTile(title: "Сотрудники", value: staff, counted: shown,
                     chip: bad > 0 ? "\(bad) с замечаниями" : "всё исправно", good: bad == 0) { tab = .assets }
        }
    }

    // ── быстрые кнопки ──────────────────────────────────────────────────────
    private var actions: some View {
        HStack(alignment: .top, spacing: 8) {
            QuickButton(title: "Запись", icon: "plus", color: Brand.blue) {
                store.action = .newEntry; tab = .report
            }
            QuickButton(title: "Картридж", icon: "printer.fill", color: .orange) {
                store.action = .newCart; tab = .carts
            }
            QuickButton(title: "Найти", icon: "magnifyingglass", color: Brand.sky) {
                store.action = .findEmployee; tab = .assets
            }
            QuickButton(title: "Начальнику", icon: "envelope.fill", color: Brand.sun,
                        ink: Brand.ink) {
                store.action = .sendReport; tab = .report
            }
        }
    }
}

private struct HomeTile: View {
    let title: String
    let value: Int
    /// Главная открылась — число «докручивается» от нуля.
    let counted: Bool
    let chip: String
    let good: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Text("\(counted ? value : 0)")
                    .font(.title.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(counted ? value : 0)))
                    .animation(Motion.reduced ? nil : Animation.snappy(duration: 0.9).delay(0.45), value: counted)
                    .modifier(Bump(value: value))
                Text(chip)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(good ? Color.green : Color.orange)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background((good ? Color.green : Color.orange).opacity(0.15), in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

private struct QuickButton: View {
    let title: String
    let icon: String
    let color: Color
    var ink: Color = .white
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ink)
                    .symbolEffect(.bounce, value: taps)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular.tint(color), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(title).font(.caption).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressStyle())
        .feel(.impact(weight: .light), trigger: taps)
    }
}

/// «Потяни вниз» на главной: робот показывается и крутится. Отдельным объектом: за ним следит только сам робот,
/// а главная на каждый кадр прокрутки не пересчитывается (она считает дни рождения, неделю отчёта и плитки —
/// прокрутка шла рывками).
@MainActor @Observable
final class Pull {
    var y: CGFloat = 0
    var armed = false
    var spin = 0.0
    var spinning = false
}

private struct PullBot: View {
    let pull: Pull

    var body: some View {
        PixelBot(mood: pull.armed ? .happy : .idle)
            .frame(width: 46, height: 46)
            .rotationEffect(.degrees(pull.spin))
            .opacity(pull.spinning ? 1 : Double(min(1, max(0, -pull.y / 70))))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// ── 5.5: погода, праздник, заявки в работе, итог недели, поздравления, проверка данных ──
extension HomeView {
    @ViewBuilder var weatherChip: some View {
        if let text = weather.text {
            Label {
                Text(text).font(.subheadline.weight(.semibold))
            } icon: {
                // значок живой: появился или обновили — подпрыгивает, а капли дождя и снежинки пробегают по нему
                Image(systemName: weather.icon).symbolRenderingMode(.multicolor)
                    .symbolEffect(.bounce, value: weatherTick)
                    .symbolEffect(.variableColor.iterative, value: weatherTick)
                    .onAppear { weatherTick += 1 }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
        } else if weather.loading {
            Text("+00° · погода загружается").font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .redacted(reason: .placeholder)
        } else if city.trimmed.isEmpty {
            // город не указан — погоды нет вовсе; подсказываем, где её включить
            Button {
                cityDraft = ""
                cityAsk = true
            } label: {
                Label("Погода: указать город", systemImage: "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
            }
            .buttonStyle(PressStyle())
        }
    }

    @ViewBuilder var holiday: some View {
        if let h = Holidays.near() {
            HStack(spacing: 12) {
                Text(h.emoji).font(.largeTitle)
                Text(h.text).font(.headline)
                Spacer(minLength: 0)
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    /// Сегодняшние именинники: «Поздравить» открывает WhatsApp с готовым текстом (номера нет — «Поделиться»).
    @ViewBuilder func congrats(_ today: [Birthday]) -> some View {
        if !today.isEmpty {
            VStack(spacing: 8) {
                ForEach(today) { b in
                    let phone = store.employee(b.id)?["phone"]?.string ?? ""
                    if let url = Congrats.whatsApp(phone, b.fio) {
                        Button { openURL(url) } label: {
                            Label("Поздравить: " + Store.short(b.fio), systemImage: "party.popper.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        ShareLink(item: Congrats.text(b.fio)) {
                            Label("Поздравить: " + Store.short(b.fio), systemImage: "party.popper.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    @ViewBuilder var inWorkCard: some View {
        let list = store.inWork
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("В РАБОТЕ · \(list.count)", systemImage: "hourglass")
                    .font(.caption2.weight(.bold)).foregroundStyle(.orange)
                ForEach(list.prefix(3)) { e in
                    Button {
                        store.action = .openEntry(e.uid)
                        tab = .report
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.employee ?? "").font(.subheadline.weight(.semibold))
                            Text(e.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tint(.primary)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    /// Пятница и выходные: итог недели.
    @ViewBuilder var weekSummary: some View {
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: Date())
        if wd == 6 || wd == 7 || wd == 1 {
            let monday = Dates.monday(Date())
            let from = Dates.text(monday)
            let to = Dates.text(Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: monday) ?? monday)
            let entries = store.entries(week: monday).count
            let carts = store.state.carts.filter { $0.issued_at >= from && $0.issued_at <= to }.reduce(0) { $0 + $1.qty }
            let broken = store.state.employees.filter { !Store.isDismissed($0) && trouble($0) > 0 }.count
            HStack(spacing: 12) {
                Text(broken == 0 ? "🎉" : "📋").font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ИТОГ НЕДЕЛИ").font(.caption2.weight(.bold)).foregroundStyle(Brand.gold)
                    Text("\(entries) \(plural(entries, "заявка", "заявки", "заявок")), \(carts) \(plural(carts, "картридж", "картриджа", "картриджей")), "
                         + (broken == 0 ? "без проблем" : "с проблемой: \(broken)"))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    @ViewBuilder var auditCard: some View {
        if issues > 0 {
            Button { auditOpen = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checklist.unchecked").font(.headline).foregroundStyle(.orange)
                    Text("Проверка данных: \(issues) \(plural(issues, "неточность", "неточности", "неточностей"))")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
    }

    /// Мысль дня картинкой — в Telegram, WhatsApp, куда угодно.
    var quoteShare: some View {
        ShareLink(item: QuoteImage(quote: currentQuote), preview: SharePreview("Мысль дня", image: Image(systemName: "quote.bubble.fill"))) {
            Image(systemName: "square.and.arrow.up").font(.footnote.weight(.semibold)).padding(12)
        }
        .accessibilityLabel("Поделиться мыслью дня")
    }

    var currentQuote: Quote {
        evening ? Quote(text: "Рабочий день окончен — отдыхай 🌙", who: "ITdesk", about: "до завтра")
            : Quotes.all[quote % Quotes.all.count]
    }

    func pulled(_ y: CGFloat) {
        pull.y = y
        if y < -80 && !pull.armed {
            pull.armed = true
        } else if y > -10 && pull.armed {
            pull.armed = false
            pull.spinning = true
            withAnimation(.easeInOut(duration: 0.8)) { pull.spin += 360 }
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                pull.spinning = false
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { quote += 1 }
            weatherTick += 1
            Task { await weather.load(force: true) }
        }
    }

    /// Раз в день пузырёк: сегодня день рождения или скоро кончается гарантия.
    func showBubble() async {
        let today = Dates.text(Date())
        guard bubbleDay != today else { return }
        var text: String?
        if let b = store.birthdays(within: 0).first(where: { $0.days == 0 }) {
            text = "🎂 Сегодня день рождения: " + Store.short(b.fio)
        } else {
            let soon = store.allDevices.filter { (0...30).contains(Store.warrantyDays($0.item, today: store.today) ?? -1) }.count
            if soon > 0 { text = "🛡 Гарантия кончается: \(soon) \(plural(soon, "устройство", "устройства", "устройств"))" }
        }
        guard let text else { return }
        bubbleDay = today
        try? await Task.sleep(for: .seconds(1.2))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { bubble = text }
        try? await Task.sleep(for: .seconds(4))
        withAnimation(.easeOut(duration: 0.3)) { bubble = nil }
    }
}
