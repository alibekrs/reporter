#if DEBUG
import SwiftUI

/// Варианты оформления на выбор: палитры, значок приложения, нижняя панель, аватарки, названия.
/// Только в сборке для прохода по интерфейсу (в IPA нет): тест задаёт REPORTER_GALLERY=<страница> и снимает экран.
struct Gallery: View {
    static var page: String? { ProcessInfo.processInfo.environment["REPORTER_GALLERY"] }
    let page: String

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.10).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold())
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private var title: String {
        switch page {
        case "palettes": "Цвета приложения"
        case "icons": "Значок приложения"
        case "tabbar": "Нижняя панель"
        case "avatars": "Аватарки в «Учёте»"
        default: "Название"
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case "palettes": palettes
        case "icons": icons
        case "tabbar": tabbars
        case "avatars": avatars
        default: names
        }
    }

    // ── цвета ──
    struct Pal {
        let name: String, sky: Color, deep: Color, sun: Color
        var bg: [Color] {
            [deep.opacity(0.35), .black, sun.opacity(0.22), deep.opacity(0.5), .black, sun.opacity(0.12),
             sky.opacity(0.3), .black, deep.opacity(0.35)]
        }
    }

    static let pals = [
        Pal(name: "A · Синий и жёлтый (сейчас)", sky: hex(0x3FA4E8), deep: hex(0x0A70AC), sun: hex(0xF2C00E)),
        Pal(name: "B · Изумруд", sky: hex(0x34D399), deep: hex(0x047857), sun: hex(0xFBBF24)),
        Pal(name: "C · Индиго", sky: hex(0x818CF8), deep: hex(0x4338CA), sun: hex(0xF472B6)),
        Pal(name: "D · Графит и оранжевый", sky: hex(0xFB923C), deep: hex(0xC2410C), sun: hex(0xFDE047)),
        Pal(name: "E · Бирюза и лайм", sky: hex(0x22D3EE), deep: hex(0x0E7490), sun: hex(0xA3E635)),
        Pal(name: "F · Вишня и золото", sky: hex(0xFB7185), deep: hex(0xBE123C), sun: hex(0xFBBF24)),
    ]

    private var palettes: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 10) {
            ForEach(Self.pals.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    MiniPhone(p: Self.pals[i])
                    Text(Self.pals[i].name).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }

    // ── значок ──
    private var icons: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
            icon("A · Документ (сейчас)", [hex(0x3FA4E8), hex(0x0A70AC)], "doc.text.fill", badge: "checkmark.circle.fill",
                 badgeColor: hex(0xF2C00E))
            icon("B · Щит", [hex(0x6366F1), hex(0x1E3A8A)], "checkmark.shield.fill")
            icon("C · Монитор и ключ", [hex(0x2DD4BF), hex(0x0F766E)], "desktopcomputer", badge: "wrench.and.screwdriver.fill",
                 badgeColor: hex(0xFDE047))
            icon("D · Планшет с задачами", [hex(0x4ADE80), hex(0x15803D)], "list.bullet.clipboard.fill")
            icon("E · Папка с графиком", [hex(0xFDBA74), hex(0xEA580C)], "folder.fill", badge: "chart.bar.fill",
                 badgeColor: .white)
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous).fill(hex(0x111827))
                    Text("R").font(.system(size: 92, weight: .black, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [hex(0x3FA4E8), hex(0x818CF8)], startPoint: .top,
                                                        endPoint: .bottom))
                    Circle().fill(hex(0xF2C00E)).frame(width: 20).offset(x: 34, y: 36)
                }
                .frame(width: 132, height: 132)
                Text("F · Буква").font(.caption.bold())
            }
        }
        .padding(.top, 6)
    }

    private func icon(_ name: String, _ colors: [Color], _ symbol: String, badge: String? = nil,
                      badgeColor: Color = .white) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center))
                Image(systemName: symbol).font(.system(size: 60, weight: .semibold)).foregroundStyle(.white)
                if let badge {
                    Image(systemName: badge).font(.system(size: 30, weight: .bold)).foregroundStyle(badgeColor)
                        .shadow(color: .black.opacity(0.3), radius: 3).offset(x: 34, y: 34)
                }
            }
            .frame(width: 132, height: 132)
            Text(name).font(.caption.bold())
        }
    }

    // ── нижняя панель ──
    static let bars: [(String, [String])] = [
        ("A · Сейчас", ["house", "desktopcomputer", "list.clipboard", "printer", "gearshape"]),
        ("B · С заливкой", ["house.fill", "display", "doc.text.fill", "printer.fill", "gearshape.fill"]),
        ("C · Люди и отчёты", ["square.grid.2x2.fill", "person.2.fill", "chart.bar.doc.horizontal.fill",
                               "printer.filled.and.paper", "slider.horizontal.3"]),
        ("D · Техника", ["house.fill", "cpu", "doc.richtext", "drop.fill", "gearshape.2.fill"]),
        ("E · В кружках", ["house.circle.fill", "person.crop.circle.fill", "doc.circle.fill", "drop.circle.fill",
                           "gear.circle.fill"]),
        ("F · Тонкие", ["house", "person.crop.rectangle.stack", "doc.plaintext", "printer", "ellipsis.circle"]),
    ]
    static let tabs = ["Главная", "Учёт", "Отчёт", "Картриджи", "Настройки"]

    private var tabbars: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.bars.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 5) {
                    Text(Self.bars[i].0).font(.caption.bold()).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { t in
                            VStack(spacing: 3) {
                                Image(systemName: Self.bars[i].1[t]).font(.system(size: 22))
                                    .foregroundStyle(t == 0 ? hex(0x3FA4E8) : .white.opacity(0.85))
                                    .frame(height: 26)
                                Text(Self.tabs[t]).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: Capsule())
                }
            }
        }
        .padding(.top, 4)
        .background(MeshGradient(width: 3, height: 3, points: Self.mesh, colors: Self.pals[0].bg).padding(-14))
    }

    // ── аватарки ──
    static let staff = [("Иванов Сергей Петрович", "Директор", "briefcase.fill", hex(0xF59E0B)),
                        ("Сидорова Мария Петровна", "Главный бухгалтер", "banknote.fill", hex(0x10B981)),
                        ("Ахметов Ерлан Нурланович", "Системный администратор", "desktopcomputer", hex(0x3B82F6)),
                        ("Ким Алина Викторовна", "Юрист", "building.columns.fill", hex(0xA855F7))]

    private var avatars: some View {
        VStack(alignment: .leading, spacing: 8) {
            avatarGroup("A · Инициалы, цвет — по должности") { s in
                Circle().fill(s.3.gradient).overlay(Text(initials(s.0)).font(.system(size: 15, weight: .bold)))
            }
            avatarGroup("B · Значок должности") { s in
                Circle().fill(s.3.opacity(0.22)).overlay(Image(systemName: s.2).font(.system(size: 17)).foregroundStyle(s.3))
            }
            avatarGroup("C · Человечки (мужчина/женщина — по отчеству)") { s in
                Circle().fill(s.3.opacity(0.22)).overlay(Text(emoji(s.1, female: s.0.hasSuffix("вна"))).font(.system(size: 24)))
            }
            avatarGroup("D · Инициалы и значок должности") { s in
                Circle().fill(Color.white.opacity(0.14)).overlay(Text(initials(s.0)).font(.system(size: 15, weight: .bold)))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: s.2).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 19, height: 19).background(s.3, in: Circle())
                            .overlay(Circle().stroke(Color(red: 0.06, green: 0.07, blue: 0.10), lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
            }
        }
    }

    private func avatarGroup<A: View>(_ title: String, @ViewBuilder _ avatar: @escaping ((String, String, String, Color)) -> A)
        -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(Self.staff.indices, id: \.self) { i in
                let s = Self.staff[i]
                HStack(spacing: 12) {
                    avatar(s).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.0).font(.subheadline).lineLimit(1)
                        Text(s.1).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func initials(_ fio: String) -> String {
        fio.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private func emoji(_ role: String, female: Bool) -> String {
        switch role {
        case "Директор": female ? "👩‍💼" : "👨‍💼"
        case "Главный бухгалтер": female ? "👩‍💼" : "👨‍💼"
        case "Системный администратор": female ? "👩‍💻" : "👨‍💻"
        default: female ? "👩‍⚖️" : "👨‍⚖️"
        }
    }

    // ── название ──
    static let titles = [("REPORTER", "сейчас"), ("ТехУчёт", "учёт техники и людей"), ("АйТишка", "по-свойски, коротко"),
                         ("ITdesk", "рабочий стол айтишника"), ("Админка", "всё для сисадмина"),
                         ("Kömek", "«помощь» по-казахски"), ("Inventa", "от «инвентаризация»"),
                         ("Сисадмин", "прямо и понятно"), ("Учётка", "учёт — коротко")]

    private var names: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                ForEach(Self.titles.indices, id: \.self) { i in
                    VStack(spacing: 5) {
                        Image("Logo").resizable().scaledToFit().frame(width: 64, height: 64)
                        Text(Self.titles[i].0).font(.system(size: 12)).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 14)
            .background(MeshGradient(width: 3, height: 3, points: Self.mesh, colors: Self.pals[2].bg),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            ForEach(Self.titles.indices, id: \.self) { i in
                HStack {
                    Text("\(i + 1). " + Self.titles[i].0).font(.headline)
                    Spacer()
                    Text(Self.titles[i].1).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    static let mesh: [SIMD2<Float>] = [[0, 0], [0.5, 0], [1, 0], [0, 0.55], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]]
}

/// Главная в уменьшенном виде — в цветах палитры.
private struct MiniPhone: View {
    let p: Gallery.Pal

    var body: some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: Gallery.mesh, colors: p.bg)
            VStack(alignment: .leading, spacing: 7) {
                Text("Главная").font(.system(size: 14, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("ЭТА НЕДЕЛЯ").font(.system(size: 7, weight: .bold)).opacity(0.8)
                    Text("12 заявок").font(.system(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(LinearGradient(colors: [p.sky, p.deep], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(p.sun.opacity(0.6)).frame(width: 34).blur(radius: 10).allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 6) {
                    tile("24", "сотрудника", "person.2.fill")
                    tile("57", "техники", "desktopcomputer")
                }
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(p.sun)
                    Text("Иванов С. П.").font(.system(size: 10))
                    Spacer()
                    Text("Сохранить").font(.system(size: 9, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(p.deep, in: Capsule())
                }
                .padding(7)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer(minLength: 0)
                HStack {
                    ForEach(["house.fill", "desktopcomputer", "list.clipboard", "printer", "gearshape"], id: \.self) { s in
                        Image(systemName: s).font(.system(size: 11)).frame(maxWidth: .infinity)
                            .foregroundStyle(s == "house.fill" ? p.sky : .white.opacity(0.8))
                    }
                }
                .padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
            }
            .padding(10)
        }
        .frame(height: 248)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.15)))
    }

    private func tile(_ n: String, _ caption: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(p.sky)
            Text(n).font(.system(size: 15, weight: .bold))
            Text(caption).font(.system(size: 7)).opacity(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
}
#endif
