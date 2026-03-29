import SwiftUI

struct DashboardView: View {
    @ObservedObject var sessionManager: SessionManager
    @State private var focusedSessionId: String?
    @State private var drafts: [String: String] = [:]
    @State private var showingNewSession = false
    @FocusState private var isInputFocused: Bool

    private func draftBinding(for sessionId: String) -> Binding<String> {
        Binding(
            get: { drafts[sessionId] ?? "" },
            set: { drafts[sessionId] = $0 }
        )
    }

    private var sortedSessions: [SessionState] {
        sessionManager.sessions
            .filter { $0.status != .ended && $0.tmuxWindow != nil }
            .sorted { $0.tabIndex < $1.tabIndex }
    }

    private var focusedSession: SessionState? {
        if let id = focusedSessionId,
           let s = sortedSessions.first(where: { $0.id == id }) { return s }
        if let needy = sortedSessions
            .filter({ $0.needsAttention })
            .sorted(by: { $0.statusChangedAt < $1.statusChangedAt })
            .first { return needy }
        return sortedSessions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if sortedSessions.isEmpty {
                emptyView
            } else {
                tabBar
                if let session = focusedSession {
                    Divider()
                    focusedPanel(session)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: sessionManager.focusSessionRequest) {
            if let id = sessionManager.focusSessionRequest {
                focusedSessionId = id
                sessionManager.focusSessionRequest = nil
                isInputFocused = true
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(sortedSessions) { session in
                SessionTab(
                    session: session,
                    isFocused: focusedSession?.id == session.id,
                    onTap: { focusedSessionId = session.id },
                    onRename: { name in
                        sessionManager.renameSession(session.id, to: name)
                    }
                )
            }

            Button(action: { showingNewSession = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("New Claude session")
            .fileImporter(
                isPresented: $showingNewSession,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let newId = sessionManager.launchNewSession(
                        directory: url.path, name: nil
                    )
                    focusedSessionId = newId
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - Focused Panel

    private func focusedPanel(_ session: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // Header: name + status
                HStack {
                    Text(session.tmuxWindowName ?? session.projectName)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    statusLabel(session)
                }

                // Problem statement
                if let problem = session.problemStatement {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                Divider()

                // Last exchange
                if let prompt = session.lastUserPrompt {
                    HStack(alignment: .top, spacing: 0) {
                        Text("You: ")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(prompt)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }

                if session.status == .working {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Working \(session.timeSinceStatusChange)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if let response = session.lastResponse {
                    let lines = response.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let summary = lines.prefix(3).joined(separator: " ")
                    if !summary.isEmpty {
                        HStack(alignment: .top, spacing: 0) {
                            Text("Claude: ")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(String(summary.prefix(300)))
                                .font(.system(size: 12))
                                .foregroundStyle(.primary.opacity(0.8))
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }

                // Question
                if let question = session.claudeQuestion {
                    HStack(spacing: 5) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        Text(question)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Action + metadata
                HStack {
                    if session.tmuxWindow != nil {
                        Button(action: { sessionManager.switchToSession(session) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("Open Terminal")
                            }
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }

                // Metadata
                HStack(spacing: 8) {
                    Text(session.projectName)
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                    if let branch = session.gitBranch, branch != "HEAD" {
                        Text(branch)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.quaternary)
                    }
                    if let ctx = session.contextPercent {
                        Text("\(ctx)% context")
                            .font(.system(size: 10))
                            .foregroundStyle(ctx > 80 ? Color.orange : Color.gray.opacity(0.5))
                    }
                    if session.turnCount > 0 {
                        Text("\(session.turnCount) turns")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .padding(14)

            Spacer(minLength: 0)

            Divider()
            inputBar(session)
        }
    }

    @ViewBuilder
    private func statusLabel(_ session: SessionState) -> some View {
        if session.status == .working {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(session.timeSinceStatusChange)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else if session.needsAttention {
            Text(session.timeSinceStatusChange)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
        } else {
            Text("Idle \(session.timeSinceStatusChange)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Input Bar

    private func inputBar(_ session: SessionState) -> some View {
        let draft = draftBinding(for: session.id)

        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Quick reply\u{2026}", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...3)
                .focused($isInputFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .onKeyPress(.return, phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) { return .ignored }
                    sendResponse(to: session)
                    return .handled
                }

            Button(action: { sendResponse(to: session) }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(draft.wrappedValue.isEmpty ? Color.secondary.opacity(0.3) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.wrappedValue.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func sendResponse(to session: SessionState) {
        let text = (drafts[session.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let window = session.tmuxWindow else { return }

        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")

        Task.detached {
            Shell.run("tmux send-keys -t \(window).0 '\(escaped)' Enter")
        }

        drafts[session.id] = ""
        if let idx = sessionManager.sessions.firstIndex(where: { $0.id == session.id }) {
            sessionManager.sessions[idx].needsAttention = false
            sessionManager.sessions[idx].status = .working
            sessionManager.sessions[idx].lastUserPrompt = text
            sessionManager.sessions[idx].statusChangedAt = Date()
            sessionManager.sessions[idx].lastSentAt = Date()
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("No sessions")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
