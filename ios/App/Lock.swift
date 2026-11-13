import LocalAuthentication
import SwiftUI

// ── вход: Face ID и PIN-код ─────────────────────────────────────────────────
/// Что где лежит: включён ли вход и почта для восстановления — в настройках (UserDefaults); PIN-код (соль и хеш)
/// и ключ восстановления — в связке ключей. Ключ приходит письмом и открывает ещё и зашифрованный бэкап.
enum AppLock {
    static let key = "lock.on"
    static let mailKey = "lock.mail"
    static let pinLength = 4
    private static let pinKey = "lock.pin"
    private static let failsKey = "lock.fails"
    private static let maxFails = 5

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
    static var hasPIN: Bool { !Keychain.get(pinKey).isEmpty }
    static var mail: String { UserDefaults.standard.string(forKey: mailKey) ?? "" }
    static var hasRecovery: Bool { !mail.isEmpty && !Keychain.get(RecoveryKey.keychain).isEmpty }

    /// «Face ID» или «Touch ID» — что есть у этого iPhone; nil — ничего (вход только по PIN-коду).
    static let biometry: String? = {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }()

    static var title: String { biometry.map { "Вход по \($0) и PIN-коду" } ?? "Вход по PIN-коду" }

    /// «a•••@gmail.com»: на экране входа адрес виден не целиком.
    static func masked(_ mail: String) -> String {
        let p = mail.split(separator: "@", maxSplits: 1)
        guard p.count == 2, let first = p[0].first else { return mail }
        return "\(first)•••@\(p[1])"
    }

    // ── PIN-код ──
    /// Пустой — PIN-кода больше нет (вход выключили).
    static func setPIN(_ pin: String) {
        Keychain.set(pinKey, pin.isEmpty ? "" : PinCode.seal(pin))
        clearFails()
    }

    static func clearFails() { UserDefaults.standard.removeObject(forKey: failsKey) }

    enum Check { case ok, wrong(left: Int), blocked }

    /// Пять неверных подряд — PIN-код не принимается, пока не войдут по Face ID или ключом из письма.
    static func check(_ pin: String) -> Check {
        let fails = UserDefaults.standard.integer(forKey: failsKey)
        guard fails < maxFails else { return .blocked }
        if PinCode.matches(pin, Keychain.get(pinKey)) {
            clearFails()
            return .ok
        }
        UserDefaults.standard.set(fails + 1, forKey: failsKey)
        return fails + 1 < maxFails ? .wrong(left: maxFails - fails - 1) : .blocked
    }

    static var blockedText: String {
        "PIN-код заблокирован после \(maxFails) неверных попыток. Войдите " + (biometry.map { "по \($0) или " } ?? "")
            + "через «Забыли PIN-код?»."
    }

    // ── ключ восстановления ──
    static func keyMatches(_ typed: String) -> Bool {
        let k = Keychain.get(RecoveryKey.keychain)
        return !k.isEmpty && RecoveryKey.normalize(typed) == k
    }

    static func saveRecovery(mail: String, key: String) {
        UserDefaults.standard.set(mail, forKey: mailKey)
        Keychain.set(RecoveryKey.keychain, RecoveryKey.normalize(key))
    }

    static func newKey() -> String {
        #if DEBUG
        if let k = testKey { return k }
        #endif
        return RecoveryKey.make()
    }

    /// Письмо с ключом уходит с почты для отчёта (SMTP из настроек): своего сервера у приложения нет.
    static func send(key: String, to address: String) async throws {
        let to = address.trimmed
        guard to.contains("@"), !to.contains(" ") else { throw APIError(message: "Проверьте адрес почты.") }
        #if DEBUG
        if testKey != nil {
            try await Task.sleep(for: .milliseconds(400))
            return
        }
        #endif
        let s = MailSettings.load()
        let missing = s.missing.filter { $0 != "получатель" }      // «кому» — это начальник, ключ уходит не ему
        guard missing.isEmpty else {
            throw APIError(message: "Ключ уходит письмом с вашей почты из раздела «Почта для отчёта». "
                           + "Там не заполнено: " + missing.joined(separator: ", ") + ".")
        }
        try await SMTP.send(host: s.server.trimmed, port: Int(s.port.trimmed) ?? 465, user: s.sender.trimmed,
                            password: s.password, from: s.sender.trimmed, to: to,
                            message: KeyMail.message(from: s.sender.trimmed, to: to, key: key))
    }

    #if DEBUG
    /// Проход по интерфейсу (UITests): ключ задаёт тест, письмо не уходит — почты в симуляторе нет.
    /// В IPA (сборка Release) этого нет.
    private static var testKey: String? { ProcessInfo.processInfo.environment["REPORTER_TEST_KEY"] }
    #endif

    // ── Face ID ──
    /// Face ID настроен и не заблокирован — можно спросить сразу при открытии.
    static var canFaceID: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }

    enum FaceIDResult { case ok, pin, cancel, failed(String) }

    /// Только Face ID, без кода-пароля iPhone: запасной вход — свой PIN-код (кнопка «Ввести PIN-код» в окне Face ID).
    static func faceID() async -> FaceIDResult {
        let c = LAContext()
        c.localizedFallbackTitle = "Ввести PIN-код"
        let name = biometry ?? "Face ID"
        do {
            let ok = try await c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Вход в REPORTER")
            return ok ? .ok : .failed("iPhone не подтвердил, что это вы.")
        } catch let e as LAError {
            switch e.code {
            case .userFallback: return .pin
            case .userCancel, .appCancel, .systemCancel: return .cancel
            case .biometryNotEnrolled, .biometryNotAvailable:
                return .failed("\(name) на этом iPhone не настроен — войдите по PIN-коду.")
            case .biometryLockout: return .failed("\(name) заблокирован после неудачных попыток — войдите по PIN-коду.")
            default: return .failed(e.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Экран входа — в своём окне над всем приложением: и над открытыми листами (карточка, корзина, форма записи).
/// Наложение внутри главного окна их не закрывало — данные было видно без входа.
@MainActor
final class LockScreen: ObservableObject {
    static let shared = LockScreen()

    enum Step { case start, pin, forgot, newPin }

    @Published var step = Step.start
    @Published var message = ""
    /// Приложение не на экране (переключатель приложений, окно Face ID): только значок и название, без кнопок.
    @Published private(set) var cover = false
    /// С входом приложение стартует закрытым.
    private(set) var locked: Bool
    private var asked = false               // Face ID после закрытия уже спрашивали — сам второй раз не спрашивает
    private var asking = false
    private var window: UIWindow?

    private init() {
        // вход 5.1 был без PIN-кода — без него экран входа не открыть: включают заново, с PIN-кодом и почтой
        if AppLock.isOn && !AppLock.hasPIN { UserDefaults.standard.set(false, forKey: AppLock.key) }
        locked = AppLock.isOn
    }

    /// Запуск приложения: окно входа встаёт раньше первого кадра — данные не мелькают.
    func start(in scene: UIWindowScene) {
        if locked { show(scene) }
    }

    /// Ушли в фон — закрыть; вернулись — экран входа, и один раз сами спрашиваем Face ID.
    func scene(_ phase: ScenePhase) {
        guard AppLock.isOn else {
            locked = false
            hide()
            return
        }
        if phase == .background {
            locked = true
            asked = false
            step = .start
            message = ""
            hideKeyboard()        // клавиатура живёт в своём окне выше входа — не оставляем её над ним
        }
        cover = phase != .active
        if locked || cover { show() } else { hide() }
        guard phase == .active, locked else { return }
        window?.makeKey()         // поле ключа на экране входа получает клавиатуру
        if !asked, AppLock.canFaceID {
            asked = true
            Task { await faceID() }
        }
    }

    func faceID() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        switch await AppLock.faceID() {
        case .ok: open()
        case .pin:
            step = .pin
            message = ""
        case .cancel: break
        case .failed(let why): message = why
        }
    }

    func enter(_ pin: String) {
        switch AppLock.check(pin) {
        case .ok: open()
        case .wrong(let left): message = "Неверный PIN-код. Осталось попыток: \(left)"
        case .blocked: message = AppLock.blockedText
        }
    }

    /// Ключ из письма подошёл, новый PIN-код набран дважды — входим.
    func setPIN(_ pin: String) {
        AppLock.setPIN(pin)
        open()
    }

    /// Шаг и подсказку не сбрасываем: окно ещё гаснет, и экран мелькнул бы кнопками. Сброс — при уходе в фон.
    private func open() {
        AppLock.clearFails()
        locked = false
        hide()
    }

    private func show(_ scene: UIWindowScene? = nil) {
        guard window == nil,
              let scene = scene ?? UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let theme = UserDefaults.standard.integer(forKey: "theme")       // как applyTheme
        w.overrideUserInterfaceStyle = theme == 1 ? .light : (theme == 2 ? .dark : .unspecified)
        w.rootViewController = UIHostingController(rootView: LockView())
        w.makeKeyAndVisible()
        window = w
    }

    private func hide() {
        guard let w = window else { return }
        window = nil
        // ввод — снова в главное окно приложения
        w.windowScene?.windows.first(where: { $0 !== w && $0.windowLevel == .normal })?.makeKey()
        UIView.animate(withDuration: 0.2, animations: { w.alpha = 0 }, completion: { _ in w.isHidden = true })
    }
}

/// Экран входа. Пока приложение не на экране — только значок и название.
struct LockView: View {
    @ObservedObject private var lock = LockScreen.shared
    @State private var key = ""
    @State private var sending = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 14) {
                Image("Logo").resizable().scaledToFit().frame(height: digits ? 56 : 96)
                Text("REPORTER").font(digits ? .headline : .title2.bold())
                if !lock.cover {
                    content
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
        }
        .tint(Brand.blue)
        .animation(.snappy, value: lock.step)
        .animation(.easeOut(duration: 0.15), value: lock.cover)
    }

    /// На шагах с цифрами значок меньше — цифрам нужно место.
    private var digits: Bool { !lock.cover && (lock.step == .pin || lock.step == .newPin) }

    @ViewBuilder private var content: some View {
        switch lock.step {
        case .start: start
        case .pin:
            PinPad(title: "Введите PIN-код", message: lock.message, faceID: AppLock.biometry,
                   onFaceID: { Task { await lock.faceID() } }) { lock.enter($0) }
            forgotButton
        case .forgot: forgot
        case .newPin: NewPin(title: "Придумайте новый PIN-код") { lock.setPIN($0) }
        }
    }

    private var start: some View {
        VStack(spacing: 12) {
            if let name = AppLock.biometry {
                Button { Task { await lock.faceID() } } label: {
                    Label("Войти по \(name)", systemImage: name == "Touch ID" ? "touchid" : "faceid")
                        .font(.headline).frame(maxWidth: 260).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                lock.message = ""
                lock.step = .pin
            } label: {
                Text("Ввести PIN-код").font(.headline).frame(maxWidth: 260).padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            forgotButton
            note
        }
    }

    private var forgotButton: some View {
        Button("Забыли PIN-код?") {
            lock.message = ""
            lock.step = .forgot
        }
        .font(.subheadline)
        .padding(.top, 4)
    }

    private var forgot: some View {
        VStack(spacing: 12) {
            Text("Восстановление PIN-кода").font(.headline)
            Text(AppLock.mail.isEmpty
                 ? "Почта для восстановления не указана — войдите по Face ID и задайте новый PIN-код в настройках."
                 : "Введите ключ из письма «\(KeyMail.subject)» — оно приходило на \(AppLock.masked(AppLock.mail)).")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Ключ из письма", text: $key)
                .font(.title3.monospaced())
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(checkKey)
                .padding(12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Button(action: checkKey) {
                Text("Продолжить").font(.headline).frame(maxWidth: 260).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(key.trimmed.isEmpty)
            Button { Task { await resend() } } label: {
                if sending { ProgressView() } else { Text("Отправить письмо ещё раз") }
            }
            .font(.subheadline)
            .disabled(sending || AppLock.mail.isEmpty)
            Button("Назад") {
                key = ""
                lock.message = ""
                lock.step = .start
            }
            .font(.subheadline)
            note
        }
    }

    @ViewBuilder private var note: some View {
        if !lock.message.isEmpty {
            Text(lock.message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
        }
    }

    private func checkKey() {
        guard AppLock.keyMatches(key) else {
            lock.message = "Ключ не подходит. Он в письме — 12 знаков, например K7QF-29XM-3PLD."
            return
        }
        hideKeyboard()
        key = ""
        lock.message = ""
        lock.step = .newPin
    }

    private func resend() async {
        hideKeyboard()
        sending = true
        defer { sending = false }
        do {
            try await AppLock.send(key: Keychain.get(RecoveryKey.keychain), to: AppLock.mail)
            lock.message = "Письмо с ключом отправлено на \(AppLock.masked(AppLock.mail))."
        } catch {
            lock.message = error.localizedDescription
        }
    }
}

/// Точки и цифры, как на экране блокировки iPhone: набрали последнюю цифру — сразу проверка.
struct PinPad: View {
    let title: String
    var message = ""
    /// «Face ID» — кнопка слева от нуля.
    var faceID: String? = nil
    var onFaceID: () -> Void = {}
    let done: (String) -> Void

    @State private var pin = ""
    private static let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            HStack(spacing: 18) {
                ForEach(0..<AppLock.pinLength, id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Color.primary : Color.clear)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("PIN-код")
            .accessibilityValue("\(pin.count) из \(AppLock.pinLength)")
            .accessibilityIdentifier("pin.dots")
            Text(message)
                .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                .frame(minHeight: 36, alignment: .top)
            Grid(horizontalSpacing: 24, verticalSpacing: 14) {
                ForEach(Self.rows, id: \.self) { row in
                    GridRow { ForEach(row, id: \.self) { digit($0) } }
                }
                GridRow {
                    if let faceID {
                        icon(faceID == "Touch ID" ? "touchid" : "faceid", "Войти по \(faceID)", action: onFaceID)
                    } else {
                        Color.clear.frame(width: 76, height: 76)
                    }
                    digit("0")
                    icon("delete.left", "Стереть") { if !pin.isEmpty { pin.removeLast() } }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: pin.count)
        .sensoryFeedback(.error, trigger: message) { _, new in !new.isEmpty }
    }

    private func digit(_ d: String) -> some View {
        Button {
            guard pin.count < AppLock.pinLength else { return }
            pin += d
            guard pin.count == AppLock.pinLength else { return }
            let full = pin
            Task {
                try? await Task.sleep(for: .milliseconds(150))      // последняя точка успевает закраситься
                pin = ""
                done(full)
            }
        } label: {
            Text(d)
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .frame(width: 76, height: 76)
                .glassEffect(.regular, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pin.\(d)")
    }

    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title2).frame(width: 76, height: 76).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Новый PIN-код: дважды; не совпали — сначала.
struct NewPin: View {
    var title = "Придумайте PIN-код"
    let done: (String) -> Void
    @State private var first = ""
    @State private var message = ""

    var body: some View {
        PinPad(title: first.isEmpty ? title : "Повторите PIN-код", message: message) { p in
            if first.isEmpty {
                first = p
                message = ""
            } else if p == first {
                done(p)
            } else {
                first = ""
                message = "PIN-коды не совпали — наберите ещё раз"
            }
        }
    }
}

/// Включение входа: PIN-код дважды, затем почта для восстановления — если её ещё нет.
struct LockSetup: View {
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Group {
                if pin.isEmpty {
                    NewPin { p in
                        if AppLock.hasRecovery { finish(p) } else { pin = p }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RecoverySetup { finish(pin) }
                }
            }
            .navigationTitle(pin.isEmpty ? AppLock.title : "Почта для восстановления")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
        .presentationCornerRadius(24)
    }

    private func finish(_ p: String) {
        done(p)
        dismiss()
    }
}

/// Почта для восстановления: на неё уходит ключ; набрать его обратно — значит, письмо дошло и адрес верный.
struct RecoverySetup: View {
    let done: () -> Void
    @State private var mail = AppLock.mail.isEmpty ? MailSettings.load().sender : AppLock.mail
    @State private var sent = ""            // отправленный ключ — ждём его обратно из письма
    @State private var typed = ""
    @State private var sending = false
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                LabeledField("Почта", text: $mail, mail: true)
                Button { Task { await send() } } label: {
                    HStack {
                        Label(sent.isEmpty ? "Отправить ключ" : "Отправить ещё раз", systemImage: "paperplane.fill")
                        Spacer()
                        if sending { ProgressView() }
                    }
                }
                .disabled(sending || !mail.contains("@"))
            } footer: {
                Text("На эту почту придёт ключ восстановления: он сбрасывает забытый PIN-код и открывает зашифрованный "
                     + "бэкап, если забудете пароль. Письмо уходит с вашей почты из раздела «Почта для отчёта».")
            }
            if !sent.isEmpty {
                Section {
                    TextField("Ключ из письма", text: $typed)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button { confirm() } label: { Label("Подтвердить ключ", systemImage: "checkmark.shield.fill") }
                        .disabled(typed.trimmed.isEmpty)
                } header: { Text("Ключ из письма") } footer: {
                    Text("Письмо «\(KeyMail.subject)» отправлено на \(mail.trimmed). Скопируйте ключ из него сюда — "
                         + "так видно, что письмо дошло. Само письмо сохраните.")
                }
            }
            if !message.isEmpty {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .keyboardDone()
        .animation(.snappy, value: sent)
        .animation(.snappy, value: message)
        .onChange(of: mail) {
            // адрес поменяли после отправки — ключ ушёл на старый, ждать его по новому нельзя
            sent = ""
            typed = ""
        }
    }

    private func send() async {
        hideKeyboard()
        sending = true
        defer { sending = false }
        let key = AppLock.newKey()
        do {
            try await AppLock.send(key: key, to: mail)
            sent = key
            typed = ""
            message = ""
        } catch {
            message = error.localizedDescription
        }
    }

    private func confirm() {
        guard RecoveryKey.normalize(typed) == RecoveryKey.normalize(sent) else {
            message = "Ключ не совпадает с отправленным. Скопируйте его из последнего письма."
            return
        }
        AppLock.saveRecovery(mail: mail.trimmed, key: sent)
        done()
    }
}
