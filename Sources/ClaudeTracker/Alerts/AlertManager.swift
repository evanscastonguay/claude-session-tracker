import Foundation
import UserNotifications
import AppKit

@MainActor
final class AlertManager: ObservableObject {
    private var cooldowns: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 60

    init() {
        requestNotificationPermission()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                print("[AlertManager] Permission error: \(error)")
            }
        }
    }

    // MARK: - Alert Dispatch

    func alertIfNeeded(session: SessionState, event: HookEvent) {
        let settings = LaunchSettings.load()
        guard settings.soundEnabled else { return }

        // Check cooldown
        if let lastAlert = cooldowns[session.id],
           Date().timeIntervalSince(lastAlert) < cooldownInterval {
            return
        }

        switch event.hookEventName {
        case "Notification":
            sendAlert(
                session: session,
                title: "Needs Input",
                body: session.lastUserPrompt.map { "Last: \($0)" } ?? "Waiting for your input",
                sound: settings.notificationSound
            )

        case "Stop":
            sendAlert(
                session: session,
                title: "Turn Complete",
                body: session.lastToolName.map { "Last tool: \($0)" } ?? "Ready for next prompt",
                sound: settings.notificationSound
            )

        default:
            break
        }
    }

    // MARK: - Alert Sending

    private func sendAlert(session: SessionState, title: String, body: String, sound: LaunchSettings.NotificationSound) {
        cooldowns[session.id] = Date()

        // Native notification
        let content = UNMutableNotificationContent()
        content.title = "Claude \u{2014} \(session.tmuxWindowName ?? session.projectName)"
        content.subtitle = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claude-tracker-\(session.id)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)

        // Play configured sound
        Task.detached {
            Shell.run("afplay \(sound.path)")
        }
    }

    func clearCooldown(for sessionId: String) {
        cooldowns.removeValue(forKey: sessionId)
    }
}
