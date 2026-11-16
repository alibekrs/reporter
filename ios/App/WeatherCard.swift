import AVFoundation
import SwiftUI

// ── карточка погоды на главной: сакура по дате, погода, время суток, праздники и мелкие живые детали ──
// Дерево рисуется в картинку (в фоне) и каждый кадр только наклоняется по ветру. Всё остальное — капли, листья,
// птицы, звёзды — считается по времени, без хранимого состояния: анимация лёгкая и стоит, когда главная не на экране.

/// Сакура по дате: почки, цветение, зелень, жёлтая осень, голые ветки — день за днём, а не сменой сезона.
struct Stage: Equatable, Sendable {
    enum Mode: Sendable { case none, bud, flower, mix, leaf }
    let key: String
    let mode: Mode
    let cover: CGFloat                  // доля кроны
    let cols: [UInt32]
    var flowers: [UInt32] = []
    var fall: CGFloat = 0               // сколько слетает
    var falling: [UInt32] = []
    var petal = false

    static let autumn: [UInt32] = [0xE4572E, 0xF08A24, 0xC8322B, 0xF4B942, 0xD9661F]

    static func of(_ doy: Int) -> Stage {
        switch doy {
        case 79...90: return Stage(key: "bud", mode: .bud, cover: 0.45, cols: [0xC2457A, 0xE07AA0, 0x9C2F5C])
        case 91...120: return Stage(key: "bloom", mode: .flower, cover: 1, cols: [0xFFD3E2, 0xFFB8CF, 0xFFF1F6, 0xF7A1C0],
                                    fall: 0.7, falling: [0xFFC4D8, 0xFFDBE7, 0xFFF1F6], petal: true)
        case 121...135: return Stage(key: "may", mode: .mix, cover: 1, cols: [0x8BC34A, 0x9CCC65, 0x7CB342, 0x6AA13A],
                                     flowers: [0xFFD3E2, 0xFFF1F6, 0xFFB8CF], fall: 1, falling: [0xFFC4D8, 0xFFF1F6], petal: true)
        case 136...151: return Stage(key: "green1", mode: .leaf, cover: 0.95, cols: [0x7CB342, 0x8BC34A, 0x558B2F, 0x9CCC65],
                                     falling: [0x7CB342, 0x8BC34A])
        case 152...237: return Stage(key: "summer", mode: .leaf, cover: 1, cols: [0x2E7D32, 0x3F9142, 0x58A84F, 0x245F29],
                                     falling: [0x2E7D32, 0x3F9142, 0x58A84F])
        case 238...273: return Stage(key: "sept", mode: .leaf, cover: 1, cols: [0x3F9142, 0x58A84F, 0x2E7D32, 0xD4C03A, 0xE8B730, 0xC9A227],
                                     fall: 0.3, falling: [0xD4C03A, 0xE8B730, 0xC9A227])
        case 274...304: return Stage(key: "oct", mode: .leaf, cover: 1, cols: autumn, fall: 1.2, falling: autumn)
        case 305...320: return Stage(key: "nov1", mode: .leaf, cover: 0.6, cols: autumn, fall: 1, falling: autumn)
        case 321...334: return Stage(key: "nov2", mode: .leaf, cover: 0.16, cols: [0xC8322B, 0xD9661F, 0x9C4A1F, 0xB8860B],
                                     fall: 0.35, falling: [0xC8322B, 0xD9661F, 0x9C4A1F, 0xB8860B])
        default: return Stage(key: "bare", mode: .none, cover: 0, cols: [])
        }
    }
}

/// Всё, что сцене нужно знать о дне: свет, сезонные приметы, праздники. Считается на каждый кадр — это дёшево.
struct Look {
    let doy: Int, hour: Double, weekday: Int, mday: Int
    let light: Double, glow: Double
    let stage: Stage
    let winterish, wet, snowCover, clearish: Bool
    let newYear, nauryz, friday, fri13, march8, meteor: Bool
    let summer, autumn, june, spring: Bool
    let rime, icicles, snowBranches: Bool
    let carpet: CGFloat
    let phase: Double                    // луна: 0 — новолуние, 0.5 — полнолуние
    let tone: CGFloat

    init(_ s: Weather.Sky, _ d: Date) {
        let cal = Calendar.current
        doy = cal.ordinality(of: .day, in: .year, for: d) ?? 1
        hour = Weather.Sky.hours(d)
        weekday = cal.component(.weekday, from: d)          // 6 — пятница
        mday = cal.component(.day, from: d)
        light = Weather.Sky.light(d, s.sunrise, s.sunset)
        glow = max(0, min(1, max(1 - abs(hour - s.sunrise) / 1.1, 1 - abs(hour - s.sunset) / 1.1)))
        stage = Stage.of(doy)
        winterish = doy >= 335 || doy <= 59
        wet = s.wet
        snowCover = s.kind == .snow || (winterish && s.temp <= 4) || (s.temp <= 0 && (doy <= 78 || doy >= 305))
        clearish = s.kind == .clear || s.kind == .cloudy
        newYear = doy >= 355 || doy <= 10
        nauryz = (79...83).contains(doy)
        friday = weekday == 6 && hour >= 17
        fri13 = weekday == 6 && mday == 13
        march8 = Weather.Sky.march8(d)
        meteor = (223...225).contains(doy) || (347...348).contains(doy)
        summer = (136...237).contains(doy)
        autumn = (238...334).contains(doy)
        june = (152...176).contains(doy)
        spring = (79...135).contains(doy)
        rime = snowCover && s.temp <= -5 && hour >= 6 && hour <= 11 && s.kind != .snow
        icicles = winterish && s.temp > 0 && (s.kind == .clear || s.kind == .cloudy)
        snowBranches = snowCover && (stage.key == "bare" || stage.key == "nov2")
        carpet = (255...334).contains(doy) && !snowCover ? CGFloat(min(1, Double(doy - 255) / 55)) : 0
        let t = d.timeIntervalSince1970 - 947_182_440            // новолуние 6 января 2000, 18:14 UTC
        phase = (t / 86400 / 29.530588).truncatingRemainder(dividingBy: 1) + (t < 0 ? 1 : 0)
        let k = (0.42 + 0.58 * light) * (s.kind == .storm || s.kind == .hail ? 0.72 : 1)
        tone = CGFloat((k * 20).rounded() / 20)
    }

    /// Птица на ветке: весной зарянка, зимой снегирь; ночью и в дождь — нет.
    func bird(_ s: Weather.Sky) -> Int {
        guard light > 0.5, !wet else { return 0 }
        if spring { return 1 }
        if winterish && s.kind != .snow { return 2 }
        return 0
    }
}

/// Цвет с затемнением: ночью и в грозу дерево и земля темнее.
private func toned(_ hex: UInt32, _ k: CGFloat, _ alpha: Double = 1) -> Color {
    Color(red: Double((hex >> 16) & 255) / 255 * Double(k), green: Double((hex >> 8) & 255) / 255 * Double(k),
          blue: Double(hex & 255) / 255 * Double(k), opacity: alpha)
}

private func cgTone(_ hex: UInt32, _ k: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255 * k, green: CGFloat((hex >> 8) & 255) / 255 * k,
            blue: CGFloat(hex & 255) / 255 * k, alpha: alpha)
}

private func rgb(_ hex: UInt32) -> (Double, Double, Double) {
    (Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255)
}

private func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

private func color(_ c: (Double, Double, Double), _ a: Double = 1) -> Color { Color(red: c.0, green: c.1, blue: c.2, opacity: a) }

private func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
}

// ── сакура: ветви по зерну — одно и то же дерево при каждом запуске ─────────
struct Sakura: Sendable {
    struct Seg: Sendable { let a: CGPoint, m: CGPoint, b: CGPoint; let width: CGFloat; let depth: Int }
    struct Ice: Sendable { let p: CGPoint; let l: CGFloat }
    /// Координаты от основания ствола (0, 0), вверх — минус.
    let segs: [Seg]
    let tips: [CGPoint]
    let minX: CGFloat, maxX: CGFloat, minY: CGFloat
    let garland: [CGPoint]           // нижний край кроны — гирлянда
    let lantern: CGPoint             // фонарик и паутинка
    let perch: CGPoint               // птичка, ленточка 8 Марта
    let balloon: CGPoint             // шарики на день рождения
    let ice: [Ice]                   // сосульки
    let climb: [CGPoint]             // путь белки: ствол и ветка

    init(height h: CGFloat) {
        var seed: UInt64 = 7
        func r() -> CGFloat {
            seed = (seed * 16807) % 2147483647
            return CGFloat(seed) / 2147483647
        }
        var segs: [Seg] = [], tips: [CGPoint] = []
        func branch(_ p: CGPoint, _ ang: CGFloat, _ len: CGFloat, _ wd: CGFloat, _ d: Int) {
            let bend = (r() - 0.5) * 0.5
            let e = CGPoint(x: p.x + cos(ang) * len, y: p.y + sin(ang) * len)
            let m = CGPoint(x: p.x + cos(ang + bend) * len * 0.5, y: p.y + sin(ang + bend) * len * 0.5)
            segs.append(Seg(a: p, m: m, b: e, width: wd, depth: d))
            if d >= 6 || len < 6 {
                tips.append(e)
                return
            }
            let n = d < 2 ? 2 : 2 + (r() < 0.45 ? 1 : 0)
            for i in 0..<n {
                let spread = (d == 0 ? 0.4 : 0.45) + r() * 0.25
                var a = ang + (n == 2 ? (i == 1 ? spread : -spread) : CGFloat(i - 1) * spread) + (r() - 0.5) * 0.25
                if d > 1 { a += a < -.pi / 2 ? -0.08 : 0.08 }      // сакура раскидистая: ветви в стороны
                a = min(max(a, -.pi + 0.3), -0.3)                    // но не свисают вниз — крона куполом
                branch(e, a, len * (0.64 + r() * 0.12), wd * 0.64, d + 1)
            }
        }
        branch(.zero, -.pi / 2 + 0.05, h * 0.3, 15, 0)
        self.segs = segs
        self.tips = tips
        let xs = tips.map(\.x)
        minX = xs.min() ?? 0
        maxX = xs.max() ?? 0
        minY = tips.map(\.y).min() ?? 0
        var bins = [CGPoint?](repeating: nil, count: 14)
        for t in tips {
            let i = min(13, Int((t.x - minX) / max(1, maxX - minX) * 14))
            if bins[i] == nil || t.y > bins[i]!.y { bins[i] = t }
        }
        garland = bins.compactMap { $0.map { CGPoint(x: $0.x, y: $0.y - 6) } }
        let d2 = segs.filter { $0.depth == 2 }.min { $0.b.x < $1.b.x }
        lantern = d2?.b ?? CGPoint(x: -h * 0.3, y: -h * 0.6)
        let d3 = segs.filter { $0.depth == 3 }.min { abs($0.b.x + h * 0.36) < abs($1.b.x + h * 0.36) }
        perch = d3?.b ?? lantern
        balloon = tips.min { abs($0.x - h * 0.36) + abs($0.y + h * 0.54) < abs($1.x - h * 0.36) + abs($1.y + h * 0.54) } ?? .zero
        var ice: [Ice] = []
        for s in segs where (1...3).contains(s.depth) {
            for t in [0.35, 0.65] as [CGFloat] {
                let x = s.a.x + (s.b.x - s.a.x) * t
                ice.append(Ice(p: CGPoint(x: x, y: s.a.y + (s.b.y - s.a.y) * t + s.width * 0.5),
                               l: 7 + (x * 7.3).truncatingRemainder(dividingBy: 8).magnitude))
            }
        }
        let every = max(1, Int((Double(ice.count) / 16).rounded(.up)))
        self.ice = ice.enumerated().filter { $0.offset % every == 0 }.map(\.element)
        let one = segs.first { $0.depth == 1 && $0.b.x > 0 } ?? segs[min(1, segs.count - 1)]
        let two = segs.first { $0.depth == 2 && abs($0.a.x - one.b.x) < 0.01 && abs($0.a.y - one.b.y) < 0.01 } ?? one
        climb = [.zero, segs[0].b, one.b, two.b]
    }

    @MainActor private static var shapes: [Int: Sakura] = [:]
    @MainActor private static var images: [String: UIImage] = [:]

    @MainActor static func shape(_ h: CGFloat) -> Sakura {
        let key = Int(h.rounded())
        if let s = shapes[key] { return s }
        let s = Sakura(height: CGFloat(key))
        shapes[key] = s
        return s
    }

    /// Ключ картинки дерева: меняется с датой (крона), светом (тон), снегом и инеем.
    static func key(_ l: Look, size: CGSize, scale: CGFloat) -> String {
        "\(l.stage.key)-\(l.tone)-\(l.snowBranches)-\(l.rime)-\(Int(size.width))x\(Int(size.height))@\(scale)"
    }

    /// Дерево целиком картинкой размером с карточку. Рисуется в фоне: тысячи цветков — десятки миллисекунд.
    @MainActor static func image(_ l: Look, size: CGSize, scale: CGFloat) async -> UIImage {
        let key = Self.key(l, size: size, scale: scale)
        if let img = images[key] { return img }
        let tree = shape(size.height * 0.84)
        let stage = l.stage, tone = l.tone, snow = l.snowBranches, rime = l.rime
        let img = await Task.detached(priority: .userInitiated) {
            Self.render(tree, stage, tone: tone, snow: snow, rime: rime, size: size, scale: scale)
        }.value
        if images.count > 6 { images.removeAll() }
        images[key] = img
        return img
    }

    nonisolated private static func render(_ tree: Sakura, _ st: Stage, tone k: CGFloat, snow: Bool, rime: Bool,
                                           size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let c = rc.cgContext
            c.translateBy(x: size.width * 0.62, y: size.height - 20)
            var seed: UInt64 = 11
            func r() -> CGFloat {
                seed = (seed * 16807) % 2147483647
                return CGFloat(seed) / 2147483647
            }
            // лёгкая тень под гроздьями — крона объёмная
            if st.cover > 0.3 {
                let base: UInt32 = st.mode == .flower ? 0xE889AD : st.key == "oct" || st.key == "nov1" ? 0x8F2F1B : 0x1D4D21
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [cgTone(base, k, 0.22), cgTone(base, k, 0)] as CFArray, locations: [0, 1])!
                for t in tree.tips {
                    let p = CGPoint(x: t.x, y: t.y + 6)
                    c.drawRadialGradient(g, startCenter: p, startRadius: 2, endCenter: p, endRadius: 16, options: [])
                }
            }
            // ветви: тёмная кора с бликом слева; зимой сверху лежит снег, морозным утром — иней
            c.setLineCap(.round)
            for s in tree.segs {
                c.setStrokeColor(cgTone(0x3E2C28, k))
                c.setLineWidth(s.width)
                c.move(to: s.a); c.addQuadCurve(to: s.b, control: s.m); c.strokePath()
                if s.width > 2.5 {
                    let dx = s.width * 0.25
                    c.setStrokeColor(cgTone(0x7A5A4E, k))
                    c.setLineWidth(s.width * 0.28)
                    c.move(to: CGPoint(x: s.a.x - dx, y: s.a.y))
                    c.addQuadCurve(to: CGPoint(x: s.b.x - dx * 0.8, y: s.b.y), control: CGPoint(x: s.m.x - dx, y: s.m.y))
                    c.strokePath()
                }
                if snow && s.depth > 0 {
                    c.setStrokeColor(cgTone(0xFFFFFF, max(0.75, k)))
                    c.setLineWidth(max(1.6, s.width * 0.45))
                    c.move(to: CGPoint(x: s.a.x, y: s.a.y - s.width * 0.45))
                    c.addQuadCurve(to: CGPoint(x: s.b.x, y: s.b.y - s.width * 0.4),
                                   control: CGPoint(x: s.m.x, y: s.m.y - s.width * 0.5))
                    c.strokePath()
                }
                if rime && s.depth > 1 {
                    c.setStrokeColor(CGColor(red: 0.92, green: 0.96, blue: 1, alpha: 0.85))
                    c.setLineWidth(0.8)
                    for q in 0..<4 {
                        let t = (CGFloat(q) + 0.5) / 4
                        let x = s.a.x + (s.b.x - s.a.x) * t, y = s.a.y + (s.b.y - s.a.y) * t
                        c.move(to: CGPoint(x: x, y: y))
                        c.addLine(to: CGPoint(x: x + (r() - 0.5) * 6, y: y - 2 - r() * 4))
                        c.strokePath()
                    }
                }
            }
            guard st.cover > 0, !st.cols.isEmpty else { return }
            // цветы, почки и листья гроздьями на концах и по ветвям; во втором проходе верх грозди светлее
            let spots = tree.tips + tree.segs.filter { $0.depth >= 2 }.flatMap { [$0.m, $0.b] }
            let many = st.mode == .flower ? 7 : st.mode == .mix ? 6 : st.mode == .bud ? 3 : 5
            for pass in 0..<2 {
                for t in spots {
                    for _ in 0..<many {
                        let x = t.x + (r() - 0.5) * 30, y = t.y + (r() - 0.6) * 22
                        let keep = r() < st.cover
                        let pick = st.cols[Int(r() * CGFloat(st.cols.count)) % st.cols.count]
                        let fl = r()
                        guard keep else { continue }
                        let lit = pass == 1 && y < t.y
                        if st.mode == .bud {
                            c.setFillColor(cgTone(pick, k))
                            let s = 1.4 + fl * 1.3
                            c.fillEllipse(in: CGRect(x: x - s, y: y - s, width: s * 2, height: s * 2))
                        } else if st.mode == .flower || (st.mode == .mix && fl < 0.35) {
                            let cols = st.mode == .flower ? st.cols : st.flowers
                            c.setFillColor(cgTone(lit ? 0xFFF4F8 : cols[Int(fl * 97) % cols.count], k))
                            let s = 3.2 + fl * 2.2
                            for p in 0..<5 {
                                let a = CGFloat(p) * 1.2566 + x
                                c.saveGState()
                                c.translateBy(x: x + cos(a) * s * 0.55, y: y + sin(a) * s * 0.55)
                                c.rotate(by: a)
                                c.fillEllipse(in: CGRect(x: -s * 0.55, y: -s * 0.4, width: s * 1.1, height: s * 0.8))
                                c.restoreGState()
                            }
                            c.setFillColor(cgTone(0xD9567F, k))
                            c.fillEllipse(in: CGRect(x: x - s * 0.22, y: y - s * 0.22, width: s * 0.44, height: s * 0.44))
                        } else {
                            if lit {
                                let p = rgb(pick), m = mix(p, (1, 1, 1), 0.3)
                                c.setFillColor(CGColor(red: m.0 * k, green: m.1 * k, blue: m.2 * k, alpha: 1))
                            } else {
                                c.setFillColor(cgTone(pick, k))
                            }
                            let rx = 4.2 + fl * 2, ry = 2.2 + fl
                            c.saveGState()
                            c.translateBy(x: x, y: y)
                            c.rotate(by: fl * 9)
                            c.fillEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                            c.restoreGState()
                        }
                    }
                }
            }
        }
    }
}

/// Касания сцены и вспышки молнии. Не @State: кадр читает их сам, TimelineView и так перерисовывает каждый кадр.
final class SceneFX: @unchecked Sendable {
    static let shared = SceneFX()
    var lean = CGSize.zero               // наклон телефона — объём
    var shakeAt = -100.0                 // дерево встряхнули: касание или «потянуть главную»
    var strong = false
    var birdAt = -100.0                  // птичка улетела
    var winkAt = -100.0                  // луна подмигнула
    var moonTaps: [Double] = []
    var flash = -1                       // номер последней вспышки — вибрация один раз на вспышку

    func shake(strong: Bool) {
        shakeAt = Date().timeIntervalSince1970
        self.strong = strong
    }
}

/// Тихий звук касания дерева: шорох дождя или птичка. Играет как «окружение» — в беззвучном режиме молчит.
@MainActor
enum TreeSound {
    private static let engine = AVAudioEngine()
    private static let player = AVAudioPlayerNode()
    private static var ready = false
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

    static func play(rain: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if !ready {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            ready = true
        }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning, let buf = buffer(rain) else { return }
        player.scheduleBuffer(buf, at: nil, options: .interrupts)
        player.play()
    }

    private static func buffer(_ rain: Bool) -> AVAudioPCMBuffer? {
        let rate = 44100.0, len = AVAudioFrameCount(rate * (rain ? 1.4 : 0.6))
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: len), let ch = b.floatChannelData?[0] else { return nil }
        b.frameLength = len
        var low: Float = 0
        for i in 0..<Int(len) {
            let t = Double(i) / rate
            if rain {
                // шум, сглаженный до шороха, с редкими каплями; нарастает и затихает
                let n = Float.random(in: -1...1) * (Float.random(in: 0...1) < 0.02 ? 1 : 0.35)
                low += (n - low) * 0.35
                let env = Float(min(t / 0.15, 1) * max(0, 1 - (t - 0.15) / 1.25))
                ch[i] = low * env * 0.25
            } else {
                // три коротких «чирика»: тон вверх и вниз
                let k = Int(t / 0.16), u = t - Double(k) * 0.16
                guard k < 3, u < 0.11 else { ch[i] = 0; continue }
                let f = u < 0.05 ? 2700 + u / 0.05 * 900 : 3600 - (u - 0.05) / 0.06 * 1100
                ch[i] = Float(sin(2 * .pi * f * u) * 0.06 * (1 - t / 0.6))
            }
        }
        return b
    }
}

// ── сцена ───────────────────────────────────────────────────────────────────
struct WeatherScene: View {
    let sky: Weather.Sky
    let active: Bool
    var bday = false
    @State private var size = CGSize.zero
    @State private var tree: UIImage?
    @State private var treeKey = ""
    @Environment(\.displayScale) private var scale

    #if DEBUG
    /// Тур: кадр стоит — симулятор не тратит силы на анимацию и снимок сцены одинаков.
    private var frozen: Bool { Weather.demo }
    #else
    private var frozen: Bool { false }
    #endif

    var body: some View {
        // всё нужное кадру — здесь, в body: состояние, прочитанное только внутри Canvas, перерисовку не вызывает
        let sky = self.sky, img = tree, box = size, fx = SceneFX.shared, party = bday || sky.bday
        let shape: Sakura? = box.height > 0 ? Sakura.shape(box.height * 0.84) : nil
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        let frost: Path? = sky.temp <= -15 && box.width > 0 ? Self.frost(box) : nil
        let rare = frozen
        TimelineView(.animation(minimumInterval: low ? 1.0 / 30 : 1.0 / 60, paused: !active || Motion.reduced || frozen)) { tl in
            Canvas { ctx, sz in
                ScenePainter(sky: sky, look: Look(sky, sky.fixed ?? tl.date), tree: img, shape: shape, frost: frost,
                             t: tl.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600),
                             now: tl.date.timeIntervalSince1970, fx: fx, bday: party, low: low, rare: rare)
                    .draw(&ctx, sz)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        // картинка дерева меняется с датой, светом, снегом; проверяем раз в минуту — сумерки тоже доходят до дерева
        .task(id: "\(Int(box.width))x\(Int(box.height))-\(scale)-\(sky.kind)-\(sky.temp)-\(sky.fixed?.timeIntervalSince1970 ?? 0)") {
            guard box.width > 0, box.height > 0 else { return }
            while !Task.isCancelled {
                let look = Look(sky, sky.date)
                let key = Sakura.key(look, size: box, scale: scale)
                if key != treeKey {
                    tree = await Sakura.image(look, size: box, scale: scale)
                    treeKey = key
                }
                if sky.fixed != nil { return }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onReceive(Tilt.shared.$lean) { fx.lean = $0 }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { p in tapped(p, box) }
        .accessibilityHidden(true)
    }

    /// Касание: луна (5 раз — подмигнёт) или дерево (встряхнуть, спугнуть птичку, тихий звук).
    private func tapped(_ p: CGPoint, _ box: CGSize) {
        let fx = SceneFX.shared, now = Date().timeIntervalSince1970, look = Look(sky, sky.date)
        if let m = ScenePainter.moon(sky, look, box), hypot(p.x - m.x, p.y - m.y) < 26 {
            fx.moonTaps = fx.moonTaps.filter { now - $0 < 2.5 } + [now]
            if fx.moonTaps.count >= 5 {
                fx.winkAt = now
                fx.moonTaps = []
            }
            return
        }
        guard p.x > box.width * 0.58 else { return }
        fx.shake(strong: false)
        if look.bird(sky) > 0 { fx.birdAt = now }
        TreeSound.play(rain: sky.wet || sky.after)
    }

    /// Узор инея по углам карточки — веточки-папоротники; один раз на размер.
    @MainActor private static var frostCache: [String: Path] = [:]
    @MainActor static func frost(_ s: CGSize) -> Path {
        let key = "\(Int(s.width))x\(Int(s.height))"
        if let p = frostCache[key] { return p }
        var seed: UInt64 = 5
        func r() -> CGFloat {
            seed = (seed * 16807) % 2147483647
            return CGFloat(seed) / 2147483647
        }
        var p = Path()
        func fern(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ len: CGFloat, _ d: Int) {
            let ex = x + cos(a) * len, ey = y + sin(a) * len
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: ex, y: ey))
            guard d < 4 else { return }
            fern(ex, ey, a + 0.6, len * 0.6, d + 1)
            fern(ex, ey, a - 0.6, len * 0.6, d + 1)
            fern(ex, ey, a + (r() - 0.5) * 0.3, len * 0.75, d + 1)
        }
        for (cx, cy) in [(0, 0), (s.width, 0), (0, s.height), (s.width, s.height)] as [(CGFloat, CGFloat)] {
            let base = atan2(s.height / 2 - cy, s.width / 2 - cx)
            for k in 0..<7 { fern(cx, cy, base + CGFloat(k - 3) * 0.32, 22 + r() * 14, 0) }
        }
        frostCache[key] = p
        return p
    }
}

private struct ScenePainter {
    let sky: Weather.Sky
    let look: Look
    let tree: UIImage?
    let shape: Sakura?
    let frost: Path?
    let t: Double                        // секунды в пределах часа — для частиц
    let now: Double                      // время касаний
    let fx: SceneFX
    let bday: Bool
    let low: Bool
    let rare: Bool                       // тур: редкие события чаще

    /// Случайное, но одно и то же для частицы i: капли и листья не хранятся, а считаются по времени.
    static func h(_ i: Int, _ s: Int) -> CGFloat {
        let x = sin(Double(i * 127 + s * 311 + 1) * 12.9898) * 43758.5453
        return CGFloat(x - x.rounded(.down))
    }

    /// Где луна (и есть ли она): вечером слева от дерева, к утру правее.
    static func moon(_ s: Weather.Sky, _ l: Look, _ size: CGSize) -> CGPoint? {
        guard l.clearish || s.after, l.light < 0.6, size.width > 0 else { return nil }
        let nl = 24 - (s.sunset - s.sunrise)
        let p = max(0, min(1, (l.hour - s.sunset + 24).truncatingRemainder(dividingBy: 24) / nl))
        return CGPoint(x: size.width * (0.66 + 0.26 * p), y: 44 - sin(.pi * p) * 18)
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let W = size.width, H = size.height, w = CGFloat(min(sky.wind, 20)), tt = CGFloat(t), L = look.light
        let kind = sky.kind, h = Self.h, tone = look.tone, st = look.stage
        let bx = W * 0.62, by = H - 20, lean = fx.lean, cut: CGFloat = low ? 0.5 : 1
        func tc(_ hex: UInt32, _ a: Double = 1) -> Color { toned(hex, tone, a) }
        func hill(_ x: CGFloat) -> CGFloat {
            let u = (x - bx) / (W * 0.42)
            return abs(u) >= 1 ? H + 18 : H + 18 - 52 * sqrt(1 - u * u)
        }
        func layer(_ amt: CGFloat) -> GraphicsContext {
            var c = ctx
            c.translateBy(x: -lean.width * amt, y: -lean.height * amt * 0.5)
            return c
        }
        let since = now - fx.shakeAt
        let shake = max(0, (fx.strong ? 1.3 : 1) - since * 1.1)
        let g = w / 20
        let sway = (sin(tt * (0.9 + g)) * 0.6 + sin(tt * 2.3) * 0.25) * g * 12 + g * 9 + sin(tt * 24) * CGFloat(shake) * 9
        let kk = -sway / (H * 0.9)
        /// Точка дерева (от основания) на экране с наклоном по ветру.
        func onTree(_ p: CGPoint) -> CGPoint { CGPoint(x: bx + p.x + kk * p.y, y: by + p.y) }

        // ── небо: ночь ↔ день, у восхода и заката розово-оранжевое
        let dayCols: (UInt32, UInt32) = sky.after && !sky.wet ? (0x7CC0F0, 0xDBEEFB) : { () -> (UInt32, UInt32) in
            switch kind {
            case .clear: return (0x6FB8F2, 0xCFE8FB)
            case .cloudy: return (0x93A3B7, 0xD3DAE3)
            case .rain: return (0x6B7B90, 0xAAB5C3)
            case .hail: return (0x4A5468, 0x7D8799)
            case .snow: return (0xB4C2D4, 0xE8EEF5)
            case .storm: return (0x323A4F, 0x646D82)
            case .fog: return (0xBCC3CB, 0xE3E6E9)
            }
        }()
        let nightCols: (UInt32, UInt32) = kind == .clear ? (0x0A1230, 0x25316A) : (0x151A2B, 0x343B53)
        var top = mix(rgb(nightCols.0), rgb(dayCols.0), L), bot = mix(rgb(nightCols.1), rgb(dayCols.1), L)
        let gk = look.glow * (look.clearish ? 0.85 : 0.35)
        top = mix(top, rgb(0x6F5FA8), gk * 0.6)
        bot = mix(bot, rgb(0xFFA76B), gk)
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [color(top), color(bot)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: H)))

        // ── дальний план: сияние, звёзды, самолёт, солнце, луна, радуга
        var sk = layer(2)
        if look.winterish && L < 0.2 && kind == .clear && sky.temp <= -15 && (rare || Int(tt / 60) % 6 == 0) {
            sk.drawLayer { a in
                a.blendMode = .plusLighter
                for k in 0..<3 {
                    let kf = CGFloat(k)
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: 14 + kf * 9 + sin(tt * 0.35 + kf * 2) * 13))
                    for x in stride(from: CGFloat(0), through: W, by: 6) {
                        p.addLine(to: CGPoint(x: x, y: 14 + kf * 9 + sin(x * 0.018 + tt * 0.35 + kf * 2) * 13))
                    }
                    for x in stride(from: W, through: 0, by: -6) {
                        p.addLine(to: CGPoint(x: x, y: 70 + kf * 9 + sin(x * 0.04 + tt * 0.8 + kf) * 12))
                    }
                    p.closeSubpath()
                    a.fill(p, with: .linearGradient(Gradient(stops: [
                        .init(color: Color(red: 0.47, green: 1, blue: 0.78, opacity: 0), location: 0),
                        .init(color: Color(red: 0.31, green: 1, blue: 0.67, opacity: 0.3), location: 0.3),
                        .init(color: Color(red: 0.59, green: 0.35, blue: 1, opacity: 0.12), location: 0.75),
                        .init(color: Color(red: 0.59, green: 0.35, blue: 1, opacity: 0), location: 1),
                    ]), startPoint: CGPoint(x: 0, y: 6), endPoint: CGPoint(x: 0, y: 130)))
                }
            }
        }
        if L < 0.5 && look.clearish {
            for i in 0..<46 {
                let a = (0.35 + 0.35 * sin(1.5 * t + Double(h(i, 3)) * 6)) * (1 - L * 2)
                sk.fill(Path(CGRect(x: h(i, 1) * W, y: h(i, 2) * H * 0.6, width: 1.6, height: 1.6)), with: .color(.white.opacity(a)))
            }
        }
        if L < 0.25 && kind == .clear {
            // падающая звезда; в Персеиды и Геминиды — звездопад
            let period: CGFloat = rare ? (look.meteor ? 0.9 : 4) : (look.meteor ? 3 : 25)
            let cyc = (tt / period).rounded(.down), u = tt - cyc * period
            if u < 0.7 {
                let p = u / 0.7, sx = W * (0.45 + h(Int(cyc) % 997, 40) * 0.55), sy = 8 + h(Int(cyc) % 997, 41) * H * 0.3
                let hx = sx - p * 260, hy = sy + p * 110
                var s = Path()
                s.move(to: CGPoint(x: hx, y: hy))
                s.addLine(to: CGPoint(x: hx + 60, y: hy - 25))
                sk.stroke(s, with: .linearGradient(Gradient(colors: [.white.opacity(Double(1 - p)), .white.opacity(0)]),
                                                   startPoint: CGPoint(x: hx, y: hy), endPoint: CGPoint(x: hx + 60, y: hy - 25)), lineWidth: 1.6)
            }
        }
        if L > 0.5 && kind != .storm && kind != .fog && kind != .hail {
            // изредка самолёт с белым следом
            let period: CGFloat = rare ? 14 : 80, u = tt.truncatingRemainder(dividingBy: period)
            if u < 11 {
                let x = -20 + (W + 40) * u / 11, y = 20 + u * 0.8
                var s = Path()
                s.move(to: CGPoint(x: x - 170, y: y - 7.3))
                s.addLine(to: CGPoint(x: x - 6, y: y))
                sk.stroke(s, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.75)]),
                                                   startPoint: CGPoint(x: x - 170, y: y), endPoint: CGPoint(x: x - 6, y: y)), lineWidth: 1.6)
                sk.fill(Path(CGRect(x: x - 6, y: y - 1, width: 8, height: 2)), with: .color(Color(hex: 0xF8FAFC)))
                var wing = Path()
                wing.move(to: CGPoint(x: x - 3, y: y)); wing.addLine(to: CGPoint(x: x - 5, y: y - 4)); wing.addLine(to: CGPoint(x: x - 1, y: y))
                sk.fill(wing, with: .color(Color(hex: 0xF8FAFC)))
            }
        }
        var sunX: CGFloat?
        if look.clearish && L > 0.05 {
            let p = CGFloat(max(0, min(1, (look.hour - sky.sunrise) / (sky.sunset - sky.sunrise))))
            let x = W * (0.36 + 0.58 * p), y = H * 0.62 - sin(.pi * p) * H * 0.5, dusk = 1 - sin(.pi * p)
            var s = sk
            s.opacity = L
            var rays = Path()
            for k in 0..<10 {
                let a = tt * 0.25 + CGFloat(k) * .pi / 5
                rays.move(to: CGPoint(x: x + cos(a) * 24, y: y + sin(a) * 24))
                rays.addLine(to: CGPoint(x: x + cos(a) * 31, y: y + sin(a) * 31))
            }
            s.stroke(rays, with: .color(Color(hex: 0xFDE047).opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            s.fill(oval(x, y, 18, 18), with: .color(color(mix(rgb(0xFDE047), rgb(0xFB923C), Double(dusk) * 0.8))))
            sunX = x
        }
        if let m = Self.moon(sky, look, size) {
            var s = sk
            s.opacity = 1 - L
            drawMoon(&s, m, 14)
        }
        if sky.after && !sky.wet && L > 0.3 {
            for (i, c) in ([0xFF4D4D, 0xFF9A3C, 0xFFE14D, 0x5FD35F, 0x4DB8FF, 0x5B6CFF, 0xA35BFF] as [UInt32]).enumerated() {
                let r = H * 0.98 - CGFloat(i) * 3.4
                var arc = Path()
                for a in stride(from: CGFloat.pi * 1.08, through: .pi * 1.92, by: 0.04) {
                    let pt = CGPoint(x: W * 0.66 + cos(a) * r, y: H + 30 + sin(a) * r)
                    if arc.isEmpty { arc.move(to: pt) } else { arc.addLine(to: pt) }
                }
                sk.stroke(arc, with: .color(toned(c, 1, 0.34 * L)), lineWidth: 3.4)
            }
        }

        // ── облака, воздушный змей, клин птиц
        var cl = layer(4)
        let cloudCount: Int = sky.after && !sky.wet ? 2 : { () -> Int in
            switch kind {
            case .clear: return 1
            case .fog: return 2
            case .snow: return 3
            default: return 4
            }
        }()
        let cloudColor: Color = L < 0.4 ? toned(0x505A78, 1, 0.85)
            : kind == .storm || kind == .hail ? toned(0x3C4254, 1, 0.95)
            : kind == .clear ? .white.opacity(0.75) : toned(0xECF0F5, 1, 0.9)
        for i in 0..<cloudCount {
            let s = 0.7 + CGFloat(i % 3) * 0.25
            let x = (CGFloat(i) / 4 * W * 1.2 + 100 + (6 + w * 3) * s * tt).truncatingRemainder(dividingBy: W + 140) - 100
            let y = 16 + CGFloat(i % 2) * 22
            var p = Path()
            if bday && i == 0 {
                // в день рождения одно облако — сердечком
                let cx = x + 26 * s, cy = y + 8 * s, k = s * 1.1
                p.move(to: CGPoint(x: cx, y: cy + 14 * k))
                p.addCurve(to: CGPoint(x: cx, y: cy - 8 * k), control1: CGPoint(x: cx - 30 * k, y: cy - 4 * k), control2: CGPoint(x: cx - 14 * k, y: cy - 22 * k))
                p.addCurve(to: CGPoint(x: cx, y: cy + 14 * k), control1: CGPoint(x: cx + 14 * k, y: cy - 22 * k), control2: CGPoint(x: cx + 30 * k, y: cy - 4 * k))
            } else {
                for (dx, dy, r) in [(0.0, 8.0, 16.0), (18, 0, 20), (40, 6, 17), (56, 12, 12), (24, 14, 16)] as [(CGFloat, CGFloat, CGFloat)] {
                    p.addEllipse(in: CGRect(x: x + dx * s - r * s, y: y + dy * s - r * s, width: r * s * 2, height: r * s * 2))
                }
            }
            cl.fill(p, with: .color(cloudColor))
        }
        if (look.spring || look.summer) && kind == .clear && !sky.after && w >= 6 && w <= 13 && L > 0.5 {
            let kx = W * 0.4 + sin(tt * 0.7) * 8, ky = 28 + sin(tt * 1.1) * 5, a = 0.25 + sin(tt * 1.6) * 0.12
            var string = Path()
            string.move(to: CGPoint(x: kx, y: ky + 8))
            string.addQuadCurve(to: CGPoint(x: W * 1.02, y: H * 0.9), control: CGPoint(x: W * 0.75, y: H * 0.45))
            cl.stroke(string, with: .color(.white.opacity(0.55)), lineWidth: 0.7)
            var tail = Path()
            tail.move(to: CGPoint(x: kx, y: ky + 8))
            for i in 1...5 { tail.addLine(to: CGPoint(x: kx - CGFloat(i) * 5, y: ky + 8 + CGFloat(i) * 4 + sin(tt * 6 + CGFloat(i)) * 2.5)) }
            cl.stroke(tail, with: .color(tc(0x334155)), lineWidth: 0.8)
            for i in [2, 4] {
                cl.fill(oval(kx - CGFloat(i) * 5, ky + 8 + CGFloat(i) * 4 + sin(tt * 6 + CGFloat(i)) * 2.5, 1.6, 1.6), with: .color(Color(hex: 0xF59E0B)))
            }
            var kc = cl
            kc.translateBy(x: kx, y: ky)
            kc.rotate(by: .radians(Double(a)))
            var red = Path(), yel = Path()
            red.move(to: CGPoint(x: 0, y: -10)); red.addLine(to: CGPoint(x: 7, y: 0)); red.addLine(to: CGPoint(x: 0, y: 9)); red.addLine(to: CGPoint(x: -7, y: 0))
            yel.move(to: CGPoint(x: 0, y: -10)); yel.addLine(to: CGPoint(x: 7, y: 0)); yel.addLine(to: .zero)
            yel.move(to: CGPoint(x: 0, y: 9)); yel.addLine(to: CGPoint(x: -7, y: 0)); yel.addLine(to: .zero)
            kc.fill(red, with: .color(Color(hex: 0xEF4444)))
            kc.fill(yel, with: .color(Color(hex: 0xFACC15)))
        }
        if look.autumn && L > 0.4 && look.clearish {
            let period: CGFloat = rare ? 9 : 35, u = tt.truncatingRemainder(dividingBy: period)
            if u < 9 {
                let x0 = W + 30 - (W + 140) * (u / 9), y0 = 30 + u * 2
                var p = Path()
                for i in -3...3 {
                    let x = x0 + CGFloat(abs(i)) * 10, y = y0 + CGFloat(i) * 6, f = sin(tt * 9 + CGFloat(i)) * 2.2
                    p.move(to: CGPoint(x: x - 4, y: y - f)); p.addLine(to: CGPoint(x: x, y: y + 1)); p.addLine(to: CGPoint(x: x + 4, y: y - f))
                }
                cl.stroke(p, with: .color(tc(0x2B2B35)), lineWidth: 1.3)
            }
        }

        // ── дальний холм с домиком
        var far = layer(5)
        let farHex: UInt32 = look.snowCover ? 0xE3E9F3 : ["oct", "nov1", "nov2"].contains(st.key) ? 0x8A7448 : st.key == "bare" ? 0x7F7458 : 0x5F9A4F
        far.fill(oval(W, H + 26, W * 0.32, 64), with: .color(toned(farHex, tone * 0.92)))
        drawHouse(&far, W * 0.93, H - 34, tt)

        // ── ближний холм: снег или трава, ковёр листьев, пятна света, тень, лужи, следы, тюльпаны, звери
        var gr = layer(6)
        let groundHex: UInt32 = look.snowCover ? 0xF2F6FB : (79...151).contains(look.doy) ? 0x86C46E
            : (152...273).contains(look.doy) ? 0x4F9A3F : (274...334).contains(look.doy) ? 0x9C7D45 : 0x8D7A55
        gr.fill(oval(bx, H + 18, W * 0.42, 52), with: .color(toned(groundHex, look.snowCover ? max(0.6, tone) : tone)))
        if look.snowCover {
            let grow: CGFloat = kind == .snow ? CGFloat(max(0, min(1, look.hour / 20))) : 0   // пока идёт снег, сугроб растёт
            let snow = toned(0xFFFFFF, max(0.6, tone))
            gr.fill(oval(W * 0.5, H + 14, W * 0.75, 26 + grow * 16), with: .color(snow))
            if grow > 0 {
                gr.fill(oval(bx + 6, by + 4, 34, 4 + grow * 9), with: .color(snow))
            }
        } else {
            var blades = Path()
            for x in stride(from: W * 0.22, to: W, by: 7) {
                let base = hill(x) + 2, bend = w * 0.55 + sin(tt * (2 + w * 0.15) + x * 0.15) * (0.8 + w * 0.22)
                blades.move(to: CGPoint(x: x, y: base))
                blades.addQuadCurve(to: CGPoint(x: x + bend, y: base - 6 - (x * 13).truncatingRemainder(dividingBy: 4) + abs(bend) * 0.25),
                                    control: CGPoint(x: x + bend * 0.3, y: base - 4))
            }
            gr.stroke(blades, with: .color(toned(groundHex, tone * 0.75)), lineWidth: 1.2)
        }
        if look.carpet > 0 {
            // ковёр листьев: с сентября растёт, ветер ворошит; одним путём на цвет — быстро
            var seed: UInt64 = 23
            func r() -> CGFloat {
                seed = (seed * 16807) % 2147483647
                return CGFloat(seed) / 2147483647
            }
            var paths = [Path](repeating: Path(), count: Stage.autumn.count)
            for i in 0..<Int(140 * look.carpet * cut) {
                let x = bx + (r() - 0.5) * W * 0.62, y = hill(x) + 2 + r() * 12, rot = r() * 3, ci = Int(r() * 5) % 5
                let jig = sin(tt * 3 + CGFloat(i)) * w * 0.12
                let tr = CGAffineTransform(translationX: x + jig, y: y).rotated(by: rot + jig * 0.1)
                paths[ci].addPath(oval(0, 0, 3.6, 1.8), transform: tr)
            }
            for (i, p) in paths.enumerated() { gr.fill(p, with: .color(tc(Stage.autumn[i]))) }
        }
        if look.summer && kind == .clear && !sky.after && L > 0.6 {
            for i in 0..<14 {
                let fi = CGFloat(i)
                let x = W * (0.3 + (fi * 0.618).truncatingRemainder(dividingBy: 1) * 0.62) + sway * 0.3 + sin(tt * 0.8 + fi) * 2
                let y = hill(x) + 4 + (fi * 0.37).truncatingRemainder(dividingBy: 1) * 10
                gr.fill(oval(x, y, 5 + CGFloat(i % 3), 1.8), with: .color(Color(red: 1, green: 0.98, blue: 0.78, opacity: 0.22 + 0.1 * sin(t * 1.3 + Double(i)))))
            }
        }
        if let sx = sunX, look.clearish {
            // тень дерева уходит от солнца, днём короткая, к вечеру длинная
            let dir: CGFloat = bx - sx >= 0 ? 1 : -1
            let p = CGFloat(max(0, min(1, (look.hour - sky.sunrise) / (sky.sunset - sky.sunrise))))
            let len = 26 + (1 - sin(.pi * p)) * 80
            gr.fill(oval(bx + dir * len * 0.55, by + 4, len * 0.62, 6), with: .color(.black.opacity(0.16 * L * (kind == .cloudy ? 0.45 : 1))))
        }
        if (look.wet || sky.after) && !look.snowCover {
            let moon = Self.moon(sky, look, size)
            for (px, rx) in [(0.47, 22.0), (0.83, 17.0)] as [(CGFloat, CGFloat)] {
                let x = W * px, y = hill(x) + 9
                gr.fill(oval(x, y, rx, 4), with: .color(tc(0x6D84A3, 0.55)))
                if let m = moon, look.phase > 0.15 && look.phase < 0.85 {
                    gr.fill(oval(x + (m.x - x) * 0.08, y, 3.4 + sin(tt * 4) * 0.4, 1.2),
                            with: .color(toned(0xF5F1D6, 1, 0.55 + 0.15 * sin(t * 3 + Double(px) * 9))))
                }
                if sky.after && !sky.wet && L > 0.3 {
                    for (j, c) in ([0xFF4D4D, 0xFFE14D, 0x5FD35F, 0x4DB8FF, 0xA35BFF] as [UInt32]).enumerated() {
                        var ln = Path()
                        ln.move(to: CGPoint(x: x - rx * 0.55, y: y - 1.6 + CGFloat(j) * 0.8))
                        ln.addLine(to: CGPoint(x: x + rx * 0.35, y: y - 1.6 + CGFloat(j) * 0.8))
                        gr.stroke(ln, with: .color(toned(c, 1, 0.32 * L)), lineWidth: 0.9)
                    }
                }
                if sky.wet {
                    for i in 0..<3 {
                        let ph = (tt * 0.9 + CGFloat(i) / 3 + px).truncatingRemainder(dividingBy: 1)
                        gr.stroke(oval(x + CGFloat(i - 1) * rx * 0.4, y, rx * 0.5 * ph, rx * 0.09 * ph + 0.3),
                                  with: .color(Color(red: 0.9, green: 0.94, blue: 1, opacity: Double(1 - ph) * 0.6)), lineWidth: 1)
                    }
                }
            }
        }
        if look.snowCover {
            var paws = Path()
            for i in 0..<9 {
                let x = W * 0.4 + CGFloat(i) * (W * 0.34 / 9), y = hill(x) + 8 + (i % 2 == 1 ? 3 : -1)
                paws.addPath(oval(x, y, 2, 1.5))
                for dx in [-2.0, 0, 2] as [CGFloat] { paws.addPath(oval(x + dx + 2.4, y - 2.2, 0.8, 0.8)) }
            }
            gr.fill(paws, with: .color(Color(red: 0.43, green: 0.49, blue: 0.63, opacity: 0.32)))
        }
        if look.nauryz {
            for i in 0..<9 {
                let x = W * (0.6 + CGFloat(i) * 0.045), base = hill(x) + 4, s = sin(tt * 1.5 + CGFloat(i)) * (1 + w * 0.15)
                var stem = Path()
                stem.move(to: CGPoint(x: x, y: base))
                stem.addQuadCurve(to: CGPoint(x: x + s, y: base - 12), control: CGPoint(x: x, y: base - 6))
                gr.stroke(stem, with: .color(tc(0x3F8F3A)), lineWidth: 1.4)
                var cup = Path()
                cup.move(to: CGPoint(x: x + s - 3.5, y: base - 15)); cup.addLine(to: CGPoint(x: x + s - 3.5, y: base - 10))
                cup.addQuadCurve(to: CGPoint(x: x + s + 3.5, y: base - 10), control: CGPoint(x: x + s, y: base - 8))
                cup.addLine(to: CGPoint(x: x + s + 3.5, y: base - 15)); cup.addLine(to: CGPoint(x: x + s + 1.6, y: base - 13))
                cup.addLine(to: CGPoint(x: x + s, y: base - 16)); cup.addLine(to: CGPoint(x: x + s - 1.6, y: base - 13))
                gr.fill(cup, with: .color(tc([0xE11D48, 0xF59E0B, 0xEC4899][i % 3])))
            }
        }
        if look.carpet > 0.2 && L > 0.4 && !look.wet && kind != .snow {
            // ёжик шуршит в листве
            let x = W * (0.555 + 0.028 * sin(tt * 0.25)), y = hill(x) + 4
            drawHedgehog(&gr, x, y, cos(tt * 0.25) >= 0 ? 1 : -1, tt)
            for i in 0..<2 {
                let hop = max(0, sin(tt * 5 + CGFloat(i) * 2)) * 4
                var c = gr
                c.translateBy(x: x + (i == 1 ? 9 : -9), y: y - 1 - hop)
                c.rotate(by: .radians(Double(hop * 0.3)))
                c.fill(oval(0, 0, 3, 1.6), with: .color(tc(Stage.autumn[i])))
            }
        }
        if look.snowCover && sky.temp <= -5 { drawSnowman(&gr, W * 0.87, hill(W * 0.87) + 5) }
        if !look.wet && kind != .snow { drawCat(&gr, W * 0.77, hill(W * 0.77) + 3, tt, L) }

        // ── дерево с украшениями и живностью
        var tr = layer(8)
        if let tree {
            var c = tr
            c.concatenate(CGAffineTransform(a: 1, b: 0, c: kk, d: 1, tx: -kk * by, ty: 0))
            c.draw(Image(uiImage: tree), in: CGRect(origin: .zero, size: size))
        }
        if let shape {
            var c = tr
            c.translateBy(x: bx, y: by)
            c.concatenate(CGAffineTransform(a: 1, b: 0, c: kk, d: 1, tx: 0, ty: 0))
            decorate(&c, shape, tt, L)
            fallingLeaves(&tr, shape, tt, onTree, hill, cut)
        }
        if look.summer && L > 0.5 && (kind == .clear || kind == .cloudy) && w < 10 {
            for (i, c) in ([0xFACC15, 0xFFFFFF, 0x60A5FA] as [UInt32]).enumerated() {
                let fi = CGFloat(i)
                let x = W * (0.45 + 0.4 * (sin(tt * 0.31 * (fi + 1) + fi * 2) + 1) / 2), y = H * 0.6 + sin(tt * 0.9 + fi * 1.3) * H * 0.18
                var b = tr
                b.translateBy(x: x, y: y)
                b.scaleBy(x: max(0.15, abs(sin(tt * 13 + fi))), y: 1)
                var p = Path()
                p.addPath(oval(-3, -2, 3.2, 2.6)); p.addPath(oval(3, -2, 3.2, 2.6)); p.addPath(oval(-2.2, 2, 2, 1.7)); p.addPath(oval(2.2, 2, 2, 1.7))
                b.fill(p, with: .color(tc(c)))
            }
        }
        if look.summer && L < 0.3 && !look.wet {
            for i in 0..<Int(16 * cut) {
                let fi = CGFloat(i)
                let x = W * (0.32 + (fi * 0.618).truncatingRemainder(dividingBy: 1) * 0.66) + sin(tt * 0.4 + fi) * 18
                let y = H * (0.45 + (fi * 0.37).truncatingRemainder(dividingBy: 1) * 0.45) + cos(tt * 0.5 + fi * 2) * 10
                let a = max(0, sin(t * 1.7 + Double(i) * 2.1))
                tr.fill(oval(x, y, 7, 7), with: .radialGradient(Gradient(colors: [Color(red: 0.91, green: 1, blue: 0.54, opacity: a), .clear]),
                                                               center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 7))
            }
        }
        if look.june && L > 0.4 && !look.wet && kind != .snow {
            for i in 0..<Int(26 * cut) {
                let p = h(i, 50) * 6
                let x = (h(i, 51) * W + (w * 3 + 5) * tt + sin(tt + p) * 6).truncatingRemainder(dividingBy: W + 12) - 6
                let y = h(i, 52) * H * 0.8 + sin(tt * 0.7 + p) * 8
                tr.fill(oval(x, y, 3.5, 3.5), with: .radialGradient(Gradient(colors: [.white.opacity(0.95), .white.opacity(0)]),
                                                                     center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 3.5))
            }
        }

        // ── дождь, град, снег, туман — по всей карточке
        if kind == .rain || kind == .storm || kind == .hail {
            let slant = w * 0.045
            var p = Path()
            let n = Int(CGFloat(kind == .storm ? 140 : kind == .hail ? 50 : 95) * cut)
            for i in 0..<n {
                let v = 420 + h(i, 12) * 260, l = 8 + h(i, 13) * 10
                let y = (h(i, 14) * H + v * tt).truncatingRemainder(dividingBy: H + l) - l
                let x = h(i, 11) * (W + slant * H + 20) - slant * H + slant * (y + l)
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x - l * slant, y: y - l))
            }
            ctx.stroke(p, with: .color(L < 0.4 ? toned(0xAABEE6, 1, 0.55) : toned(0xEBF2FF, 1, 0.75)), lineWidth: 1.3)
        }
        if kind == .hail {
            // град падает и отскакивает от земли
            var p = Path()
            for i in 0..<Int(60 * cut) {
                let v = 300 + h(i, 60) * 140, r = 1.6 + h(i, 61) * 1.2, x = h(i, 62) * W
                let gy = hill(x) + 2, tf = (gy + 6) / v, period = tf + 1.2
                let u = (tt + h(i, 63) * period).truncatingRemainder(dividingBy: period)
                let y: CGFloat
                if u < tf { y = -6 + v * u } else {
                    let b = u - tf
                    y = gy - v * 0.28 * b + 450 * b * b
                }
                guard y < H + 5 else { continue }
                p.addPath(oval(x + (u < tf ? v * w * 0.027 * u : 30 * (u - tf)), y, r, r))
            }
            ctx.fill(p, with: .color(Color(red: 0.96, green: 0.98, blue: 1, opacity: 0.95)))
        }
        if kind == .snow {
            var p = Path()
            for i in 0..<Int(CGFloat(sky.first ? 170 : 80) * cut) {
                let r = 1 + h(i, 17) * 2.4, v = 18 + h(i, 18) * 30
                let y = (h(i, 19) * H + v * tt).truncatingRemainder(dividingBy: H + 8) - 4
                let x = (h(i, 20) * W + w * 3 * tt + 10 * sin(tt + h(i, 21) * 6) + W + 8).truncatingRemainder(dividingBy: W + 8) - 4
                p.addPath(oval(x, y, r, r))
            }
            ctx.fill(p, with: .color(.white.opacity(0.95)))
        }
        if kind == .fog {
            for i in 0..<3 {
                let y = H * (0.35 + CGFloat(i) * 0.22)
                let x = (tt * (8 + w * 2) * CGFloat(i + 1)).truncatingRemainder(dividingBy: W * 2) - W
                ctx.fill(oval(x + W * 0.5, y, W * 0.7, 14), with: .color(.white.opacity(L < 0.4 ? 0.12 : 0.38)))
            }
        }
        // молния: вспышка раз в несколько секунд, на телефоне — короткая вибрация
        if kind == .storm {
            let cycle = (tt / 5).rounded(.down)
            let f = tt - cycle * 5 - h(Int(cycle) % 1000, 15) * 2
            if f >= 0 && f < 0.33 {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(Double((1 - f * 3) * 0.55))))
                if fx.flash != Int(cycle) && !rare {
                    fx.flash = Int(cycle)
                    Task { @MainActor in UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                }
            }
        }

        // под текстом слева чуть светлее (днём) или темнее (ночью) — читается на любом небе
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [sky.dark ? .black.opacity(0.2) : .white.opacity(0.24), .clear]),
                                       startPoint: .zero, endPoint: CGPoint(x: W * 0.6, y: 0)))

        // капли стекают по стеклу карточки
        if kind == .rain || kind == .storm || sky.after {
            for i in 0..<(sky.after && !sky.wet ? 6 : 14) {
                let period = 7 + h(i, 70) * 5, u = (tt + h(i, 71) * period).truncatingRemainder(dividingBy: period)
                let hold = h(i, 72) * 2.5, r = 2 + h(i, 73) * 2.4, x = h(i, 74) * W, y0 = h(i, 75) * H * 0.5
                let y = y0 + max(0, u - hold) * (25 + h(i, 76) * 70)
                guard y < H + 6 else { continue }
                if y - y0 > 2 {
                    var trail = Path()
                    trail.move(to: CGPoint(x: x, y: y0)); trail.addLine(to: CGPoint(x: x, y: y - r))
                    ctx.stroke(trail, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: r * 0.7, lineCap: .round))
                }
                ctx.fill(oval(x, y, r, r * 1.15), with: .color(.white.opacity(0.22)))
                ctx.stroke(oval(x, y, r, r * 1.15), with: .color(.white.opacity(0.45)), lineWidth: 0.8)
                ctx.fill(oval(x - r * 0.35, y - r * 0.4, r * 0.28, r * 0.28), with: .color(.white.opacity(0.8)))
            }
        }
        // в сильный мороз по краям карточки — узор инея
        if let frost {
            let a = Double(max(0, min(1, 0.55 + CGFloat(-15 - sky.temp) * 0.06)))
            for (cx, cy) in [(0, 0), (W, 0), (0, H), (W, H)] as [(CGFloat, CGFloat)] {
                ctx.fill(oval(cx, cy, 110, 110), with: .radialGradient(Gradient(colors: [.white.opacity(0.42 * a), .white.opacity(0)]),
                                                                       center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: 110))
            }
            ctx.stroke(frost, with: .color(.white.opacity(0.6 * a)), lineWidth: 0.8)
        }
    }

    // ── луна: настоящая фаза; 5 касаний — подмигивает
    private func drawMoon(_ c: inout GraphicsContext, _ m: CGPoint, _ r: CGFloat) {
        let moonCol = Color(hex: 0xF5F1D6)
        c.fill(oval(m.x, m.y, r * 2.6, r * 2.6), with: .radialGradient(Gradient(colors: [moonCol.opacity(0.18), moonCol.opacity(0)]),
                                                                        center: m, startRadius: r, endRadius: r * 2.6))
        c.fill(oval(m.x, m.y, r, r), with: .color(moonCol.opacity(0.12)))
        let f = look.phase, k = CGFloat(cos(2 * .pi * f))         // 1 — новолуние, −1 — полнолуние
        var p = Path()
        var pts: [CGPoint] = []
        for i in 0...24 {                                        // освещённый край — полукруг справа
            let a = -CGFloat.pi / 2 + CGFloat(i) / 24 * .pi
            pts.append(CGPoint(x: cos(a) * r, y: sin(a) * r))
        }
        for i in 0...24 {                                        // терминатор — полуэллипс обратно вверх
            let a = CGFloat.pi / 2 - CGFloat(i) / 24 * .pi
            pts.append(CGPoint(x: cos(a) * r * k, y: sin(a) * r))
        }
        let flip: CGFloat = f > 0.5 ? -1 : 1                    // убывающая — освещена слева
        p.addLines(pts.map { CGPoint(x: m.x + $0.x * flip, y: m.y + $0.y) })
        p.closeSubpath()
        c.fill(p, with: .color(moonCol))
        let wink = now - fx.winkAt
        if wink >= 0 && wink < 1.8 {
            c.fill(oval(m.x, m.y, r, r), with: .color(moonCol.opacity(min(1, (1.8 - wink)) * 0.85)))
            let ink = Color(hex: 0x7A6A3A)
            c.fill(oval(m.x - 5, m.y - 3, 1.8, 1.8), with: .color(ink))
            var lid = Path()
            lid.move(to: CGPoint(x: m.x + 3, y: m.y - 3))
            lid.addQuadCurve(to: CGPoint(x: m.x + 8, y: m.y - 3), control: CGPoint(x: m.x + 5.5, y: m.y - 5))
            var smile = Path()
            smile.move(to: CGPoint(x: m.x - 5, y: m.y + 3))
            smile.addQuadCurve(to: CGPoint(x: m.x + 5, y: m.y + 3), control: CGPoint(x: m.x, y: m.y + 9))
            c.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            c.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }

    // ── домик на дальнем холме: ночью свет в окне, в холод дым из трубы
    private func drawHouse(_ c: inout GraphicsContext, _ x: CGFloat, _ base: CGFloat, _ tt: CGFloat) {
        let tone = look.tone
        c.fill(Path(CGRect(x: x - 11, y: base - 15, width: 22, height: 15)), with: .color(toned(0xD9C7A7, tone)))
        var roof = Path()
        roof.move(to: CGPoint(x: x - 14, y: base - 14)); roof.addLine(to: CGPoint(x: x, y: base - 27)); roof.addLine(to: CGPoint(x: x + 14, y: base - 14))
        roof.addRect(CGRect(x: x + 5, y: base - 28, width: 4, height: 9))
        c.fill(roof, with: .color(toned(0x9B3B2F, tone)))
        if look.snowCover {
            var s = Path()
            s.move(to: CGPoint(x: x - 13, y: base - 15)); s.addLine(to: CGPoint(x: x, y: base - 26.5)); s.addLine(to: CGPoint(x: x + 13, y: base - 15))
            c.stroke(s, with: .color(toned(0xFFFFFF, max(0.75, tone))), lineWidth: 2.4)
        }
        let lit = look.light < 0.4
        if lit {
            c.fill(oval(x - 3, base - 8, 16, 16), with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.82, blue: 0.48, opacity: 0.55), .clear]),
                                                                        center: CGPoint(x: x - 3, y: base - 8), startRadius: 1, endRadius: 16))
        }
        c.fill(Path(CGRect(x: x - 6, y: base - 11, width: 6, height: 6)), with: .color(lit ? Color(hex: 0xFFD27A) : toned(0x5B6B84, tone)))
        c.fill(Path(CGRect(x: x + 3, y: base - 9, width: 4, height: 9)), with: .color(toned(0x6B4A35, tone)))
        if look.snowCover || sky.temp < 5 {
            for i in 0..<6 {
                let ph = (tt * 0.22 + CGFloat(i) / 6).truncatingRemainder(dividingBy: 1)
                let gray: Double = lit ? 0.6 : 0.93
                c.fill(oval(x + 7 + CGFloat(sky.wind) * ph * 2.4 + sin(tt + CGFloat(i)) * 2, base - 30 - ph * 30, 2 + ph * 5, 2 + ph * 5),
                       with: .color(Color(white: gray, opacity: Double(1 - ph) * 0.4)))
            }
        }
    }

    // ── кошка: в сухую погоду спит под деревом, ночью видны только глаза; в пятницу 13-го — чёрная и не спит
    private func drawCat(_ c: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ tt: CGFloat, _ L: Double) {
        let tone = look.tone
        if L < 0.3 {
            let blink: CGFloat = tt.truncatingRemainder(dividingBy: 4) < 0.15 ? 0.15 : 1
            for dx in [-13.0, -6.0] as [CGFloat] {
                c.fill(oval(x + dx, y - 9, 6, 6), with: .radialGradient(Gradient(colors: [Color(red: 0.78, green: 1, blue: 0.47, opacity: 0.6), .clear]),
                                                                        center: CGPoint(x: x + dx, y: y - 9), startRadius: 0, endRadius: 6))
                c.fill(oval(x + dx, y - 9, 1.8, 1.4 * blink), with: .color(Color(hex: 0xD9FF7A)))
            }
            return
        }
        let black = look.fri13
        let fur = black ? toned(0x26262B, tone) : toned(0xE08A3C, tone), dark = black ? Color(hex: 0x3A3A42) : toned(0xB5651D, tone)
        let b = 1 + sin(tt * 2) * 0.04
        c.fill(oval(x, y - 6, 13, 7 * b), with: .color(fur))
        var tail = Path()
        tail.addArc(center: CGPoint(x: x - 2, y: y - 3), radius: 13, startAngle: .radians(0.1), endAngle: .radians(1.9), clockwise: false)
        c.stroke(tail, with: .color(fur), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        var head = oval(x - 12, y - 7, 5.5, 5.5)
        head.move(to: CGPoint(x: x - 16, y: y - 10)); head.addLine(to: CGPoint(x: x - 15, y: y - 16)); head.addLine(to: CGPoint(x: x - 12, y: y - 11))
        head.move(to: CGPoint(x: x - 11, y: y - 11)); head.addLine(to: CGPoint(x: x - 8, y: y - 16)); head.addLine(to: CGPoint(x: x - 8, y: y - 9))
        c.fill(head, with: .color(fur))
        var stripes = Path()
        for dx in [-2.0, 3, 8] as [CGFloat] { stripes.move(to: CGPoint(x: x + dx, y: y - 12.5)); stripes.addLine(to: CGPoint(x: x + dx - 1, y: y - 9)) }
        c.stroke(stripes, with: .color(dark), lineWidth: 1.2)
        if black {
            c.fill(oval(x - 14.5, y - 8, 1.3, 1.6), with: .color(Color(hex: 0xFACC15)))
            c.fill(oval(x - 10.5, y - 8, 1.3, 1.6), with: .color(Color(hex: 0xFACC15)))
            return
        }
        var eye = Path()
        eye.move(to: CGPoint(x: x - 15, y: y - 7)); eye.addQuadCurve(to: CGPoint(x: x - 13, y: y - 7), control: CGPoint(x: x - 14, y: y - 6))
        c.stroke(eye, with: .color(dark), lineWidth: 1.2)
        let zp = (tt * 0.5).truncatingRemainder(dividingBy: 1)
        c.draw(Text("z").font(.system(size: 8 + zp * 4, weight: .bold)).foregroundColor(.white.opacity(Double(1 - zp) * 0.8)),
               at: CGPoint(x: x - 18 + zp * 4, y: y - 20 - zp * 14))
    }

    private func drawSnowman(_ c: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat) {
        let snow = toned(0xFFFFFF, max(0.7, look.tone))
        c.fill(oval(x, y - 9, 9.5, 9.5), with: .color(snow))
        c.fill(oval(x, y - 24, 6.8, 6.8), with: .color(snow))
        c.fill(Path(CGRect(x: x - 6, y: y - 32.5, width: 12, height: 2)), with: .color(Color(hex: 0x222222)))
        c.fill(Path(CGRect(x: x - 4, y: y - 40, width: 8, height: 8)), with: .color(Color(hex: 0x222222)))
        c.fill(oval(x - 2.3, y - 25.5, 1, 1), with: .color(Color(hex: 0x222222)))
        c.fill(oval(x + 2.3, y - 25.5, 1, 1), with: .color(Color(hex: 0x222222)))
        var nose = Path()
        nose.move(to: CGPoint(x: x, y: y - 23.5)); nose.addLine(to: CGPoint(x: x - 7, y: y - 22.5)); nose.addLine(to: CGPoint(x: x, y: y - 21.5))
        c.fill(nose, with: .color(Color(hex: 0xF97316)))
        var arms = Path()
        arms.move(to: CGPoint(x: x - 8, y: y - 16)); arms.addLine(to: CGPoint(x: x - 16, y: y - 21))
        arms.move(to: CGPoint(x: x + 8, y: y - 16)); arms.addLine(to: CGPoint(x: x + 16, y: y - 22))
        c.stroke(arms, with: .color(toned(0x5B3A26, look.tone)), lineWidth: 1.4)
    }

    private func drawHedgehog(_ c: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ dir: CGFloat, _ tt: CGFloat) {
        var g = c
        g.translateBy(x: x, y: y)
        g.scaleBy(x: dir, y: 1)
        let tone = look.tone
        var body = Path()
        var pts: [CGPoint] = []
        for i in 0...16 { let a = CGFloat.pi + CGFloat(i) / 16 * .pi; pts.append(CGPoint(x: cos(a) * 8, y: -4 + sin(a) * 5)) }
        body.addLines(pts)
        body.closeSubpath()
        g.fill(body, with: .color(toned(0x6B4A2F, tone)))
        var spikes = Path()
        for i in 0..<9 {
            let a = CGFloat.pi + (CGFloat(i) + 0.5) * .pi / 9
            spikes.move(to: CGPoint(x: cos(a) * 6, y: -4 + sin(a) * 3.6))
            spikes.addLine(to: CGPoint(x: cos(a) * 10, y: -4 + sin(a) * 6.5))
        }
        g.stroke(spikes, with: .color(toned(0x4A3220, tone)), lineWidth: 1)
        var snout = Path()
        snout.move(to: CGPoint(x: 6, y: -6)); snout.addLine(to: CGPoint(x: 12, y: -3)); snout.addLine(to: CGPoint(x: 6, y: -1.5))
        g.fill(snout, with: .color(toned(0xD8B48A, tone)))
        g.fill(oval(12, -3, 0.9, 0.9), with: .color(.black))
        g.fill(oval(8, -4.4, 0.5, 0.5), with: .color(.black))
        let s = sin(tt * 8) * 1.5
        var legs = Path()
        legs.move(to: CGPoint(x: -3, y: -1)); legs.addLine(to: CGPoint(x: -3 + s, y: 1))
        legs.move(to: CGPoint(x: 3, y: -1)); legs.addLine(to: CGPoint(x: 3 - s, y: 1))
        g.stroke(legs, with: .color(toned(0x3A2A1A, tone)), lineWidth: 1.2)
    }

    // ── на ветках: сосульки, иней, капли, паутинка, гирлянда, фонарик, ленточка, шарики, птичка, белка
    private func decorate(_ c: inout GraphicsContext, _ s: Sakura, _ tt: CGFloat, _ L: Double) {
        let h = Self.h
        if look.icicles {
            for (i, ic) in s.ice.enumerated() {
                var p = Path()
                p.move(to: CGPoint(x: ic.p.x - 2.2, y: ic.p.y)); p.addLine(to: CGPoint(x: ic.p.x, y: ic.p.y + ic.l)); p.addLine(to: CGPoint(x: ic.p.x + 2.2, y: ic.p.y))
                p.closeSubpath()
                c.fill(p, with: .color(Color(red: 0.78, green: 0.89, blue: 1, opacity: 0.95)))
                c.stroke(p, with: .color(Color(red: 0.35, green: 0.55, blue: 0.78, opacity: 0.7)), lineWidth: 0.7)
                let ph = (tt * 0.6 + CGFloat(i) * 0.37).truncatingRemainder(dividingBy: 1)
                c.fill(oval(ic.p.x, ic.p.y + ic.l + ph * ph * 60, 1.5, 1.5), with: .color(Color(red: 0.43, green: 0.67, blue: 0.92, opacity: Double(1 - ph))))
            }
        }
        if look.rime {
            for i in 0..<22 {
                let t = s.tips[(i * 7) % s.tips.count], a = max(0, sin(tt * 3 + CGFloat(i) * 1.9))
                c.fill(Path(CGRect(x: t.x - 0.8, y: t.y - 0.8, width: 1.6, height: 1.6)), with: .color(.white.opacity(Double(a))))
            }
        }
        if sky.after && !sky.wet && L > 0.3 && look.stage.cover > 0.3 {
            var p = Path()
            for i in 0..<28 {
                let t = s.tips[(i * 5) % s.tips.count], a = pow(max(0, sin(tt * 2.5 + CGFloat(i) * 1.3)), 3) * 3.2
                p.move(to: CGPoint(x: t.x - a, y: t.y + 3)); p.addLine(to: CGPoint(x: t.x + a, y: t.y + 3))
                p.move(to: CGPoint(x: t.x, y: t.y + 3 - a)); p.addLine(to: CGPoint(x: t.x, y: t.y + 3 + a))
            }
            c.stroke(p, with: .color(.white.opacity(0.95)), lineWidth: 0.8)
        }
        if look.autumn && look.hour >= 6 && look.hour <= 10.5 && !look.wet && L > 0.3 {
            // паутинка с росой
            let cx = s.lantern.x - 2, cy = s.lantern.y + 14
            var web = Path()
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                web.move(to: CGPoint(x: cx, y: cy)); web.addLine(to: CGPoint(x: cx + cos(a) * 10, y: cy + sin(a) * 10))
            }
            for rr in [3.5, 6.5, 9.5] as [CGFloat] {
                web.move(to: CGPoint(x: cx + rr, y: cy))
                for i in 1...8 { let a = CGFloat(i) * .pi / 4; web.addLine(to: CGPoint(x: cx + cos(a) * rr, y: cy + sin(a) * rr)) }
            }
            web.move(to: CGPoint(x: cx, y: cy - 10)); web.addLine(to: s.lantern)
            c.stroke(web, with: .color(.white.opacity(0.6)), lineWidth: 0.5)
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4 + 0.4
                c.fill(oval(cx + cos(a) * 6.5, cy + sin(a) * 6.5, 0.9, 0.9), with: .color(.white.opacity(0.5 + 0.5 * sin(t * 3 + Double(i)))))
            }
        }
        if look.newYear || look.friday {
            // гирлянда: на Новый год разноцветная, в пятницу вечером — тёплая
            let pts = s.garland
            if pts.count > 1 {
                var wire = Path()
                wire.move(to: pts[0])
                for i in 1..<pts.count {
                    wire.addQuadCurve(to: pts[i], control: CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: max(pts[i - 1].y, pts[i].y) + 7))
                }
                c.stroke(wire, with: .color(toned(0x2A2A2A, look.tone)), lineWidth: 0.8)
                let ny: [UInt32] = [0xEF4444, 0xFACC15, 0x22C55E, 0x3B82F6, 0xEC4899]
                for i in 0..<(pts.count * 2 - 1) {
                    let a = pts[i / 2], b = pts[min(pts.count - 1, i / 2 + 1)], mid = i % 2 == 1
                    let x = mid ? (a.x + b.x) / 2 : a.x, y = mid ? max(a.y, b.y) + 3.5 : a.y
                    let hex = look.newYear ? ny[i % ny.count] : 0xFFE3A3, on = 0.55 + 0.45 * sin(t * 3 + Double(i) * 1.7)
                    if L < 0.6 {
                        c.fill(oval(x, y, 9, 9), with: .radialGradient(Gradient(colors: [toned(hex, 1, 0.5 * on), toned(hex, 1, 0)]),
                                                                       center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 9))
                    }
                    c.fill(oval(x, y + 1, 2.1, 2.1), with: .color(toned(hex, 1, 0.5 + 0.5 * on)))
                }
            }
        }
        if L < 0.35 {
            // фонарик на ветке
            let x = s.lantern.x + sin(tt * 1.3) * 2, y = s.lantern.y
            var str = Path()
            str.move(to: s.lantern); str.addLine(to: CGPoint(x: x, y: y + 12))
            c.stroke(str, with: .color(Color(hex: 0x3A2A20)), lineWidth: 0.8)
            c.fill(oval(x, y + 18, 30, 30), with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.67, blue: 0.31, opacity: 0.55), .clear]),
                                                                   center: CGPoint(x: x, y: y + 18), startRadius: 1, endRadius: 30))
            c.fill(oval(x, y + 18, 5, 6.5), with: .color(Color(hex: 0xFF8A3D)))
            c.fill(oval(x, y + 18, 2.4, 4), with: .color(Color(hex: 0xFFD08A)))
            c.fill(Path(CGRect(x: x - 3, y: y + 11, width: 6, height: 1.6)), with: .color(Color(hex: 0x5B2A12)))
            c.fill(Path(CGRect(x: x - 3, y: y + 24, width: 6, height: 1.6)), with: .color(Color(hex: 0x5B2A12)))
        }
        if look.march8 {
            // ленточка и веточка мимозы
            let x = s.perch.x, y = s.perch.y
            var bow = Path()
            bow.move(to: CGPoint(x: x, y: y)); bow.addLine(to: CGPoint(x: x - 7, y: y - 4)); bow.addLine(to: CGPoint(x: x - 7, y: y + 4)); bow.closeSubpath()
            bow.move(to: CGPoint(x: x, y: y)); bow.addLine(to: CGPoint(x: x + 7, y: y - 4)); bow.addLine(to: CGPoint(x: x + 7, y: y + 4)); bow.closeSubpath()
            c.fill(bow, with: .color(Color(hex: 0xE11D48)))
            var ends = Path()
            ends.move(to: CGPoint(x: x - 1, y: y)); ends.addLine(to: CGPoint(x: x - 4, y: y + 11 + sin(tt * 2) * 1.5))
            ends.move(to: CGPoint(x: x + 1, y: y)); ends.addLine(to: CGPoint(x: x + 3, y: y + 12 + sin(tt * 2 + 1) * 1.5))
            c.stroke(ends, with: .color(Color(hex: 0xE11D48)), lineWidth: 1.6)
            c.fill(oval(x, y, 1.8, 1.8), with: .color(Color(hex: 0xBE123C)))
            var twig = Path()
            twig.move(to: CGPoint(x: x + 4, y: y + 2)); twig.addLine(to: CGPoint(x: x + 12, y: y + 16))
            c.stroke(twig, with: .color(toned(0x4D7C2A, look.tone)), lineWidth: 1)
            for i in 0..<9 {
                c.fill(oval(x + 6 + CGFloat(i % 3) * 3, y + 6 + CGFloat(i / 3) * 3.5, 1.8, 1.8), with: .color(toned(i % 2 == 1 ? 0xFDE047 : 0xFACC15, look.tone)))
            }
        }
        if bday {
            // шарики на день рождения
            let t0 = s.balloon
            for (i, (hex, dx, dy)) in ([(0xEF4444, -10.0, -44.0), (0xFACC15, 9, -50), (0x3B82F6, 0, -36)] as [(UInt32, CGFloat, CGFloat)]).enumerated() {
                let fi = CGFloat(i)
                let x = t0.x + dx + sin(tt * 1.2 + fi) * 3, y = t0.y + dy + sin(tt * 1.7 + fi) * 2
                var str = Path()
                str.move(to: t0); str.addQuadCurve(to: CGPoint(x: x, y: y + 9), control: CGPoint(x: (t0.x + x) / 2 + 3, y: (t0.y + y) / 2))
                c.stroke(str, with: .color(.white.opacity(0.8)), lineWidth: 0.7)
                c.fill(oval(x, y, 7, 9), with: .color(Color(hex: hex)))
                c.fill(oval(x - 2.4, y - 3, 1.6, 2.6), with: .color(.white.opacity(0.55)))
            }
        }
        let bird = look.bird(sky)
        if bird > 0 {
            // птичка на ветке: весной зарянка, зимой снегирь; от касания улетает и через 10 с возвращается
            let away = now - fx.birdAt
            if away >= 0 && away < 10 {
                if away < 2.2 { drawBird(&c, s.perch.x - CGFloat(away) * 90, s.perch.y - 4 - CGFloat(away) * 60, tt, bird == 2, true) }
            } else {
                drawBird(&c, s.perch.x, s.perch.y - 4 - abs(sin(tt * 2.2)) * 1.2, tt, bird == 2, false)
            }
        }
        if look.winterish && L > 0.5 && !look.wet && sky.kind != .snow {
            // белка пробегает по стволу на ветку и стряхивает снег
            let period: CGFloat = rare ? 9 : 45, u = tt.truncatingRemainder(dividingBy: period)
            if u < 4.5 {
                func at(_ q: CGFloat) -> (CGPoint, CGFloat) {
                    let path = s.climb, v = min(q / 3.5, 0.999) * CGFloat(path.count - 1), i = Int(v), f = v - CGFloat(i)
                    let a = path[i], b = path[i + 1]
                    return (CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), atan2(b.y - a.y, b.x - a.x))
                }
                let (p, ang) = at(u)
                var sq = c
                sq.opacity = Double(max(0, min(1, 4.5 - u)))
                sq.translateBy(x: p.x, y: p.y)
                sq.rotate(by: .radians(Double(ang)))
                let tone = look.tone
                var tail = sq
                tail.translateBy(x: -7, y: -6)
                tail.rotate(by: .radians(Double(-0.5 + sin(tt * 12) * 0.15)))
                tail.fill(oval(0, 0, 4, 7.5), with: .color(toned(0xC97A35, tone)))
                var body = oval(0, -2.5, 6, 3.4)
                body.addPath(oval(5.5, -4, 2.8, 2.8))
                body.move(to: CGPoint(x: 5, y: -6.2)); body.addLine(to: CGPoint(x: 6, y: -9)); body.addLine(to: CGPoint(x: 7, y: -6))
                sq.fill(body, with: .color(toned(0xB5651D, tone)))
                sq.fill(oval(6.6, -4.6, 0.6, 0.6), with: .color(.black))
                if look.snowBranches {
                    var puff = Path()
                    for j in 0..<6 {
                        let s0 = CGFloat(j) * 0.55
                        guard u > s0, s0 < 3.5 else { continue }
                        let (q, _) = at(s0), fall = u - s0
                        puff.addPath(oval(q.x + h(j, 80) * 6, q.y + 35 * fall + 40 * fall * fall, 1.6, 1.6))
                    }
                    c.fill(puff, with: .color(.white.opacity(0.9)))
                }
            }
        }
    }

    private func drawBird(_ c: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ tt: CGFloat, _ finch: Bool, _ flying: Bool) {
        var b = c
        b.translateBy(x: x, y: y)
        let tone = look.tone
        var body = b
        body.rotate(by: .radians(-0.2))
        body.fill(oval(0, 0, 5.5, 3.8), with: .color(toned(finch ? 0x6B7280 : 0x8A5A3C, tone)))
        b.fill(oval(-1.5, 1.2, finch ? 3.6 : 3, finch ? 2.8 : 2.4), with: .color(toned(finch ? 0xE0443A : 0xE8743B, tone)))
        b.fill(oval(-4.8, -2.5, 2.8, 2.8), with: .color(toned(finch ? 0x1F2328 : 0x8A5A3C, tone)))
        var beak = Path()
        beak.move(to: CGPoint(x: -7.4, y: -2.6)); beak.addLine(to: CGPoint(x: -9.6, y: -2)); beak.addLine(to: CGPoint(x: -7.4, y: -1.6))
        b.fill(beak, with: .color(finch ? Color(hex: 0x333333) : Color(hex: 0xF2C94C)))
        b.fill(oval(-5.4, -3, 0.6, 0.6), with: .color(finch ? .white : .black))
        var tail = Path()
        tail.move(to: CGPoint(x: 4.5, y: -1)); tail.addLine(to: CGPoint(x: 10, y: -3.5)); tail.addLine(to: CGPoint(x: 9, y: 1))
        if flying {
            let f = sin(tt * 30) * 6
            tail.move(to: CGPoint(x: 0, y: -1)); tail.addLine(to: CGPoint(x: 3, y: -5 - f)); tail.addLine(to: CGPoint(x: 6, y: -1))
        }
        b.fill(tail, with: .color(toned(finch ? 0x1F2328 : 0x6B4430, tone)))
    }

    // ── листья и лепестки слетают с веток и ложатся на землю; касание — горсть сразу
    private func fallingLeaves(_ c: inout GraphicsContext, _ s: Sakura, _ tt: CGFloat,
                               _ onTree: (CGPoint) -> CGPoint, _ hill: (CGFloat) -> CGFloat, _ cut: CGFloat) {
        let st = look.stage, h = Self.h, w = CGFloat(min(sky.wind, 20)), tone = look.tone
        guard !s.tips.isEmpty else { return }
        let windy = w >= 14
        let cols = st.falling
        var rate: CGFloat = st.fall > 0 ? st.fall + w * 0.2 + (look.wet ? 0.6 : 0) : 0
        if st.key == "summer" || st.key == "green1" { rate = w >= 8 ? w * 0.06 : 0 }
        rate *= cut
        func leaf(_ x: CGFloat, _ y: CGFloat, _ rot: CGFloat, _ hex: UInt32, _ a: Double, _ small: Bool, _ white: Bool) {
            var l = c
            l.translateBy(x: x, y: y)
            l.rotate(by: .radians(Double(rot)))
            let rx: CGFloat = small ? 3 : 4.6, ry: CGFloat = small ? 2.4 : 2.6
            l.fill(oval(0, 0, rx, ry), with: .color(toned(hex, white ? max(0.75, tone) : tone, a)))
        }
        if !cols.isEmpty {
            for i in 0..<min(40, Int(rate * 10)) {
                let period = 8 + h(i, 4) * 4
                let q = (tt + h(i, 5) * period) / period
                let cycle = q.rounded(.down), u = (q - cycle) * period
                let tip = s.tips[Int(h(i, Int(cycle) % 997 + 7) * CGFloat(s.tips.count)) % s.tips.count]
                let p0 = onTree(tip), y0 = p0.y + h(i, 16) * 8
                let vy = (22 + h(i, 6) * 18) * (windy ? 0.45 : 1), vx = w * (windy ? 7 : 4.5)
                let land = max(0, (hill(p0.x + vx * 2) + 4 - y0) / vy)
                let uf = min(u, land), a = h(i, 7) * 6
                let x = p0.x + vx * uf + 8 * sin(2 * uf + a), y = y0 + vy * uf
                let alpha = u > land ? max(0, 1 - (u - land) / 3) : 1
                guard alpha > 0 else { continue }
                leaf(x, y, u > land ? 0.3 : sin(a + (2 + h(i, 9) * 3) * u) * 1.2,
                     cols[Int(h(i, 10) * CGFloat(cols.count)) % cols.count], Double(alpha), st.petal, false)
            }
        }
        // касание дерева или «потянуть главную»: горсть листьев (зимой — снега) сразу
        let since = CGFloat(now - fx.shakeAt)
        let snowy = cols.isEmpty && look.snowBranches
        if since >= 0 && since < 5 && (!cols.isEmpty && st.cover > 0 || snowy) {
            let seed = Int(fx.shakeAt * 10) % 997
            for i in 0..<(fx.strong ? 20 : 14) {
                let tip = s.tips[Int(h(i, seed + 30) * CGFloat(s.tips.count)) % s.tips.count]
                let p0 = onTree(tip), vy = 26 + h(i, seed + 31) * 22, vx = w * 4.5
                let land = max(0, (hill(p0.x) + 4 - p0.y) / vy)
                let uf = min(since, land), a = h(i, seed + 32) * 6
                let alpha = since > land ? max(0, 1 - (since - land) / 3) : 1
                guard alpha > 0 else { continue }
                let hex = snowy ? 0xFFFFFF : cols[Int(h(i, seed + 33) * CGFloat(cols.count)) % cols.count]
                leaf(p0.x + vx * uf + 8 * sin(2 * uf + a), p0.y + vy * uf, since > land ? 0.3 : sin(a + 3 * since) * 1.2,
                     hex, Double(alpha), snowy || st.petal, snowy)
            }
        }
    }
}

// ── карточка ────────────────────────────────────────────────────────────────
struct WeatherCard: View {
    @ObservedObject var weather: Weather
    let city: String
    /// Высота — как у карточки недели отчёта.
    let height: CGFloat
    /// Сегодня у кого-то день рождения — шарики на дереве и облако-сердечко.
    var bday = false
    let ask: () -> Void
    @Environment(\.pageActive) private var active

    var body: some View {
        let sky = weather.now ?? .placeholder()
        let ink = sky.dark ? Color.white : Color(hex: 0x17203D)
        ZStack(alignment: .topLeading) {
            WeatherScene(sky: sky, active: active, bday: bday)
            HStack(spacing: 0) {
                content(sky.dark)
                    .frame(maxWidth: 235, maxHeight: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink)
            .shadow(color: .black.opacity(sky.dark ? 0.25 : 0), radius: 2, y: 1)
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    @ViewBuilder private func content(_ dark: Bool) -> some View {
        if let now = weather.now {
            Button { weather.tapped() } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(now.signedTemp).font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text(now.place).font(.headline).lineLimit(1)
                    Text("\(now.word.prefix(1).uppercased() + now.word.dropFirst()) · ветер \(now.wind) м/с")
                        .font(.footnote.weight(.semibold)).opacity(0.85).lineLimit(1).minimumScaleFactor(0.8)
                    Text("днём \(signed(now.hi)) · ночью \(signed(now.lo))")
                        .font(.footnote.weight(.semibold)).opacity(0.85).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    chip(now.tip, dark)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Погода: \(now.signedTemp), \(now.word), ветер \(now.wind) м/с, \(now.place). "
                                + "Днём \(signed(now.hi)), ночью \(signed(now.lo)). \(now.tip)")
            .accessibilityHint("Обновить погоду")
            .accessibilityAddTraits(.isButton)
        } else if weather.loading {
            VStack(alignment: .leading, spacing: 6) {
                Text("+00°").font(.system(size: 44, weight: .heavy, design: .rounded))
                Text("Погода загружается").font(.headline)
            }
            .redacted(reason: .placeholder)
        } else {
            let noCity = city.trimmingCharacters(in: .whitespaces).isEmpty
            VStack(alignment: .leading, spacing: 6) {
                Text("Погода").font(.title2.weight(.bold))
                Text(noCity ? "Укажите город — здесь будут погода, ветер и совет на день"
                            : weather.problem ?? "Нет связи — погода появится, когда будет интернет")
                    .font(.footnote.weight(.semibold)).opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: ask) { chip(noCity ? "📍 Указать город" : "📍 Сменить город", dark) }
                    .buttonStyle(PressStyle())
            }
        }
    }

    private func chip(_ text: String, _ dark: Bool) -> some View {
        Text(text).font(.caption.weight(.bold)).lineLimit(2).multilineTextAlignment(.leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(dark ? 0.18 : 0.55), in: Capsule())
    }

    private func signed(_ n: Int) -> String { (n > 0 ? "+" : "") + "\(n)°" }
}
