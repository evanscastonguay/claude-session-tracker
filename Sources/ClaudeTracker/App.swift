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
    @Environment(\.openWindow) private var openWindow

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
                    // When window appears, check if there's a pending focus request
                    if let sessionId = coordinator.pendingSessionFocus {
                        sessionManager.focusSessionRequest = sessionId
                        sessionManager.refreshSession(sessionId)
                        coordinator.pendingSessionFocus = nil
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: coordinator.pendingSessionFocus) {
                    // Handle focus requests that arrive while window is already open
                    if let sessionId = coordinator.pendingSessionFocus {
                        sessionManager.focusSessionRequest = sessionId
                        sessionManager.refreshSession(sessionId)
                        coordinator.pendingSessionFocus = nil
                    }
                }
        }
        .defaultSize(width: 680, height: 520)
        .defaultPosition(.top)
        .keyboardShortcut("b", modifiers: [.command, .shift])

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
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

        // Listen for notification clicks
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNotificationClick),
            name: .openSessionFromNotification,
            object: nil
        )
    }

    @objc func handleNotificationClick(_ notification: Notification) {
        let sessionId = notification.userInfo?["sessionId"] as? String

        // 1. Set the pending focus (will be picked up by window onAppear or onChange)
        if let sessionId = sessionId {
            AppCoordinator.shared.pendingSessionFocus = sessionId
        }

        // 2. Show dock icon so we can activate
        NSApp.setActivationPolicy(.regular)

        // 3. Activate the app
        NSApp.activate(ignoringOtherApps: true)

        // 4. Find existing dashboard window or it will be created by SwiftUI
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Try to find the window
            let dashboardWindow = NSApp.windows.first(where: {
                $0.title.contains("Claude Tracker") ||
                $0.identifier?.rawValue.contains("dashboard") == true
            })

            if let window = dashboardWindow {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }

            // 5. Re-activate to ensure focus
            NSApp.activate(ignoringOtherApps: true)

            // 6. Hide dock icon after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.setActivationPolicy(.accessory)
                // Re-activate after policy change to keep window focused
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}
