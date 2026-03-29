import Foundation
import UserNotifications
import AppKit

@MainActor
final class AlertManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private var cooldowns: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 60

    /// Called to focus a session in the tracker window
    var onFocusSession: ((String) -> Void)?
    /// Called to switch to a session's tmux window in terminal
    var onSwitchToTerminal: ((SessionState) -> Void)?
    /// Lookup session by ID
    var getSession: ((String) -> SessionState?)?

    override init() {
        super.init()
        requestNotificationPermission()
        UNUserNotificationCenter.current().delegate = self
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    // MARK: - Notification Click → focus based on setting

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.identifier
            .replacingOccurrences(of: "claude-tracker-", with: "")

        Task { @MainActor in
            focusOnSession(sessionId: sessionId)
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

    // MARK: - Alert Dispatch

    func alertIfNeeded(session: SessionState, event: HookEvent) {
        guard event.hookEventName == "Notification" else { return }

        if let lastAlert = cooldowns[session.id],
           Date().timeIntervalSince(lastAlert) < cooldownInterval {
            return
        }
        cooldowns[session.id] = Date()

        let settings = LaunchSettings.load()

        // 1. Sound
        if settings.soundEnabled {
            let path = settings.notificationSound.path
            Task.detached {
                Shell.run("afplay '\(path)'")
            }
        }

        // 2. Notification
        let content = UNMutableNotificationContent()
        content.title = session.tmuxWindowName ?? session.projectName
        content.body = "Waiting for your input"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "claude-tracker-\(session.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)

        // 3. Dock bounce
        if settings.dockBounce {
            NSApp.setActivationPolicy(.regular)
            NSApp.requestUserAttention(.criticalRequest)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !NSApp.isActive {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        // 4. Auto-focus (when enabled, immediately brings focus without clicking notification)
        if settings.autoBringToFront {
            focusOnSession(sessionId: session.id)
        }
    }

    // MARK: - Focus

    /// Focus on a session — used by both notification click and auto-focus
    private func focusOnSession(sessionId: String) {
        let settings = LaunchSettings.load()

        switch settings.focusTarget {
        case .tracker:
            NSApp.activate(ignoringOtherApps: true)
            onFocusSession?(sessionId)
        case .terminal:
            if let session = getSession?(sessionId), let window = session.tmuxWindow {
                let terminalApp = settings.terminalApp.rawValue
                Task.detached {
                    Shell.run("tmux select-window -t \(window)")
                    Shell.run("open -a '\(terminalApp)'")
                }
            }
        case .none:
            // Still open tracker when clicking notification directly
            NSApp.activate(ignoringOtherApps: true)
            onFocusSession?(sessionId)
        }
    }

    func clearCooldown(for sessionId: String) {
        cooldowns.removeValue(forKey: sessionId)
    }
}
