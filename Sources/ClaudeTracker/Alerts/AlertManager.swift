import Foundation
import UserNotifications
import AppKit

extension Notification.Name {
    static let openSessionFromNotification = Notification.Name("openSessionFromNotification")
}

@MainActor
final class AlertManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private var cooldowns: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 60

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - User clicks notification → open tracker

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.identifier
            .replacingOccurrences(of: "claude-tracker-", with: "")

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .openSessionFromNotification,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner but NO system sound — we play our own
        completionHandler([.banner])
    }

    // MARK: - Alert

    func alertIfNeeded(session: SessionState, event: HookEvent) {
        guard event.hookEventName == "Notification" else { return }

        if let lastAlert = cooldowns[session.id],
           Date().timeIntervalSince(lastAlert) < cooldownInterval { return }
        cooldowns[session.id] = Date()

        let settings = LaunchSettings.load()

        // Sound — ONLY our configured sound, no macOS default
        if settings.soundEnabled {
            let path = settings.notificationSound.path
            Task.detached { Shell.run("afplay '\(path)'") }
        }

        // Notification banner — no sound (we handle sound ourselves)
        let content = UNMutableNotificationContent()
        content.title = session.tmuxWindowName ?? session.projectName
        content.body = "Waiting for your input"
        // No content.sound — we play our own via afplay

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "claude-tracker-\(session.id)",
                content: content,
                trigger: nil
            )
        )

        // Dock bounce
        if settings.dockBounce {
            NSApp.setActivationPolicy(.regular)
            NSApp.requestUserAttention(.criticalRequest)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !NSApp.isActive {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
