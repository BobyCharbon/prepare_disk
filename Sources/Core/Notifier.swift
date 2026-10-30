import AppKit
import UserNotifications

/// Notifications macOS, sons et progression dans le Dock.
@MainActor
final class Notifier {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(_ title: String, _ body: String, isError: Bool = false, sound: Bool = false) {
        if sound { NSSound(named: isError ? "Basso" : "Glass")?.play() }
        guard settings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        if isError || sound { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Pourcentage affiché sur l'icône du Dock (nil pour l'effacer).
    func setDockProgress(_ progress: Double?) {
        NSApp.dockTile.badgeLabel = progress.map { "\(Int($0 * 100))%" }
    }
}
