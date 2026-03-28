import SwiftUI

struct DashboardView: View {
    @ObservedObject var sessionManager: SessionManager
    @State private var focusedSessionId: String?
    @State private var responseText: String = ""
    @FocusState private var isInputFocused: Bool

    private var sortedSessions: [SessionState] {
        sessionManager.sessions
            .filter { $0.status != .ended }
            .sorted { $0.tabIndex < $1.tabIndex }
    }

    private var focusedSession: SessionState? {
        if let id = focusedSessionId,
           let s = sortedSessions.first(where: { $0.id == id }) {
            return s
        }
        if let needy = sortedSessions
            .filter({ $0.needsAttention })
            .sorted(by: { $0.statusChangedAt < $1.statusChangedAt })
            .first {
            return needy
        }
        return sortedSessions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if sortedSessions.isEmpty {
                emptyView
            } else {
                // Tab bar
                tabBar

                Divider()

                // Main content
                if let session = focusedSession {
                    conversationView(session)

                    Divider()

                    // Input area
                    inputArea(session)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(sortedSessions) { session in
                tabItem(session)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func tabItem(_ session: SessionState) -> some View {
        let isFocused = focusedSession?.id == session.id
        let color = dotColor(session)

        return Button(action: {
            focusedSessionId = session.id
            responseText = ""
        }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .overlay(
                        session.status == .working
                            ? Circle().stroke(color.opacity(0.3), lineWidth: 2).frame(width: 12, height: 12)
                            : nil
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text("[\(session.tabIndex)] \(session.tmuxWindowName ?? session.projectName)")
                        .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                        .lineLimit(1)
                    if !isFocused {
                        Text(session.statusSummary)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isFocused ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Conversation View

    private func conversationView(_ session: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header
            HStack {
                Text(session.tmuxWindowName ?? session.projectName)
                    .font(.system(size: 14, weight: .medium))
                Text(session.projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
                statusBadge(session)
                if let ctx = session.contextPercent {
                    Text("\(ctx)%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ctx > 80 ? .orange : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Scrollable conversation area
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Your prompt
                    if let prompt = session.lastUserPrompt {
                        MessageBubble(
                            role: "You",
                            content: prompt,
                            style: .user
                        )
                    }

                    // Claude's response
                    if let response = session.lastResponse, !response.isEmpty {
                        MessageBubble(
                            role: "Claude",
                            content: response,
                            style: .assistant
                        )
                    } else if session.status == .working {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(session.currentActivity)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                    } else if session.lastResponse == nil {
                        Text(session.currentActivity)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Input Area

    private func inputArea(_ session: SessionState) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Type your response\u{2026}", text: $responseText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($isInputFocused)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.command) {
                        sendResponse(to: session)
                    }
                }

            Button(action: { sendResponse(to: session) }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(responseText.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(responseText.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send response (Cmd+Return)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func sendResponse(to session: SessionState) {
        let text = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let window = session.tmuxWindow else { return }

        // Send via tmux send-keys
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
            .replacingOccurrences(of: "\"", with: "\\\"")

        Task.detached {
            // Send the text to the tmux pane
            Shell.run("tmux send-keys -t \(window).0 '\(escaped)' Enter")
        }

        // Clear and switch
        responseText = ""
        sessionManager.switchToSession(session)
    }

    // MARK: - Helpers

    private func dotColor(_ session: SessionState) -> Color {
        if session.needsAttention { return .orange }
        switch session.status {
        case .working: return .blue
        case .idle: return .green.opacity(0.7)
        case .waitingForInput: return .orange
        case .error: return .red
        case .ended: return .gray
        }
    }

    private func statusBadge(_ session: SessionState) -> some View {
        let (text, color) = statusData(session)
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.08))
            .clipShape(Capsule())
    }

    private func statusData(_ session: SessionState) -> (String, Color) {
        if session.needsAttention { return ("Ready", .orange) }
        switch session.status {
        case .working: return (session.spinnerDuration.map { "Working \($0)" } ?? "Working", .blue)
        case .idle: return ("Idle", .green.opacity(0.7))
        case .waitingForInput: return ("Waiting", .orange)
        case .error: return ("Error", .red)
        case .ended: return ("Ended", .gray)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("No active sessions")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Text("Start Claude Code in a terminal to begin")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
            Spacer()
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let role: String
    let content: String
    let style: MessageStyle

    enum MessageStyle {
        case user, assistant
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            Text(content)
                .font(.system(size: style == .user ? 12 : 13))
                .foregroundStyle(style == .user ? Color.secondary : Color.primary.opacity(0.85))
                .lineSpacing(style == .assistant ? 3 : 1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    style == .user
                        ? Color.accentColor.opacity(0.06)
                        : Color(nsColor: .controlBackgroundColor)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 16)
    }
}
