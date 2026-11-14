import SwiftUI
import UIKit

// ── темы оформления ─────────────────────────────────────────────────────────
/// Цветовая тема: акценты, фон под стеклом и цвета талисмана. Brand берёт цвета из выбранной.
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let sky: Color          // светлый акцент: подсветка, градиенты
    let blue: Color         // основной акцент: кнопки, выделение
    let sun: Color          // яркий второй цвет: значки, бейджи
    let gold: Color         // второй цвет, читаемый на светлом
    let ink: Color          // текст и значки на sun
    var scheme: ColorScheme? = nil      // Лаванда — всегда светлая, OLED и Матрица — всегда тёмные
    var mono = false                     // Матрица — моноширинный шрифт
    var secret = false                   // Матрица открывается пасхалкой

    /// Фон под стеклом (сетка 3×3): тёмный — оттенки акцентов на почти чёрном, светлый — их пастель.
    func mesh(dark: Bool) -> [Color] {
        if id == "oled" || id == "matrix" { return Array(repeating: .black, count: 9) }
        if dark {
            let k: Color = Color(red: 0.02, green: 0.02, blue: 0.06)
            return [blue.mix(with: k, by: 0.7), k, sun.mix(with: k, by: 0.82), blue.mix(with: k, by: 0.6), k,
                    sun.mix(with: k, by: 0.88), sky.mix(with: k, by: 0.72), k, blue.mix(with: k, by: 0.7)]
        }
        return [sky.mix(with: .white, by: 0.82), .white.mix(with: sky, by: 0.03), sun.mix(with: .white, by: 0.86),
                sky.mix(with: .white, by: 0.78), .white.mix(with: sky, by: 0.05), sun.mix(with: .white, by: 0.84),
                sky.mix(with: .white, by: 0.8), .white.mix(with: sky, by: 0.06), sky.mix(with: .white, by: 0.82)]
    }
}

enum Theme {
    static let key = "palette"
    static let defaultID = "indigo"
    static let matrixKey = "palette.matrix"          // секретная тема открыта
    static let all: [Palette] = [
        Palette(id: "indigo", name: "Индиго", sky: Color(hex: 0x818CF8), blue: Color(hex: 0x4F46E5), sun: Color(hex: 0xF472B6),
                gold: Color(hex: 0xDB2777), ink: Color(hex: 0x40092A)),
        Palette(id: "ocean", name: "Океан", sky: Color(hex: 0x3FA4E8), blue: Color(hex: 0x0A70AC), sun: Color(hex: 0xF2C00E),
                gold: Color(hex: 0xD59F00), ink: Color(hex: 0x3B2E00)),
        Palette(id: "emerald", name: "Изумруд", sky: Color(hex: 0x34D399), blue: Color(hex: 0x059669), sun: Color(hex: 0xFBBF24),
                gold: Color(hex: 0xB45309), ink: Color(hex: 0x422800)),
        Palette(id: "sunset", name: "Закат", sky: Color(hex: 0xFB923C), blue: Color(hex: 0xEA580C), sun: Color(hex: 0xFDE047),
                gold: Color(hex: 0xA16207), ink: Color(hex: 0x3F3300)),
        Palette(id: "cherry", name: "Вишня", sky: Color(hex: 0xFB7185), blue: Color(hex: 0xE11D48), sun: Color(hex: 0xFBBF24),
                gold: Color(hex: 0xB45309), ink: Color(hex: 0x422800)),
        Palette(id: "teal", name: "Бирюза", sky: Color(hex: 0x22D3EE), blue: Color(hex: 0x0891B2), sun: Color(hex: 0xA3E635),
                gold: Color(hex: 0x4D7C0F), ink: Color(hex: 0x1A2E05)),
        Palette(id: "aurora", name: "Сияние", sky: Color(hex: 0x2DD4BF), blue: Color(hex: 0x7C3AED), sun: Color(hex: 0xF0ABFC),
                gold: Color(hex: 0xA21CAF), ink: Color(hex: 0x3B0745)),
        Palette(id: "lavender", name: "Лаванда", sky: Color(hex: 0xA78BFA), blue: Color(hex: 0x7C3AED), sun: Color(hex: 0xF472B6),
                gold: Color(hex: 0xDB2777), ink: Color(hex: 0x40092A), scheme: .light),
        Palette(id: "oled", name: "OLED", sky: Color(hex: 0xA5B4FC), blue: Color(hex: 0x6366F1), sun: Color(hex: 0xF472B6),
                gold: Color(hex: 0xDB2777), ink: Color(hex: 0x40092A), scheme: .dark),
        Palette(id: "matrix", name: "Матрица", sky: Color(hex: 0x4ADE80), blue: Color(hex: 0x16A34A), sun: Color(hex: 0x86EFAC),
                gold: Color(hex: 0x15803D), ink: Color(hex: 0x052E16), scheme: .dark, mono: true, secret: true),
    ]

    static var current: Palette {
        let id = UserDefaults.standard.string(forKey: key) ?? defaultID
        return all.first { $0.id == id } ?? all[0]
    }

    /// Темы на выбор: секретная — только когда открыта пасхалкой.
    static var choices: [Palette] {
        all.filter { !$0.secret || UserDefaults.standard.bool(forKey: matrixKey) }
    }

    /// Сменить тему: новая проявляется кругом от пальца (point — в координатах окна).
    @MainActor
    static func choose(_ id: String, from point: CGPoint?) {
        guard id != current.id else { return }
        Wipe.run(from: point) {
            UserDefaults.standard.set(id, forKey: key)
            applyTheme(UserDefaults.standard.integer(forKey: "theme"))
        }
    }
}

/// «Меньше анимаций»: системная настройка или своя в «Настройках».
enum Motion {
    static let key = "motion.less"
    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled || UserDefaults.standard.bool(forKey: key) }
}

/// Смена оформления «шторкой»: снимок старого экрана сверху, в нём растёт круглая дыра — под ней уже новое.
@MainActor
enum Wipe {
    static func run(from point: CGPoint?, _ change: () -> Void) {
        let window = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first?
            .windows.first { $0.windowLevel == .normal && !$0.isHidden }
        guard !Motion.reduced, let window, let snap = window.snapshotView(afterScreenUpdates: false) else {
            change()
            return
        }
        window.addSubview(snap)
        change()
        let b = window.bounds
        let c = point ?? CGPoint(x: b.midX, y: b.maxY - 120)
        let r = hypot(max(c.x, b.width - c.x), max(c.y, b.height - c.y))
        func hole(_ radius: CGFloat) -> CGPath {
            let p = UIBezierPath(rect: b)
            p.append(UIBezierPath(arcCenter: c, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true))
            return p.cgPath
        }
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.path = hole(r)
        snap.layer.mask = mask
        CATransaction.begin()
        CATransaction.setCompletionBlock { snap.removeFromSuperview() }
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = hole(1)
        a.toValue = hole(r)
        a.duration = 0.6
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mask.add(a, forKey: "wipe")
        CATransaction.commit()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
