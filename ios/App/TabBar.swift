import SwiftUI

enum AppTab: Int, CaseIterable, Hashable {
    case home, assets, report, carts, settings

    var title: String {
        switch self {
        case .home: "Главная"
        case .assets: "Учёт"
        case .report: "Отчёт"
        case .carts: "Картриджи"
        case .settings: "Настройки"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .assets: "desktopcomputer"
        case .report: "list.bullet.clipboard"
        case .carts: "printer"
        case .settings: "gearshape"
        }
    }

    /// Что делает «+» на этой странице; nil — кнопки нет.
    var add: QuickAction? {
        switch self {
        case .assets: .newEmployee
        case .report: .newEntry
        case .carts: .newCart
        case .home, .settings: nil
        }
    }
}

/// Нижняя панель из жидкого стекла, как в Telegram: нажал — линза под пальцем,
/// повёл — линза едет за пальцем и подсвечивает вкладку, отпустил — открылась та, где палец.
/// Без пальца линза едет за прокруткой страниц кадр в кадр.
struct GlassTabBar: View {
    static let height: CGFloat = 54

    let selection: AppTab
    /// 0…4 — где сейчас прокрутка страниц
    let progress: CGFloat
    let onSelect: (AppTab) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var fingerX: CGFloat?
    @State private var hovered: AppTab?
    @State private var taps: [AppTab: Int] = [:]

    private let tabs = AppTab.allCases

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(tabs.count)
            let page = min(max(progress, 0), CGFloat(tabs.count - 1))
            let shown = hovered ?? tabs[Int(page.rounded())]
            let lensX: CGFloat = fingerX.map { min(max($0 - w / 2, 0), geo.size.width - w) } ?? page * w
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Brand.sky.opacity(scheme == .dark ? 0.3 : 0.2))
                    .overlay(Capsule().strokeBorder(.white.opacity(scheme == .dark ? 0.25 : 0.6), lineWidth: 0.8))
                    .shadow(color: Brand.blue.opacity(0.25), radius: 8, y: 3)
                    .frame(width: w, height: geo.size.height - 10)
                    .scaleEffect(fingerX == nil ? 1 : 1.14)
                    .offset(x: lensX)
                    // пружина только когда палец на панели или отпущен; за прокруткой — без задержки
                    .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: fingerX)
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.self) { t in
                        TabIcon(tab: t, active: t == shown, trigger: taps[t, default: 0])
                            .frame(width: w, height: geo.size.height)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(t == selection ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { onSelect(t) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        fingerX = v.location.x
                        let t = tab(at: v.location.x, width: w)
                        if t != hovered { hovered = t }
                    }
                    .onEnded { v in
                        let t = tab(at: v.location.x, width: w)
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                            fingerX = nil
                            hovered = nil
                        }
                        if t == selection { taps[t, default: 0] += 1 }   // та же вкладка — просто оживить иконку
                        onSelect(t)
                    }
            )
        }
        .frame(height: Self.height)
        .padding(.horizontal, 5)
        // плотная подложка под стеклом: одно стекло на тёмном фоне почти не видно
        .background(Capsule().fill(scheme == .dark ? Color(white: 0.13).opacity(0.92) : Color.white.opacity(0.9)))
        .overlay(Capsule().strokeBorder(.white.opacity(scheme == .dark ? 0.14 : 0.5), lineWidth: 0.8))
        // без .interactive(): интерактивное стекло забирало короткие касания и над панелью — переключатели настроек
        // в нижней части экрана через раз не нажимались
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(scheme == .dark ? 0.6 : 0.15), radius: 14, y: 6)
        .onChange(of: selection) { _, t in taps[t, default: 0] += 1 }     // иконка оживает, когда страница сменилась
        .sensoryFeedback(.selection, trigger: hovered) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: selection)
    }

    private func tab(at x: CGFloat, width w: CGFloat) -> AppTab {
        tabs[min(max(Int(x / w), 0), tabs.count - 1)]
    }
}

/// Иконка вкладки: у каждой своя анимация при нажатии, как в Telegram.
private struct TabIcon: View {
    let tab: AppTab
    let active: Bool
    let trigger: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // только иконка, без подписи; название вкладки — для VoiceOver
        symbol
            .font(.system(size: 23, weight: .semibold))
            .symbolVariant(active ? .fill : .none)
            .contentTransition(.symbolEffect(.replace))
            .frame(height: 28)
            .accessibilityLabel(tab.title)
        .foregroundStyle(active ? (scheme == .dark ? Brand.sky : Brand.blue) : Color.secondary)
        .scaleEffect(active ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)
    }

    @ViewBuilder private var symbol: some View {
        let img = Image(systemName: tab.icon)
        switch tab {
        case .home: img.symbolEffect(.bounce.up, value: trigger)
        case .assets: img.symbolEffect(.bounce.down, value: trigger)
        case .report: img.symbolEffect(.wiggle, value: trigger)
        case .carts: img.symbolEffect(.bounce.up.byLayer, value: trigger)
        case .settings: img.symbolEffect(.rotate, value: trigger)
        }
    }
}

/// Живой фон под стеклом: фирменные цвета медленно перетекают.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let s = Float(sin(t * 0.35)) * 0.14
            let c = Float(cos(t * 0.27)) * 0.14
            MeshGradient(width: 3, height: 3, points: [
                SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0), SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 0.5 + c), SIMD2<Float>(0.5 + s, 0.5 - c), SIMD2<Float>(1, 0.5 + s),
                SIMD2<Float>(0, 1), SIMD2<Float>(0.5, 1), SIMD2<Float>(1, 1),
            ], colors: scheme == .dark ? AppBackground.dark : AppBackground.light)
        }
        .ignoresSafeArea()
    }

    private static let light: [Color] = [
        Color(red: 0.86, green: 0.93, blue: 0.99), Color(red: 0.95, green: 0.97, blue: 1.0), Color(red: 1.0, green: 0.95, blue: 0.80),
        Color(red: 0.80, green: 0.90, blue: 0.99), Color(red: 0.93, green: 0.96, blue: 0.99), Color(red: 0.99, green: 0.93, blue: 0.78),
        Color(red: 0.84, green: 0.89, blue: 1.0), Color(red: 0.90, green: 0.95, blue: 0.99), Color(red: 0.86, green: 0.93, blue: 0.99),
    ]

    private static let dark: [Color] = [
        Color(red: 0.03, green: 0.10, blue: 0.18), Color(red: 0.02, green: 0.04, blue: 0.08), Color(red: 0.20, green: 0.15, blue: 0.02),
        Color(red: 0.03, green: 0.16, blue: 0.28), Color(red: 0.02, green: 0.05, blue: 0.10), Color(red: 0.12, green: 0.10, blue: 0.02),
        Color(red: 0.06, green: 0.10, blue: 0.25), Color(red: 0.02, green: 0.05, blue: 0.10), Color(red: 0.03, green: 0.10, blue: 0.18),
    ]
}
