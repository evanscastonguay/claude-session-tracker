import SwiftUI

/// Shared state for cross-component communication
class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()
    @Published var pendingSessionFocus: String?
}

@main
struct ClaudeTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var coordinator = AppCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(sessionManager: sessionManager)
        } label: {
            Image(systemName: sessionManager.needsAttention
                ? "brain.head.profile.fill"
                : "brain.head.profile")
        }
        .menuBarExtraStyle(.menu)

        Window("Claude Tracker", id: "dashboard") {
            DashboardView(sessionManager: sessionManager)
                .frame(minWidth: 500, minHeight: 350)
                .onAppear {
                    consumePendingFocus(sessionManager: sessionManager)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: coordinator.pendingSessionFocus) {
                    consumePendingFocus(sessionManager: sessionManager)
                }
        }
        .defaultSize(width: 680, height: 520)
        .defaultPosition(.top)
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .handlesExternalEvents(matching: ["dashboard", "focus"])

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }

    private func consumePendingFocus(sessionManager: SessionManager) {
        if let id = coordinator.pendingSessionFocus {
            sessionManager.focusSessionRequest = id
            sessionManager.refreshSession(id)
            coordinator.pendingSessionFocus = nil
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Dashboard") {
            openDashboard()
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])

        Divider()

        let sessions = sessionManager.sessions
            .filter { $0.status != .ended && $0.tmuxWindow != nil }
            .sorted { $0.tabIndex < $1.tabIndex }

        ForEach(sessions) { session in
            let icon = session.needsAttention ? "circle.fill" : (session.status == .working ? "progress.indicator" : "circle")
            Button(action: {
                AppCoordinator.shared.pendingSessionFocus = session.id
                openDashboard()
            }) {
                Label("[\(session.tabIndex)] \(session.tmuxWindowName ?? session.projectName) \u{2014} \(session.statusSummary)", systemImage: icon)
            }
        }

        Divider()

        Button("Settings\u{2026}") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNotificationClick),
            name: .openSessionFromNotification,
            object: nil
        )
    }

    @objc func handleNotificationClick(_ notification: Notification) {
        if let sessionId = notification.userInfo?["sessionId"] as? String {
            AppCoordinator.shared.pendingSessionFocus = sessionId
        }

        // Open dashboard via URL scheme + activate once
        if let url = URL(string: "claudetracker://dashboard") {
            NSWorkspace.shared.open(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
