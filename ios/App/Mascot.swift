import SwiftUI

// ── талисман: пиксельный робот-сисадмин в наушниках ─────────────────────────
/// Рисунок в поле 200×200 (масштабируется под размер), цвета — из темы.
struct PixelBot: View {
    enum Mood { case idle, blink, happy, sleep, note, wave }
    var mood: Mood = .idle
    @AppStorage(Theme.key) private var palette = Theme.defaultID      // смена темы перекрашивает робота

    var body: some View {
        let p = Theme.current
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 200, y: size.height / 200)
            draw(&ctx, p)
        }
        .accessibilityHidden(true)
    }

    private func draw(_ c: inout GraphicsContext, _ p: Palette) {
        let silver = Color(hex: 0xCBD5E1), steel = Color(hex: 0x94A3B8)
        let eye = p.sky.mix(with: .white, by: 0.35), deep = p.blue.mix(with: .black, by: 0.35)
        func line(_ a: CGPoint, _ b: CGPoint, _ col: Color, _ w: CGFloat) {
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            c.stroke(path, with: .color(col), style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 4) {
            c.fill(Path(CGRect(x: x, y: y, width: w, height: 4)), with: .color(eye))
        }
        // тень, антенна, руки
        c.fill(Path(ellipseIn: CGRect(x: 54, y: 181, width: 92, height: 14)), with: .color(.black.opacity(0.28)))
        line(CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 22), silver, 4)
        c.fill(Path(ellipseIn: CGRect(x: 93, y: 11, width: 14, height: 14)), with: .color(p.sun))
        line(CGPoint(x: 46, y: 146), CGPoint(x: 34, y: 170), deep, 13)
        if mood == .note { line(CGPoint(x: 156, y: 146), CGPoint(x: 170, y: 132), deep, 13) }
        else if mood != .wave { line(CGPoint(x: 154, y: 146), CGPoint(x: 166, y: 170), deep, 13) }
        // корпус и лицо-экран
        let body = Path(ellipseIn: CGRect(x: 34, y: 46, width: 132, height: 132))
        c.fill(body, with: .radialGradient(Gradient(colors: [p.blue.mix(with: .white, by: 0.12), p.blue.mix(with: .black, by: 0.62)]),
                                           center: CGPoint(x: 80, y: 80), startRadius: 0, endRadius: 140))
        c.stroke(body, with: .color(p.sky.opacity(0.7)), lineWidth: 2)
        c.fill(Path(roundedRect: CGRect(x: 52, y: 80, width: 96, height: 62), cornerRadius: 31),
               with: .color(Color(hex: 0x0B0A24)))
        // глаза и рот из «пикселей»
        for cx in [81.0, 119.0] {
            switch mood {
            case .idle, .note:
                let s = mood == .note ? 3.0 : 0.0
                for dy in [0.0, 5, 10, 15] { for dx in [0.0, 5] { px(cx - 5 + dx + s, 96 + dy + s) } }
            case .blink:
                px(cx - 7, 108); px(cx - 2, 108); px(cx + 3, 108)
            case .happy, .wave:
                px(cx - 9, 110); px(cx - 5, 106); px(cx - 1, 102); px(cx + 3, 106); px(cx + 7, 110)
            case .sleep:
                px(cx - 8, 107); px(cx - 3, 110); px(cx + 2, 110); px(cx + 7, 107)
            }
        }
        switch mood {
        case .happy, .wave: px(86, 124); px(90, 128); px(94, 131, 12); px(106, 128); px(110, 124)
        case .sleep: px(96, 130, 8)
        default: px(90, 128); px(95, 131, 10); px(106, 128)
        }
        // наушники и микрофон
        var band = Path()
        band.move(to: CGPoint(x: 36, y: 106))
        band.addCurve(to: CGPoint(x: 164, y: 106), control1: CGPoint(x: 36, y: 16), control2: CGPoint(x: 164, y: 16))
        c.stroke(band, with: .color(silver), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        for x in [20.0, 156] {
            c.fill(Path(roundedRect: CGRect(x: x, y: 88, width: 24, height: 42), cornerRadius: 11), with: .color(steel))
            c.fill(Path(roundedRect: CGRect(x: x + 5, y: 95, width: 14, height: 28), cornerRadius: 7), with: .color(p.sky))
        }
        var mic = Path()
        mic.move(to: CGPoint(x: 166, y: 126))
        mic.addCurve(to: CGPoint(x: 124, y: 158), control1: CGPoint(x: 166, y: 154), control2: CGPoint(x: 142, y: 160))
        c.stroke(mic, with: .color(silver), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        c.fill(Path(ellipseIn: CGRect(x: 114, y: 152, width: 12, height: 12)), with: .color(p.sun))
        // приветствие: рука поднята над наушником
        if mood == .wave {
            line(CGPoint(x: 160, y: 142), CGPoint(x: 185, y: 102), deep, 13)
            c.fill(Path(ellipseIn: CGRect(x: 177, y: 88, width: 16, height: 16)), with: .color(silver))
        }
        // блокнот, сон, праздник
        if mood == .note {
            c.drawLayer { l in
                l.translateBy(x: 169, y: 120)
                l.rotate(by: .degrees(-12))
                l.translateBy(x: -169, y: -120)
                let r = Path(roundedRect: CGRect(x: 150, y: 96, width: 38, height: 48), cornerRadius: 5)
                l.fill(r, with: .color(Color(hex: 0xFEF3C7)))
                l.stroke(r, with: .color(Color(hex: 0xF59E0B)), lineWidth: 2)
                for (y, w) in [(110.0, 24.0), (119, 24), (128, 18)] {
                    var lp = Path()
                    lp.move(to: CGPoint(x: 157, y: y))
                    lp.addLine(to: CGPoint(x: 157 + w, y: y))
                    l.stroke(lp, with: .color(Color(hex: 0xF59E0B)), lineWidth: 2)
                }
            }
        }
        if mood == .sleep {
            c.draw(Text("Z").font(.system(size: 22, weight: .heavy)).foregroundStyle(p.sky), at: CGPoint(x: 160, y: 38))
            c.draw(Text("z").font(.system(size: 15, weight: .heavy)).foregroundStyle(p.sky), at: CGPoint(x: 178, y: 22))
        }
        if mood == .happy {
            for (x, y, col) in [(30.0, 40.0, p.sun), (170, 36, p.sky), (20, 90, Color.yellow), (182, 80, p.sun), (50, 18, Color.green)] {
                c.fill(Path(roundedRect: CGRect(x: x, y: y, width: 8, height: 12), cornerRadius: 2), with: .color(col))
            }
        }
    }
}

/// Быстрые действия из блокнота талисмана — только значками; подпись — по долгому нажатию и для VoiceOver.
enum MascotItem: String, CaseIterable, Identifiable {
    case entry, cart, employee, backup, theme
    var id: String { rawValue }

    var title: String {
        switch self {
        case .entry: "Новая запись"
        case .cart: "Выдать картридж"
        case .employee: "Новый сотрудник"
        case .backup: "Отправить бэкап"
        case .theme: "Сменить тему"
        }
    }

    var icon: String {
        switch self {
        case .entry: "square.and.pencil"
        case .cart: "printer.fill"
        case .employee: "person.badge.plus"
        case .backup: "paperplane.fill"
        case .theme: "paintpalette.fill"
        }
    }
}

/// Талисман вместо «+» на всех вкладках: нажали — достаёт блокнот, кнопки вытекают из него каплями.
/// В покое стоит, изредка моргает (одна маленькая картинка раз в несколько секунд), после 20:00 спит.
struct MascotMenu: View {
    @Binding var open: Bool
    let shown: Bool
    var celebrate = false
    /// Бэкап уходит — талисман держит блокнот.
    var busy = false
    /// Главная открылась (заставка или окно входа ушли) — талисман машет рукой.
    var greet = false
    let act: (MascotItem) -> Void

    @AppStorage(Theme.key) private var palette = Theme.defaultID
    @AppStorage("hint.mascot") private var greeted = false        // подсказка «нажми на меня» уже была
    @AppStorage("hint.menu") private var labeled = false           // подписи у кнопок уже показывали
    @State private var themes = false
    @State private var hint: MascotItem?
    @State private var allLabels = false
    @State private var blink = false
    @State private var wave = false
    @State private var waved = false
    @State private var taps = 0

    static let size: CGFloat = 64
    fileprivate static let items = MascotItem.allCases

    var body: some View {
        ZStack {
            if !Motion.reduced && shown { Goo(fanned: fanned) }   // робот спрятан (клавиатура) — капля под ним не торчит точкой
            ForEach(Array(Self.items.enumerated()), id: \.element) { i, item in bubble(item, i) }
            tray
            bot
        }
        .frame(width: Self.size, height: Self.size)
        .onChange(of: greet, initial: true) { _, on in if on { Task { await waving() } } }
    }

    private var fanned: Bool { open && !themes }

    /// Веер вверх-влево: слева направо по дуге от робота.
    fileprivate static func spot(_ i: Int) -> CGSize {
        let a = (188 - 26 * Double(i)) * .pi / 180
        return CGSize(width: 104 * cos(a), height: -104 * sin(a))
    }

    fileprivate static func spring(_ i: Int, _ fanned: Bool) -> Animation {
        .spring(response: 0.42, dampingFraction: 0.68).delay(fanned ? Double(i) * 0.03 : 0)
    }

    private func bubble(_ item: MascotItem, _ i: Int) -> some View {
        Image(systemName: item.icon)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background { if Motion.reduced { Circle().fill(Brand.blue) } }   // без жидкости — просто кружок
            .contentShape(Circle())
            .onTapGesture { tap(item) }
            .onLongPressGesture(minimumDuration: 0.35) { show(item) }
            // кнопка — только кружок: подпись рядом не входит в её рамку, иначе центр рамки уезжает с кружка
            .accessibilityElement()
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap(item) }
            .overlay(alignment: labelPlace(i).0) {
                if fanned && (hint == item || allLabels) { label(item.title).offset(labelPlace(i).1) }
            }
            .scaleEffect(fanned ? 1 : 0.3)
            .opacity(fanned ? 1 : 0)
            .offset(fanned ? Self.spot(i) : .zero)
            .animation(Self.spring(i, fanned), value: fanned)
            .allowsHitTesting(fanned)
            .accessibilityHidden(!fanned)
    }

    /// Подпись у кнопки: слева от кружка, у самой верхней — над ним, у соседней с ней — слева чуть выше:
    /// при первом открытии подписи видны у всех сразу, и две верхние иначе наезжали друг на друга.
    private func labelPlace(_ i: Int) -> (Alignment, CGSize) {
        switch Self.items.count - 1 - i {
        case 0: (.topTrailing, CGSize(width: 0, height: -36))
        case 1: (.trailing, CGSize(width: -60, height: -12))
        default: (.trailing, CGSize(width: -60, height: 0))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)          // VoiceOver читает название у самой кнопки
    }

    /// Лоток тем: две строки кружков над роботом; выбрали — новая тема расходится кругом от пальца.
    private var tray: some View {
        let list = Theme.choices
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 10), count: 5), spacing: 10) {
            ForEach(list) { p in
                Circle()
                    .fill(LinearGradient(colors: [p.sky, p.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(.primary, lineWidth: palette == p.id ? 2.5 : 0).padding(-3))
                    .onTapGesture(coordinateSpace: .global) { point in
                        Theme.choose(p.id, from: point)
                        close()
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Тема «\(p.name)»")
                    .accessibilityAddTraits(palette == p.id ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction {
                        Theme.choose(p.id, from: nil)
                        close()
                    }
            }
        }
        .frame(width: 5 * 36 + 4 * 10)
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .fixedSize()
        .scaleEffect(themes ? 1 : 0.3, anchor: .bottomTrailing)
        .opacity(themes ? 1 : 0)
        .offset(x: -132, y: -100)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: themes)
        .allowsHitTesting(themes)
        .accessibilityHidden(!themes)
    }

    private var bot: some View {
        PixelBot(mood: mood)
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
            .onTapGesture { toggle() }
            .feel(.impact(weight: .light), trigger: taps)
            // кнопка — только робот: с подсказкой в рамке её центр приходился на «Найти» главной
            .accessibilityElement()
            .accessibilityLabel(open ? "Закрыть быстрые действия" : "Быстрые действия")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .overlay(alignment: .topTrailing) {
                if !greeted && shown && !open {
                    label("Нажми на меня — быстрые действия").offset(x: -6, y: -40)
                }
            }
            .scaleEffect(shown ? 1 : 0.2)
            .opacity(shown ? 1 : 0)
            .animation(.spring(response: 0.45, dampingFraction: 0.65), value: shown)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .task { await blinking() }
    }

    private var mood: PixelBot.Mood {
        if open || busy { return .note }
        if celebrate { return .happy }
        let h = Calendar.current.component(.hour, from: Date())
        if h >= 20 || h < 7 { return .sleep }
        if wave { return .wave }
        return blink ? .blink : .idle
    }

    /// Приветствие: главная открылась — талисман трижды машет рукой (ночью он спит).
    private func waving() async {
        guard !waved, !Motion.reduced else { return }
        waved = true
        try? await Task.sleep(for: .milliseconds(900))        // карточки главной к этому времени выехали
        for _ in 0..<3 {
            wave = true
            try? await Task.sleep(for: .milliseconds(280))
            wave = false
            try? await Task.sleep(for: .milliseconds(220))
        }
    }

    private func blinking() async {
        guard !Motion.reduced else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 4...7)))
            guard !Task.isCancelled else { return }
            blink = true
            try? await Task.sleep(for: .milliseconds(150))
            blink = false
        }
    }

    private func toggle() {
        taps += 1
        greeted = true
        if open {
            close()
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { open = true }
        if !labeled {                       // первый раз — подписи у всех кнопок на 2,5 секунды
            labeled = true
            withAnimation { allLabels = true }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { allLabels = false }
            }
        }
    }

    private func tap(_ item: MascotItem) {
        if item == .theme {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { themes = true }
            return
        }
        close()
        act(item)
    }

    private func show(_ item: MascotItem) {
        withAnimation { hint = item }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if hint == item { withAnimation { hint = nil } }
        }
    }

    private func close() {
        hint = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            open = false
            themes = false
        }
    }
}

/// Жидкость: капли с порогом прозрачности сливаются, пока кнопки выезжают из робота. Отдельным видом: когда
/// талисман моргает или машет, капли не перерисовываются (размытие на каждую перерисовку — дорого).
private struct Goo: View {
    let fanned: Bool
    @AppStorage(Theme.key) private var palette = Theme.defaultID      // смена темы перекрашивает капли

    var body: some View {
        let color = Brand.blue
        Canvas { ctx, size in
            ctx.addFilter(.alphaThreshold(min: 0.5, color: color))
            ctx.addFilter(.blur(radius: 9))
            ctx.drawLayer { l in
                for i in 0...MascotMenu.items.count {
                    if let s = ctx.resolveSymbol(id: i) { l.draw(s, at: CGPoint(x: size.width / 2, y: size.height / 2)) }
                }
            }
        } symbols: {
            Circle().frame(width: 30, height: 30).tag(MascotMenu.items.count)
            ForEach(Array(MascotMenu.items.indices), id: \.self) { i in
                Circle().frame(width: 52, height: 52)
                    .scaleEffect(fanned ? 1 : 0.2)
                    .offset(fanned ? MascotMenu.spot(i) : .zero)
                    .animation(MascotMenu.spring(i, fanned), value: fanned)
                    .tag(i)
            }
        }
        .frame(width: 340, height: 340)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Пустой экран: робот и подсказка, что сделать (вместо системной заглушки).
struct EmptyState: View {
    let title: String
    let text: Text

    init(_ title: String, systemImage: String, description: Text) {
        self.title = title
        text = description
    }

    var body: some View {
        VStack(spacing: 10) {
            PixelBot().frame(width: 96, height: 96)
            Text(title).font(.title3.bold())
            text.font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

/// Конфетти и самолётик: отчёт ушёл начальнику. Играет один раз по trigger и исчезает.
struct Confetti: View {
    let trigger: Int
    @State private var pieces: [Piece] = []
    @State private var fall = false

    struct Piece: Identifiable {
        let id = UUID()
        let x: CGFloat, drift: CGFloat, spin: Double, delay: Double
        let color: Color
        let size: CGSize
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(pieces) { p in
                    RoundedRectangle(cornerRadius: 2).fill(p.color)
                        .frame(width: p.size.width, height: p.size.height)
                        .rotationEffect(.degrees(fall ? p.spin : 0))
                        .position(x: p.x * g.size.width + (fall ? p.drift : 0), y: fall ? g.size.height + 40 : -20)
                        .animation(.easeIn(duration: 1.8).delay(p.delay), value: fall)
                }
                if !pieces.isEmpty {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Brand.sky)
                        .rotationEffect(.degrees(fall ? -30 : 0))
                        .position(x: fall ? g.size.width + 40 : g.size.width / 2, y: fall ? -40 : g.size.height * 0.6)
                        .opacity(fall ? 0 : 1)
                        .animation(.easeIn(duration: 1.0), value: fall)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            guard !Motion.reduced else { return }
            let colors = [Brand.sky, Brand.blue, Brand.sun, Color.yellow, Color.green, Color.orange]
            pieces = (0..<70).map { _ in
                Piece(x: .random(in: 0...1), drift: .random(in: -60...60), spin: .random(in: 180...900),
                      delay: .random(in: 0...0.35), color: colors.randomElement()!,
                      size: CGSize(width: .random(in: 6...10), height: .random(in: 8...14)))
            }
            fall = false
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                fall = true
                try? await Task.sleep(for: .seconds(2.4))
                pieces = []
                fall = false
            }
        }
    }
}
