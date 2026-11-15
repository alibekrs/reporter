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

    /// Первое появление: карточка выезжает снизу и проявляется.
    func appearRise(_ delay: Double = 0) -> some View { modifier(Rise(delay: delay)) }
}

private struct Rise: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .onAppear {
                guard !shown else { return }
                if Motion.reduced { shown = true } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(delay)) { shown = true }
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
    @Published var text: String?
    @Published var icon = "cloud.fill"
    @Published var loading = false
    private var at = Date.distantPast
    private var place = ""

    /// Раз в полчаса или по запросу. Нет сети — карточки просто нет.
    func load(force: Bool = false) async {
        let city = (UserDefaults.standard.string(forKey: Self.cityKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty else {
            text = nil
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
            struct C: Decodable { let temperature_2m: Double; let weather_code: Int }
            let current: C
        }
        do {
            var g = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            g.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
                            URLQueryItem(name: "language", value: "ru")]
            let (gd, _) = try await URLSession.shared.data(from: g.url!)
            guard let r = try JSONDecoder().decode(Geo.self, from: gd).results?.first else {
                text = "Город «\(city)» не найден"
                icon = "questionmark.circle"
                return
            }
            var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            f.queryItems = [URLQueryItem(name: "latitude", value: String(r.latitude)),
                            URLQueryItem(name: "longitude", value: String(r.longitude)),
                            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
                            URLQueryItem(name: "timezone", value: "auto")]
            let (wd, _) = try await URLSession.shared.data(from: f.url!)
            let c = try JSONDecoder().decode(Now.self, from: wd).current
            let t = Int(c.temperature_2m.rounded())
            let d = Self.describe(c.weather_code)
            icon = d.icon
            text = "\(t > 0 ? "+" : "")\(t)° · \(d.word) · \(r.name)"
            at = Date()
            place = city
        } catch {
            // нет связи: оставляем прошлое, если было
        }
    }

    static func describe(_ code: Int) -> (icon: String, word: String) {
        switch code {
        case 0: return ("sun.max.fill", "ясно")
        case 1, 2: return ("cloud.sun.fill", "переменная облачность")
        case 3: return ("cloud.fill", "пасмурно")
        case 45, 48: return ("cloud.fog.fill", "туман")
        case 51...57: return ("cloud.drizzle.fill", "морось")
        case 61...67, 80...82: return ("cloud.rain.fill", "дождь")
        case 71...77, 85, 86: return ("cloud.snow.fill", "снег")
        case 95...99: return ("cloud.bolt.rain.fill", "гроза")
        default: return ("cloud.fill", "облачно")
        }
    }
}

// ── мысль дня картинкой: «Поделиться» отдаёт PNG ───────────────────────────
struct QuoteImage: Transferable {
    let quote: Quote

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in try await item.png() }
    }

    @MainActor func png() throws -> Data {
        let r = ImageRenderer(content: QuoteArt(quote: quote))
        r.scale = 3
        guard let data = r.uiImage?.pngData() else { throw APIError(message: "Не получилось нарисовать картинку.") }
        return data
    }
}

private struct QuoteArt: View {
    let quote: Quote

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("МЫСЛЬ ДНЯ").font(.caption.weight(.heavy)).foregroundStyle(.white.opacity(0.8))
            Text("«\(quote.text)»").font(.title2.weight(.bold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Text("\(quote.who) · \(quote.about)").font(.subheadline).foregroundStyle(.white.opacity(0.85))
            Text("ITdesk").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(28)
        .frame(width: 380, alignment: .leading)
        .background(Brand.gradient)
    }
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
    @Published var x: Double = 0
    @Published var y: Double = 0
    private let motion = CMMotionManager()
    private var users = 0

    /// Датчик работает, только пока его кто-то показывает на экране, и не чаще 15 раз в секунду.
    func start() {
        users += 1
        guard users == 1, !Motion.reduced, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            MainActor.assumeIsolated {
                self?.x = max(-1, min(1, g.x * 2))
                self?.y = max(-1, min(1, (g.y + 0.55) * 2))      // телефон обычно держат под наклоном
            }
        }
    }

    func stop() {
        users = max(0, users - 1)
        if users == 0 { motion.stopDeviceMotionUpdates() }
    }
}

/// Сдвиг за наклоном телефона (только пока active).
struct Parallax: ViewModifier {
    var amount: CGFloat = 6
    @ObservedObject private var tilt = Tilt.shared

    func body(content: Content) -> some View {
        content.offset(x: tilt.x * amount, y: tilt.y * amount)
    }
}

/// Голографический блик: радужный отлив, который бежит за наклоном телефона.
struct HoloSheen: View {
    @ObservedObject private var tilt = Tilt.shared

    var body: some View {
        AngularGradient(colors: [.pink, .yellow, .green, .cyan, .blue, .purple, .pink],
                        center: UnitPoint(x: 0.5 + tilt.x * 0.4, y: 0.5 + tilt.y * 0.4),
                        angle: .degrees(tilt.x * 90))
            .opacity(Motion.reduced ? 0 : 0.28)
            .blendMode(.overlay)
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
    @State private var flakes: [Flake] = []
    @State private var go = false

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
        .task {
            guard !emoji.isEmpty, !Motion.reduced else { return }
            flakes = (0..<22).map { i in
                Flake(id: i, x: .random(in: 0...1), drift: .random(in: -40...40), size: .random(in: 14...24),
                      delay: .random(in: 0...1.5), e: emoji[i % emoji.count])
            }
            try? await Task.sleep(for: .milliseconds(50))
            go = true
            try? await Task.sleep(for: .seconds(7))
            flakes = []
        }
    }

    /// Что падает сегодня: Наурыз — тюльпаны, зима — снег, весна — цветы, осень — листья.
    static var season: [String] {
        if Holidays.nauryz { return ["🌷", "🌸", "🌼"] }
        switch Calendar(identifier: .gregorian).component(.month, from: Date()) {
        case 12, 1, 2: return ["❄️"]
        case 3, 4, 5: return ["🌸"]
        case 9, 10, 11: return ["🍂", "🍁"]
        default: return []
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
enum QR {
    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let o = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(o, from: o.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
