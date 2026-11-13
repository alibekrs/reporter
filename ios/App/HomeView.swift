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

    private static let monthName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL"
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(today).font(.subheadline).foregroundStyle(.secondary).rise(shown, 0)
                    birthdays.rise(shown, 0.03)
                    quoteCard.rise(shown, 0.05)
                    weekCard.rise(shown, 0.12)
                    tiles.rise(shown, 0.19)
                    summaryButton.rise(shown, 0.23)
                    actions.rise(shown, 0.28)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .clearsBar()
            .navigationTitle("ITdesk")
            .sheet(isPresented: $summaryOpen) { SummaryView().presentationCornerRadius(24) }
        }
        .onAppear { if ready { start() } }
        .onChange(of: ready) { _, r in if r { start() } }
        .onChange(of: store.today) { _, _ in quote = Quotes.todayIndex }     // новый день — новая мысль дня
    }

    // ── дни рождения ────────────────────────────────────────────────────────
    /// Сегодня и в ближайшую неделю; нажатие — к сотрудникам.
    @ViewBuilder private var birthdays: some View {
        let list = store.birthdays(within: 7)
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

    private var today: String {
        let s = Dates.human.string(from: Date())
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // ── цитата дня ──────────────────────────────────────────────────────────
    private var quoteCard: some View {
        let q = Quotes.all[quote % Quotes.all.count]
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
        .sensoryFeedback(.selection, trigger: quote)
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
                Text("\(week.count)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: Double(week.count)))
                Text(plural(week.count, "запись", "записи", "записей")).font(.headline).opacity(0.85)
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
            HomeTile(title: "Картриджи · " + HomeView.monthName.string(from: Date()), value: monthQty,
                     chip: weekQty > 0 ? "+\(weekQty) за неделю" : "за неделю 0", good: true) { tab = .carts }
            HomeTile(title: "Сотрудники", value: staff,
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
    let chip: String
    let good: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Text("\(value)")
                    .font(.title.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(value)))
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
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

private extension View {
    /// Появление снизу с задержкой — карточки выезжают по очереди.
    func rise(_ on: Bool, _ delay: Double) -> some View {
        opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 22)
            .scaleEffect(on ? 1 : 0.97)
            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(delay), value: on)
    }
}
