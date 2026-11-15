import AudioToolbox
import CoreImage.CIFilterBuiltins
import CoreMotion
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// ── отклик и звуки (Настройки → Оформление) ─────────────────────────────────
enum Feel {
    static let hapticsKey = "feel.haptics"
    static let soundsKey = "feel.sounds"
    static var haptics: Bool { UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true }
    static var sounds: Bool { UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? true }

    /// «Дзынь»: заявка закрыта. Системный звук — молчит, когда iPhone на беззвучном.
    static func ding() { if sounds { AudioServicesPlaySystemSound(1103) } }
    /// «Ушло»: отчёт начальнику отправлен.
    static func sent() { if sounds { AudioServicesPlaySystemSound(1001) } }
}

extension View {
    /// Как sensoryFeedback, но молчит, когда отклик выключен в настройках.
    func feel<T: Equatable>(_ f: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(f, trigger: trigger) { _, _ in Feel.haptics }
    }

    func feel<T: Equatable>(_ f: SensoryFeedback, trigger: T, condition: @escaping (T, T) -> Bool) -> some View {
        sensoryFeedback(f, trigger: trigger) { old, new in Feel.haptics && condition(old, new) }
    }

    /// Карточка выезжает снизу и проявляется, когда on стало true; с задержкой — карточки идут по очереди.
    /// on хранит страница, а не карточка: строки списка пересоздаются при прокрутке и выезжали бы заново.
    func rise(_ on: Bool, _ delay: Double = 0) -> some View {
        opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 22)
            .scaleEffect(on ? 1 : 0.97)
            .animation(Motion.reduced ? nil : Animation.spring(response: 0.6, dampingFraction: 0.8).delay(delay), value: on)
    }
}

/// Число подпрыгивает, когда изменилось: «+1» к заявкам, картриджам, сотрудникам.
struct Bump: ViewModifier {
    let value: Int
    @State private var up = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(up ? 1.18 : 1, anchor: .leading)
            .onChange(of: value) {
                guard !Motion.reduced else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { up = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(220))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { up = false }
                }
            }
    }
}

/// Блик один раз пробегает по виду слева направо: именинник в «Учёте».
struct Shine: ViewModifier {
    var on = true
    @State private var go = false

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Color.yellow.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 70)
                        .offset(x: go ? g.size.width + 70 : -70)
                }
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear {
                    guard !Motion.reduced else { return }
                    withAnimation(.easeInOut(duration: 1.3).delay(0.4)) { go = true }
                }
            }
        }
    }
}

// ── число на значке приложения: заявки «в работе» ───────────────────────────
enum Badge {
    static func set(_ n: Int) { UNUserNotificationCenter.current().setBadgeCount(n) { _ in } }
    static func allow() async { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) }
}

// ── праздники Казахстана ────────────────────────────────────────────────────
enum Holidays {
    static let list: [(month: Int, day: Int, name: String, emoji: String)] = [
        (1, 1, "Новый год", "🎄"), (1, 7, "Рождество", "⭐️"), (3, 8, "8 Марта", "💐"), (3, 21, "Наурыз", "🌷"),
        (5, 1, "Праздник единства народа Казахстана", "🤝"), (5, 7, "День защитника Отечества", "🎖"),
        (5, 9, "День Победы", "🕊"), (7, 6, "День столицы", "🏙"), (8, 30, "День Конституции", "📜"),
        (10, 25, "День Республики", "🇰🇿"), (12, 16, "День Независимости", "🇰🇿"),
    ]

    /// Сегодняшний или завтрашний праздник: «Завтра — Наурыз», 🌷.
    static func near(_ date: Date = Date()) -> (text: String, emoji: String)? {
        let cal = Calendar(identifier: .gregorian)
        for (offset, word) in [(0, "Сегодня"), (1, "Завтра")] {
            guard let d = cal.date(byAdding: .day, value: offset, to: date) else { continue }
            let m = cal.component(.month, from: d), day = cal.component(.day, from: d)
            if let h = list.first(where: { $0.month == m && $0.day == day }) { return ("\(word) — \(h.name)", h.emoji) }
        }
        return nil
    }

    /// Наурыз (21–23 марта): на главной падают лепестки.
    static var nauryz: Bool {
        let c = Calendar(identifier: .gregorian).dateComponents([.month, .day], from: Date())
        return c.month == 3 && (21...23).contains(c.day ?? 0)
    }
}

// ── серия: недели подряд, когда отчёт ушёл ──────────────────────────────────
enum Streak {
    static let key = "streak.weeks"

    static func record(_ monday: Date) {
        var weeks = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        weeks.insert(Dates.text(monday))
        UserDefaults.standard.set(Array(weeks.sorted().suffix(120)), forKey: key)
    }

    /// Сколько недель подряд: с этой, если отчёт уже ушёл, иначе с прошлой.
    static var count: Int {
        let weeks = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let cal = Calendar(identifier: .gregorian)
        var monday = Dates.monday(Date())
        if !weeks.contains(Dates.text(monday)) { monday = cal.date(byAdding: .day, value: -7, to: monday) ?? monday }
        var n = 0
        while weeks.contains(Dates.text(monday)) {
            n += 1
            monday = cal.date(byAdding: .day, value: -7, to: monday) ?? monday
        }
        return n
    }
}

// ── погода на главной (Open-Meteo: бесплатно, без регистрации) ──────────────
@MainActor
final class Weather: ObservableObject {
    static let shared = Weather()
    static let cityKey = "weather.city"
    /// Что показывает карточка. nil — ещё не загружено, города нет или нет связи.
    @Published var now: Sky?
    /// «Город не найден» — карточка предлагает сменить город.
    @Published var problem: String?
    @Published var loading = false
    private var at = Date.distantPast
    private var place = ""

    struct Sky: Equatable {
        enum Kind { case clear, cloudy, fog, rain, snow, storm }
        var temp: Int, hi: Int, lo: Int
        var wind: Int                      // м/с
        var kind: Kind
        var word: String                   // «дождь»
        var day: Bool
        var season: Season
        var place: String

        /// Ночь и гроза — картинка тёмная, текст на ней белый.
        var dark: Bool { !day || kind == .storm }

        var tip: String {
            switch kind {
            case .storm: return "⚡ Гроза — держите технику на ИБП"
            case .rain: return temp <= 1 ? "🧊 Гололёд — выходите пораньше" : "☂️ Возьмите зонт"
            case .snow: return "❄️ Снегопад — на дорогу больше времени"
            case .fog: return "🌫 Туман — осторожно за рулём"
            case .clear, .cloudy: break
            }
            if wind >= 14 { return "💨 Сильный ветер" }
            if temp >= 28 { return "🥤 Жарко — пейте воду" }
            if temp <= -15 { return "🧣 Мороз — одевайтесь теплее" }
            if temp <= 0 { return "🧣 Одевайтесь теплее" }
            return day ? "🙂 Хорошая погода" : "🌙 Хорошего вечера"
        }

        /// Картинка без данных: город не указан или погода ещё грузится — сезон и время суток сегодняшние.
        static func placeholder() -> Sky {
            let h = Calendar.current.component(.hour, from: Date())
            return Sky(temp: 0, hi: 0, lo: 0, wind: 3, kind: .clear, word: "", day: (6..<20).contains(h),
                       season: Season.of(Date()), place: "")
        }
    }

    /// Раз в полчаса или по запросу. Нет сети — остаётся прошлое.
    func load(force: Bool = false) async {
        #if DEBUG
        if Self.demo {
            now = Self.demos[demoIndex]
            return
        }
        #endif
        let city = (UserDefaults.standard.string(forKey: Self.cityKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty else {
            now = nil
            problem = nil
            return
        }
        guard force || city != place || Date().timeIntervalSince(at) > 1800, !loading else { return }
        loading = true
        defer { loading = false }
        struct Geo: Decodable {
            struct R: Decodable { let latitude: Double; let longitude: Double; let name: String }
            let results: [R]?
        }
        struct Now: Decodable {
            struct C: Decodable { let temperature_2m: Double; let weather_code: Int; let wind_speed_10m: Double; let is_day: Int }
            struct D: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: C
            let daily: D
        }
        do {
            var g = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            g.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
                            URLQueryItem(name: "language", value: "ru")]
            let (gd, _) = try await URLSession.shared.data(from: g.url!)
            guard let r = try JSONDecoder().decode(Geo.self, from: gd).results?.first else {
                now = nil
                problem = "Город «\(city)» не найден"
                place = city
                at = Date()
                return
            }
            var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            f.queryItems = [URLQueryItem(name: "latitude", value: String(r.latitude)),
                            URLQueryItem(name: "longitude", value: String(r.longitude)),
                            URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m,is_day"),
                            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
                            URLQueryItem(name: "wind_speed_unit", value: "ms"),
                            URLQueryItem(name: "forecast_days", value: "1"),
                            URLQueryItem(name: "timezone", value: "auto")]
            let (wd, _) = try await URLSession.shared.data(from: f.url!)
            let n = try JSONDecoder().decode(Now.self, from: wd)
            let c = n.current
            let t = Int(c.temperature_2m.rounded())
            now = Sky(temp: t,
                      hi: n.daily.temperature_2m_max.first.map { Int($0.rounded()) } ?? t,
                      lo: n.daily.temperature_2m_min.first.map { Int($0.rounded()) } ?? t,
                      wind: Int(c.wind_speed_10m.rounded()), kind: Self.kind(c.weather_code), word: Self.word(c.weather_code),
                      day: c.is_day == 1, season: Season.of(Date()), place: r.name)
            problem = nil
            at = Date()
            place = city
        } catch {
            // нет связи: оставляем прошлое, если было
        }
    }

    /// Касание по карточке: обновить.
    func tapped() {
        #if DEBUG
        if Self.demo {
            demoIndex = (demoIndex + 1) % Self.demos.count
            now = Self.demos[demoIndex]
            return
        }
        #endif
        Task { await load(force: true) }
    }

    static func kind(_ code: Int) -> Sky.Kind {
        switch code {
        case 0, 1: return .clear
        case 45, 48: return .fog
        case 51...67, 80...82: return .rain
        case 71...77, 85, 86: return .snow
        case 95...99: return .storm
        default: return .cloudy
        }
    }

    static func word(_ code: Int) -> String {
        switch code {
        case 0: return "ясно"
        case 1, 2: return "переменная облачность"
        case 3: return "пасмурно"
        case 45, 48: return "туман"
        case 51...57: return "морось"
        case 61...67, 80...82: return "дождь"
        case 71...77, 85, 86: return "снег"
        case 95...99: return "гроза"
        default: return "облачно"
        }
    }

    #if DEBUG
    /// Тур в симуляторе (REPORTER_WEATHER_DEMO): погода без сети, касание по карточке листает сцены.
    static let demo = ProcessInfo.processInfo.environment["REPORTER_WEATHER_DEMO"] != nil
    private var demoIndex = 0
    static let demos: [Sky] = [
        Sky(temp: 6, hi: 8, lo: 2, wind: 9, kind: .rain, word: "дождь", day: true, season: .autumn, place: "Актобе"),
        Sky(temp: -12, hi: -8, lo: -17, wind: 4, kind: .snow, word: "снег", day: true, season: .winter, place: "Актобе"),
        Sky(temp: 14, hi: 16, lo: 5, wind: 3, kind: .clear, word: "ясно", day: true, season: .spring, place: "Актобе"),
        Sky(temp: 27, hi: 31, lo: 18, wind: 14, kind: .storm, word: "гроза", day: true, season: .summer, place: "Актобе"),
        Sky(temp: 9, hi: 13, lo: 4, wind: 2, kind: .clear, word: "ясно", day: false, season: .spring, place: "Актобе"),
        Sky(temp: 4, hi: 7, lo: 1, wind: 6, kind: .fog, word: "туман", day: true, season: .autumn, place: "Актобе"),
    ]
    #endif
}

// ── поздравление в WhatsApp ─────────────────────────────────────────────────
enum Congrats {
    static func text(_ fio: String) -> String {
        let p = fio.split(separator: " ")
        let name = p.count > 1 ? String(p[1]) : fio
        return "\(name), с днём рождения! 🎉 Здоровья, удачи и чтобы техника не подводила. Ваш IT-отдел"
    }

    /// WhatsApp по номеру сотрудника; номера нет — nil (тогда «Поделиться»).
    static func whatsApp(_ phone: String, _ fio: String) -> URL? {
        var digits = phone.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("8") { digits = "7" + digits.dropFirst() }
        guard digits.count >= 10 else { return nil }
        var c = URLComponents(string: "https://wa.me/" + digits)
        c?.queryItems = [URLQueryItem(name: "text", value: text(fio))]
        return c?.url
    }
}

// ── наклон телефона: параллакс на главной и блик голограммы ─────────────────
@MainActor
final class Tilt: ObservableObject {
    static let shared = Tilt()
    /// Наклон от −1 до 1 по обеим осям — одним значением: одно обновление экрана на отсчёт датчика.
    @Published private(set) var lean = CGSize.zero
    private let motion = CMMotionManager()
    private var users = 0
    private var fx = 0.0, fy = 0.0          // сглаженный наклон; на экран идёт, когда сдвиг уже заметен

    /// Датчик работает, только пока его кто-то показывает на экране. 60 отсчётов в секунду со сглаживанием:
    /// при 15 карточки главной двигались рывками, и всё приложение казалось тормозящим.
    func start() {
        users += 1
        guard users == 1, !Motion.reduced, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            MainActor.assumeIsolated { self?.feed(g.x, g.y) }
        }
    }

    func stop() {
        users = max(0, users - 1)
        if users == 0 { motion.stopDeviceMotionUpdates() }
    }

    private func feed(_ gx: Double, _ gy: Double) {
        // к новому положению — на четверть пути за отсчёт: дрожь руки сглаживается
        fx += (max(-1, min(1, gx * 2)) - fx) * 0.25
        fy += (max(-1, min(1, (gy + 0.55) * 2)) - fy) * 0.25      // телефон обычно держат под наклоном
        // сдвиг меньше пикселя не показываем: телефон лежит или просто в руке — экран не перерисовывается
        guard abs(fx - Double(lean.width)) > 0.01 || abs(fy - Double(lean.height)) > 0.01 else { return }
        lean = CGSize(width: fx, height: fy)
    }
}

/// Сдвиг за наклоном телефона (только пока active).
struct Parallax: ViewModifier {
    var amount: CGFloat = 6
    @ObservedObject private var tilt = Tilt.shared

    func body(content: Content) -> some View {
        content.offset(x: tilt.lean.width * amount, y: tilt.lean.height * amount)
    }
}

/// Голографический блик: радужный отлив, который бежит за наклоном телефона.
struct HoloSheen: View {
    @ObservedObject private var tilt = Tilt.shared

    var body: some View {
        // без режима наложения: на тёмном фоне отлив в нём пропадал, а слой с наложением рисуется дороже
        AngularGradient(colors: [.pink, .yellow, .green, .cyan, .blue, .purple, .pink],
                        center: UnitPoint(x: 0.5 + tilt.lean.width * 0.4, y: 0.5 + tilt.lean.height * 0.4),
                        angle: .degrees(Double(tilt.lean.width) * 90))
            .opacity(Motion.reduced ? 0 : 0.2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { Tilt.shared.start() }
            .onDisappear { Tilt.shared.stop() }
    }
}

// ── фольга: новую медаль стирают пальцем ────────────────────────────────────
struct Foil: ViewModifier {
    @Binding var revealed: Bool
    @State private var points: [CGPoint] = []

    func body(content: Content) -> some View {
        content.overlay {
            if !revealed {
                LinearGradient(colors: [Color(hex: 0xE5E7EB), Color(hex: 0x9CA3AF), Color(hex: 0xD1D5DB)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Text("сотри").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.9)))
                    .mask {
                        // точки читаем здесь: замыкание Canvas считается при рисовании, вне body, и новые точки
                        // не перерисовывали фольгу — стёртое не было видно до самого открытия медали
                        let pts = points
                        Canvas { ctx, size in
                            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                            ctx.blendMode = .clear
                            for p in pts {
                                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)), with: .color(.black))
                            }
                        }
                    }
                    .clipShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        points.append(v.location)
                        if points.count > 40 { withAnimation(.easeOut(duration: 0.4)) { revealed = true } }
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Новая медаль под фольгой")
                    .accessibilityAction(named: "Открыть") { revealed = true }
                    .transition(.opacity)
            }
        }
    }
}

// ── падающие снежинки, лепестки, шарики: несколько секунд и исчезают ────────
struct Fall: View {
    let emoji: [String]
    /// Пора падать: главная уже видна. При запуске страницу закрывает заставка или окно входа — под ними
    /// листья падали незаметно.
    let on: Bool
    /// Новый день — падает снова (приложение живёт в памяти сутками).
    let day: String
    @State private var flakes: [Flake] = []
    @State private var go = false
    /// За какой день уже падало: смена темы пересоздаёт страницу, и листья сыпались заново.
    private static var played = ""

    struct Flake: Identifiable {
        let id: Int
        let x: CGFloat, drift: CGFloat, size: CGFloat, delay: Double
        let e: String
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(flakes) { f in
                    Text(f.e).font(.system(size: f.size))
                        .position(x: f.x * g.size.width + (go ? f.drift : 0), y: go ? g.size.height + 30 : -30)
                        .opacity(go ? 0.15 : 1)
                        .animation(.easeIn(duration: 5).delay(f.delay), value: go)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: on ? day : "") {
            guard on, Fall.played != day, !emoji.isEmpty, !Motion.reduced else { return }
            Fall.played = day
            go = false
            flakes = (0..<22).map { i in
                Flake(id: i, x: .random(in: 0...1), drift: .random(in: -40...40), size: .random(in: 14...24),
                      delay: .random(in: 0...1.5), e: emoji[i % emoji.count])
            }
            try? await Task.sleep(for: .milliseconds(50))
            go = true
            try? await Task.sleep(for: .seconds(7))
            flakes = []
            go = false
        }
    }
}

/// Тряска: неверный PIN-код.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// QR-код для обратной стороны карточки устройства.
@MainActor
enum QR {
    /// Последний нарисованный код: карточка перерисовывается часто, а рисовать код заново — десятки миллисекунд.
    private static var last: (text: String, image: UIImage)?

    static func image(_ text: String) -> UIImage? {
        if let last, last.text == text { return last.image }
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let o = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(o, from: o.extent) else { return nil }
        let image = UIImage(cgImage: cg)
        last = (text, image)
        return image
    }
}
