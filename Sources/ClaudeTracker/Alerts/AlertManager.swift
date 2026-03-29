import Foundation
import UserNotifications
import AppKit

/// Notification name posted when user clicks a macOS notification banner
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

    // MARK: - User clicks notification banner → open tracker

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.identifier
            .replacingOccurrences(of: "claude-tracker-", with: "")

        // Post notification — the App scene picks this up to open the window
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
        completionHandler([.banner, .sound])
    }

    // MARK: - Alert

    func alertIfNeeded(session: SessionState, event: HookEvent) {
        guard event.hookEventName == "Notification" else { return }

        if let lastAlert = cooldowns[session.id],
           Date().timeIntervalSince(lastAlert) < cooldownInterval { return }
        cooldowns[session.id] = Date()

        let settings = LaunchSettings.load()

        // Sound
        if settings.soundEnabled {
            let path = settings.notificationSound.path
            Task.detached { Shell.run("afplay '\(path)'") }
        }

        // macOS notification — user clicks it to open tracker
        let content = UNMutableNotificationContent()
        content.title = session.tmuxWindowName ?? session.projectName
        content.body = "Waiting for your input"
        content.sound = .default

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
