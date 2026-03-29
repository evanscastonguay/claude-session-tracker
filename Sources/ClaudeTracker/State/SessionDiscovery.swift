import Foundation

/// Discovers active Claude sessions from filesystem and correlates with tmux
enum SessionDiscovery {

    struct SessionFile: Codable {
        let pid: Int
        let sessionId: String
        let cwd: String
        let startedAt: Int64
        let kind: String?
        let entrypoint: String?
    }

    struct TmuxPane {
        let panePid: Int
        let sessionWindow: String   // "0:2"
        let windowName: String
    }

    struct PaneStatus {
        let contextPercent: Int?
        let detectedStatus: SessionStatus
        let spinnerDuration: String?  // e.g. "2m 10s" from active spinner, or "3m 27s" from completed
    }

    /// Scan ~/.claude/sessions/*.json for active sessions
    static func discoverSessions() -> [SessionFile] {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        return files.compactMap { url -> SessionFile? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SessionFile.self, from: data)
        }.filter { session in
            kill(Int32(session.pid), 0) == 0
        }
    }

    /// Get all tmux panes with their PIDs
    static func getTmuxPanes() -> [TmuxPane] {
        let (output, exitCode) = Shell.run(
            "tmux list-panes -a -F '#{pane_pid}\t#{session_name}:#{window_index}\t#{window_name}' 2>/dev/null"
        )
        guard exitCode == 0 else { return [] }

        return output.components(separatedBy: "\n").compactMap { line -> TmuxPane? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, let pid = Int(parts[0]) else { return nil }
            return TmuxPane(panePid: pid, sessionWindow: parts[1], windowName: parts[2])
        }
    }

    /// Get the parent PID of a given PID
    static func getParentPid(_ pid: Int) -> Int? {
        let (output, _) = Shell.run("ps -o ppid= -p \(pid)")
        return Int(output.trimmingCharacters(in: .whitespaces))
    }

    /// Check if a Claude process has active child processes (indicates it's running tools)
    static func hasActiveChildren(_ pid: Int) -> Bool {
        let (output, exitCode) = Shell.run("pgrep -P \(pid) 2>/dev/null")
        guard exitCode == 0 else { return false }
        // Filter out caffeinate which is always present
        let children = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        for childPidStr in children {
            guard let childPid = Int(childPidStr) else { continue }
            let (cmd, _) = Shell.run("ps -o comm= -p \(childPid) 2>/dev/null")
            if !cmd.isEmpty && cmd != "caffeinate" {
                return true
            }
        }
        return false
    }

    /// Capture the last few lines of a tmux pane to detect status.
    ///
    /// Claude Code TUI patterns observed:
    ///   WORKING:  `✻ Puzzling… (3m 10s)` or `· Thinking… (5s)` — ellipsis + time in parens
    ///             `Running…` — tool actively executing
    ///   COMPLETED: `✻ Sautéed for 4m 38s` — past tense, "for" before duration
    ///   IDLE:     `❯` prompt visible between `───` separator lines
    static func capturePaneStatus(window: String) -> PaneStatus {
        let (output, exitCode) = Shell.run("tmux capture-pane -t \(window).0 -p -S -12 2>/dev/null")
        guard exitCode == 0 else { return PaneStatus(contextPercent: nil, detectedStatus: .idle, spinnerDuration: nil) }

        var contextPercent: Int?
        var hasActiveSpinner = false
        var hasCompletedSpinner = false
        var hasRunningTool = false
        var spinnerDuration: String?

        let lines = output.components(separatedBy: "\n")

        for line in lines {
            // Extract context % from status line like "[Opus 4.6 (1M context)] 83%"
            if line.contains("[") && line.contains("]") && line.contains("%") {
                if let range = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                    let numStr = line[range].dropLast()
                    if let pct = Int(numStr) {
                        contextPercent = pct
                    }
                }
            }

            // ACTIVE spinner: has "…" (unicode ellipsis) + time in parens
            // e.g., "✻ Puzzling… (3m 10s · ↓ 1.0k tokens)" or "✶ Honking… (5s)"
            // Spinner chars vary: ✻ ✶ · etc.
            if line.contains("\u{2026}") {  // unicode ellipsis
                if line.range(of: #"\u{2026}.*\(\d+"#, options: .regularExpression) != nil {
                    hasActiveSpinner = true
                    // Extract duration: first number group inside parens
                    // "5m 12s · ↑ 481 tokens · thought for 2s" → "5m 12s"
                    if let parenStart = line.range(of: "("),
                       let parenEnd = line[parenStart.upperBound...].firstIndex(of: ")") {
                        let content = String(line[parenStart.upperBound..<parenEnd])
                        // Split on " · " to get just the duration part
                        let dur = content.components(separatedBy: " \u{00B7}").first  // " · "
                            ?? content.components(separatedBy: " ·").first
                            ?? content
                        let trimmed = dur.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { spinnerDuration = trimmed }
                    }
                }
                if line.contains("Running") {
                    hasRunningTool = true
                }
            }

            // COMPLETED spinner: verb + "for" + duration at END of line (not inside parens)
            // e.g., "✻ Sautéed for 4m 38s" but NOT "thought for 2s" inside parens
            // Only match if line does NOT contain "…" (active spinners have ellipsis)
            if !line.contains("\u{2026}") && !hasActiveSpinner {
                if line.range(of: #" for \d+[smh]"#, options: .regularExpression) != nil {
                    hasCompletedSpinner = true
                    if let forRange = line.range(of: " for ") {
                        let afterFor = String(line[forRange.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !afterFor.isEmpty { spinnerDuration = afterFor }
                    }
                }
            }
        }

        let status: SessionStatus
        if hasActiveSpinner || hasRunningTool {
            status = .working
        } else if hasCompletedSpinner {
            status = .idle
        } else {
            status = .idle
        }

        return PaneStatus(contextPercent: contextPercent, detectedStatus: status, spinnerDuration: spinnerDuration)
    }

    struct DiscoveryResult {
        let session: SessionFile
        let tmuxWindow: String?
        let tmuxWindowName: String?
        let contextPercent: Int?
        let detectedStatus: SessionStatus
        let spinnerDuration: String?
    }

    /// Full discovery: sessions + tmux correlation + status detection
    static func fullDiscovery() -> [DiscoveryResult] {
        let sessions = discoverSessions()
        let panes = getTmuxPanes()

        return sessions.map { session in
            var tmuxWindow: String?
            var tmuxWindowName: String?
            var contextPercent: Int?
            var detectedStatus: SessionStatus = .idle
            var spinnerDuration: String?

            // Match Claude PID to tmux pane: check both direct match (tmux launched claude)
            // and parent match (shell launched claude inside tmux pane)
            let matchedPane = panes.first(where: { $0.panePid == session.pid })
                ?? getParentPid(session.pid).flatMap { parentPid in
                    panes.first(where: { $0.panePid == parentPid })
                }
            if let pane = matchedPane {
                tmuxWindow = pane.sessionWindow
                tmuxWindowName = pane.windowName

                let paneStatus = capturePaneStatus(window: pane.sessionWindow)
                contextPercent = paneStatus.contextPercent
                detectedStatus = paneStatus.detectedStatus
                spinnerDuration = paneStatus.spinnerDuration
            }

            // Cross-check with child processes
            if detectedStatus == .idle && hasActiveChildren(session.pid) {
                detectedStatus = .working
            }

            return DiscoveryResult(
                session: session,
                tmuxWindow: tmuxWindow,
                tmuxWindowName: tmuxWindowName,
                contextPercent: contextPercent,
                detectedStatus: detectedStatus,
                spinnerDuration: spinnerDuration
            )
        }
    }
}
