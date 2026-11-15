import SwiftUI

// ── карточка погоды на главной: сакура по сезону, дождь, снег, ветер, ночь ──
// Дерево рисуется один раз в картинку (в фоне), каждый кадр только наклоняется по ветру; капли, снег и листья
// считаются по времени, без состояния — анимация лёгкая и стоит, когда главная не на экране.

enum Season {
    case winter, spring, summer, autumn

    static func of(_ d: Date) -> Season {
        switch Calendar(identifier: .gregorian).component(.month, from: d) {
        case 12, 1, 2: return .winter
        case 3, 4, 5: return .spring
        case 6, 7, 8: return .summer
        default: return .autumn
        }
    }

    /// Цвет кроны: цветы весной, листва летом и осенью; зимой ветки голые.
    var crown: [UInt32] {
        switch self {
        case .spring: return [0xFFD3E2, 0xFFB8CF, 0xFFF1F6, 0xF7A1C0]
        case .summer: return [0x2E7D32, 0x3F9142, 0x58A84F, 0x245F29]
        case .autumn: return [0xE4572E, 0xF08A24, 0xC8322B, 0xF4B942, 0xD9661F]
        case .winter: return []
        }
    }

    /// Что слетает с дерева.
    var falling: [UInt32] {
        switch self {
        case .spring: return [0xFFC4D8, 0xFFDBE7, 0xFFF1F6]
        case .summer, .autumn: return crown
        case .winter: return []
        }
    }

    var ground: UInt32 {
        switch self {
        case .summer: return 0x4F9A3F
        case .spring: return 0x86C46E
        case .autumn: return 0x9C7D45
        case .winter: return 0xF2F6FB
        }
    }
}

/// Цвет с затемнением: ночью и в грозу дерево и земля темнее.
private func toned(_ hex: UInt32, _ k: Double, _ alpha: Double = 1) -> Color {
    Color(red: Double((hex >> 16) & 255) / 255 * k, green: Double((hex >> 8) & 255) / 255 * k,
          blue: Double(hex & 255) / 255 * k, opacity: alpha)
}

private func cgTone(_ hex: UInt32, _ k: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255 * k, green: CGFloat((hex >> 8) & 255) / 255 * k,
            blue: CGFloat(hex & 255) / 255 * k, alpha: alpha)
}

// ── сакура: ветви по зерну — одно и то же дерево при каждом запуске ─────────
struct Sakura: Sendable {
    struct Seg: Sendable { let a: CGPoint, m: CGPoint, b: CGPoint; let width: CGFloat; let depth: Int }
    /// Координаты от основания ствола (0, 0), вверх — минус.
    let segs: [Seg]
    let tips: [CGPoint]

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
                let spread = (d == 0 ? 0.62 : 0.5) + r() * 0.25
                var a = ang + (n == 2 ? (i == 1 ? spread : -spread) : CGFloat(i - 1) * spread) + (r() - 0.5) * 0.25
                if d > 1 { a += a < -.pi / 2 ? -0.12 : 0.12 }      // сакура раскидистая: ветви в стороны
                branch(e, a, len * (0.7 + r() * 0.12), wd * 0.64, d + 1)
            }
        }
        branch(.zero, -.pi / 2 + 0.05, h * 0.3, 15, 0)
        self.segs = segs
        self.tips = tips
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

    /// Дерево целиком картинкой размером с карточку. Рисуется в фоне: тысячи цветков — десятки миллисекунд.
    @MainActor static func image(_ season: Season, tone: CGFloat, night: Bool, size: CGSize, scale: CGFloat) async -> UIImage {
        let key = "\(season)-\(tone)-\(night)-\(Int(size.width))x\(Int(size.height))@\(scale)"
        if let img = images[key] { return img }
        let tree = shape(size.height * 0.95)
        let img = await Task.detached(priority: .userInitiated) {
            Self.render(tree, season, tone: tone, night: night, size: size, scale: scale)
        }.value
        if images.count > 6 { images.removeAll() }
        images[key] = img
        return img
    }

    nonisolated private static func render(_ tree: Sakura, _ season: Season, tone k: CGFloat, night: Bool,
                                           size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let c = rc.cgContext
            c.translateBy(x: size.width * 0.72, y: size.height - 20)
            var seed: UInt64 = 11
            func r() -> CGFloat {
                seed = (seed * 16807) % 2147483647
                return CGFloat(seed) / 2147483647
            }
            let cols = season.crown
            // тень под гроздьями — крона объёмная
            if !cols.isEmpty {
                let base: UInt32 = season == .spring ? 0xE889AD : season == .summer ? 0x1D4D21 : 0x8F2F1B
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [cgTone(base, k, 0.35), cgTone(base, k, 0)] as CFArray, locations: [0, 1])!
                for t in tree.tips {
                    let p = CGPoint(x: t.x, y: t.y + 4)
                    c.drawRadialGradient(g, startCenter: p, startRadius: 2, endCenter: p, endRadius: 26, options: [])
                }
            }
            // ветви: тёмная кора с бликом слева, зимой сверху лежит снег
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
                if season == .winter && s.depth > 0 {
                    c.setStrokeColor(night ? cgTone(0xC3CDE0, 1) : cgTone(0xFFFFFF, 1))
                    c.setLineWidth(max(1.6, s.width * 0.45))
                    c.move(to: CGPoint(x: s.a.x, y: s.a.y - s.width * 0.45))
                    c.addQuadCurve(to: CGPoint(x: s.b.x, y: s.b.y - s.width * 0.4),
                                   control: CGPoint(x: s.m.x, y: s.m.y - s.width * 0.5))
                    c.strokePath()
                }
            }
            guard !cols.isEmpty else { return }
            // цветы и листья гроздьями на концах и по внешним ветвям; во втором проходе верх грозди светлее
            let spots = tree.tips + tree.segs.filter { $0.depth >= 4 }.map(\.m)
            let many = season == .spring ? 7 : 5
            let lit: UInt32 = season == .spring ? 0xFFF4F8 : season == .summer ? 0x7CC36A : 0xF7C75A
            for pass in 0..<2 {
                for t in spots {
                    for _ in 0..<many {
                        let x = t.x + (r() - 0.5) * 30, y = t.y + (r() - 0.6) * 22
                        let pick = cols[Int(r() * CGFloat(cols.count)) % cols.count]
                        let color = cgTone(pass == 1 && y < t.y ? lit : pick, k)
                        c.setFillColor(color)
                        if season == .spring {
                            let s = 3.2 + r() * 2.2
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
                            let rx = 4.2 + r() * 2, ry = 2.2 + r()
                            c.saveGState()
                            c.translateBy(x: x, y: y)
                            c.rotate(by: r() * 3)
                            c.fillEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                            c.restoreGState()
                        }
                    }
                }
            }
        }
    }
}

// ── сцена: небо, солнце или луна, облака, дерево, листопад, дождь, снег, туман, молнии ──
struct WeatherScene: View {
    let sky: Weather.Sky
    let active: Bool
    @State private var size = CGSize.zero
    @State private var tree: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        // всё нужное кадру — здесь, в body: состояние, прочитанное только внутри Canvas, перерисовку не вызывает
        let sky = self.sky, tree = self.tree, size = self.size
        let shape: Sakura? = size.height > 0 ? Sakura.shape(size.height * 0.95) : nil
        let tone: CGFloat = !sky.day ? 0.42 : sky.kind == .storm ? 0.7 : 1
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || Motion.reduced)) { tl in
            Canvas { ctx, sz in
                ScenePainter(sky: sky, tree: tree, shape: shape, tone: Double(tone),
                             t: tl.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600)).draw(&ctx, sz)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: "\(sky.season)-\(tone)-\(sky.day)-\(Int(size.width))x\(Int(size.height))-\(scale)") {
            guard size.width > 0, size.height > 0 else { return }
            tree = await Sakura.image(sky.season, tone: tone, night: !sky.day, size: size, scale: scale)
        }
        .accessibilityHidden(true)
    }
}

private struct ScenePainter {
    let sky: Weather.Sky
    let tree: UIImage?
    let shape: Sakura?
    let tone: Double
    let t: Double

    /// Случайное, но одно и то же для частицы i: капли и листья не хранятся, а считаются по времени.
    static func h(_ i: Int, _ s: Int) -> CGFloat {
        let x = sin(Double(i * 127 + s * 311 + 1) * 12.9898) * 43758.5453
        return CGFloat(x - x.rounded(.down))
    }

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let W = size.width, H = size.height, w = CGFloat(min(sky.wind, 20)), tt = CGFloat(t)
        let night = !sky.day, kind = sky.kind, h = Self.h

        // небо
        let colors: (UInt32, UInt32) = night
            ? (kind == .clear ? (0x0C1430, 0x28346A) : (0x161B2C, 0x363D55))
            : { () -> (UInt32, UInt32) in switch kind {
                case .clear: return (0x6FB8F2, 0xCFE8FB)
                case .cloudy: return (0x93A3B7, 0xD3DAE3)
                case .rain: return (0x6B7B90, 0xAAB5C3)
                case .snow: return (0xB4C2D4, 0xE8EEF5)
                case .storm: return (0x323A4F, 0x646D82)
                case .fog: return (0xBCC3CB, 0xE3E6E9)
                } }()
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [Color(hex: colors.0), Color(hex: colors.1)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: H)))

        // звёзды, луна, солнце
        if night && (kind == .clear || kind == .cloudy) {
            for i in 0..<40 {
                let a = 0.35 + 0.35 * sin(1.5 * t + Double(h(i, 3)) * 6)
                ctx.fill(Path(CGRect(x: h(i, 1) * W, y: h(i, 2) * H * 0.6, width: 1.6, height: 1.6)), with: .color(.white.opacity(a)))
            }
        }
        if kind == .clear || kind == .cloudy {
            let c = CGPoint(x: W * 0.5, y: 34)
            if night {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30)), with: .color(Color(hex: 0xF5F1D6)))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 18, width: 26, height: 26)), with: .color(Color(hex: colors.0)))
            } else {
                var rays = Path()
                for k in 0..<10 {
                    let a = tt * 0.25 + CGFloat(k) * .pi / 5
                    rays.move(to: CGPoint(x: c.x + cos(a) * 24, y: c.y + sin(a) * 24))
                    rays.addLine(to: CGPoint(x: c.x + cos(a) * 31, y: c.y + sin(a) * 31))
                }
                ctx.stroke(rays, with: .color(Color(hex: 0xFDE047).opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36)), with: .color(Color(hex: 0xFDE047)))
            }
        }

        // облака плывут по ветру
        if !(kind == .clear && w == 0) {
            let color: Color = night ? toned(0x505A78, 1, 0.85)
                : kind == .storm ? toned(0x3C4254, 1, 0.95)
                : kind == .clear ? .white.opacity(0.75) : toned(0xECF0F5, 1, 0.9)
            for i in 0..<(kind == .clear ? 1 : 4) {
                let s = 0.7 + CGFloat(i % 3) * 0.25
                let x = (CGFloat(i) / 4 * W * 1.2 + 100 + (6 + w * 3) * s * tt).truncatingRemainder(dividingBy: W + 140) - 100
                let y = 16 + CGFloat(i % 2) * 22
                var p = Path()
                for (dx, dy, r) in [(0.0, 8.0, 16.0), (18, 0, 20), (40, 6, 17), (56, 12, 12), (24, 14, 16)] as [(CGFloat, CGFloat, CGFloat)] {
                    p.addEllipse(in: CGRect(x: x + dx * s - r * s, y: y + dy * s - r * s, width: r * s * 2, height: r * s * 2))
                }
                ctx.fill(p, with: .color(color))
            }
        }

        // земля
        ctx.fill(Path(ellipseIn: CGRect(x: W * 0.72 - W * 0.42, y: H + 18 - 52, width: W * 0.84, height: 104)),
                 with: .color(toned(sky.season.ground, tone)))
        if sky.season == .winter || kind == .snow {
            ctx.fill(Path(ellipseIn: CGRect(x: W * 0.5 - W * 0.75, y: H + 14 - 26, width: W * 1.5, height: 52)),
                     with: .color(Color(hex: night ? 0xAEB9CF : 0xFFFFFF)))
        }

        // дерево качается: основание стоит, верхушка уходит по ветру
        let g = w / 20
        let sway = (sin(tt * (0.9 + g)) * 0.6 + sin(tt * 2.3) * 0.25) * g * 12 + g * 9
        let bx = W * 0.72, by = H - 20, k = -sway / (H * 0.9)
        if let tree {
            var c = ctx
            c.concatenate(CGAffineTransform(a: 1, b: 0, c: k, d: 1, tx: -k * by, ty: 0))
            c.draw(Image(uiImage: tree), in: CGRect(origin: .zero, size: size))
        }

        // листья и лепестки слетают с веток и ложатся на землю
        let leaf = sky.season.falling
        if let shape, !shape.tips.isEmpty, !leaf.isEmpty {
            let rate: CGFloat = switch sky.season {
            case .autumn: 0.9 + w * 0.25 + (kind == .rain || kind == .storm ? 0.8 : 0)
            case .spring: 0.5 + w * 0.15
            case .summer: w >= 8 ? w * 0.06 : 0
            case .winter: 0
            }
            let petal = sky.season == .spring
            for i in 0..<min(40, Int(rate * 10)) {
                let period = 8 + h(i, 4) * 4
                let q = (tt + h(i, 5) * period) / period
                let cycle = q.rounded(.down), u = (q - cycle) * period
                let tip = shape.tips[Int(h(i, Int(cycle) % 997 + 7) * CGFloat(shape.tips.count)) % shape.tips.count]
                let x0 = bx + tip.x + sway * (-tip.y) / (H * 0.9), y0 = by + tip.y + h(i, 16) * 8
                let vy = 22 + h(i, 6) * 18
                let land = max(0, (H - 10 - h(i, 8) * 4 - y0) / vy)
                let uf = min(u, land), a = h(i, 7) * 6
                let x = x0 + w * 4.5 * uf + 8 * sin(2 * uf + a), y = y0 + vy * uf
                let alpha = u > land ? max(0, 1 - (u - land) / 3) : 1
                guard alpha > 0, x < W + 20 else { continue }
                var c = ctx
                c.translateBy(x: x, y: y)
                c.rotate(by: .radians(u > land ? 0.3 : sin(a + (2 + h(i, 9) * 3) * u) * 1.2))
                let rx: CGFloat = petal ? 3 : 4.6, ry: CGFloat = petal ? 2.4 : 2.6
                c.fill(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)),
                       with: .color(toned(leaf[Int(h(i, 10) * CGFloat(leaf.count)) % leaf.count], tone, Double(alpha))))
            }
        }

        // дождь — по всей карточке, косой по ветру
        if kind == .rain || kind == .storm {
            let slant = w * 0.045
            var p = Path()
            for i in 0..<(kind == .storm ? 140 : 95) {
                let v = 420 + h(i, 12) * 260, l = 8 + h(i, 13) * 10
                let y = (h(i, 14) * H + v * tt).truncatingRemainder(dividingBy: H + l) - l
                let x = h(i, 11) * (W + slant * H + 20) - slant * H + slant * (y + l)
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x - l * slant, y: y - l))
            }
            ctx.stroke(p, with: .color(night ? toned(0xAABEE6, 1, 0.55) : toned(0xEBF2FF, 1, 0.75)), lineWidth: 1.3)
        }

        // снег
        if kind == .snow {
            var p = Path()
            for i in 0..<80 {
                let r = 1 + h(i, 17) * 2.4, v = 18 + h(i, 18) * 30
                let y = (h(i, 19) * H + v * tt).truncatingRemainder(dividingBy: H + 8) - 4
                let x = (h(i, 20) * W + w * 3 * tt + 10 * sin(tt + h(i, 21) * 6) + W + 8).truncatingRemainder(dividingBy: W + 8) - 4
                p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            ctx.fill(p, with: .color(.white.opacity(0.95)))
        }

        // туман
        if kind == .fog {
            for i in 0..<3 {
                let y = H * (0.35 + CGFloat(i) * 0.22)
                let x = (tt * (8 + w * 2) * CGFloat(i + 1)).truncatingRemainder(dividingBy: W * 2) - W
                ctx.fill(Path(ellipseIn: CGRect(x: x + W * 0.5 - W * 0.7, y: y - 14, width: W * 1.4, height: 28)),
                         with: .color(.white.opacity(night ? 0.12 : 0.38)))
            }
        }

        // молния: вспышка раз в несколько секунд
        if kind == .storm {
            let cycle = (tt / 5).rounded(.down)
            let f = tt - cycle * 5 - h(Int(cycle) % 1000, 15) * 2
            if f >= 0 && f < 0.33 {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(Double((1 - f * 3) * 0.55))))
            }
        }

        // под текстом слева чуть светлее (днём) или темнее (ночью) — читается на любом небе
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [sky.dark ? .black.opacity(0.18) : .white.opacity(0.22), .clear]),
                                       startPoint: .zero, endPoint: CGPoint(x: W * 0.6, y: 0)))
    }
}

// ── карточка ────────────────────────────────────────────────────────────────
struct WeatherCard: View {
    @ObservedObject var weather: Weather
    let city: String
    /// Высота — как у карточки недели отчёта.
    let height: CGFloat
    let ask: () -> Void
    @Environment(\.pageActive) private var active

    var body: some View {
        let sky = weather.now ?? .placeholder()
        let ink = sky.dark ? Color.white : Color(hex: 0x17203D)
        ZStack(alignment: .topLeading) {
            WeatherScene(sky: sky, active: active)
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
                    Text(signed(now.temp)).font(.system(size: 44, weight: .heavy, design: .rounded))
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Погода: \(signed(now.temp)), \(now.word), ветер \(now.wind) м/с, \(now.place). "
                                + "Днём \(signed(now.hi)), ночью \(signed(now.lo)). \(now.tip)")
            .accessibilityHint("Обновить погоду")
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
