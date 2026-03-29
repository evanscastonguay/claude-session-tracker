import Foundation
import UserNotifications
import AppKit

@MainActor
final class AlertManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private var cooldowns: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 60

    /// Called when user clicks a notification — opens tracker and focuses the session
    var onNotificationTapped: ((String) -> Void)?

    override init() {
        super.init()
        requestNotificationPermission()
        UNUserNotificationCenter.current().delegate = self
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

    // MARK: - Notification Delegate (click handling)

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.identifier
            .replacingOccurrences(of: "claude-tracker-", with: "")

        Task { @MainActor in
            // Bring tracker to front and focus the session
            NSApp.activate(ignoringOtherApps: true)
            onNotificationTapped?(sessionId)
        }

        completionHandler()
    }

    // Show notifications even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Alert Dispatch

    func alertIfNeeded(session: SessionState, event: HookEvent) {
        let settings = LaunchSettings.load()

        // Check cooldown
        if let lastAlert = cooldowns[session.id],
           Date().timeIntervalSince(lastAlert) < cooldownInterval {
            return
        }

        let isCompletion = event.hookEventName == "Notification" || event.hookEventName == "Stop"
        guard isCompletion else { return }

        cooldowns[session.id] = Date()
        let sessionName = session.tmuxWindowName ?? session.projectName

        // 1. Sound
        if settings.soundEnabled {
            let sound = settings.notificationSound
            Task.detached {
                Shell.run("afplay \(sound.path)")
            }
        }

        // 2. Native notification (always — clickable to open tracker)
        let content = UNMutableNotificationContent()
        content.title = sessionName
        content.body = event.hookEventName == "Notification"
            ? "Waiting for your input"
            : "Turn complete — ready for next prompt"
        content.sound = .default
        content.categoryIdentifier = "SESSION_COMPLETE"

        let request = UNNotificationRequest(
            identifier: "claude-tracker-\(session.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)

        // 3. Dock bounce
        if settings.dockBounce {
            // Temporarily show in dock to enable bounce, then hide again
            NSApp.setActivationPolicy(.regular)
            NSApp.requestUserAttention(.criticalRequest)
            // Hide dock icon again after 5s
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !NSApp.isActive {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        // 4. Auto bring to front
        if settings.autoBringToFront {
            NSApp.activate(ignoringOtherApps: true)
            onNotificationTapped?(session.id)
        }
    }

    func clearCooldown(for sessionId: String) {
        cooldowns.removeValue(forKey: sessionId)
    }
}
