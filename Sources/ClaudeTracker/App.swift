import SwiftUI

@main
struct ClaudeTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessionManager = SessionManager()
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
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openSessionFromNotification)) { notif in
                    if let sessionId = notif.userInfo?["sessionId"] as? String {
                        sessionManager.focusSessionRequest = sessionId
                        sessionManager.refreshSession(sessionId)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 680, height: 520)
        .defaultPosition(.top)
        .keyboardShortcut("b", modifiers: [.command, .shift])

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 400, height: 400)
        .windowResizability(.contentMinSize)
    }
}

struct MenuBarContent: View {
    @ObservedObject var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Dashboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])

        Divider()

        let sessions = sessionManager.sessions
            .filter { $0.status != .ended && $0.tmuxWindow != nil }
            .sorted { $0.tabIndex < $1.tabIndex }

        ForEach(sessions) { session in
            let icon = session.needsAttention ? "circle.fill" : (session.status == .working ? "progress.indicator" : "circle")
            Button(action: {
                sessionManager.focusSessionRequest = session.id
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
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
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
