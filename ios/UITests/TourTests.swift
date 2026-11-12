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

    /// Вход по Face ID: в симуляторе нет ни Face ID, ни кода-пароля — приложение объясняет, почему не включить.
    private func security() {
        tidy()
        open("Настройки")
        guard let toggle = reveal(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Вход по Face ID")),
                                  fromTop: true, tries: 10) else {
            XCTFail("Настройки: нет переключателя «Вход по Face ID»")
            return
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            shot("faceid-unavailable")
            alert.buttons.firstMatch.tap()
        } else {
            // в симуляторе оказался код-пароль: системное окно проверки — отменяем, переключатель не должен включиться
            print("РАЗБОР Face ID: окна «не настроено» нет — отменяем системную проверку")
            shot("faceid-prompt")
            let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for label in ["Cancel", "Отменить", "Отмена"] where board.buttons[label].exists {
                board.buttons[label].tap()
                break
            }
        }
        pause(1)
        XCTAssertEqual(toggle.value as? String, "0", "Защита: вход по Face ID включился без проверки")
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
        encrypt.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        pause(0.8)
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
        // и жмём по координате — без нового поиска и без обрыва теста, если плашка уже ушла. Что запись пропала,
        // видно на снимке
        let spot = back.frame
        shot("undo-toast")
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
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Разрешить"] {                // запрос показывает система, язык у неё свой
            let allow = board.buttons[label]
            if allow.waitForExistence(timeout: 3) { allow.tap(); break }
        }
        pause(1.5)
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
        pause(6)                                             // заставка доигрывает
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
