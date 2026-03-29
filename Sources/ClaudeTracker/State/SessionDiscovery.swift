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

    /// Capture pane to extract ONLY context %. Status comes from hooks, not pane parsing.
    static func capturePaneStatus(window: String) -> PaneStatus {
        let (output, exitCode) = Shell.run("tmux capture-pane -t \(window).0 -p -S -5 2>/dev/null")
        guard exitCode == 0 else { return PaneStatus(contextPercent: nil) }

        var contextPercent: Int?
        for line in output.components(separatedBy: "\n") {
            if line.contains("[") && line.contains("]") && line.contains("%") {
                if let range = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                    let numStr = line[range].dropLast()
                    if let pct = Int(numStr) {
                        contextPercent = pct
                    }
                }
            }
        }
        return PaneStatus(contextPercent: contextPercent)
    }

    struct DiscoveryResult {
        let session: SessionFile
        let tmuxWindow: String?
        let tmuxWindowName: String?
        let contextPercent: Int?
    }

    /// Full discovery: sessions + tmux correlation. Status comes from hooks, not pane.
    static func fullDiscovery() -> [DiscoveryResult] {
        let sessions = discoverSessions()
        let panes = getTmuxPanes()

        return sessions.map { session in
            var tmuxWindow: String?
            var tmuxWindowName: String?
            var contextPercent: Int?

            let matchedPane = panes.first(where: { $0.panePid == session.pid })
                ?? getParentPid(session.pid).flatMap { parentPid in
                    panes.first(where: { $0.panePid == parentPid })
                }
            if let pane = matchedPane {
                tmuxWindow = pane.sessionWindow
                tmuxWindowName = pane.windowName
                contextPercent = capturePaneStatus(window: pane.sessionWindow).contextPercent
            }

            return DiscoveryResult(
                session: session,
                tmuxWindow: tmuxWindow,
                tmuxWindowName: tmuxWindowName,
                contextPercent: contextPercent
            )
        }
    }
}
