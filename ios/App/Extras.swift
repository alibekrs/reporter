import QuickLook
import SwiftUI
import UserNotifications

// ── просмотр отчёта ─────────────────────────────────────────────────────────
struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Готовый Word-отчёт на экране: проверить перед отправкой и передать куда угодно через «Поделиться».
struct ReportPreview: View {
    let file: PreviewFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FilePreview(url: file.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Просмотр отчёта")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: file.url) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    }
                }
        }
    }
}

/// Системный просмотр файла (Quick Look) внутри нашего листа — со своими «Закрыть» и «Поделиться».
private struct FilePreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Source { Source(url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {}

    final class Source: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(_ url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// ── напоминание в пятницу ───────────────────────────────────────────────────
/// «Пора отправить отчёт» по пятницам в 16:00. На каждую ближайшую пятницу — своё уведомление: так его
/// можно не ставить на неделю, за которую отчёт уже ушёл.
enum Reminder {
    static let onKey = "reminder.on"
    private static let sentKey = "reminder.sentWeek"

    /// Спросить разрешение на уведомления. false — пользователь запретил.
    static func allow() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Отчёт за неделю ушёл начальнику — напоминать о нём не нужно.
    static func sent(_ monday: Date) {
        let d = UserDefaults.standard, week = Dates.text(monday)
        if week > (d.string(forKey: sentKey) ?? "") { d.set(week, forKey: sentKey) }
        refresh()
    }

    /// Пересобрать напоминания на шесть недель вперёд. Зовётся при открытии приложения, при переключении
    /// напоминания и после отправки отчёта.
    static func refresh() {
        let center = UNUserNotificationCenter.current(), d = UserDefaults.standard
        center.removeAllPendingNotificationRequests()
        guard d.bool(forKey: onKey) else { return }
        let cal = Calendar(identifier: .gregorian), sent = d.string(forKey: sentKey) ?? ""
        var monday = Dates.monday(Date())
        for _ in 0..<6 {
            let week = Dates.text(monday)
            let fire = cal.date(byAdding: DateComponents(day: 4, hour: 16), to: monday) ?? monday
            monday = cal.date(byAdding: .day, value: 7, to: monday) ?? monday
            guard week > sent, fire > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Пора отправить отчёт"
            content.body = "Пятница: отчёт за неделю ещё не ушёл начальнику."
            content.sound = .default
            var when = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            when.calendar = cal
            center.add(UNNotificationRequest(identifier: "friday-" + week, content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }
}

// ── быстрые действия с иконки ───────────────────────────────────────────────
/// Долгое нажатие на иконку приложения: «Новая запись», «Выдать картридж», «Найти сотрудника»,
/// «Отправить отчёт» (список — в project.yml). Действие приходит в делегат сцены, главный экран его забирает.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // приложение открыли действием с иконки: запоминаем уже здесь — главный экран стартует без заставки
        if let item = options.shortcutItem { SceneDelegate.pending = item.type }
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Действие, которое ещё не выполнено: приложение могли открыть им с нуля, когда экрана ещё нет.
    static var pending: String?
    static let arrived = Notification.Name("reporter.shortcut")

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem { Self.pending = item.type }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Self.pending = shortcutItem.type
        NotificationCenter.default.post(name: Self.arrived, object: nil)
        completionHandler(true)
    }
}
