import Foundation
import UserNotifications
import AppKit

@MainActor
final class AlertManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private var cooldowns: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 60
    @Published var isLooping = false

    var onNotificationTapped: ((String) -> Void)?

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

    // MARK: - Notification Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.identifier
            .replacingOccurrences(of: "claude-tracker-", with: "")
        Task { @MainActor in
            stopLoop()
            NSApp.activate(ignoringOtherApps: true)
            onNotificationTapped?(sessionId)
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
        let settings = LaunchSettings.load()

        let isCompletion = event.hookEventName == "Notification" || event.hookEventName == "Stop"
        guard isCompletion else { return }

        // Check cooldown
        if let lastAlert = cooldowns[session.id],
           Date().timeIntervalSince(lastAlert) < cooldownInterval {
            return
        }
        cooldowns[session.id] = Date()

        // 1. Sound
        if settings.soundEnabled {
            if settings.loopSound {
                startLoop(sound: settings.notificationSound)
            } else {
                playOnce(sound: settings.notificationSound)
            }
        }

        // 2. Notification
        let content = UNMutableNotificationContent()
        content.title = session.tmuxWindowName ?? session.projectName
        content.body = event.hookEventName == "Notification"
            ? "Waiting for your input"
            : "Turn complete"
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

        // 4. Focus
        if settings.autoBringToFront {
            switch settings.focusTarget {
            case .tracker:
                NSApp.activate(ignoringOtherApps: true)
                onNotificationTapped?(session.id)
            case .terminal:
                let terminalApp = settings.terminalApp.rawValue
                if let window = session.tmuxWindow {
                    Task.detached {
                        Shell.run("tmux select-window -t \(window)")
                        Shell.run("open -a '\(terminalApp)'")
                    }
                }
            case .none:
                break
            }
        }
    }

    // MARK: - Sound Loop

    private func playOnce(sound: LaunchSettings.NotificationSound) {
        Task.detached {
            Shell.run("afplay '\(sound.path)'")
        }
    }

    private func startLoop(sound: LaunchSettings.NotificationSound) {
        isLooping = true
        let path = sound.path
        Task.detached { [weak self] in
            while true {
                // Check flag on main actor
                let shouldContinue = await MainActor.run { self?.isLooping ?? false }
                guard shouldContinue else { break }

                // Play sound (blocks ~1s)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                process.arguments = [path]
                try? process.run()
                process.waitUntilExit()

                // Wait between loops
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Stop loop — kills any playing sound immediately
    func stopLoop() {
        guard isLooping else { return }
        isLooping = false
        // Kill any running afplay processes started by us
        Task.detached {
            Shell.run("pkill -f 'afplay.*Library/Sounds' 2>/dev/null")
        }
    }

    func acknowledge(sessionId: String) {
        stopLoop()
        cooldowns.removeValue(forKey: sessionId)
    }
}
