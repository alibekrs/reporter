import XCTest

/// Проход по приложению в симуляторе iPhone: кнопки нажимаются по-настоящему, каждый экран — скриншот.
/// Скриншоты пишутся на Mac (~/Library/Caches/reporter-screens), CI выкладывает их артефактом.
final class TourTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true          // одна ошибка не обрывает проход — нужны все скриншоты
    }

    /// Тёмная тема, как на телефоне: заставка, вкладки, «+» на каждой странице, заведение данных,
    /// свайпы между страницами, быстрые кнопки главной, клавиатура, настройки.
    @MainActor func test1Dark() { Tour(self, "dark").full() }

    /// Светлая тема: все страницы с уже заведёнными данными.
    @MainActor func test2Light() { Tour(self, "light").light() }
}

@MainActor
final class Tour {
    private let test: XCTestCase
    private let name: String
    private let app = XCUIApplication()
    private var count = 0

    private static let dir: URL = {
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSTemporaryDirectory()
        let d = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/reporter-screens")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let tabs = ["Главная", "Учёт", "Отчёт", "Картриджи", "Настройки"]
    // вход (security): ключ «из письма» задаёт тест — письмо в симуляторе не уходит
    private static let testKey = "ABCD-EFGH-JKLM"
    private static let typedKey = "abcd efgh jklm"         // как набрал бы человек: строчными, с пробелами
    private static let firstPIN = "1234"
    private static let pin = "2580"                         // после «Забыли PIN-код?»
    private static let withAdd: Set = ["Учёт", "Отчёт", "Картриджи"]

    init(_ test: XCTestCase, _ name: String) {
        self.test = test
        self.name = name
    }

    // ── сценарии ────────────────────────────────────────────────────────────

    func full() {
        launch()
        for i in 0..<7 { shot("splash\(i)"); pause(0.5) }    // заставка по кадрам
        pause(1.5)
        shot("home")
        checkBar()
        checkNoAdd("Главная")
        assets()
        report()
        carts()
        swipes()
        quick()
        templates()
        settings()
        longList()
        extras()
    }

    /// Нововведения 5.0. Идут последними: если шаг сорвётся, остальной проход уже снят.
    private func extras() {
        keepsTyped()
        search()
        undo()
        asTemplate()
        preview()
        lastCartridge()
        history()
        summary()
        units()
        reminder()
        whatsNew51()
        iconAction()
    }

    /// Нововведения 5.1: жизнь техники, сотрудники, корзина, защита, бэкап.
    private func whatsNew51() {
        devices()
        printerCartridge()
        fleet()
        contacts()
        onboarding()
        dismissal()
        trash()
        security()
        backupOptions()
    }

    /// Принтер с картриджем, датой покупки и гарантией → карточка устройства → передача другому сотруднику.
    private func devices() {
        tidy()
        open("Учёт")
        guard openEmployee("Тестов 01") else { return }
        guard let add = reveal(app.buttons.matching(NSPredicate(format: "label == %@", "Добавить: принтер")), tries: 16) else {
            XCTFail("Карточка: нет кнопки «Добавить: принтер»")
            backToList("Тестов 01")
            return
        }
        add.tap()
        pause(0.8)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Принтер 1"))
        guard let printer = reveal(row, tries: 3) else {
            XCTFail("Карточка: новый принтер не появился")
            backToList("Тестов 01")
            return
        }
        printer.tap()                                         // раскрыть поля принтера
        pause(0.8)
        type("Модель", "HP LaserJet")
        type("Например, CF226", "CF226")
        hideKeyboard()
        for label in ["Куплен: указать", "Гарантия до: указать"] {
            if let b = reveal(app.buttons.matching(NSPredicate(format: "label == %@", label)), tries: 4) {
                b.tap()
                pause(0.5)
            } else {
                XCTFail("Принтер: нет «\(label)»")
            }
        }
        shot("device-filled")
        tapBarButton("Тестов 01", "Сохранить")
        pause(1)
        let historyButton = app.buttons.matching(NSPredicate(format: "label == %@", "История и передача"))
        var hist = reveal(historyButton, tries: 4)
        if hist == nil, let p = reveal(row, fromTop: true, tries: 16) {   // после сохранения принтер свернулся
            p.tap()
            pause(0.8)
            hist = reveal(historyButton, tries: 4)
        }
        guard let hist else {
            XCTFail("Принтер: нет кнопки «История и передача»")
            backToList("Тестов 01")
            return
        }
        hist.tap()
        guard app.navigationBars["Устройство"].waitForExistence(timeout: 5) else {
            XCTFail("Принтер: карточка устройства не открылась")
            backToList("Тестов 01")
            return
        }
        pause(0.8)
        shot("device-card")
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Передать")), "кнопка «Передать»")
        guard app.navigationBars["Передать"].waitForExistence(timeout: 4) else {
            XCTFail("Устройство: «Передать» не открылось")
            tidy()
            backToList("Тестов 01")
            return
        }
        tapFirst(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Тестов 02")), "сотрудник «Тестов 02»")
        let confirm = app.buttons["Передать: Тестов 02"]
        if confirm.waitForExistence(timeout: 4) {
            confirm.tap()
        } else {
            XCTFail("Передача: нет подтверждения «Передать: Тестов 02»")
            tidy()
        }
        pause(1.5)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Тестов 01 → Тестов 02")).firstMatch
            .waitForExistence(timeout: 4), "Устройство: в истории нет передачи")
        shot("device-moved")
        tapBarButton("Устройство", "Закрыть")
        pause(1.2)
        XCTAssertNil(visible(row), "Карточка: переданный принтер остался у прежнего владельца")
        backToList("Тестов 01")
    }

    /// Выдача картриджа: у сотрудника есть принтер с картриджем — модель подставляется из его карточки.
    private func printerCartridge() {
        tidy()
        open("Картриджи")
        guard let add = checkAdd("Картриджи, принтер"), tapAdd(add, opens: "Выдача", "carts-printer") else { return }
        type("ФИО или часть имени", "Тестов 02")
        pause(0.8)
        tapFirst(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Его принтер: CF226")),
                 "подсказка «Его принтер: CF226»")
        pause(0.8)
        XCTAssertTrue(hasField("CF226"), "Выдача: картридж принтера не подставился")
        hideKeyboard()
        shot("carts-printer")
        tapBarButton("Выдача", "Отмена")
        pause(1)
    }

    /// Сводка: возраст техники по дате покупки.
    private func fleet() {
        tidy()
        open("Главная")
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Сводка за месяц и год")), "кнопка «Сводка»")
        guard app.navigationBars["Сводка"].waitForExistence(timeout: 4) else {
            XCTFail("Главная: сводка не открылась")
            return
        }
        let header = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "возраст техники"))
        _ = reveal(header, tries: 6)
        XCTAssertTrue(header.firstMatch.exists, "Сводка: нет возраста техники")
        shot("summary-fleet")
        tapBarButton("Сводка", "Закрыть")
        pause(1)
    }

    /// Телефон, почта и день рождения в карточке; день рождения сегодня — карточка на главной.
    private func contacts() {
        tidy()
        open("Учёт")
        guard openEmployee("Иванов Иван Петрович") else { return }
        let p = { (t: String) in NSPredicate(format: "label == %@ OR placeholderValue == %@", t, t) }
        if reveal(app.textFields.matching(p("Телефон")), tries: 10) != nil {
            type("Телефон", "+7 701 000 00 00")
            type("Почта", "ivanov@example.com")
        } else {
            XCTFail("Карточка: нет поля «Телефон»")
        }
        hideKeyboard()
        if let b = reveal(app.buttons.matching(NSPredicate(format: "label == %@", "День рождения: указать")), fromTop: true,
                          tries: 10) {
            b.tap()
            pause(0.6)
        } else {
            XCTFail("Карточка: нет «День рождения: указать»")
        }
        shot("employee-birthday")
        tapBarButton("Иванов Иван Петрович", "Сохранить")
        pause(1)
        if reveal(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Позвонить")), tries: 6) == nil {
            XCTFail("Карточка: у телефона нет кнопки «Позвонить»")
        }
        shot("employee-contacts")
        backToList("Иванов Иван Петрович")
        open("Главная")
        for _ in 0..<3 { drag(fromY: 0.3, toY: 0.8) }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ДЕНЬ РОЖДЕНИЯ СЕГОДНЯ")).firstMatch
            .waitForExistence(timeout: 4), "Главная: нет карточки дня рождения")
        shot("home-birthday")
    }

    /// Чек-лист нового сотрудника: отметить пункты и записать сделанное в отчёт.
    private func onboarding() {
        tidy()
        open("Учёт")
        guard openEmployee("Тестов 03") else { return }
        for step in ["Создать учётную запись и почту", "Выдать и настроить компьютер", "Подключить принтер",
                     "Добавить в группы и сетевые папки"] {
            tapFirst(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", step)), "пункт «\(step)»")
            pause(0.4)
        }
        shot("onboarding")
        let done = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Готово — записать в отчёт"))
        tapFirst(done, "кнопка «Готово — записать в отчёт»")
        pause(1.2)
        XCTAssertNil(visible(done), "Карточка: после «Готово» чек-лист не убрался")
        backToList("Тестов 03")
        open("Отчёт")
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Тестов 03",
                                                     "Подготовка рабочего места"))
        XCTAssertNotNil(reveal(entry, fromTop: true, tries: 10), "Отчёт: чек-лист не записался в отчёт")
        shot("onboarding-entry")
    }

    /// Уволить: карточка уходит в «Уволенные» внизу учёта.
    private func dismissal() {
        tidy()
        open("Учёт")
        guard openEmployee("Тестов 04") else { return }
        guard let fire = reveal(app.buttons.matching(NSPredicate(format: "label == %@", "Уволить")), tries: 18) else {
            XCTFail("Карточка: нет кнопки «Уволить»")
            backToList("Тестов 04")
            return
        }
        fire.tap()
        let yes = app.buttons["Да, уволить"]
        guard yes.waitForExistence(timeout: 4) else {
            XCTFail("Уволить: нет подтверждения")
            backToList("Тестов 04")
            return
        }
        yes.tap()
        pause(1.2)
        XCTAssertNotNil(reveal(app.buttons.matching(NSPredicate(format: "label == %@", "Вернуть на работу")), tries: 4),
                        "Карточка уволенного: нет «Вернуть на работу»")
        backToList("Тестов 04")
        let fired = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Тестов 04", "уволен"))
        XCTAssertNotNil(reveal(fired, tries: 12), "Учёт: уволенный не появился в «Уволенных»")
        shot("assets-dismissed")
    }

    /// Корзина: удалённая запись (после того как плашка «Вернуть» ушла) возвращается из настроек.
    private func trash() {
        tidy()
        open("Отчёт")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Замятие бумаги в принтере"))
        guard let row = reveal(rows, fromTop: true, tries: 8) else {
            XCTFail("Отчёт: нет записи, на которой проверить корзину")
            return
        }
        row.press(forDuration: 1.2)
        let delete = app.buttons["Удалить"]
        guard delete.waitForExistence(timeout: 3) else {
            XCTFail("Отчёт: долгое нажатие не открыло меню записи")
            return
        }
        delete.tap()
        if app.buttons["Вернуть"].waitForExistence(timeout: 3) { shot("undo-toast") }
        pause(7)                                              // плашка «Вернуть» ушла — остаётся только корзина
        open("Настройки")
        guard let bin = reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Корзина")), fromTop: true,
                               tries: 12) else {
            XCTFail("Настройки: нет строки «Корзина»")
            return
        }
        bin.tap()
        guard app.navigationBars["Корзина"].waitForExistence(timeout: 4) else {
            XCTFail("Настройки: корзина не открылась")
            return
        }
        pause(0.8)
        shot("trash")
        tapFirst(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Вернуть: Замятие бумаги")),
                 "«Вернуть» у записи в корзине")
        pause(1.2)
        shot("trash-restored")
        tapBarButton("Корзина", "Закрыть")
        pause(1)
        open("Отчёт")
        XCTAssertNotNil(reveal(rows, fromTop: true, tries: 8), "Отчёт: запись из корзины не вернулась")
    }

    /// Вход по PIN-коду (5.2): PIN-код дважды, почта для восстановления и ключ из письма (письмо в симуляторе
    /// не уходит — ключ задаёт тест через REPORTER_TEST_KEY), экран входа после сворачивания (в переключателе
    /// приложений — без кнопок), неверный и верный PIN-код, «Забыли PIN-код?» — ключ из письма и новый PIN-код.
    private func security() {
        tidy()
        open("Настройки")
        let q = app.switches.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "lock.toggle", "Вход по"))
        guard let toggle = reveal(q, fromTop: true, tries: 10) else {
            XCTFail("Настройки: нет переключателя входа")
            return
        }
        pause(1.2)
        let create = app.staticTexts["Придумайте PIN-код"]
        let at = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        at.tap()
        if !create.waitForExistence(timeout: 4) {
            print("РАЗБОР вход: касание переключателя потерялось — нажимаем подольше")
            at.press(forDuration: 0.25)
        }
        guard create.waitForExistence(timeout: 4) else {
            XCTFail("Защита: переключатель не открыл настройку PIN-кода")
            shot("lock-setup-missing")
            return
        }
        shot("lock-setup-pin")
        enterPIN(Self.firstPIN)
        guard app.staticTexts["Повторите PIN-код"].waitForExistence(timeout: 4) else {
            XCTFail("Защита: после PIN-кода не спросили повторить")
            tidy()
            return
        }
        enterPIN(Self.firstPIN)
        let send = app.buttons["Отправить ключ"]
        guard send.waitForExistence(timeout: 4) else {
            XCTFail("Защита: после PIN-кода нет шага с почтой для восстановления")
            shot("lock-mail-missing")
            tidy()
            return
        }
        // поле уже заполнено адресом из «Почты для отчёта», если он там есть
        if !((app.textFields["Почта"].value as? String) ?? "").contains("@") {
            type("Почта", "it@example.com")
            hideKeyboard()
        }
        send.tap()
        guard app.textFields["Ключ из письма"].waitForExistence(timeout: 6) else {
            XCTFail("Защита: ключ не «отправился»")
            shot("lock-key-missing")
            tidy()
            return
        }
        type("Ключ из письма", Self.typedKey)                // строчными и с пробелами — ключ всё равно подходит
        hideKeyboard()
        shot("lock-setup-key")
        app.buttons["Подтвердить ключ"].tap()
        pause(1.5)
        XCTAssertEqual(toggle.value as? String, "1", "Защита: вход не включился после PIN-кода и ключа")
        shot("lock-on")

        // свернули: в переключателе приложений — только значок; вернулись — экран входа
        XCUIDevice.shared.press(.home)
        pause(2)
        switcher()
        app.activate()
        let enter = app.buttons["Ввести PIN-код"]
        guard enter.waitForExistence(timeout: 8) else {
            XCTFail("Защита: после сворачивания нет экрана входа")
            shot("lock-missing")
            return
        }
        pause(0.8)
        shot("lock-screen")
        XCTAssertTrue(app.buttons["Забыли PIN-код?"].exists, "Экран входа: нет «Забыли PIN-код?»")
        let faceID = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Войти по")).firstMatch.exists
        print("РАЗБОР вход: кнопка Face ID " + (faceID ? "есть" : "не показана — в симуляторе нет Face ID"))
        enter.tap()
        enterPIN("9999")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Неверный PIN-код")).firstMatch
            .waitForExistence(timeout: 3), "Экран входа: неверный PIN-код не отклонён")
        shot("lock-wrong-pin")
        enterPIN(Self.firstPIN)
        XCTAssertTrue(app.staticTexts["Введите PIN-код"].waitForNonExistence(timeout: 4),
                      "Экран входа: верный PIN-код не открыл приложение")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3) && toggle.isHittable, "Защита: после входа настройки закрыты")

        // забыли PIN-код: ключ из письма → новый PIN-код дважды → вход
        XCUIDevice.shared.press(.home)
        pause(1.5)
        app.activate()
        let forgot = app.buttons["Забыли PIN-код?"]
        guard forgot.waitForExistence(timeout: 8) else {
            XCTFail("Защита: после второго сворачивания нет экрана входа")
            return
        }
        pause(0.8)
        forgot.tap()
        guard app.textFields["Ключ из письма"].waitForExistence(timeout: 4) else {
            XCTFail("Восстановление: нет поля для ключа")
            shot("lock-forgot-missing")
            return
        }
        type("Ключ из письма", Self.typedKey)
        shot("lock-forgot")
        app.typeText("\n")                                   // «Продолжить» — кнопкой клавиатуры
        guard app.staticTexts["Придумайте новый PIN-код"].waitForExistence(timeout: 4) else {
            XCTFail("Восстановление: ключ из письма не принят")
            shot("lock-key-rejected")
            return
        }
        shot("lock-new-pin")
        enterPIN(Self.pin)
        XCTAssertTrue(app.staticTexts["Повторите PIN-код"].waitForExistence(timeout: 3), "Восстановление: не спросили повторить")
        enterPIN(Self.pin)
        XCTAssertTrue(app.staticTexts["Повторите PIN-код"].waitForNonExistence(timeout: 4),
                      "Восстановление: новый PIN-код не открыл приложение")
        pause(1)
        XCTAssertTrue(toggle.isHittable, "Восстановление: после нового PIN-кода приложение закрыто")
    }

    /// Набрать PIN-код цифрами экрана. Точка после касания не закрасилась — повторяем нажатием подольше
    /// (на медленном симуляторе короткие касания иногда теряются).
    private func enterPIN(_ pin: String) {
        let dots = app.descendants(matching: .any)["pin.dots"]
        for (i, d) in pin.enumerated() {
            let key = app.buttons["pin.\(d)"]
            guard key.waitForExistence(timeout: 4) else {
                XCTFail("Нет цифры «\(d)» для PIN-кода")
                shot("pin-missing")
                return
            }
            key.tap()
            guard i < pin.count - 1 else { break }          // после последней точки сразу гаснут — идёт проверка
            let want = "\(i + 1) из \(pin.count)"
            if dots.exists, !waitValue(dots, want, timeout: 3) {
                print("РАЗБОР PIN: касание «\(d)» потерялось — нажимаем подольше")
                key.press(forDuration: 0.25)
                _ = waitValue(dots, want, timeout: 3)
            }
        }
        pause(1)                                             // проверка после последней цифры
    }

    private func waitValue(_ e: XCUIElement, _ value: String, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (e.value as? String) == value { return true }
            pause(0.2)
        } while Date() < deadline
        return false
    }

    /// Экран входа (вход включён шагом security) — открыть PIN-кодом. Экрана нет — ничего не делаем.
    private func unlock(_ shotName: String? = nil, wait: Double = 6) {
        let enter = app.buttons["Ввести PIN-код"]
        guard enter.waitForExistence(timeout: wait) else { return }
        pause(0.8)
        if let shotName { shot(shotName) }
        enter.tap()
        let title = app.staticTexts["Введите PIN-код"]
        guard title.waitForExistence(timeout: 4) else {
            XCTFail("Вход: «Ввести PIN-код» не открыл цифры")
            shot("unlock-stuck")
            return
        }
        enterPIN(Self.pin)
        if title.waitForNonExistence(timeout: 4) { return }
        // «Забыли PIN-код?» в шаге security не прошёл — тогда действует первый PIN-код
        print("РАЗБОР вход: PIN-код \(Self.pin) не подошёл, пробуем \(Self.firstPIN)")
        enterPIN(Self.firstPIN)
        XCTAssertTrue(title.waitForNonExistence(timeout: 4), "Вход: ни один PIN-код не подошёл")
    }

    /// Переключатель приложений (смахнуть вверх от нижнего края и задержать палец): что видно о приложении в фоне.
    private func switcher() {
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let from = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.998))
        let to = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1.2)
        pause(1.5)
        shot("lock-switcher")
    }

    /// Бэкап: «каждый день», шифрование с паролем, проверка без отправленного бэкапа — понятный ответ.
    private func backupOptions() {
        tidy()
        open("Настройки")
        guard let often = reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Как часто")),
                                 fromTop: true, tries: 16) else {
            XCTFail("Бэкап: нет «Как часто»")
            return
        }
        often.tap()
        let daily = app.buttons["Каждый день"]
        if daily.waitForExistence(timeout: 3) { daily.tap() } else { XCTFail("Бэкап: в «Как часто» нет «Каждый день»") }
        pause(0.8)
        guard let encrypt = reveal(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Шифровать бэкап")),
                                   tries: 3) else {
            XCTFail("Бэкап: нет «Шифровать бэкап»")
            return
        }
        flip(encrypt, "encrypt")
        XCTAssertEqual(encrypt.value as? String, "1", "Бэкап: шифрование не включилось")
        type("не короче 8 знаков", "проверка-1234")
        hideKeyboard()
        if let check = reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Проверить бэкап сейчас")),
                              tries: 4) {
            check.tap()
        } else {
            XCTFail("Бэкап: нет кнопки «Проверить бэкап сейчас»")
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "сначала отправьте бэкап")).firstMatch
            .waitForExistence(timeout: 4), "Бэкап: проверка без бэкапа не объяснила, что проверять нечего")
        shot("backup-options")
    }

    /// Открыть карточку сотрудника из списка учёта.
    private func openEmployee(_ name: String) -> Bool {
        let q = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name))
        guard let row = reveal(q, fromTop: true, tries: 16) else {
            XCTFail("Учёт: нет строки «\(name)»")
            return false
        }
        row.tap()
        guard app.navigationBars[name].waitForExistence(timeout: 5) else {
            XCTFail("Учёт: карточка «\(name)» не открылась")
            return false
        }
        pause(0.6)
        return true
    }

    /// Из карточки — «назад» к списку.
    private func backToList(_ name: String) {
        hideKeyboard()
        let bar = app.navigationBars[name]
        if bar.exists {
            bar.buttons.element(boundBy: 0).tap()
            pause(0.8)
        }
    }

    /// Нажать переключатель (по самому тумблеру справа): коротким касанием, а не сдвинулся — нажатием подольше,
    /// как пальцем (на медленном симуляторе короткое касание этого переключателя теряется примерно через раз; разбор
    /// с выгрузкой дерева элементов ничего поверх не нашёл). Окно (разрешение уведомлений, ошибка) — нажатие дошло.
    private func flip(_ toggle: XCUIElement, _ name: String) {
        pause(1.2)
        let before = toggle.value as? String
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let ways: [(String, (XCUICoordinate) -> Void)] = [("касание", { $0.tap() }),
                                                         ("нажатие подольше", { $0.press(forDuration: 0.25) })]
        for (how, act) in ways {
            // поверх — системное окно (Face ID, код-пароль): нажатие уйдёт в никуда, а XCUITest упадёт
            guard toggle.isHittable else {
                print("РАЗБОР \(name): переключатель закрыт другим окном")
                shot(name + "-covered")
                return
            }
            act(toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)))
            pause(1.2)
            let alert = app.alerts.firstMatch
            if alert.exists {
                print("РАЗБОР \(name): окно — " + alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
                return
            }
            if board.alerts.firstMatch.exists || toggle.value as? String != before {
                if how != "касание" { print("РАЗБОР \(name): сработало только «\(how)»") }
                return
            }
            print("РАЗБОР \(name): «\(how)» не сдвинуло переключатель")
        }
    }

    /// Прокрутить, пока элемент не окажется на экране. fromTop — сначала к началу страницы.
    private func reveal(_ q: XCUIElementQuery, fromTop: Bool = false, tries: Int = 8) -> XCUIElement? {
        if fromTop { for _ in 0..<6 { drag(fromY: 0.3, toY: 0.85) } }
        for _ in 0..<tries {
            if let e = visible(q) { return e }
            drag(fromY: 0.72, toY: 0.38)
        }
        return visible(q)
    }

    /// Набранная запись не стирается, если из неё зайти в «Изменить шаблоны» и вернуться.
    private func keepsTyped() {
        tidy()
        open("Отчёт")
        guard let add = checkAdd("Отчёт, шаблоны из записи"), tapAdd(add, opens: "Новая запись", "report") else { return }
        type("Сотрудник / объект", "Сидоров")
        hideKeyboard()
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Заполнить по шаблону")), "меню «Заполнить по шаблону»")
        pause(0.8)
        let edit = app.buttons["Изменить шаблоны"]
        for _ in 0..<8 where !(edit.exists && edit.isHittable) { drag(fromY: 0.7, toY: 0.35) }   // пункт — в конце длинного меню
        guard edit.exists, edit.isHittable else {
            XCTFail("Запись: в меню шаблонов не нашлось «Изменить шаблоны»")
            shot("template-menu-stuck")
            // меню могло остаться открытым — закрываем нажатием мимо него (по заголовку листа), потом сам лист
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.095)).tap()
            pause(0.8)
            tidy()
            return
        }
        edit.tap()
        guard app.navigationBars["Шаблоны"].waitForExistence(timeout: 4) else {
            XCTFail("Запись: «Изменить шаблоны» не открыли список шаблонов")
            return
        }
        shot("templates-from-entry")
        app.navigationBars["Шаблоны"].buttons.element(boundBy: 0).tap()      // «назад» к записи
        pause(1)
        XCTAssertTrue(hasField("Сидоров"), "Запись: после возврата из шаблонов набранное стёрлось")
        shot("entry-kept")
        tapBarButton("Новая запись", "Отмена")
        pause(1)
    }

    /// Поиск по всему отчёту: находит запись по слову, остальные прячет.
    private func search() {
        tidy()
        open("Отчёт")
        guard let field = visible(app.searchFields) else {
            XCTFail("Отчёт: нет строки поиска")
            return
        }
        field.tap()
        dismissKeyboardTip()
        field.typeText("щщщ")                                // такого слова в отчёте нет
        pause(1)
        shot("report-search-none")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "бумаг")
        pause(1)
        let other = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Не печатает принтер"))
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Замятие бумаги в принтере"))),
                        "Отчёт: поиск не нашёл запись «Замятие бумаги»")
        XCTAssertNil(visible(other), "Отчёт: поиск показывает запись без искомого слова")
        shot("report-search")
        closeSearch()
        pause(0.8)
        if visible(other) == nil {                           // поиск не закрылся кнопкой — стираем текст
            let clear = field.buttons.firstMatch
            if clear.exists && clear.isHittable { clear.tap() }
            hideKeyboard()
            pause(0.8)
        }
        XCTAssertNotNil(visible(other), "Отчёт: после поиска список недели не вернулся")
    }

    /// Удалённую запись возвращает кнопка «Вернуть» на плашке.
    private func undo() {
        tidy()
        open("Отчёт")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Не печатает принтер"))
        guard let row = visible(rows) else {
            XCTFail("Отчёт: нет записи, на которой проверить удаление")
            return
        }
        row.press(forDuration: 1.2)
        let delete = app.buttons["Удалить"]
        guard delete.waitForExistence(timeout: 3) else {
            XCTFail("Отчёт: долгое нажатие не открыло меню записи")
            return
        }
        shot("entry-menu")
        delete.tap()
        let back = app.buttons["Вернуть"]
        guard back.waitForExistence(timeout: 3) else {
            XCTFail("Отчёт: на плашке «Удалено» нет кнопки «Вернуть»")
            return
        }
        // плашка висит шесть секунд, а медленный симулятор тратит на шаг по секунде: место кнопки запоминаем сразу
        // и жмём по координате — без нового поиска и без обрыва теста, если плашка уже ушла. Снимок плашки — в шаге
        // корзины: здесь на него не хватало времени
        let spot = back.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: spot.midX, dy: spot.midY)).tap()
        pause(1)
        XCTAssertNotNil(visible(rows), "Отчёт: «Вернуть» не вернула удалённую запись")
        shot("undo-done")
    }

    /// Долгое нажатие на запись → «Сохранить как шаблон»: новый шаблон с её текстом.
    private func asTemplate() {
        tidy()
        open("Отчёт")
        guard let row = visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Не печатает принтер"))) else {
            XCTFail("Отчёт: нет записи, из которой сделать шаблон")
            return
        }
        row.press(forDuration: 1.2)
        let item = app.buttons["Сохранить как шаблон"]
        guard item.waitForExistence(timeout: 3) else {
            XCTFail("Отчёт: в меню записи нет «Сохранить как шаблон»")
            return
        }
        item.tap()
        guard app.navigationBars["Новый шаблон"].waitForExistence(timeout: 4) else {
            XCTFail("Отчёт: «Сохранить как шаблон» не открыл новый шаблон")
            return
        }
        XCTAssertTrue(hasField("Не печатает принтер"), "Шаблон из записи: описание не перенеслось")
        shot("template-from-entry")
        tapBarButton("Новый шаблон", "Отмена")
        pause(1)
    }

    /// Просмотр Word-отчёта за неделю перед отправкой.
    private func preview() {
        tidy()
        open("Отчёт")
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Посмотреть отчёт")), "кнопка «Посмотреть отчёт»")
        guard app.navigationBars["Просмотр отчёта"].waitForExistence(timeout: 6) else {
            XCTFail("Отчёт: просмотр не открылся")
            return
        }
        // Quick Look открывает Word не сразу (в симуляторе — десятки секунд, сначала пустой экран, потом «Загрузка…»):
        // ждём текст документа
        let loading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                                                           "Загрузка", "Loading")).firstMatch
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Выполненные")).firstMatch   // только в документе: «Ответственный» есть и в настройках
        pause(6)
        let deadline = Date().addingTimeInterval(60)
        while (loading.exists || !text.exists) && Date() < deadline { pause(2) }
        pause(1.5)
        shot("report-preview")
        XCTAssertFalse(loading.exists, "Просмотр: документ не открылся за минуту — висит «Загрузка…»")
        XCTAssertTrue(app.navigationBars["Просмотр отчёта"].buttons["Поделиться"].exists, "Просмотр: нет «Поделиться»")
        tapBarButton("Просмотр отчёта", "Закрыть")
        pause(1)
    }

    /// Новая выдача тому же сотруднику: приложение показывает прошлую и само подставляет модель.
    private func lastCartridge() {
        tidy()
        open("Картриджи")
        guard let add = checkAdd("Картриджи, прошлая выдача"), tapAdd(add, opens: "Выдача", "carts") else { return }
        type("ФИО или часть имени", "Иванов")
        pause(0.8)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "В прошлый раз: 285")).firstMatch
            .waitForExistence(timeout: 3), "Выдача: нет строки «В прошлый раз»")
        tapFirst(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Иванов Иван Петрович")),
                 "подсказка сотрудника из учёта")
        pause(0.8)
        XCTAssertTrue(hasField("285"), "Выдача: модель прошлого картриджа не подставилась")
        hideKeyboard()
        shot("carts-last")
        tapBarButton("Выдача", "Отмена")
        pause(1)
    }

    /// Карточка сотрудника: история его картриджей и заявок.
    private func history() {
        tidy()
        open("Учёт")
        for _ in 0..<5 { drag(fromY: 0.3, toY: 0.8) }        // после длинного списка страница стоит в конце
        tapFirst(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Иванов Иван Петрович")), "строка сотрудника")
        let card = app.navigationBars["Иванов Иван Петрович"]
        guard card.waitForExistence(timeout: 4) else {
            XCTFail("Учёт: карточка сотрудника не открылась")
            return
        }
        let all = app.descendants(matching: .any)
        let carts = all.matching(NSPredicate(format: "label BEGINSWITH %@", "Картриджи: 1")).firstMatch
        XCTAssertTrue(carts.waitForExistence(timeout: 3), "Карточка: в истории нет картриджей")
        XCTAssertTrue(all.matching(NSPredicate(format: "label BEGINSWITH %@", "Заявки: ")).firstMatch.exists,
                      "Карточка: в истории нет заявок")
        if carts.exists && carts.isHittable { carts.tap(); pause(0.8) }
        shot("employee-history")
        card.buttons.element(boundBy: 0).tap()                // «назад» к списку
        pause(1)
    }

    /// Сводка за месяц и за год с главной.
    private func summary() {
        tidy()
        open("Главная")
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Сводка за месяц и год")), "кнопка «Сводка»")
        guard app.navigationBars["Сводка"].waitForExistence(timeout: 4) else {
            XCTFail("Главная: сводка не открылась")
            return
        }
        pause(0.8)
        shot("summary-month")
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Год")), "сегмент «Год»")
        pause(1)
        shot("summary-year")
        tapBarButton("Сводка", "Закрыть")
        pause(1)
    }

    /// Подразделения в настройках: новое сохраняется и появляется в списке.
    private func units() {
        tidy()
        open("Настройки")
        // после прохода настройки стоят в конце — сверху вниз до строки
        guard let row = reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Подразделения")),
                               fromTop: true, tries: 10) else {
            XCTFail("Настройки: нет строки «Подразделения»")
            return
        }
        row.tap()
        guard app.navigationBars["Подразделения"].waitForExistence(timeout: 4) else {
            XCTFail("Настройки: «Подразделения» не открылись")
            return
        }
        tapBarButton("Подразделения", "Новое подразделение")
        guard app.navigationBars["Новое подразделение"].waitForExistence(timeout: 4) else {
            XCTFail("Подразделения: «+» не открыл новое подразделение")
            return
        }
        type("Например, Бухгалтерия", "Бухгалтерия")
        shot("unit-new")
        tapBarButton("Новое подразделение", "Сохранить")
        pause(1)
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Бухгалтерия"))),
                        "Подразделения: новое не появилось в списке")
        shot("units")
        // карточка отдела: люди, техника, заявки и картриджи за месяц
        tapFirst(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Филиал")), "строка «Филиал»")
        if app.navigationBars["Филиал"].waitForExistence(timeout: 4) {
            pause(0.6)
            shot("unit-card")
            app.navigationBars["Филиал"].buttons.element(boundBy: 0).tap()
            pause(0.8)
        } else {
            XCTFail("Подразделения: карточка отдела не открылась")
        }
        tapBarButton("Подразделения", "Закрыть")
        pause(1)
    }

    /// Напоминание в пятницу: переключатель включается после системного запроса на уведомления.
    private func reminder() {
        tidy()
        open("Настройки")
        for _ in 0..<2 { drag(fromY: 0.3, toY: 0.8) }
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Напомнить в пятницу")).firstMatch
        guard toggle.waitForExistence(timeout: 3) else {
            XCTFail("Настройки: нет переключателя «Напомнить в пятницу»")
            return
        }
        flip(toggle, "reminder")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Разрешить"] {                // запрос показывает система, язык у неё свой
            let allow = board.buttons[label]
            if allow.waitForExistence(timeout: 3) { allow.tap(); break }
        }
        pause(1.5)
        let failed = app.alerts.firstMatch                   // приложение объяснило, почему не включилось
        if failed.exists {
            print("РАЗБОР напоминание: " + failed.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
            shot("reminder-alert")
            failed.buttons.firstMatch.tap()
            pause(0.8)
        }
        XCTAssertEqual(toggle.value as? String, "1", "Настройки: напоминание в пятницу не включилось")
        shot("reminder-on")
    }

    /// Быстрое действие с иконки: долгое нажатие на иконку → «Новая запись» открывает форму записи.
    /// Меню рисует домашний экран симулятора; не открылось — шаг не проверен, но это не ошибка приложения.
    private func iconAction() {
        tidy()
        XCUIDevice.shared.press(.home)
        pause(1.5)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = board.icons["REPORTER"]                   // запросы к домашнему экрану медленные — без лишних
        guard icon.waitForExistence(timeout: 5) else {
            print("РАЗБОР иконка: REPORTER не нашлась на домашнем экране — быстрое действие не проверено")
            app.activate()
            return
        }
        icon.press(forDuration: 1.3)
        let item = board.buttons["Новая запись"]
        guard item.waitForExistence(timeout: 4) else {
            print("РАЗБОР иконка: меню быстрых действий не открылось — быстрое действие не проверено")
            shot("icon-menu-missing")
            XCUIDevice.shared.press(.home)
            app.activate()
            return
        }
        shot("icon-menu")
        item.tap()
        unlock("icon-lock")                                  // вход включён шагом security: сначала экран входа
        XCTAssertTrue(app.navigationBars["Новая запись"].waitForExistence(timeout: 8),
                      "Иконка: «Новая запись» не открыла форму записи")
        shot("icon-entry")
        tidy()

        // то же при закрытом приложении: оно стартует сразу на форме выдачи, без заставки
        app.terminate()
        pause(1.5)
        icon.press(forDuration: 1.3)
        let cart = board.buttons["Выдать картридж"]
        guard cart.waitForExistence(timeout: 4) else {
            print("РАЗБОР иконка: меню быстрых действий не открылось второй раз — холодный запуск не проверен")
            XCUIDevice.shared.press(.home)
            return
        }
        cart.tap()
        unlock(wait: 10)
        XCTAssertTrue(app.navigationBars["Выдача"].waitForExistence(timeout: 12),
                      "Иконка: «Выдать картридж» при закрытом приложении не открыла форму выдачи")
        shot("icon-cold")
        tidy()
    }

    /// Закрыть лишнее перед следующим шагом: клавиатуру и лист, оставшийся от сорвавшегося шага.
    private func tidy() {
        hideKeyboard()
        for label in ["Отмена", "Закрыть"] {
            let b = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if b.exists && b.isHittable { b.tap(); pause(0.8) }
        }
    }

    func light() {
        launch()
        // вход включён первым проходом: заставки нет, сразу экран входа; нет входа — за это время доиграет заставка
        unlock("lock-launch", wait: 8)
        pause(1.5)
        open("Настройки")
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Светлая")), "сегмент «Светлая»")
        pause(1)
        shot("settings")
        for t in Self.tabs.dropLast() {
            open(t)
            checkAddIfNeeded(t, t)
            shot(t)
        }
        checkBar()
        open("Настройки")
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Авто")), "сегмент «Авто»")
    }

    private func assets() {
        open("Учёт")
        shot("assets")
        guard let add = checkAdd("Учёт"), tapAdd(add, opens: "Новый сотрудник", "assets") else { return }
        pause(0.8)
        checkNoAdd("Карточка сотрудника")
        shot("assets-new")
        type("Фамилия", "Иванов")
        type("Имя", "Иван")
        type("Отчество", "Петрович")
        type("Должность", "Инженер")
        pause(0.6)
        // клавиатура открыта — панель и «+» спрятаны и не закрывают поля
        XCTAssertFalse(tab("Главная").isHittable, "карточка сотрудника: нижняя панель висит над клавиатурой")
        shot("assets-filled")
        tapBarButton("Новый сотрудник", "Сохранить")
        pause(1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "карточка сотрудника: после «Сохранить» клавиатура не закрылась")
        shot("assets-saved")
        // карточка остаётся открытой в «Учёте», а другие страницы работают как обычно
        open("Отчёт")
        checkAdd("Отчёт при открытой карточке")
        swipe(left: true)
        XCTAssertTrue(tab("Картриджи").isSelected, "при открытой карточке сотрудника не листаются другие страницы")
        open("Учёт")
        checkNoAdd("Карточка сотрудника после возврата")
        let card = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS %@", "Иванов")).firstMatch
        if card.waitForExistence(timeout: 4) {
            card.buttons.element(boundBy: 0).tap()               // «назад» к списку
        } else {
            XCTFail("Учёт: после сохранения заголовок карточки не стал ФИО")
        }
        pause(1)
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Иванов Иван Петрович"))),
                        "Учёт: сотрудник не появился в списке")
        checkAdd("Учёт после карточки")
        shot("assets-list")
    }

    private func report() {
        open("Отчёт")
        shot("report")
        guard let add = checkAdd("Отчёт"), tapAdd(add, opens: "Новая запись", "report") else { return }
        shot("report-new")
        type("Сотрудник / объект", "Иванов Иван Петрович")
        type("Описание", "Не печатает принтер")
        type("Действия", "Заменил картридж")
        type("Результат", "Печатает в штатном режиме")
        shot("report-filled")
        tapBarButton("Новая запись", "Сохранить")
        pause(1.2)
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Не печатает принтер"))),
                        "Отчёт: запись не появилась в списке")
        shot("report-saved")

        // запись по шаблону: меню над полями заполняет «что случилось», «что сделано» и «итог»
        guard let again = checkAdd("Отчёт, по шаблону"), tapAdd(again, opens: "Новая запись", "report") else { return }
        type("Сотрудник / объект", "Иванов Иван Петрович")
        hideKeyboard()
        pickTemplate("Замятие бумаги")
        for text in ["Замятие бумаги в принтере", "Извлёк замятую бумагу, почистил ролики", "Принтер печатает в штатном режиме"] {
            XCTAssertTrue(hasField(text), "Отчёт: шаблон не заполнил поле «\(text)»")
        }
        shot("report-template-filled")
        tapBarButton("Новая запись", "Сохранить")
        pause(1.2)
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Замятие бумаги в принтере"))),
                        "Отчёт: запись по шаблону не появилась в списке")
        shot("report-template-saved")
    }

    /// Шаблоны в настройках: «Картридж» правится, новый шаблон сохраняется и сразу есть в меню записи отчёта.
    private func templates() {
        open("Настройки")
        tapFirst(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Шаблоны заявок")), "строка «Шаблоны заявок»")
        guard app.navigationBars["Шаблоны"].waitForExistence(timeout: 4) else {
            XCTFail("Настройки: «Шаблоны заявок» не открылись")
            return
        }
        pause(0.8)
        shot("templates")
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Замятие бумаги"))),
                        "Шаблоны: нет стандартных шаблонов")
        tapFirst(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Принтер плохо печатает")), "шаблон «Картридж»")
        if app.navigationBars["Шаблон"].waitForExistence(timeout: 4) {
            shot("template-cartridge")
            app.navigationBars["Шаблон"].buttons.element(boundBy: 0).tap()       // «назад» без сохранения
            pause(0.8)
        } else {
            XCTFail("Шаблоны: «Картридж» не открылся")
        }
        tapBarButton("Шаблоны", "Порядок")
        pause(0.8)
        shot("templates-order")
        tapBarButton("Шаблоны", "Готово")
        pause(0.5)
        tapBarButton("Шаблоны", "Новый шаблон")
        guard app.navigationBars["Новый шаблон"].waitForExistence(timeout: 4) else {
            XCTFail("Шаблоны: «+» не открыл новый шаблон")
            return
        }
        type("Например, Замятие бумаги", "Проверка связи")
        type("Описание проблемы", "Нет связи с филиалом")
        type("Что сделали", "Перезагрузил роутер")
        type("Чем закончилось", "Связь восстановлена")
        shot("template-new")
        tapBarButton("Новый шаблон", "Сохранить")
        pause(1)
        XCTAssertTrue(app.navigationBars["Шаблоны"].waitForExistence(timeout: 4),
                      "Шаблоны: после «Сохранить» не вернулись к списку")
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Проверка связи"))),
                        "Шаблоны: новый шаблон не появился сверху списка")
        shot("templates-added")
        tapBarButton("Шаблоны", "Закрыть")
        pause(1)

        // новый шаблон — в меню записи отчёта
        open("Отчёт")
        guard let add = checkAdd("Отчёт, свой шаблон"), tapAdd(add, opens: "Новая запись", "report") else { return }
        pickTemplate("Проверка связи")
        XCTAssertTrue(hasField("Перезагрузил роутер"), "Отчёт: свой шаблон не заполнил действия")
        shot("report-own-template")
        tapBarButton("Новая запись", "Отмена")
        pause(1)
    }

    private func carts() {
        open("Картриджи")
        shot("carts")
        guard let add = checkAdd("Картриджи"), tapAdd(add, opens: "Выдача", "carts") else { return }
        shot("carts-new")
        type("ФИО или часть имени", "Иванов")
        pause(0.8)
        shot("carts-hint")
        tapFirst(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Иванов Иван Петрович")),
                 "подсказка сотрудника из учёта")
        type("Модель, например 285", "285")
        tapBarButton("Выдача", "Сохранить")
        pause(0.7)
        shot("carts-toast")                                  // двухстрочная плашка: кому выдано и «Заявка добавлена в отчёт»
        let unknown = app.buttons["Записать на это имя"]
        if unknown.waitForExistence(timeout: 1.5) {
            XCTFail("Картриджи: сотрудник из учёта не узнан")
            unknown.tap()
        }
        pause(1.2)
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "285"))),
                        "Картриджи: выдача не появилась в списке")
        shot("carts-saved")
        open("Отчёт")
        XCTAssertNotNil(visible(app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Иванов Иван Петрович", "Принтер плохо печатает"))),
                        "Картриджи: выдача не добавила заявку в отчёт")
        shot("report-cart-entry")
    }

    /// Листание пальцем: страница и вкладка меняются, «+» появляется только где нужно.
    private func swipes() {
        open("Отчёт")
        for to in ["Картриджи", "Настройки"] {
            swipe(left: true)
            XCTAssertTrue(tab(to).isSelected, "свайп влево не открыл «\(to)»")
            checkAddIfNeeded(to, to + " после свайпа")
        }
        shot("swipe-settings")
        for to in ["Картриджи", "Отчёт", "Учёт", "Главная"] {
            swipe(left: false)
            XCTAssertTrue(tab(to).isSelected, "свайп вправо не открыл «\(to)»")
            checkAddIfNeeded(to, to + " после свайпа")
        }
        shot("swipe-home")
    }

    /// Быстрые кнопки и плитки главной.
    private func quick() {
        open("Главная")
        shot("home-data")
        for (button, sheet, page) in [("Запись", "Новая запись", "report"), ("Картридж", "Выдача", "carts")] {
            open("Главная")
            tapFirst(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", button)), "быстрая кнопка «\(button)»")
            if app.navigationBars[sheet].waitForExistence(timeout: 5) {
                shot("quick-" + page)
                tapBarButton(sheet, "Отмена")
            } else {
                XCTFail("Быстрая кнопка «\(button)» не открыла «\(sheet)»")
            }
            pause(1)
            XCTAssertTrue(tab(page == "report" ? "Отчёт" : "Картриджи").isSelected,
                          "быстрая кнопка «\(button)» не перешла на свою страницу")
        }

        open("Главная")
        tapFirst(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Найти")), "быстрая кнопка «Найти»")
        pause(1.5)
        dismissKeyboardTip()
        XCTAssertTrue(tab("Учёт").isSelected, "«Найти» не перешла на «Учёт»")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "«Найти» не открыла поиск с клавиатурой")
        // панель и «+» уходят за клавиатуру, а не висят над ней
        XCTAssertFalse(tab("Главная").isHittable, "нижняя панель вылезла над клавиатурой")
        XCTAssertNil(visible(app.buttons.matching(NSPredicate(format: "label == %@", "Добавить"))),
                     "«+» вылезла над клавиатурой")
        shot("quick-search")
        closeSearch()

        open("Главная")
        tapFirst(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Начальнику")), "быстрая кнопка «Начальнику»")
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {               // почта не настроена — должна быть понятная ошибка
            shot("quick-mail")
            alert.buttons.firstMatch.tap()
        } else {
            XCTFail("«Начальнику» без настроек почты не показала ошибку")
        }
        pause(1)
        XCTAssertTrue(tab("Отчёт").isSelected, "«Начальнику» не перешла на «Отчёт»")

        for (tile, page) in [("Сотрудники", "Учёт"), ("Картриджи ·", "Картриджи")] {
            open("Главная")
            tapFirst(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", tile)), "плитка «\(tile)»")
            pause(1.2)
            XCTAssertTrue(tab(page).isSelected, "плитка «\(tile)» не перешла на «\(page)»")
        }
    }

    private func settings() {
        open("Настройки")
        checkNoAdd("Настройки")
        shot("settings")
        for i in 2...6 {
            drag(fromY: 0.75, toY: 0.25)
            shot("settings-\(i)")
        }
        // самый низ настроек — последняя подпись — прокручивается выше панели
        let last = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "«Файлы»")).firstMatch
        if last.waitForExistence(timeout: 3) {
            XCTAssertLessThanOrEqual(last.frame.maxY, tab("Главная").frame.minY,
                                     "Настройки: конец страницы остаётся под панелью: \(last.frame)")
        } else {
            XCTFail("Настройки: нет последней подписи про бэкап")
        }
    }

    /// Длинный список: ещё 12 сотрудников, прокрутка до конца — последняя строка выше «+» и панели.
    private func longList() {
        open("Учёт")
        for i in 1...12 {
            let name = String(format: "Тестов %02ld", i)
            guard let add = checkAdd("Учёт, \(name)"), tapAdd(add, opens: "Новый сотрудник", "long") else { return }
            type("Фамилия", name)
            tapBarButton("Новый сотрудник", "Сохранить")
            let card = app.navigationBars[name]
            guard card.waitForExistence(timeout: 4) else {
                XCTFail("Учёт: карточка «\(name)» не сохранилась")
                return
            }
            card.buttons.element(boundBy: 0).tap()            // «назад» к списку
            pause(0.8)
        }
        for _ in 0..<4 { drag(fromY: 0.75, toY: 0.25) }
        shot("long-list-end")
        let s = screen
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Тестов")).allElementsBoundByIndex
            .filter { $0.exists && s.contains($0.frame) }
        guard let bottom = rows.max(by: { $0.frame.maxY < $1.frame.maxY }) else {
            XCTFail("Учёт: строк «Тестов» не видно")
            return
        }
        XCTAssertTrue(bottom.label.contains("Тестов 12"), "Учёт: внизу не последний сотрудник: \(bottom.label)")
        if let add = visible(app.buttons.matching(NSPredicate(format: "label == %@", "Добавить"))) {
            XCTAssertLessThanOrEqual(bottom.frame.maxY, add.frame.minY,
                                     "Учёт: последняя строка уходит под «+»: \(bottom.frame), «+» \(add.frame)")
        } else {
            XCTFail("Учёт: в конце длинного списка нет «+»")
        }
        XCTAssertLessThanOrEqual(bottom.frame.maxY, tab("Главная").frame.minY, "Учёт: последняя строка уходит под панель")
    }

    // ── проверки ────────────────────────────────────────────────────────────

    private var screen: CGRect { app.windows.firstMatch.frame }

    /// Вкладка нижней панели (кнопка с таким названием у нижнего края).
    private func tab(_ title: String) -> XCUIElement {
        let bottom = screen.maxY - 150
        return app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
            .first { $0.frame.minY > bottom } ?? app.buttons[title]
    }

    private func open(_ title: String) {
        hideKeyboard()                                       // при клавиатуре панель спрятана
        let t = tab(title)
        guard t.waitForExistence(timeout: 5), t.isHittable else {
            XCTFail("вкладка «\(title)» не нажимается")
            return
        }
        // медленный симулятор: первая страница строится долго, а первое касание после запуска иногда теряется
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: t)
        t.tap()
        if XCTWaiter.wait(for: [selected], timeout: 6) != .completed {
            t.tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: t)], timeout: 6)
        }
        pause(0.6)
        XCTAssertTrue(t.isSelected, "вкладка «\(title)» не выбралась")
    }

    /// Вся нижняя панель на экране.
    private func checkBar() {
        let s = screen
        for t in Self.tabs {
            let f = tab(t).frame
            XCTAssertTrue(s.contains(f), "вкладка «\(t)» не помещается на экране: \(f), экран \(s)")
        }
    }

    private func checkAddIfNeeded(_ tabTitle: String, _ page: String) {
        if Self.withAdd.contains(tabTitle) { checkAdd(page) } else { checkNoAdd(page) }
    }

    /// «+» видна целиком, стоит выше панели и нажимается.
    @discardableResult
    private func checkAdd(_ page: String) -> XCUIElement? {
        guard let add = visible(app.buttons.matching(NSPredicate(format: "label == %@", "Добавить"))) else {
            XCTFail("\(page): кнопки «+» нет на экране или она не нажимается")
            return nil
        }
        let f = add.frame, bar = tab("Главная").frame
        XCTAssertLessThanOrEqual(f.maxY, bar.minY - 4, "\(page): «+» заходит на нижнюю панель: \(f), панель \(bar)")
        XCTAssertTrue(screen.contains(f), "\(page): «+» не помещается на экране: \(f)")
        XCTAssertGreaterThanOrEqual(f.width, 44, "\(page): «+» слишком маленькая: \(f)")
        return add
    }

    private func checkNoAdd(_ page: String) {
        XCTAssertNil(visible(app.buttons.matching(NSPredicate(format: "label == %@", "Добавить"))),
                     "\(page): здесь не должно быть «+»")
    }

    /// Нажать «+» и дождаться формы. Не открылась — для разбора пробуем верхний край кнопки.
    private func tapAdd(_ add: XCUIElement, opens title: String, _ page: String) -> Bool {
        add.tap()
        if app.navigationBars[title].waitForExistence(timeout: 4) { return true }
        XCTFail("\(page): «+» не открыла «\(title)», кнопка \(add.frame)")
        shot(page + "-add-fail")
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let upper = app.navigationBars[title].waitForExistence(timeout: 3)
        print("РАЗБОР \(page): нажатие у верхнего края «+» — \(upper ? "сработало" : "тоже нет")")
        return upper
    }

    /// Первый элемент, который на этом экране и нажимается (остальные страницы живут рядом за краем).
    private func visible(_ q: XCUIElementQuery) -> XCUIElement? {
        let s = screen
        return q.allElementsBoundByIndex.first { $0.exists && $0.isHittable && s.contains($0.frame) }
    }

    // ── действия ────────────────────────────────────────────────────────────

    private func launch() {
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launchEnvironment["REPORTER_TEST_KEY"] = Self.testKey
        app.launch()
    }

    /// Листание страниц пальцем на 58% высоты: ниже переключателя темы и карточки недели.
    private func swipe(left: Bool) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.58))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0.58))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .fast, thenHoldForDuration: 0)
        pause(1.2)
    }

    private func drag(fromY: Double, toY: Double) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .fast, thenHoldForDuration: 0)
        pause(0.8)
    }

    /// Спрятать клавиатуру, если открыта: кнопкой «Готово» над ней или прокруткой.
    private func hideKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons["Готово"]
        if done.exists && done.isHittable { done.tap() } else { drag(fromY: 0.3, toY: 0.5) }
        pause(0.8)
    }

    /// Подсказка iOS «проведите по клавиатуре» при первом наборе — закрыть.
    private func dismissKeyboardTip() {
        for label in ["Continue", "Продолжить"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); pause(0.5); return }
        }
    }

    /// Выйти из поиска: крестик/«Отменить» у строки поиска, иначе спрятать клавиатуру прокруткой.
    private func closeSearch() {
        for label in ["Отменить", "Отмена", "Закрыть", "Cancel", "Close"] {
            let b = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
                .first { $0.isHittable && $0.frame.minY < 200 }
            if let b { b.tap(); pause(1); return }
        }
        drag(fromY: 0.35, toY: 0.6)
    }

    private func tapFirst(_ q: XCUIElementQuery, _ what: String) {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if let e = visible(q) { e.tap(); return }
            pause(0.3)
        } while Date() < deadline
        XCTFail("не нашлась \(what)")
    }

    private func tapBarButton(_ bar: String, _ button: String) {
        let b = app.navigationBars[bar].buttons[button]
        guard b.waitForExistence(timeout: 4) else {
            XCTFail("нет кнопки «\(button)» в «\(bar)»")
            return
        }
        b.tap()
    }

    /// Меню «Заполнить по шаблону» в записи отчёта: выбрать шаблон по названию.
    private func pickTemplate(_ name: String) {
        tapFirst(app.buttons.matching(NSPredicate(format: "label == %@", "Заполнить по шаблону")), "меню «Заполнить по шаблону»")
        pause(0.8)
        shot("template-menu")
        let q = app.buttons.matching(NSPredicate(format: "label == %@", name))
        if let b = visible(q) {
            b.tap()
        } else if q.firstMatch.waitForExistence(timeout: 3) {
            q.firstMatch.tap()                               // внизу длинного меню: XCUITest докрутит сам
        } else {
            XCTFail("нет шаблона «\(name)» в меню")
        }
        pause(0.8)
    }

    /// Есть поле ввода с таким текстом (у заполненного поля XCUITest не отдаёт подсказку — ищем по тексту).
    private func hasField(_ text: String) -> Bool {
        let p = NSPredicate(format: "value == %@", text)
        return app.textViews.matching(p).firstMatch.waitForExistence(timeout: 2)
            || app.textFields.matching(p).firstMatch.exists
    }

    /// Поле ввода по подписи; многострочные поля — textView, пароли — secureTextField.
    private func type(_ title: String, _ text: String) {
        let p = NSPredicate(format: "label == %@ OR placeholderValue == %@", title, title)
        let deadline = Date().addingTimeInterval(4)
        repeat {
            for q in [app.textFields, app.textViews, app.secureTextFields] {
                let f = q.matching(p).firstMatch
                if f.exists {
                    f.tap()
                    dismissKeyboardTip()
                    f.typeText(text)
                    return
                }
            }
            pause(0.3)
        } while Date() < deadline
        XCTFail("нет поля «\(title)»")
    }

    private func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    private func shot(_ title: String) {
        count += 1
        let s = XCUIScreen.main.screenshot()
        let file = String(format: "%@-%02ld-%@", name, count, title)
        try? s.pngRepresentation.write(to: Self.dir.appendingPathComponent(file + ".png"))
        let a = XCTAttachment(screenshot: s)
        a.name = file
        a.lifetime = .keepAlways
        test.add(a)
    }
}
