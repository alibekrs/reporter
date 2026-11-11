import SwiftUI

/// Заставка: ночь, снизу с поворотом встаёт значок приложения — от его посадки
/// расходятся волна и искры, по значку пробегает блик, буквы REPORTER падают из размытия,
/// и экран раскрывается кругом из центра значка прямо в приложение.
/// Каждый кадр считается по времени — без шагов и рывков. Нажатие — сразу к раскрытию.
struct SplashView: View {
    /// Экран начал раскрываться — главная может выезжать.
    let opening: () -> Void
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var opened = false
    @State private var finished = false

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            Canvas { ctx, size in
                SplashArt(t: t, size: size).draw(&ctx)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .allowsHitTesting(!opened)                     // пока раскрывается — приложение уже отвечает
        .accessibilityElement()
        .accessibilityLabel("REPORTER")
        .onAppear {
            // «Уменьшить движение»: сразу готовая картинка, потом раскрытие
            if reduceMotion { start = Date().addingTimeInterval(-SplashArt.calm) }
        }
        .task(id: start) {
            // ждём от start: при пропуске start сдвигается, задача перезапускается и ждёт заново
            guard await wait(until: SplashArt.exitAt) else { return }
            open()
            guard await wait(until: SplashArt.end) else { return }
            finish()
        }
    }

    private func wait(until moment: Double) async -> Bool {
        let left = moment - Date().timeIntervalSince(start)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
        return !Task.isCancelled
    }

    private func skip() {
        if Date().timeIntervalSince(start) < SplashArt.exitAt {
            start = Date().addingTimeInterval(-SplashArt.exitAt)
        }
    }

    private func open() {
        guard !opened else { return }
        opened = true
        opening()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        done()
    }
}

/// Один кадр заставки в момент t (секунды). Формулы те же, что в утверждённом прототипе.
private struct SplashArt {
    static let exitAt = 3.55          // начало раскрытия
    static let end = 4.3              // заставка полностью раскрыта
    static let calm = 2.9             // «уменьшить движение»: с этого момента всё уже на месте

    let t: Double
    let W: Double, H: Double          // экран
    let cx: Double, cy: Double        // центр значка
    let L: Double                     // сторона значка

    init(t: Double, size: CGSize) {
        let w = Double(size.width), h = Double(size.height)
        let l = min(w * 0.42, 170)
        self.t = t
        W = w
        H = h
        cx = w / 2
        cy = h * 0.42
        L = l
    }

    func draw(_ ctx: inout GraphicsContext) {
        let reveal = easeInOut(seg(Self.exitAt, 4.25))
        let fade = 1 - reveal
        if reveal > 0 {
            // раскрытие: круглое окно из центра значка растёт до углов экрана
            let r = reveal * hypot(W, H)
            var hole = Path(CGRect(x: 0, y: 0, width: W, height: H))
            hole.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            ctx.clip(to: hole, style: FillStyle(eoFill: true))
        }

        // ночное небо: к центру светлеет, пока встаёт значок; звёзды мерцают и гаснут к рассвету
        let dawn = easeOut(seg(0.2, 1.6))
        let sky = Gradient(stops: [
            .init(color: Self.night.mix(Self.dawnSky, dawn).color(), location: 0),
            .init(color: Self.deep.color(), location: 0.5),
            .init(color: Self.black.color(), location: 1),
        ])
        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)),
                 with: .radialGradient(sky, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: max(W, H) * 0.8))
        let starFade = (1 - 0.6 * dawn) * fade
        for s in Self.seeds.stars {
            let twinkle = 0.5 + 0.5 * sin(t * 3 + s.p)
            ctx.fill(dot(s.x * W, s.y * H, s.r), with: .color(Self.star.color((0.25 + 0.5 * twinkle) * starFade)))
        }

        var logo = ctx
        logo.translateBy(x: cx, y: cy)
        let zoom = 1 + 0.45 * reveal                    // на раскрытии значок чуть летит в камеру
        logo.scaleBy(x: zoom, y: zoom)

        // лучи за значком медленно вращаются
        let rays = easeOut(seg(0.7, 1.8))
        if rays > 0 {
            var c = logo
            c.rotate(by: .radians(t * 0.25))
            c.opacity = 0.22 * rays * fade
            let len = L * 1.6
            let shade = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Self.sun.color(0.9), Self.sun.color(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: -len))
            var ray = Path()
            ray.move(to: CGPoint(x: -L * 0.05, y: 0))
            ray.addLine(to: CGPoint(x: L * 0.05, y: 0))
            ray.addLine(to: CGPoint(x: L * 0.16, y: -len))
            ray.addLine(to: CGPoint(x: -L * 0.16, y: -len))
            ray.closeSubpath()
            for _ in 0..<12 {
                c.rotate(by: .radians(Double.pi / 6))
                c.fill(ray, with: shade)
            }
        }

        // тёплое свечение вокруг значка, чуть дышит
        let glow = easeOut(seg(0.4, 1.6)) * (1 + 0.06 * sin(t * 4))
        if glow > 0 {
            let g = Gradient(colors: [Self.sun.color(0.45 * glow * fade), Self.sun.color(0)])
            logo.fill(Path(CGRect(x: -L, y: -L, width: 2 * L, height: 2 * L)),
                      with: .radialGradient(g, center: .zero, startRadius: 0, endRadius: L * 0.9))
        }

        // значок встаёт снизу с поворотом и лёгким перелётом
        let rise = seg(0.3, 1.6)
        if rise > 0 {
            let b = back(rise)
            var c = logo
            c.opacity = min(rise * 2, 1) * fade
            c.translateBy(x: 0, y: (1 - b) * L * 0.55)
            c.rotate(by: .radians((1 - b) * -0.7))
            let s = 0.55 + 0.45 * b
            c.scaleBy(x: s, y: s)
            image(c)
        }

        // посадка: две волны расходятся от значка
        let wave = seg(1.62, 2.5)
        if wave > 0 && wave < 1 {
            let e = easeOut(wave)
            let width = 3 * (1 - e) + 0.5
            let y = 0.0
            logo.stroke(dot(0, y, L * (0.6 + 1.4 * e)), with: .color(Self.sun.color(0.9 * (1 - e))), lineWidth: width)
            logo.stroke(dot(0, y, L * (0.55 + easeOut(seg(1.7, 2.6)))), with: .color(Self.sky.color(0.7 * (1 - e))), lineWidth: width)
        }

        // искры разлетаются и падают
        let burst = seg(1.62, 2.9)
        if burst > 0 && burst < 1 {
            let reach = easeOut(burst) * L / 210
            let fall = 60 * burst * burst + L * 0.1
            for s in Self.seeds.sparks {
                let d = s.v * reach
                let col = s.gold ? Self.spark : Self.ice
                logo.fill(dot(cos(s.a) * d, sin(s.a) * d + fall, s.r * (1 - burst * 0.5)),
                          with: .color(col.color((1 - burst) * fade)))
            }
        }

        // блик проходит по значку — только по его рисунку
        let shine = seg(1.9, 2.55)
        if shine > 0 && shine < 1 {
            let sweep = -L + 2 * L * easeInOut(shine)
            logo.drawLayer { layer in
                image(layer)
                layer.blendMode = .sourceIn
                let band = Gradient(colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)])
                layer.fill(Path(CGRect(x: -L / 2, y: -L / 2, width: L, height: L)),
                           with: .linearGradient(band, startPoint: CGPoint(x: sweep - L * 0.25, y: -L / 2),
                                                 endPoint: CGPoint(x: sweep + L * 0.25, y: L / 2)))
            }
        }

        // REPORTER: буквы падают из размытия и пружинят, потом по ним пробегает золотая вспышка
        let fs = min(W * 0.1, 40)
        let font = Font.system(size: fs, weight: .black)
        let base = cy + L * 0.72 + fs                  // линия, на которой стоят буквы
        let word = Array("REPORTER")
        var widths: [Double] = []
        for ch in word {
            widths.append(Double(ctx.resolve(Text(String(ch)).font(font)).measure(in: Self.big).width))
        }
        let kern = fs * 0.12
        let total = widths.reduce(0, +) + kern * Double(word.count - 1)
        var x = cx - total / 2
        let shimmer = seg(2.75, 3.35)
        for i in word.indices {
            let from = 2.0 + Double(i) * 0.06
            let p = seg(from, from + 0.65)
            if p > 0 {
                let sp = spring(p)
                let away = shimmer * Double(word.count + 3) - 1.5 - Double(i)
                let lit = shimmer > 0 && shimmer < 1 ? max(0, 1 - abs(away) / 1.5) : 0
                var c = ctx
                c.opacity = min(p * 2.5, 1) * fade
                if p < 1 { c.addFilter(.blur(radius: (1 - easeOut(p)) * 10)) }
                if lit > 0 { c.addFilter(.shadow(color: Self.sun.color(0.9), radius: 9 * lit)) }
                c.translateBy(x: x + widths[i] / 2, y: base - (1 - sp) * 34)
                let s = 1.6 - 0.6 * sp
                c.scaleBy(x: s, y: s)
                let letter = c.resolve(Text(String(word[i])).font(font)
                    .foregroundStyle(Self.white.mix(Self.spark, lit).color()))
                c.draw(letter, at: .zero, anchor: baseline(letter))
            }
            x += widths[i] + kern
        }
    }

    /// Значок по центру.
    private func image(_ c: GraphicsContext) {
        c.draw(Image("Logo"), in: CGRect(x: -L / 2, y: -L / 2, width: L, height: L))
    }

    // ── помощники ───────────────────────────────────────────────────────────

    private static let big = CGSize(width: 1000, height: 1000)

    /// Точка привязки «середина базовой линии» — буквы стоят на линии, а не висят по центру.
    private func baseline(_ text: GraphicsContext.ResolvedText) -> UnitPoint {
        let size = text.measure(in: Self.big)
        guard size.height > 0 else { return .center }
        return UnitPoint(x: 0.5, y: text.firstBaseline(in: Self.big) / size.height)
    }

    private func dot(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    /// Доля пути от a до b для текущего t: 0 до начала, 1 после конца.
    private func seg(_ a: Double, _ b: Double) -> Double { min(max((t - a) / (b - a), 0), 1) }
    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(2 - 2 * x, 3) / 2 }
    /// С перелётом: чуть дальше цели и обратно.
    private func back(_ x: Double) -> Double {
        let y = x - 1
        return 1 + 2.7 * y * y * y + 1.7 * y * y
    }
    /// Пружина: один-два затухающих отскока.
    private func spring(_ x: Double) -> Double { x >= 1 ? 1 : 1 - exp(-6 * x) * cos(10 * x) }

    // ── цвета ───────────────────────────────────────────────────────────────

    struct RGB {
        var r, g, b: Double
        init(_ hex: Int) {
            r = Double((hex >> 16) & 0xff) / 255
            g = Double((hex >> 8) & 0xff) / 255
            b = Double(hex & 0xff) / 255
        }
        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
        func mix(_ o: RGB, _ k: Double) -> RGB { RGB(r: r + (o.r - r) * k, g: g + (o.g - g) * k, b: b + (o.b - b) * k) }
        func color(_ a: Double = 1) -> Color { Color(red: r, green: g, blue: b, opacity: a) }
    }

    private static let night = RGB(0x061423), dawnSky = RGB(0x123a5c), deep = RGB(0x040c16), black = RGB(0x010306)
    private static let star = RGB(0xcfe6ff), sun = RGB(0xf2c00e), sky = RGB(0x3fa4e8)
    private static let spark = RGB(0xffd84a), ice = RGB(0x7cc6ff), white = RGB(0xffffff)

    // ── звёзды и искры: одни и те же при каждом запуске (тот же генератор, что в прототипе) ──

    private struct Star { let x, y, r, p: Double }
    private struct Spark { let a, v, r: Double; let gold: Bool }

    private static let seeds: (stars: [Star], sparks: [Spark]) = {
        var s = 7
        func rnd() -> Double {
            s = s * 16807 % 2147483647
            return Double(s) / 2147483647
        }
        var stars: [Star] = []
        for _ in 0..<70 {
            let x = rnd(), y = rnd(), r = 0.4 + rnd() * 1.2, p = rnd() * 6.28
            stars.append(Star(x: x, y: y, r: r, p: p))
        }
        var sparks: [Spark] = []
        for i in 0..<46 {
            let a = Double(i) / 46 * 6.283 + rnd() * 0.3, v = 120 + rnd() * 220, r = 1 + rnd() * 2.2, gold = rnd() > 0.35
            sparks.append(Spark(a: a, v: v, r: r, gold: gold))
        }
        return (stars, sparks)
    }()
}
