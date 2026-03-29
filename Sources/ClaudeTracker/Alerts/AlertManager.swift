import Foundation
import UserNotifications
import AppKit

extension Notification.Name {
    static let openSessionFromNotification = Notification.Name("openSessionFromNotification")
}

@MainActor
final class AlertManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    override init() {
        super.init()
        // Still register as delegate for when UNNotifications DO work (clicking them)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Notification click handler

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
        completionHandler([.banner, .list])
    }

    // MARK: - Alert

    func alertIfNeeded(session: SessionState, event: HookEvent) {
        guard event.hookEventName == "Notification" else { return }

        let settings = LaunchSettings.load()
        let title = "[\(session.tabIndex)] \(session.tmuxWindowName ?? session.projectName)"

        // Build body
        let body: String
        if let question = session.claudeQuestion {
            body = question
        } else if let response = session.lastResponse {
            let firstLine = response.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? "Turn complete"
            body = String(firstLine.prefix(150))
        } else if let task = session.currentTask {
            body = "Done: \(String(task.prefix(120)))"
        } else {
            body = "Waiting for your input"
        }

        // 1. Sound via afplay (always works)
        if settings.soundEnabled {
            let path = settings.notificationSound.path
            Task.detached { Shell.run("afplay '\(path)'") }
        }

        // 2. Clickable notification via UNUserNotification
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let requestId = "claude-tracker-\(session.id)-\(Int(Date().timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: requestId, content: content, trigger: nil)
        )
    }
}
