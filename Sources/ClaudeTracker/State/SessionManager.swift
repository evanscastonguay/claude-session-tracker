import SwiftUI
import Combine

@MainActor
final class SessionManager: ObservableObject {
    @Published var sessions: [SessionState] = []
    @Published var needsAttention: Bool = false
    @Published var eventLog: [String] = []

    let alertManager = AlertManager()
    private let server = HTTPServer(port: 7429)
    private var discoveryTimer: Timer?
    private var saveTimer: Timer?
    private var pendingSave = false

    private let stateFileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-tracker")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    init() {
        loadState()
        startServer()
        startDiscovery()
    }

    // MARK: - Server

    private func startServer() {
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }
        do {
            try server.start()
            log("Server started on localhost:7429")
        } catch {
            log("Server failed to start: \(error)")
        }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: HookEvent) {
        let sessionId = event.sessionId
        let now = Date()

        // Find or create session
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: idx, with: event, at: now)
        } else {
            var session = SessionState(sessionId: sessionId, cwd: event.cwd)
            session.transcriptPath = event.transcriptPath
            session.permissionMode = event.permissionMode
            applyEvent(to: &session, event: event, at: now)
            sessions.append(session)
            log("New session: \(session.projectName) (\(sessionId.prefix(8))...)")
        }

        // Alert after state update
        if let session = sessions.first(where: { $0.id == sessionId }) {
            alertManager.alertIfNeeded(session: session, event: event)
        }

        updateAttentionState()
        scheduleSave()
    }

    private func updateSession(at index: Int, with event: HookEvent, at now: Date) {
        sessions[index].lastEventTime = now
        sessions[index].cwd = event.cwd
        sessions[index].projectName = URL(fileURLWithPath: event.cwd).lastPathComponent
        if let tp = event.transcriptPath { sessions[index].transcriptPath = tp }
        if let pm = event.permissionMode { sessions[index].permissionMode = pm }
        applyEvent(to: &sessions[index], event: event, at: now)
    }

    private func applyEvent(to session: inout SessionState, event: HookEvent, at now: Date) {
        let oldStatus = session.status
        session.lastEvent = event.hookEventName

        switch event.hookEventName {
        case "UserPromptSubmit":
            session.status = .working
            session.needsAttention = false
            session.lastResponse = nil
            session.claudeAskedQuestion = false
            session.claudeQuestion = nil
            // Extract prompt from the dedicated "prompt" field (confirmed in payload)
            // Filter out system noise: task notifications, command messages, XML-heavy content
            if let rawPrompt = event.prompt, !rawPrompt.isEmpty,
               !rawPrompt.hasPrefix("<task-notification>"),
               !rawPrompt.hasPrefix("<command-message>"),
               !rawPrompt.hasPrefix("<system-reminder>"),
               !rawPrompt.hasPrefix("[Image: source:"),
               !rawPrompt.hasPrefix("Base directory for this skill:"),
               rawPrompt.filter({ $0 == "<" }).count <= 3 {
                // Clean image references from prompt text
                let promptText = rawPrompt
                    .replacingOccurrences(of: #"\[Image #\d+\]\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\[Image:[^\]]*\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !promptText.isEmpty else { break }

                session.lastUserPrompt = promptText
                session.turnCount += 1
                session.promptArc.append(String(promptText.prefix(120)))
                if session.promptArc.count > 20 { session.promptArc.removeFirst() }
                if session.mission == nil {
                    session.mission = String(promptText.prefix(300))
                }
                session.addTrajectory(type: "prompt", summary: String(promptText.prefix(100)))
            }
            // Set transcript path if provided
            if let tp = event.transcriptPath, !tp.isEmpty {
                session.transcriptPath = tp
            }

        case "PostToolUse":
            session.status = .working
            session.lastToolName = event.toolName
            if let input = event.toolInput {
                session.lastToolDescription = input["description"]?.stringValue
                    ?? input["command"]?.stringValue.map { String($0.prefix(80)) }
                // Track files modified by Edit/Write
                if let toolName = event.toolName,
                   (toolName == "Edit" || toolName == "Write"),
                   let filePath = input["file_path"]?.stringValue {
                    let fileName = (filePath as NSString).lastPathComponent
                    if !session.filesModified.contains(fileName) {
                        session.filesModified.append(fileName)
                    }
                }
            }
            if let toolName = event.toolName {
                let desc = session.lastToolDescription ?? ""
                session.addTrajectory(type: "tool", summary: "\(toolName): \(desc)".prefix(100).description)
            }

        case "Stop":
            session.status = .idle
            session.needsAttention = true
            session.addTrajectory(type: "stop", summary: "Turn complete")
            loadSessionContext(for: &session)
            // Async LLM summarization (runs in background, updates when done)
            summarizeSession(sessionId: session.id)

        case "Notification":
            session.status = .waitingForInput
            session.needsAttention = true
            session.addTrajectory(type: "notification", summary: "Waiting for input")
            log("\(session.projectName) needs attention!")
            loadSessionContext(for: &session)
            summarizeSession(sessionId: session.id)

        case "SessionStart":
            session.status = .working
            session.addTrajectory(type: "session_start", summary: "Session started")

        case "SessionEnd":
            session.status = .ended
            session.addTrajectory(type: "stop", summary: "Session ended")

        default:
            break
        }

        // Track when status actually changes
        if session.status != oldStatus {
            session.statusChangedAt = now
            session.spinnerDuration = nil  // clear stale spinner duration on status change
        }
    }

    // MARK: - Discovery

    private func startDiscovery() {
        // Run immediately, then every 30s
        Task { await runDiscovery() }
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runDiscovery()
            }
        }
    }

    private func runDiscovery() async {
        let results = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = SessionDiscovery.fullDiscovery()
                continuation.resume(returning: r)
            }
        }

        for result in results {
            let sessionId = result.session.sessionId

            if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                // Update tmux info
                sessions[idx].pid = result.session.pid
                if let tw = result.tmuxWindow { sessions[idx].tmuxWindow = tw }
                if let twn = result.tmuxWindowName { sessions[idx].tmuxWindowName = twn }
                if let ctx = result.contextPercent { sessions[idx].contextPercent = ctx }
                sessions[idx].spinnerDuration = result.spinnerDuration

                // Find transcript path if missing
                if sessions[idx].transcriptPath == nil || sessions[idx].transcriptPath?.isEmpty == true {
                    sessions[idx].transcriptPath = TrajectoryBuilder.findTranscriptPath(sessionId: sessionId)
                }

                // Load context from JSONL if we haven't yet (first discovery with transcript)
                if sessions[idx].mission == nil && sessions[idx].transcriptPath != nil {
                    loadSessionContext(for: &sessions[idx])
                    summarizeSession(sessionId: sessionId)
                }

                // Update status from pane detection — pane is ground truth
                // BUT: if we recently sent a response, force working for 30s (race condition protection)
                let recentlySent = sessions[idx].lastSentAt.map { Date().timeIntervalSince($0) < 30 } ?? false
                let oldStatus = sessions[idx].status
                let newStatus = recentlySent ? .working : result.detectedStatus

                // ALWAYS enforce: working sessions do NOT need attention
                if newStatus == .working {
                    sessions[idx].needsAttention = false
                }

                if oldStatus != newStatus {
                    sessions[idx].status = newStatus
                    sessions[idx].statusChangedAt = Date()

                    // Transition to idle from working: mark attention + refresh context
                    if (newStatus == .idle || newStatus == .waitingForInput) && oldStatus == .working {
                        sessions[idx].needsAttention = true
                        loadSessionContext(for: &sessions[idx])
                        summarizeSession(sessionId: sessionId)
                    }
                }
            } else {
                // New session discovered from filesystem
                var session = SessionState(sessionId: sessionId, cwd: result.session.cwd)
                session.pid = result.session.pid
                session.tmuxWindow = result.tmuxWindow
                session.tmuxWindowName = result.tmuxWindowName
                session.contextPercent = result.contextPercent
                session.status = result.detectedStatus
                session.spinnerDuration = result.spinnerDuration
                // Find transcript and load full context immediately
                session.transcriptPath = TrajectoryBuilder.findTranscriptPath(sessionId: sessionId)
                if session.transcriptPath != nil {
                    loadSessionContext(for: &session)
                }
                sessions.append(session)
                log("Discovered: \(session.projectName) (window: \(result.tmuxWindowName ?? "?")) status: \(result.detectedStatus)")
                // Trigger async summarization for new session
                if session.transcriptPath != nil {
                    summarizeSession(sessionId: sessionId)
                }
            }
        }

        // Remove sessions whose processes are gone (keep for 60s after death)
        let activeSessionIds = Set(results.map(\.session.sessionId))
        for i in sessions.indices {
            if !activeSessionIds.contains(sessions[i].id) && sessions[i].status != .ended {
                sessions[i].status = .ended
            }
        }
        sessions.removeAll { $0.status == .ended && Date().timeIntervalSince($0.lastEventTime) > 300 }

        updateAttentionState()
        scheduleSave()
    }

    // MARK: - Attention

    private func updateAttentionState() {
        needsAttention = sessions.contains { $0.needsAttention || $0.status == .waitingForInput }
    }

    // MARK: - Trajectory

    func loadTrajectory(for sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }),
              let transcriptPath = sessions[idx].transcriptPath,
              sessions[idx].trajectory.isEmpty
        else { return }

        Task.detached { [weak self] in
            let trajectory = TrajectoryBuilder.buildTrajectory(from: transcriptPath)
            let lastPrompt = TrajectoryBuilder.getLastPromptFromHistory(sessionId: sessionId)

            await MainActor.run {
                guard let self = self,
                      let idx = self.sessions.firstIndex(where: { $0.id == sessionId })
                else { return }
                if !trajectory.isEmpty {
                    self.sessions[idx].trajectory = trajectory
                }
                if let prompt = lastPrompt, self.sessions[idx].lastUserPrompt == nil {
                    self.sessions[idx].lastUserPrompt = prompt
                }
            }
        }
    }

    func getPanePreview(for session: SessionState) async -> String? {
        guard let window = session.tmuxWindow else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let content = TrajectoryBuilder.capturePaneContent(window: window, lines: 15)
                continuation.resume(returning: content)
            }
        }
    }

    // MARK: - Actions

    func switchToSession(_ session: SessionState) {
        guard let window = session.tmuxWindow else { return }
        // Clear attention — user is handling this session
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].needsAttention = false
            sessions[idx].lastResponse = nil
        }
        updateAttentionState()
        // Switch tmux window and bring terminal to front
        let terminalApp = LaunchSettings.load().terminalApp.rawValue
        Task.detached {
            Shell.run("tmux select-window -t \(window)")
            Shell.run("open -a '\(terminalApp)'")
        }
    }

    // MARK: - New Session

    /// Launch a new Claude session in a new tmux window
    func launchNewSession(directory: String, name: String?) {
        let settings = LaunchSettings.load()
        let (env, args) = settings.buildCommand()

        let windowName = name ?? URL(fileURLWithPath: directory).lastPathComponent

        Task.detached {
            // Build tmux command with proper quoting
            // The claude command needs to be a single string argument to tmux new-window
            // JSON braces in --settings must survive shell expansion
            var tmuxArgs = ["tmux", "new-window", "-n", windowName]
            for (k, v) in env {
                tmuxArgs.append(contentsOf: ["-e", "\(k)=\(v)"])
            }
            tmuxArgs.append(contentsOf: ["-c", directory])

            // Build the claude command as a single shell string
            // Escape single quotes in the JSON settings arg
            let claudeCmd = args.map { arg in
                if arg.contains("{") || arg.contains("}") {
                    return "'\(arg)'"  // wrap JSON in single quotes
                }
                return arg
            }.joined(separator: " ")

            tmuxArgs.append(claudeCmd)

            // Use Process directly for proper argument passing
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = tmuxArgs
            try? process.run()
            process.waitUntilExit()
        }

        log("Launched new session: \(windowName) in \(directory)")
    }

    // MARK: - Rename

    /// Rename a session's tmux window
    func renameSession(_ sessionId: String, to name: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }),
              let window = sessions[idx].tmuxWindow
        else { return }

        sessions[idx].tmuxWindowName = name
        Task.detached {
            Shell.run("tmux rename-window -t \(window) '\(name)'")
        }
        scheduleSave()
    }

    // MARK: - Manual Refresh

    /// Force refresh context for a specific session from JSONL + re-summarize
    func refreshSession(_ sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        loadSessionContext(for: &sessions[idx])
        summarizeSession(sessionId: sessionId)
        scheduleSave()
        log("Refreshed: \(sessions[idx].tmuxWindowName ?? sessions[idx].projectName)")
    }

    // MARK: - Context Refresh (after sending response)

    /// Poll the JSONL for updated context after sending a response
    func scheduleContextRefresh(for sessionId: String, delay: TimeInterval) {
        // Poll every few seconds for up to 2 minutes to catch Claude's response
        var attempts = 0
        let maxAttempts = 15

        func poll() {
            attempts += 1
            guard attempts <= maxAttempts,
                  let idx = sessions.firstIndex(where: { $0.id == sessionId })
            else { return }

            loadSessionContext(for: &sessions[idx])

            // If we got a new response, mark attention and stop polling
            if sessions[idx].lastResponse != nil && sessions[idx].status != .working {
                sessions[idx].needsAttention = true
                summarizeSession(sessionId: sessionId)
                scheduleSave()
                return
            }

            // Keep polling
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                poll()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            poll()
        }
    }

    // MARK: - JSONL-based Response Extraction

    /// Load full session context from the JSONL transcript
    private func loadSessionContext(for session: inout SessionState) {
        // Ensure we have a transcript path
        if session.transcriptPath == nil || session.transcriptPath?.isEmpty == true {
            if let found = TrajectoryBuilder.findTranscriptPath(sessionId: session.id) {
                session.transcriptPath = found
            }
        }
        guard let path = session.transcriptPath, !path.isEmpty else { return }

        let ctx = TrajectoryBuilder.extractFullContext(from: path)

        // Apply all context to session
        session.lastResponse = ctx.lastResponse
        if let prompt = ctx.lastUserPrompt { session.lastUserPrompt = prompt }
        if let m = ctx.mission { session.mission = m }
        // problemStatement and currentTask are set by LLM summarizer, not JSONL parsing
        // Fallback: use JSONL-derived values if summarizer hasn't run yet
        if session.problemStatement == nil, let ps = ctx.problemStatement { session.problemStatement = ps }
        if session.currentTask == nil, let ct = ctx.currentTask { session.currentTask = ct }
        if let b = ctx.gitBranch { session.gitBranch = b }
        if !ctx.promptArc.isEmpty { session.promptArc = ctx.promptArc }
        session.claudeAskedQuestion = ctx.claudeQuestion != nil
        session.claudeQuestion = ctx.claudeQuestion
        session.turnCount = ctx.turnCount
        if !ctx.filesModified.isEmpty { session.filesModified = ctx.filesModified }
        if !ctx.recentExchanges.isEmpty { session.recentExchanges = ctx.recentExchanges }
    }

    // MARK: - LLM Summarization

    /// Run Claude haiku to generate problem + task summaries (async, non-blocking)
    private func summarizeSession(sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }),
              let tp = sessions[idx].transcriptPath, !tp.isEmpty
        else { return }

        let projectName = sessions[idx].projectName
        let cwd = sessions[idx].cwd

        Task.detached {
            let summary = ContextSummarizer.summarize(
                transcriptPath: tp,
                projectName: projectName,
                cwd: cwd
            )

            await MainActor.run { [weak self] in
                guard let self = self,
                      let idx = self.sessions.firstIndex(where: { $0.id == sessionId }),
                      let summary = summary
                else { return }
                self.sessions[idx].problemStatement = summary.problem
                self.sessions[idx].currentTask = summary.task
                self.scheduleSave()
            }
        }
    }

    // MARK: - Legacy Response Extraction (fallback)

    /// Extract Claude's meaningful output from raw pane capture, stripping TUI chrome
    private static func extractClaudeResponse(from rawCapture: String?) -> String? {
        guard let raw = rawCapture else { return nil }
        let lines = raw.components(separatedBy: "\n")

        // Filter out TUI chrome: separator lines (───), status line, permission mode, prompt (❯), blank lines
        var meaningful: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip separator lines (all ─ characters)
            if trimmed.allSatisfy({ $0 == "─" || $0 == "─" }) && trimmed.count > 5 { continue }
            // Skip status line
            if trimmed.contains("[Opus") || trimmed.contains("[Sonnet") || trimmed.contains("[Haiku") { continue }
            // Skip permission mode line
            if trimmed.contains("bypass permissions") || trimmed.contains("plan mode") || trimmed.contains("auto accept") { continue }
            // Skip prompt line
            if trimmed == "❯" || trimmed.hasPrefix("❯ ") { continue }
            // Skip spinner lines (completed)
            if trimmed.range(of: #"^✻|^✶|^·"#, options: .regularExpression) != nil && trimmed.contains(" for ") { continue }
            // Skip teammate/tip lines
            if trimmed.hasPrefix("@main") || trimmed.contains("shift +") { continue }
            // Skip active spinner lines
            if trimmed.contains("\u{2026}") && trimmed.range(of: #"\(\d+[smh]"#, options: .regularExpression) != nil { continue }
            // Skip diff hunks (line numbers from git diff / tool output)
            if trimmed.range(of: #"^\d+\s*[+-]"#, options: .regularExpression) != nil { continue }
            // Skip Claude tool markers
            if trimmed.hasPrefix("⏺") || trimmed.hasPrefix("⎿") { continue }
            // Skip ctrl+o expand hints
            if trimmed.contains("ctrl+o to expand") || trimmed.contains("ctrl+b") { continue }
            // Keep everything else
            meaningful.append(line)
        }

        // Trim leading/trailing blank lines
        while meaningful.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { meaningful.removeFirst() }
        while meaningful.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { meaningful.removeLast() }

        let result = meaningful.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !pendingSave else { return }
        pendingSave = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.saveState()
            self?.pendingSave = false
        }
    }

    private func saveState() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(sessions)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            print("[SessionManager] Save error: \(error)")
        }
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let loaded = try? { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return try d.decode([SessionState].self, from: data) }()
        else { return }
        // Only restore non-ended sessions
        sessions = loaded.filter { $0.status != .ended }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(ts)] \(message)"
        eventLog.append(entry)
        if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
        print(entry)
    }
}
