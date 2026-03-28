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
            // Extract prompt text from tool_input if available
            if let input = event.toolInput, let prompt = input["prompt"]?.stringValue {
                session.lastUserPrompt = String(prompt.prefix(200))
                session.addTrajectory(type: "prompt", summary: String(prompt.prefix(100)))
            }

        case "PostToolUse":
            session.status = .working
            session.lastToolName = event.toolName
            if let input = event.toolInput {
                session.lastToolDescription = input["description"]?.stringValue
                    ?? input["command"]?.stringValue.map { String($0.prefix(80)) }
            }
            if let toolName = event.toolName {
                let desc = session.lastToolDescription ?? ""
                session.addTrajectory(type: "tool", summary: "\(toolName): \(desc)".prefix(100).description)
            }

        case "Stop":
            session.status = .idle
            session.needsAttention = true
            session.addTrajectory(type: "stop", summary: "Turn complete")
            // Extract response from JSONL transcript (structured, clean data)
            loadLastTurn(for: &session)

        case "Notification":
            session.status = .waitingForInput
            session.needsAttention = true
            session.addTrajectory(type: "notification", summary: "Waiting for input")
            log("\(session.projectName) needs attention!")
            loadLastTurn(for: &session)

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

                // Update status from pane detection
                // IMPORTANT: never overwrite needsAttention or lastResponse from discovery —
                // those are only set by hooks and cleared by user action (switchToSession)
                let oldStatus = sessions[idx].status
                let newStatus = result.detectedStatus
                let hasAttention = sessions[idx].needsAttention

                if oldStatus != newStatus {
                    sessions[idx].status = newStatus
                    sessions[idx].statusChangedAt = Date()

                    // On transition to idle from working: load context (only if hooks haven't already set it)
                    if (newStatus == .idle || newStatus == .waitingForInput) && oldStatus == .working && !hasAttention {
                        sessions[idx].needsAttention = true
                        loadLastTurn(for: &sessions[idx])
                    }
                    // On transition to working: only clear if user already addressed it
                    if newStatus == .working && !hasAttention {
                        sessions[idx].lastResponse = nil
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
                sessions.append(session)
                log("Discovered: \(session.projectName) (window: \(result.tmuxWindowName ?? "?")) status: \(result.detectedStatus)")
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
        // Switch tmux window and bring Ghostty to front
        Task.detached {
            Shell.run("tmux select-window -t \(window)")
            Shell.run("open -a Ghostty")
        }
    }

    // MARK: - JSONL-based Response Extraction

    /// Load the last conversation turn from the JSONL transcript
    private func loadLastTurn(for session: inout SessionState) {
        // Ensure we have a transcript path
        if session.transcriptPath == nil || session.transcriptPath?.isEmpty == true {
            if let found = TrajectoryBuilder.findTranscriptPath(sessionId: session.id) {
                session.transcriptPath = found
            }
        }
        guard let path = session.transcriptPath, !path.isEmpty else {
            print("[loadLastTurn] No transcript path for \(session.projectName)")
            return
        }

        // Debug: write to file since stdout isn't visible
        let debugLog = { (msg: String) in
            let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-tracker/debug.log")
            let entry = "[\(Date())] \(msg)\n"
            if let data = entry.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    try? data.write(to: logPath)
                }
            }
        }
        debugLog("loadLastTurn path=\(path)")
        let turn = TrajectoryBuilder.getLastTurn(from: path)
        debugLog("result: prompt=\(turn.userPrompt?.prefix(80) ?? "nil") response_len=\(turn.assistantResponse?.count ?? -1)")
        session.lastResponse = turn.assistantResponse
        if let prompt = turn.userPrompt {
            session.lastUserPrompt = prompt
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
