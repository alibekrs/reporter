import SwiftUI
import UniformTypeIdentifiers

@main
struct ITtoolApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate    // быстрые действия с иконки
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup { RootView().environmentObject(store) }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.scenePhase) private var phase
    @AppStorage("theme") private var theme = 0
    @State private var tab = AppTab.home
    @State private var page: AppTab? = .home        // какая страница сейчас в прокрутке
    @State private var progress: CGFloat = 0        // 0…4: положение прокрутки в страницах — по нему едет линза
    // открыли быстрым действием с иконки — сразу к делу, без заставки. Со входом заставки тоже нет: её роль
    // играет экран входа, а 4 секунды заставки под ним добавлялись к Face ID — приложение открывалось долго
    @State private var splash = SceneDelegate.pending == nil && !LockScreen.shared.locked
    // заставка раскрывается — карточки главной выезжают
    @State private var revealed = SceneDelegate.pending != nil || LockScreen.shared.locked
    @State private var keyboard = false             // клавиатура на экране — панель и талисман прячутся
    @AppStorage(Theme.key) private var palette = Theme.defaultID
    @State private var menu = false                 // открыто меню талисмана
    @State private var celebrate = false            // талисман радуется: бэкап ушёл
    @State private var plane = false                // самолётик бэкапа на экране
    @State private var planeGo = false              // и улетает
    @State private var note: String?                // плашка сверху
    @AppStorage("font.size") private var fontSize = 0       // 0 — как в системе
    @State private var failure: String?

    var body: some View {
        // размер страниц задаём явно: с containerRelativeFrame лента вылезала за экран и панель уезжала вниз
        GeometryReader { geo in
            // страницы рядом в одну ленту: листаются пальцем в любом месте экрана, как в Instagram;
            // все живут одновременно — поиск, прокрутка и открытые карточки не сбрасываются
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    pageView(.home, geo.size) { HomeView(tab: $tab, ready: revealed) }
                    pageView(.assets, geo.size) { AssetsView() }
                    pageView(.report, geo.size) { ReportView() }
                    pageView(.carts, geo.size) { CartridgesView() }
                    pageView(.settings, geo.size) { SettingsView() }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .scrollDisabled(cardOpen)                    // открыта карточка сотрудника — свайп «назад» её
            .onScrollGeometryChange(for: CGFloat.self) { g in
                g.containerSize.width > 0 ? g.contentOffset.x / g.containerSize.width : 0
            } action: { _, p in
                progress = p
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // смена темы: страницы пересоздаются в новых цветах (вкладка остаётся та же)
        .id(palette)
        .background(AppBackground())
        .overlay {
            // открыто меню талисмана — страницы притушены, нажатие мимо закрывает
            if menu {
                Color.black.opacity(0.3).ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { menu = false } }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottomTrailing) {
                // при клавиатуре панель и талисман прячутся: страницы сжимаются над ней, и панель закрывала поля
                GlassTabBar(selection: tab, progress: progress) { t in
                    go(t)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
                .opacity(keyboard ? 0 : 1)
                .allowsHitTesting(!keyboard)
                .accessibilityHidden(keyboard)
                if plane { flyingPlane }
                // талисман вместо «+» — на всех вкладках, над панелью; над карточкой сотрудника его нет
                MascotMenu(open: $menu, shown: !keyboard && !cardOpen, celebrate: celebrate) { act($0) }
                    .padding(.trailing, 14)
                    .padding(.bottom, 2 + GlassTabBar.height + 8)
            }
            .errorAlert($failure)
        }
        .toast($note)
        .fontDesign(Theme.current.mono ? .monospaced : nil)
        .dynamicTypeSize(RootView.typeSizes(fontSize))
        // поиск и проверка данных открывают карточку или запись — переходим на их вкладку
        .onChange(of: store.action) { _, a in
            switch a {
            case .openEmployee: go(.assets)
            case .openEntry: go(.report)
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.15)) { keyboard = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboard = false }
        }
        .tint(Brand.blue)
        .onChange(of: page) { _, p in if let p, p != tab { tab = p } }
        .onChange(of: tab) { _, t in if page != t { go(t) } }   // быстрые кнопки главной меняют tab
        .overlay {
            // к концу заставка уже полностью раскрыта и прозрачна — убираем без перехода
            if splash {
                SplashView(opening: { revealed = true }, done: { splash = false })
            }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            store.refreshToday()                  // приложение могло пролежать в памяти до нового дня
            store.syncReminders()
            applyTheme(theme)
            await store.backup()                  // по расписанию, при открытии приложения
            await store.verifyBackup()            // раз в месяц: последний бэкап читается
        }
        .onChange(of: phase, initial: true) { _, p in
            // вход: в фоне — закрыть, на экране — спросить Face ID; не на экране — данные не видны
            LockScreen.shared.scene(p)
            guard p == .background, store.backupDue else { return }
            // бэкап «после изменений» уходит, когда приложение сворачивают: просим у системы время доотправить
            let app = UIApplication.shared, box = BackgroundTaskBox()
            box.id = app.beginBackgroundTask(withName: "REPORTER backup") {
                MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(box.id) }
            }
            Task {
                await store.backup()
                app.endBackgroundTask(box.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            store.refreshToday()                  // полночь при открытом приложении
        }
        .onReceive(NotificationCenter.default.publisher(for: SceneDelegate.arrived)) { _ in shortcut() }
        .task { shortcut() }                      // приложение открыли быстрым действием с иконки
        .onChange(of: theme) { _, t in applyTheme(t) }
        .errorAlert($store.loadError)
    }

    private func go(_ t: AppTab) {
        tab = t
        withAnimation(.smooth(duration: 0.38)) { page = t }
    }

    /// Быстрое действие с иконки приложения: сразу к делу, без заставки.
    private func shortcut() {
        guard let type = SceneDelegate.pending else { return }
        SceneDelegate.pending = nil
        splash = false
        revealed = true
        switch type {
        case "entry": store.action = .newEntry; go(.report)
        case "cart": store.action = .newCart; go(.carts)
        case "find": store.action = .findEmployee; go(.assets)
        case "mail": store.action = .sendReport; go(.report)
        default: break
        }
    }

    /// На экране «Учёт» с открытой карточкой сотрудника. Другие страницы при этом листаются как обычно.
    private var cardOpen: Bool { store.lockPaging && tab == .assets }

    /// Размер текста внутри приложения: 0 — как в системе, дальше — мелкий, обычный, крупный, очень крупный.
    static func typeSizes(_ level: Int) -> ClosedRange<DynamicTypeSize> {
        let fixed: [DynamicTypeSize] = [.small, .large, .xLarge, .xxLarge]
        guard (1...4).contains(level) else { return .xSmall ... .accessibility5 }
        return fixed[level - 1] ... fixed[level - 1]
    }

    /// Кнопка из блокнота талисмана.
    private func act(_ item: MascotItem) {
        switch item {
        case .entry: store.action = .newEntry; go(.report)
        case .cart: store.action = .newCart; go(.carts)
        case .employee: store.action = .newEmployee; go(.assets)
        case .backup: sendBackup()
        case .theme: break                          // темы выбираются в лотке самого талисмана
        }
    }

    /// Бэкап из меню: самолётик улетает, по итогу — плашка и радость талисмана или понятная ошибка.
    private func sendBackup() {
        if !Motion.reduced {
            plane = true
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(.easeIn(duration: 0.9)) { planeGo = true }
                try? await Task.sleep(for: .seconds(1))
                plane = false
                planeGo = false
            }
        }
        Task {
            await store.backup(force: true)
            let s = store.backupStatus ?? ""
            guard s.hasPrefix("Бэкап отправлен") else {
                failure = s.isEmpty ? "Бэкап не отправлен." : s
                return
            }
            note = s
            celebrate = true
            try? await Task.sleep(for: .seconds(2))
            celebrate = false
        }
    }

    private var flyingPlane: some View {
        Image(systemName: "paperplane.fill")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(Brand.sky)
            .rotationEffect(.degrees(planeGo ? -35 : 0))
            .scaleEffect(planeGo ? 0.6 : 1)
            .offset(x: planeGo ? 40 : 0, y: planeGo ? -640 : 0)
            .opacity(planeGo ? 0 : 1)
            .padding(.trailing, 30)
            .padding(.bottom, 2 + GlassTabBar.height + 30)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func pageView<V: View>(_ t: AppTab, _ size: CGSize, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: size.width, height: size.height)
            .id(t)
    }
}

/// Номер фоновой задачи: его ждут и обработчик «время вышло», и конец отправки.
final class BackgroundTaskBox: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid
}

/// Тема для всего окна: 0 — как в системе, 1 — светлая, 2 — тёмная.
@MainActor
func applyTheme(_ t: Int) {
    // Лаванда всегда светлая, OLED и Матрица — тёмные, остальные — как выбрано: авто, светлая, тёмная
    let forced = Theme.current.scheme
    let style: UIUserInterfaceStyle = forced == .light ? .light : forced == .dark ? .dark
        : (t == 1 ? .light : (t == 2 ? .dark : .unspecified))
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        for w in scene.windows { w.overrideUserInterfaceStyle = style }
    }
}

// ── фирменные цвета ─────────────────────────────────────────────────────────
/// Цвета выбранной темы (Themes.swift). Экран перерисовывается при смене темы: RootView пересоздаёт страницы.
enum Brand {
    static var blue: Color { Theme.current.blue }
    static var sky: Color { Theme.current.sky }
    static var sun: Color { Theme.current.sun }
    static var gold: Color { Theme.current.gold }         // второй цвет, читаемый на светлом
    static var ink: Color { Theme.current.ink }           // тёмный текст и значки на sun
    static var gradient: LinearGradient {
        LinearGradient(colors: [sky, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// ── настройки ───────────────────────────────────────────────────────────────
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("theme") private var theme = 0
    @State private var botToken = ""
    @State private var chat = ""
    @State private var mail = MailSettings.load()
    @State private var appeared = false
    @State private var importing = false
    @State private var restoring: PendingRestore?
    @State private var error: String?
    @State private var templatesOpen = false
    @State private var unitsOpen = false
    @State private var trashOpen = false
    @State private var checklistOpen = false
    @State private var profileOpen = false
    @State private var positionsOpen = false
    @State private var importOpen = false
    @State private var auditOpen = false
    @AppStorage("font.size") private var fontSize = 0
    @AppStorage(Feel.hapticsKey) private var haptics = true
    @AppStorage(Feel.soundsKey) private var sounds = true
    @AppStorage(Weather.cityKey) private var city = ""
    @AppStorage("app.icon") private var appIcon = ""
    @State private var backupPassword = ""
    @State private var sealed: SealedFile?
    @State private var filePassword = ""
    @AppStorage(Reminder.onKey) private var reminder = false
    @AppStorage(Reminder.birthdaysKey) private var birthdaysOn = false
    @AppStorage(Reminder.warrantyKey) private var warrantyOn = false
    @AppStorage(AppLock.key) private var lockOn = false
    @AppStorage(AppLock.mailKey) private var recoveryMail = ""
    @AppStorage(AppLock.graceKey) private var grace = 300
    @AppStorage(Theme.key) private var palette = Theme.defaultID
    @AppStorage(Motion.key) private var lessMotion = false
    @State private var lockSetupOpen = false
    @State private var pinChangeOpen = false
    @State private var recoveryOpen = false
    @State private var encryptAfterRecovery = false     // «Шифровать бэкап» ждёт почту для восстановления

    /// Зашифрованный бэкап, к которому не подошёл сохранённый пароль: спрашиваем пароль.
    struct SealedFile: Identifiable {
        let id = UUID()
        let data: Data
        let name: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image("Logo").resizable().scaledToFit().frame(height: 110)
                            .scaleEffect(appeared ? 1 : 0.6).opacity(appeared ? 1 : 0)
                        Text("ITdesk").font(.title2.bold())
                        Text("Учёт техники · отчёт · картриджи").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    // пасхалка: пять касаний по логотипу открывают секретную тему «Матрица»
                    .onTapGesture(count: 5) {
                        UserDefaults.standard.set(true, forKey: Theme.matrixKey)
                        Theme.choose("matrix", from: nil)
                    }
                    .listRowBackground(Color.clear)
                    Button { profileOpen = true } label: {
                        Label("Профиль и достижения", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .tint(.primary)
                }
                Section {
                    // цвет темы: новая расходится кругом от пальца
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Theme.choices) { p in
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(LinearGradient(colors: [p.sky, p.blue], startPoint: .topLeading,
                                                             endPoint: .bottomTrailing))
                                        .frame(width: 38, height: 38)
                                        .overlay(Circle().stroke(.primary, lineWidth: palette == p.id ? 2.5 : 0).padding(-4))
                                        .padding(4)
                                    Text(p.name).font(.caption2).foregroundStyle(palette == p.id ? .primary : .secondary)
                                }
                                .onTapGesture(coordinateSpace: .global) { Theme.choose(p.id, from: $0) }
                                .accessibilityElement()
                                .accessibilityLabel("Тема «\(p.name)»")
                                .accessibilityAddTraits(palette == p.id ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { Theme.choose(p.id, from: nil) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    Picker("Тема", selection: $theme) {
                        Text("Авто").tag(0)
                        Text("Светлая").tag(1)
                        Text("Тёмная").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .disabled(Theme.current.scheme != nil)
                    Toggle(isOn: $lessMotion) { Label("Меньше анимаций", systemImage: "figure.walk.motion") }
                    Toggle(isOn: $haptics) { Label("Отклик", systemImage: "hand.tap") }
                    Toggle(isOn: $sounds) { Label("Звуки", systemImage: "speaker.wave.2") }
                    Picker(selection: $fontSize) {
                        Text("Как в iPhone").tag(0)
                        Text("Мелкий").tag(1)
                        Text("Обычный").tag(2)
                        Text("Крупный").tag(3)
                        Text("Очень крупный").tag(4)
                    } label: { Label("Размер текста", systemImage: "textformat.size") }
                    Picker(selection: Binding(get: { appIcon }, set: { setIcon($0) })) {
                        Text("Монитор с ключом").tag("")
                        Text("Индиго").tag("AppIcon-Indigo")
                        Text("Тёмный").tag("AppIcon-Dark")
                        Text("Робот").tag("AppIcon-Robot")
                    } label: { Label("Значок приложения", systemImage: "app.badge") }
                    LabeledField("Город для погоды", text: $city)
                } header: { Text("Оформление") } footer: {
                    if let forced = Theme.current.scheme {
                        Text("Тема «\(Theme.current.name)» всегда \(forced == .light ? "светлая" : "тёмная").")
                    } else {
                        Text("Талисман и меню из блокнота тоже меняют тему: значок палитры.")
                    }
                }
                Section {
                    Button { templatesOpen = true } label: {
                        LabeledContent {
                            Text("\(store.templates.count)").monospacedDigit()
                        } label: {
                            Label("Шаблоны заявок", systemImage: "text.badge.plus")
                        }
                    }
                    .tint(.primary)
                    Button { checklistOpen = true } label: {
                        LabeledContent {
                            Text("\(store.checklist.count)").monospacedDigit()
                        } label: {
                            Label("Чек-лист нового сотрудника", systemImage: "checklist")
                        }
                    }
                    .tint(.primary)
                    Toggle(isOn: $reminder) { Label("Напомнить в пятницу в 16:00", systemImage: "bell.badge") }
                } header: { Text("Отчёт") } footer: {
                    Text("Шаблон заполняет запись отчёта одним нажатием. Выдача картриджа сама добавляет в отчёт "
                         + "законченную заявку по шаблону «Картридж». Напоминание приходит, только если отчёт "
                         + "за неделю ещё не отправлен начальнику.")
                }
                Section {
                    Toggle(isOn: $birthdaysOn) { Label("Дни рождения — в 9:00", systemImage: "gift") }
                    Toggle(isOn: $warrantyOn) { Label("Конец гарантии — за месяц", systemImage: "shield.lefthalf.filled") }
                } header: { Text("Напоминания") } footer: {
                    Text("Дата рождения — в карточке сотрудника, срок гарантии — в карточке устройства.")
                }
                Section {
                    // включается только через настройку PIN-кода: переключатель встаёт, когда PIN-код задан
                    Toggle(isOn: Binding(get: { lockOn }, set: { on in
                        if on {
                            lockSetupOpen = true
                        } else {
                            AppLock.setPIN("")
                            lockOn = false
                        }
                    })) {
                        Label(AppLock.title, systemImage: "lock.shield")
                    }
                    .accessibilityIdentifier("lock.toggle")
                    if lockOn {
                        Picker(selection: $grace) {
                            Text("Сразу").tag(0)
                            Text("Через 1 минуту").tag(60)
                            Text("Через 5 минут").tag(300)
                            Text("Через 15 минут").tag(900)
                        } label: {
                            Label("Закрывать после сворачивания", systemImage: "timer")
                        }
                        Button { pinChangeOpen = true } label: {
                            Label("Сменить PIN-код", systemImage: "circle.grid.3x3.fill")
                        }
                        .tint(.primary)
                    }
                    Button { recoveryOpen = true } label: {
                        LabeledContent {
                            Text(recoveryMail.isEmpty ? "не указана" : AppLock.masked(recoveryMail))
                        } label: {
                            Label("Почта для восстановления", systemImage: "envelope.badge.shield.half.filled")
                        }
                    }
                    .tint(.primary)
                } header: { Text("Защита") } footer: {
                    Text("Свернули приложение дольше выбранного — при возвращении оно спросит Face ID или PIN-код. "
                         + "Забыли PIN-код — его сбросит ключ восстановления из письма; этот же ключ открывает "
                         + "зашифрованный бэкап, если забудете пароль.")
                }
                Section {
                    Button { unitsOpen = true } label: {
                        LabeledContent {
                            Text("\(store.state.units.count)").monospacedDigit()
                        } label: {
                            Label("Подразделения", systemImage: "building.2")
                        }
                    }
                    .tint(.primary)
                    Button { positionsOpen = true } label: {
                        LabeledContent {
                            Text("\(store.positions.count)").monospacedDigit()
                        } label: {
                            Label("Должности", systemImage: "person.text.rectangle")
                        }
                    }
                    .tint(.primary)
                    Button { importOpen = true } label: { Label("Импорт сотрудников из Excel", systemImage: "tablecells") }
                        .tint(.primary)
                    Button { auditOpen = true } label: { Label("Проверка данных", systemImage: "checklist") }
                        .tint(.primary)
                    Button { trashOpen = true } label: {
                        LabeledContent {
                            Text("\(store.state.trash.count)").monospacedDigit()
                        } label: {
                            Label("Корзина", systemImage: "trash")
                        }
                    }
                    .tint(.primary)
                    LabeledContent("Сотрудников") { Text("\(store.activeCount)").monospacedDigit() }
                    LabeledContent("Записей в отчёте") { Text("\(store.state.entries.count)").monospacedDigit() }
                    LabeledContent("Выдач картриджей") { Text("\(store.state.carts.count)").monospacedDigit() }
                } header: { Text("Данные") } footer: {
                    Text("Всё хранится только в этом телефоне и работает без интернета. Копия — бэкап в Telegram ниже. "
                         + "Удалённое лежит в корзине 30 дней.")
                }
                Section {
                    LabeledField("Филиал", text: $mail.branch)
                    LabeledField("Ответственный", text: $mail.responsible)
                    LabeledField("Кому (начальник)", text: $mail.recipient, mail: true)
                    LabeledField("От кого (ваша почта)", text: $mail.sender, mail: true)
                    LabeledContent("Пароль приложения") {
                        SecureField("16 латинских букв", text: $mail.password)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledField("SMTP-сервер", text: $mail.server, mail: true)
                    LabeledField("Порт", text: $mail.port)
                    if mail.missing.isEmpty {
                        Label("Почта настроена", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("Не заполнено: " + mail.missing.joined(separator: ", "), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange).font(.footnote)
                    }
                } header: { Text("Почта для отчёта") } footer: {
                    Text("Отчёт за неделю уходит письмом прямо с телефона — кнопка «Отправить начальнику». "
                         + "Для Gmail: сервер smtp.gmail.com, порт 465 и пароль приложения из настроек "
                         + "аккаунта Google. Пароль хранится в связке ключей iPhone.")
                }
                Section {
                    LabeledContent("Токен бота") {
                        SecureField("123456:ABC…", text: $botToken)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LabeledContent("ID группы") {
                        TextField("-1001234567890", text: $chat)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                    }
                    Picker(selection: Binding(get: { store.state.backupEvery }, set: { store.setBackupEvery($0) })) {
                        Text("Раз в неделю").tag("week")
                        Text("Каждый день").tag("day")
                        Text("После изменений").tag("change")
                    } label: {
                        Label("Как часто", systemImage: "calendar.badge.clock")
                    }
                    // шифрование — только с почтой для восстановления: забытый пароль бэкапа заменит ключ из письма
                    Toggle(isOn: Binding(get: { store.state.backupEncrypt }, set: { on in
                        if on && recoveryMail.isEmpty {
                            encryptAfterRecovery = true
                            recoveryOpen = true
                        } else {
                            store.setBackupEncrypt(on)
                        }
                    })) {
                        Label("Шифровать бэкап", systemImage: "lock.fill")
                    }
                    if store.state.backupEncrypt {
                        LabeledContent("Пароль бэкапа") {
                            SecureField("не короче 8 знаков", text: $backupPassword)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        if recoveryMail.isEmpty {
                            // шифрование включили в 5.1, до почты для восстановления
                            Button { recoveryOpen = true } label: {
                                Label("Укажите почту для восстановления — иначе забытый пароль бэкапа не заменить",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                        }
                    }
                    LabeledContent("Последний бэкап") {
                        Text(store.state.lastBackup.map { Dates.stamp.string(from: $0) } ?? "не было")
                    }
                    if !store.state.checkResult.isEmpty {
                        Label(store.state.checkResult,
                              systemImage: store.state.checkOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(store.state.checkOK ? Color.green : Color.orange)
                    }
                    Button {
                        hideKeyboard()
                        store.setBackup(token: botToken, chat: chat)
                        Keychain.set(BackupCrypto.passwordKey, backupPassword)
                        Task { await store.backup(force: true) }
                    } label: {
                        HStack {
                            Label("Отправить бэкап сейчас", systemImage: "paperplane.fill")
                            Spacer()
                            if store.backingUp { ProgressView() }
                        }
                    }
                    .disabled(store.backingUp)
                    Button {
                        hideKeyboard()
                        Task { await store.verifyBackup(force: true) }
                    } label: {
                        HStack {
                            Label("Проверить бэкап сейчас", systemImage: "checkmark.shield")
                            Spacer()
                            if store.checking { ProgressView() }
                        }
                    }
                    .disabled(store.checking || store.backingUp)
                    Button { importing = true } label: {
                        Label("Восстановить из бэкапа", systemImage: "arrow.counterclockwise.circle.fill")
                    }
                    if let s = store.backupStatus {
                        Text(s).font(.footnote).foregroundStyle(.secondary).transition(.opacity)
                    }
                } header: { Text("Бэкап в Telegram") } footer: {
                    Text("Бот присылает в группу два файла: Excel — чтобы читать, JSON — чтобы восстановить. "
                         + "С шифрованием — один файл .reporter: открыть его можно паролем бэкапа или ключом "
                         + "восстановления из письма, пароль хранится в связке ключей iPhone. "
                         + "Раз в месяц приложение само скачивает последний бэкап "
                         + "и проверяет, что он читается. Чтобы узнать ID группы, добавьте бота в группу и напишите в ней "
                         + "/start@имя_вашего_бота. Для восстановления сохраните файл из Telegram в «Файлы».")
                }
            }
            .scrollContentBackground(.hidden)
            .clearsBar(add: true)
            .keyboardDone()
            .navigationTitle("Настройки")
            .onAppear {
                botToken = store.state.backupToken
                chat = store.state.backupChat
                backupPassword = Keychain.get(BackupCrypto.passwordKey)
                withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) { appeared = true }
            }
            .task(id: backupPassword) {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                if backupPassword != Keychain.get(BackupCrypto.passwordKey) {
                    Keychain.set(BackupCrypto.passwordKey, backupPassword)
                }
            }
            // сохраняем через полсекунды после последней буквы, а не на каждую: запись токена — это весь
            // файл данных на диск, запись почты — пароль в связке ключей
            .task(id: botToken + "\n" + chat) {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                store.setBackup(token: botToken, chat: chat)
            }
            .task(id: mail) {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                if mail != MailSettings.load() { mail.save() }
            }
            .onChange(of: reminder) { _, on in allowNotifications(on) { reminder = false } }
            .onChange(of: birthdaysOn) { _, on in allowNotifications(on) { birthdaysOn = false } }
            .onChange(of: warrantyOn) { _, on in allowNotifications(on) { warrantyOn = false } }
            .animation(.snappy, value: mail.missing)
            .animation(.snappy, value: store.backupStatus)
            .animation(.snappy, value: store.state.backupEncrypt)
            .feel(.success, trigger: store.state.lastBackup)
            // .data — и зашифрованный бэкап .reporter, и JSON
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        if BackupCrypto.isEncrypted(data) {
                            let name = url.lastPathComponent
                            let mine = [Keychain.get(BackupCrypto.passwordKey), Keychain.get(RecoveryKey.keychain)]
                            Task {
                                // свои пароль или ключ подошли — сразу к восстановлению, иначе спрашиваем.
                                // PBKDF2 на каждый замок — не в главном потоке, экран не замирает
                                if let plain = try? await Task.detached(operation: {
                                    try BackupCrypto.decrypt(data, secrets: mine)
                                }).value {
                                    do {
                                        restoring = PendingRestore(file: try BackupFile.read(plain), name: name)
                                    } catch { self.error = error.localizedDescription }
                                } else {
                                    filePassword = ""
                                    sealed = SealedFile(data: data, name: name)
                                }
                            }
                        } else {
                            restoring = PendingRestore(file: try BackupFile.read(data), name: url.lastPathComponent)
                        }
                    } catch {
                        self.error = error.localizedDescription
                    }
                case .failure(let e):
                    error = e.localizedDescription
                }
            }
            .alert("Пароль бэкапа", isPresented: Binding(get: { sealed != nil }, set: { if !$0 { sealed = nil } }),
                   presenting: sealed) { f in
                SecureField("Пароль или ключ", text: $filePassword)
                Button("Открыть") { openSealed(f) }
                Button("Отмена", role: .cancel) {}
            } message: { _ in
                Text("Файл зашифрован. Введите пароль бэкапа — или ключ восстановления из письма, если пароль забыли.")
            }
            .sheet(isPresented: $lockSetupOpen) {
                LockSetup { pin in
                    AppLock.setPIN(pin)
                    lockOn = true
                }
            }
            .sheet(isPresented: $pinChangeOpen) {
                NavigationStack {
                    NewPin(title: "Новый PIN-код") { pin in
                        AppLock.setPIN(pin)
                        pinChangeOpen = false
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Сменить PIN-код")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { pinChangeOpen = false } }
                    }
                }
                .presentationCornerRadius(24)
            }
            .sheet(isPresented: $recoveryOpen, onDismiss: { encryptAfterRecovery = false }) {
                NavigationStack {
                    RecoverySetup {
                        if encryptAfterRecovery { store.setBackupEncrypt(true) }
                        recoveryOpen = false
                    }
                    .navigationTitle("Почта для восстановления")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { recoveryOpen = false } }
                    }
                }
                .presentationCornerRadius(24)
            }
            .sheet(isPresented: $trashOpen) {
                NavigationStack {
                    TrashView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { trashOpen = false } }
                        }
                }
                .presentationCornerRadius(24)
            }
            .sheet(isPresented: $checklistOpen) {
                NavigationStack {
                    ChecklistView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { checklistOpen = false } }
                        }
                }
                .presentationCornerRadius(24)
            }
            .sheet(item: $restoring) { r in
                RestoreSheet(pending: r)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(24)
            }
            // шаблоны — отдельным листом: внутри ленты страниц свайп «назад» листал бы страницы
            .sheet(isPresented: $templatesOpen) {
                NavigationStack {
                    TemplatesView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { templatesOpen = false } }
                        }
                }
                .presentationCornerRadius(24)
            }
            .sheet(isPresented: $profileOpen) { ProfileView().presentationCornerRadius(24) }
            .sheet(isPresented: $positionsOpen) {
                NavigationStack {
                    PositionsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { positionsOpen = false } }
                        }
                }
                .presentationCornerRadius(24)
            }
            .sheet(isPresented: $importOpen) { ImportView().presentationCornerRadius(24) }
            .sheet(isPresented: $auditOpen) { AuditView(tab: .constant(.settings)).presentationCornerRadius(24) }
            .task(id: city) {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await Weather.shared.load()      // город сменили — загрузится заново
            }
            .sheet(isPresented: $unitsOpen) {
                NavigationStack {
                    UnitsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { unitsOpen = false } }
                        }
                }
                .presentationCornerRadius(24)
            }
        }
        // ошибки — снаружи стека, окно пароля бэкапа — внутри: два окна на одном виде SwiftUI показывает не всегда
        .errorAlert($error)
    }

    /// Включили напоминание — спрашиваем разрешение на уведомления; запретили — выключаем обратно.
    private func allowNotifications(_ on: Bool, revert: @escaping () -> Void) {
        Task {
            if on, !(await Reminder.allow()) {
                revert()
                error = "Уведомления для ITdesk запрещены. Разрешите их в настройках iPhone: «Уведомления» → ITdesk."
            }
            Reminder.refresh()
        }
    }

    /// Другой значок приложения; iOS сама покажет, что значок сменился.
    private func setIcon(_ name: String) {
        UIApplication.shared.setAlternateIconName(name.isEmpty ? nil : name) { e in
            Task { @MainActor in
                if let e { error = "Значок не сменился: " + e.localizedDescription } else { appIcon = name }
            }
        }
    }

    private func openSealed(_ f: SealedFile) {
        let typed = filePassword, data = f.data
        filePassword = ""
        Task {
            // окно пароля успевает закрыться: лист или ошибка поверх закрывающегося окна не показываются
            try? await Task.sleep(for: .milliseconds(450))
            do {
                let plain = try await Task.detached { try BackupCrypto.decrypt(data, secrets: [typed]) }.value
                restoring = PendingRestore(file: try BackupFile.read(plain), name: f.name)
                // подошёл пароль (не ключ из письма), а своего в телефоне нет (новый iPhone) — запоминаем его
                if Keychain.get(BackupCrypto.passwordKey).isEmpty && !RecoveryKey.looksLike(typed) {
                    Keychain.set(BackupCrypto.passwordKey, typed)
                    backupPassword = typed
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct PendingRestore: Identifiable {
    let id = UUID()
    let file: BackupFile
    let name: String
}

/// Что в файле бэкапа и подтверждение замены.
struct RestoreSheet: View {
    let pending: PendingRestore
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var done = false

    var body: some View {
        VStack(spacing: 16) {
            if done {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: done)
                    .transition(.scale.combined(with: .opacity))
                Text("Данные восстановлены").font(.title3.bold())
                Text(pending.file.stats).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("Восстановить из бэкапа?").font(.title3.bold()).padding(.top, 8)
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.fill").font(.title).foregroundStyle(Brand.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text("от " + (pending.file.exported_at ?? "неизвестной даты")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 10) {
                    StatCard(title: "сотрудников", value: pending.file.employees.count, icon: "person.2.fill", color: Brand.blue)
                    StatCard(title: "записей", value: pending.file.entries.count, icon: "list.bullet.clipboard", color: .teal)
                    StatCard(title: "выдач", value: pending.file.cartridges.count, icon: "printer.fill", color: .orange)
                }
                Label("Всё, что сейчас в телефоне, заменится данными из этого файла.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Button {
                    store.restore(pending.file)
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { done = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        dismiss()
                    }
                } label: {
                    Text("Восстановить").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Button("Отмена", role: .cancel) { dismiss() }
            }
        }
        .padding(20)
        .feel(.success, trigger: done)
    }
}

// ── общие детали интерфейса ─────────────────────────────────────────────────
struct ErrorBanner: ViewModifier {
    @Binding var error: String?

    func body(content: Content) -> some View {
        content.alert("Не получилось", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .feel(.error, trigger: error) { _, new in new != nil }
    }
}

/// Плашка «Сохранено» сверху: выезжает, сама исчезает, телефон отвечает вибрацией.
/// На плашке «Удалено» — кнопка «Вернуть», и висит она дольше.
struct Toast: ViewModifier {
    static let deleted = "Удалено"

    @EnvironmentObject private var store: Store
    @Binding var text: String?
    /// Что сделать по «Вернуть»; nil — кнопки нет.
    var undo: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let text {
                    let undoable = undo != nil && text == Toast.deleted
                    HStack(spacing: 12) {
                        Label(text, systemImage: text == Toast.deleted ? "trash.fill" : "checkmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                            .symbolEffect(.bounce, value: text)
                        if undoable {
                            // жёлтая кнопка: синий текст на синей карточке недели не читался
                            Button { undo?() } label: {
                                Text("Вернуть").fontWeight(.bold)
                                    .foregroundStyle(Brand.ink)
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .background(Brand.sun, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // с кнопкой — жёсткая ширина: деля место между двумя короткими надписями, стопка
                    // обрезала «Удалено» до «Удал…»
                    .fixedSize(horizontal: undoable, vertical: false)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    // в одну строку получается капсула, в две (выдача картриджа) — скруглённая плашка
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // новое удаление при висящей плашке «Удалено» — время на «Вернуть» идёт заново
                    .task(id: "\(store.deletions) \(text)") {
                        // текст сменился — задача отменена, и новую плашку она гасить не должна
                        do { try await Task.sleep(for: .seconds(undoable ? 6 : 1.8)) } catch { return }
                        withAnimation(.snappy) { self.text = nil }
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: text)
            .feel(.success, trigger: text) { _, new in new != nil }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// Клавиатура прячется кнопкой «Готово» над ней или прокруткой вниз.
    func keyboardDone() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { hideKeyboard() } label: {
                        Label("Готово", systemImage: "keyboard.chevron.compact.down").labelStyle(.titleAndIcon).bold()
                    }
                }
            }
    }

    func errorAlert(_ error: Binding<String?>) -> some View { modifier(ErrorBanner(error: error)) }
    func toast(_ text: Binding<String?>, undo: (() -> Void)? = nil) -> some View {
        modifier(Toast(text: text, undo: undo))
    }

    /// Низ прокрутки — выше плавающей панели, а с add — и выше «+». Ставится на сам список внутри
    /// NavigationStack: отступ снаружи стека до списка не доходил, и последние строки уходили под панель.
    func clearsBar(add: Bool = false) -> some View {
        safeAreaPadding(.bottom, GlassTabBar.height + 8 + (add ? 72 : 0))
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// Цифра с подписью на цветной плашке; число перелистывается при изменении.
struct StatCard: View {
    let title: String
    let value: Int
    let icon: String
    let color: Color
    @State private var bump = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // значки разной высоты — без общей высоты карточки в ряду стояли лесенкой
            Image(systemName: icon).font(.headline).foregroundStyle(color).frame(height: 22)
            Text("\(value)")
                .font(.title2.bold().monospacedDigit())
                .contentTransition(.numericText(value: Double(value)))
                .scaleEffect(bump ? 1.18 : 1, anchor: .leading)
                .onChange(of: value) {
                    guard !Motion.reduced else { return }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { bump = true }
                    Task {
                        try? await Task.sleep(for: .milliseconds(220))
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bump = false }
                    }
                }
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Пустой результат поиска. Системная надпись по-русски («Нет результатов по запросу …») в строку
/// не помещается и обрезается — пишем свою, короткую.
struct NothingFound: View {
    var body: some View {
        EmptyState("Ничего не найдено", systemImage: "magnifyingglass",
                               description: Text("Проверьте написание или измените запрос."))
    }
}

/// Подсказки под полем ввода: кто подходит под набранные слова (по началам слов).
struct Suggestions: View {
    let text: String
    let options: [String]
    let pick: (String) -> Void

    var body: some View {
        ForEach(matches, id: \.self) { s in
            Button { withAnimation(.snappy) { pick(s) } } label: {
                HStack(spacing: 10) {
                    Avatar(name: s).scaleEffect(0.75).frame(width: 30, height: 30)
                    Text(s).font(.callout).foregroundStyle(.primary)
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var matches: [String] {
        let tokens = text.lowercased().split(separator: " ")
        guard !tokens.isEmpty, !options.contains(text) else { return [] }
        return Array(options.lazy.filter { o in
            let words = o.lowercased().split(separator: " ")
            return tokens.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }.prefix(5))
    }
}

/// Подпись слева, поле справа.
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var mail = false

    init(_ label: String, text: Binding<String>, mail: Bool = false) {
        self.label = label
        _text = text
        self.mail = mail
    }

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(mail ? .emailAddress : .default)
                .textInputAutocapitalization(mail ? .never : .sentences)
                .autocorrectionDisabled(mail)
        }
    }
}

/// Привязка к строковому полю словаря.
func textBinding(_ dict: Binding<Dict>, _ key: String) -> Binding<String> {
    Binding(get: { dict.wrappedValue[key]?.string ?? "" },
            set: { dict.wrappedValue[key] = .string($0) })
}

/// Выбор из списка; значение не из списка тоже показывается.
struct ChoicePicker: View {
    let label: String
    let values: [String]
    @Binding var selection: String

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(values.contains(selection) ? values : [selection] + values, id: \.self) {
                Text($0.isEmpty ? "—" : $0).tag($0)
            }
        }
    }
}
