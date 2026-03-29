import Foundation

enum SessionStatus: String, Codable {
    case working
    case idle
    case waitingForInput
    case error
    case ended
}

struct Exchange: Codable, Identifiable {
    let id: UUID
    let userPrompt: String
    let assistantResponse: String

    init(userPrompt: String, assistantResponse: String) {
        self.id = UUID()
        self.userPrompt = userPrompt
        self.assistantResponse = assistantResponse
    }
}

struct TrajectoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let type: String        // "prompt", "tool", "stop", "notification", "session_start"
    let summary: String

    init(timestamp: Date, type: String, summary: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.type = type
        self.summary = summary
    }
}

struct SessionState: Identifiable, Codable {
    let id: String                  // session_id UUID
    var cwd: String
    var projectName: String
    var transcriptPath: String?
    var status: SessionStatus
    var lastEvent: String
    var lastEventTime: Date
    var statusChangedAt: Date
    var spinnerDuration: String?    // e.g. "2m 10s" extracted from pane
    var lastUserPrompt: String?
    var lastToolName: String?
    var lastToolDescription: String?
    var contextPercent: Int?
    var tmuxWindow: String?         // "0:2" format
    var tmuxWindowName: String?
    var slug: String?
    var pid: Int?
    var permissionMode: String?
    var trajectory: [TrajectoryEntry]
    var lastResponse: String?           // Claude's last text response from JSONL
    var recentExchanges: [Exchange] = [] // last 3 prompt→response pairs
    var needsAttention: Bool = false    // auto-expand flag: set on completion, cleared on switch

    // Context recovery fields
    var gitBranch: String?              // from JSONL entries
    var mission: String?                // first user prompt = session goal
    var promptArc: [String] = []        // sampled user prompts showing the journey
    var claudeAskedQuestion: Bool = false
    var claudeQuestion: String?
    var turnCount: Int = 0
    var filesModified: [String] = []
    var currentTask: String?
    var problemStatement: String?
    var lastSentAt: Date?               // when we last sent a response — forces working state for 30s

    init(sessionId: String, cwd: String) {
        self.id = sessionId
        self.cwd = cwd
        self.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        self.status = .idle
        self.lastEvent = "discovered"
        self.lastEventTime = Date()
        self.statusChangedAt = Date()
        self.trajectory = []
    }

    /// Tab index extracted from tmuxWindow "0:2" → 2
    var tabIndex: Int {
        guard let window = tmuxWindow,
              let colonIdx = window.lastIndex(of: ":"),
              let idx = Int(window[window.index(after: colonIdx)...])
        else { return 999 }
        return idx
    }

    var timeSinceLastEvent: String {
        let seconds = Int(Date().timeIntervalSince(lastEventTime))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    /// Time since status last changed
    var timeSinceStatusChange: String {
        let seconds = Int(Date().timeIntervalSince(statusChangedAt))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    /// Compact status + duration string for the card
    var statusSummary: String {
        switch status {
        case .working:
            return "Working \(timeSinceStatusChange)"
        case .idle:
            return "Idle \(timeSinceStatusChange)"
        case .waitingForInput: return "Needs Input"
        case .error: return "Error"
        case .ended: return "Ended"
        }
    }

    /// What is this session doing right now? One-liner.
    var currentActivity: String {
        switch status {
        case .waitingForInput:
            if let prompt = lastUserPrompt {
                return "\u{2192} \(prompt)"
            }
            return "Waiting for your input"
        case .working:
            if let tool = lastToolName {
                let desc = lastToolDescription ?? ""
                return "\(tool): \(desc)"
            }
            return "Processing..."
        case .idle:
            if let tool = lastToolName {
                let desc = lastToolDescription ?? ""
                return "Last: \(tool) \(desc)"
            }
            if let prompt = lastUserPrompt {
                return "Done: \(prompt)"
            }
            return "Ready"
        case .error:
            return "Error occurred"
        case .ended:
            return "Session ended"
        }
    }

    mutating func addTrajectory(type: String, summary: String) {
        let entry = TrajectoryEntry(timestamp: Date(), type: type, summary: summary)
        trajectory.append(entry)
        // Keep last 50 entries
        if trajectory.count > 50 {
            trajectory.removeFirst(trajectory.count - 50)
        }
    }
}
