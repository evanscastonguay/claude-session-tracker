import Foundation
import UserNotifications
import AppKit

@MainActor
final class AlertManager: ObservableObject {
    @Published var soundEnabled = true
    @Published var notificationsEnabled = true

    private var cooldowns: [String: Date] = [:]  // sessionId -> last alert time
    private let cooldownInterval: TimeInterval = 60

    init() {
        requestNotificationPermission()
    }

    // MARK: - Permission

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                print("[AlertManager] Permission error: \(error)")
            }
            print("[AlertManager] Notifications permission: \(granted)")
        }
    }

    // MARK: - Alert Dispatch

    func alertIfNeeded(session: SessionState, event: HookEvent) {
        let sessionId = session.id

        // Check cooldown
        if let lastAlert = cooldowns[sessionId],
           Date().timeIntervalSince(lastAlert) < cooldownInterval {
            return
        }

        switch event.hookEventName {
        case "Notification":
            // Claude is waiting for user input
            sendAlert(
                session: session,
                title: "Needs Input",
                body: session.lastUserPrompt.map { "Last: \($0)" } ?? "Session waiting for your input",
                sound: .glass,
                urgency: .attention
            )

        case "Stop":
            // Turn complete — only alert if it was working before
            if session.status == .working || session.status == .idle {
                sendAlert(
                    session: session,
                    title: "Turn Complete",
                    body: session.lastToolName.map { "Last tool: \($0)" } ?? "Ready for next prompt",
                    sound: .hero,
                    urgency: .info
                )
            }

        default:
            break
        }
    }

    // MARK: - Alert Sending

    private enum AlertSound: String {
        case glass = "/System/Library/Sounds/Glass.aiff"
        case hero = "/System/Library/Sounds/Hero.aiff"
        case ping = "/System/Library/Sounds/Ping.aiff"
        case basso = "/System/Library/Sounds/Basso.aiff"
    }

    private enum AlertUrgency {
        case info
        case attention
        case error
    }

    private func sendAlert(session: SessionState, title: String, body: String, sound: AlertSound, urgency: AlertUrgency) {
        cooldowns[session.id] = Date()

        // Native notification
        if notificationsEnabled {
            sendNotification(session: session, title: title, body: body, sound: sound)
        }

        // Audio
        if soundEnabled {
            playSound(sound)
        }
    }

    private func sendNotification(session: SessionState, title: String, body: String, sound: AlertSound) {
        let content = UNMutableNotificationContent()
        content.title = "Claude — \(session.projectName)"
        content.subtitle = title
        content.body = body
        content.sound = .default

        // Use session ID as identifier to replace stale notifications
        let request = UNNotificationRequest(
            identifier: "claude-tracker-\(session.id)",
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[AlertManager] Notification error: \(error)")
            }
        }
    }

    private func playSound(_ sound: AlertSound) {
        Task.detached {
            Shell.run("afplay \(sound.rawValue)")
        }
    }

    // MARK: - Cooldown Management

    func clearCooldown(for sessionId: String) {
        cooldowns.removeValue(forKey: sessionId)
    }

    func clearAllCooldowns() {
        cooldowns.removeAll()
    }
}
