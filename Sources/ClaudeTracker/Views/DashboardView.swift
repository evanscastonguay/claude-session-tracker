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
                    contentArea(session)
                    Divider()
                    inputBar(session)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: sessionManager.focusSessionRequest) {
            if let id = sessionManager.focusSessionRequest {
                focusedSessionId = id
                sessionManager.refreshSession(id)
                sessionManager.focusSessionRequest = nil
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
                    onTap: {
                        focusedSessionId = session.id
                        sessionManager.refreshSession(session.id)
                    },
                    onRename: { name in
                        sessionManager.renameSession(session.id, to: name)
                    }
                )
            }

            // New session button
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
                        directory: url.path,
                        name: nil
                    )
                    focusedSessionId = newId
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - Content Area

    private func contentArea(_ session: SessionState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {

                // Everything as one selectable text block
                if session.status == .working {
                    if !conversationText(session).characters.isEmpty {
                        Text(conversationText(session))
                            .font(.system(size: 12.5))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                            .controlSize(.regular)
                        Text("Claude is working\u{2026}")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(session.timeSinceStatusChange)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(conversationText(session))
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Input Bar

    private func inputBar(_ session: SessionState) -> some View {
        let draft = draftBinding(for: session.id)

        return HStack(alignment: .bottom, spacing: 8) {
            Button(action: { sessionManager.switchToSession(session) }) {
                Image(systemName: "arrow.forward.square")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Switch to Tab \(session.tabIndex) in Ghostty")

TextField("Reply\u{2026}", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
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
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored
                    }
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

    /// Send text to the session's tmux pane without switching focus
    private func sendResponse(to session: SessionState) {
        let text = (drafts[session.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let window = session.tmuxWindow else { return }

        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")

        let sessionId = session.id

        Task.detached {
            Shell.run("tmux send-keys -t \(window).0 '\(escaped)' Enter")
        }

        drafts[session.id] = ""
        // Update state: set working, clear attention, store what we sent as lastUserPrompt
        // Set lastSentAt to prevent discovery from overriding working status for 30s
        if let idx = sessionManager.sessions.firstIndex(where: { $0.id == sessionId }) {
            sessionManager.sessions[idx].needsAttention = false
            sessionManager.sessions[idx].status = .working
            sessionManager.sessions[idx].lastUserPrompt = text
            sessionManager.sessions[idx].lastResponse = nil
            sessionManager.sessions[idx].statusChangedAt = Date()
            sessionManager.sessions[idx].lastSentAt = Date()
        }

        // Poll JSONL for Claude's response after a delay
        sessionManager.scheduleContextRefresh(for: sessionId, delay: 8)
    }

    // MARK: - Empty

    // MARK: - Conversation Text Builder

    private func conversationText(_ session: SessionState) -> AttributedString {
        var result = AttributedString()

        // Problem statement removed from conversation text — shown in header instead

        // Build exchanges list
        let exchanges: [Exchange]
        if !session.recentExchanges.isEmpty {
            exchanges = session.recentExchanges
        } else if let prompt = session.lastUserPrompt {
            exchanges = [Exchange(
                userPrompt: prompt,
                assistantResponse: session.lastResponse ?? ""
            )]
        } else {
            return result
        }

        for (i, exchange) in exchanges.enumerated() {
            let isLatest = (i == exchanges.count - 1)

            // "You:" label
            var youLabel = AttributedString("You: ")
            youLabel.foregroundColor = NSColor.controlAccentColor.withAlphaComponent(0.7)
            youLabel.font = .system(size: isLatest ? 12.5 : 11, weight: .semibold)
            result.append(youLabel)

            // Prompt
            let promptStr = isLatest ? exchange.userPrompt : String(exchange.userPrompt.prefix(150))
            var promptText = AttributedString(promptStr)
            promptText.foregroundColor = isLatest ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
            promptText.font = .system(size: isLatest ? 12.5 : 11)
            result.append(promptText)

            result.append(AttributedString("\n\n"))

            // "Claude:" label
            var claudeLabel = AttributedString("Claude: ")
            claudeLabel.foregroundColor = NSColor.secondaryLabelColor
            claudeLabel.font = .system(size: isLatest ? 13 : 11, weight: .semibold)
            result.append(claudeLabel)

            // Response
            let responseStr = isLatest
                ? exchange.assistantResponse
                : String(exchange.assistantResponse.prefix(200))
            var response = AttributedString(responseStr)
            response.foregroundColor = isLatest ? NSColor.labelColor.withAlphaComponent(0.85) : NSColor.tertiaryLabelColor
            response.font = .system(size: isLatest ? 13 : 11)
            result.append(response)

            // Separator
            if !isLatest {
                var sep = AttributedString("\n\n\u{2500}\u{2500}\u{2500}\n\n")
                sep.foregroundColor = NSColor.separatorColor
                sep.font = .system(size: 9)
                result.append(sep)
            }
        }

        // Append current unpaired prompt if working (user just typed, Claude hasn't responded yet)
        if session.status == .working,
           let currentPrompt = session.lastUserPrompt,
           exchanges.last?.userPrompt != currentPrompt {
            var sep = AttributedString("\n\n\u{2500}\u{2500}\u{2500}\n\n")
            sep.foregroundColor = NSColor.separatorColor
            sep.font = .system(size: 9)
            result.append(sep)

            var youLabel = AttributedString("You: ")
            youLabel.foregroundColor = NSColor.controlAccentColor.withAlphaComponent(0.7)
            youLabel.font = .system(size: 12.5, weight: .semibold)
            result.append(youLabel)

            var promptText = AttributedString(currentPrompt)
            promptText.foregroundColor = NSColor.secondaryLabelColor
            promptText.font = .system(size: 12.5)
            result.append(promptText)
        }

        return result
    }

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
