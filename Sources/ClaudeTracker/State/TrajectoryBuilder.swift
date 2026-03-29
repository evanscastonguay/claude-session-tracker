import Foundation

/// Parses Claude conversation JSONL files to build session trajectory
enum TrajectoryBuilder {

    /// Read the last N entries from a JSONL file and extract trajectory
    static func buildTrajectory(from transcriptPath: String, maxEntries: Int = 50) -> [TrajectoryEntry] {
        guard let lines = readLastLines(of: transcriptPath, count: maxEntries * 2) else { return [] }

        var entries: [TrajectoryEntry] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = json["type"] as? String ?? ""
            let timestamp = parseTimestamp(json["timestamp"])

            if type == "user" {
                // Check if it's a tool result or actual user prompt
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if let blockType = block["type"] as? String, blockType == "text",
                           let text = block["text"] as? String {
                            entries.append(TrajectoryEntry(
                                timestamp: timestamp,
                                type: "prompt",
                                summary: String(text.prefix(120))
                            ))
                        }
                    }
                }
                // Also check toolUseResult for a simpler representation
                if json["toolUseResult"] != nil {
                    // Skip tool results — they're noise for trajectory
                    continue
                }
            }

            if type == "assistant" {
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        let blockType = block["type"] as? String ?? ""

                        if blockType == "tool_use" {
                            let toolName = block["name"] as? String ?? "?"
                            let input = block["input"] as? [String: Any]
                            let desc: String = (input?["description"] as? String)
                                ?? (input?["command"] as? String).map { String($0.prefix(60)) }
                                ?? ""
                            entries.append(TrajectoryEntry(
                                timestamp: timestamp,
                                type: "tool",
                                summary: "\(toolName): \(desc)".prefix(120).description
                            ))
                        }

                        if blockType == "text" {
                            let text = block["text"] as? String ?? ""
                            // Only include substantial text responses (not tiny acknowledgments)
                            if text.count > 50 {
                                entries.append(TrajectoryEntry(
                                    timestamp: timestamp,
                                    type: "response",
                                    summary: String(text.prefix(120))
                                ))
                            }
                        }
                    }
                }
            }
        }

        // Deduplicate and take last N
        return Array(entries.suffix(maxEntries))
    }

    /// Get the last user prompt from history.jsonl
    static func getLastPromptFromHistory(sessionId: String) -> String? {
        let historyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/history.jsonl").path

        guard let lines = readLastLines(of: historyPath, count: 20) else { return nil }

        // Search backwards for this session's last prompt
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String,
                  sid == sessionId,
                  let display = json["display"] as? String
            else { continue }
            return display
        }
        return nil
    }

    /// Capture the last N lines from a tmux pane for preview
    static func capturePaneContent(window: String, lines: Int = 15) -> String? {
        let (output, exitCode) = Shell.run("tmux capture-pane -t \(window).0 -p -S -\(lines) 2>/dev/null")
        guard exitCode == 0, !output.isEmpty else { return nil }
        return output
    }

    /// Check if a prompt is actual human text (not system/XML noise)
    private static func isRealUserPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        // Filter system/XML messages
        if trimmed.hasPrefix("<task-notification>") { return false }
        if trimmed.hasPrefix("<command-message>") { return false }
        if trimmed.hasPrefix("<command-name>") { return false }
        if trimmed.hasPrefix("<system-reminder>") { return false }
        // Filter skill invocations
        if trimmed.hasPrefix("Base directory for this skill:") { return false }
        if trimmed.hasPrefix("# s") && trimmed.contains("skill") { return false }
        // Filter image-only references
        if trimmed.hasPrefix("[Image: source:") { return false }
        if trimmed.hasPrefix("[Image:") && trimmed.hasSuffix("]") && trimmed.count < 200 { return false }
        // Filter XML-heavy content
        let angleBrackets = trimmed.filter { $0 == "<" }.count
        if angleBrackets > 3 && angleBrackets > trimmed.split(separator: " ").count / 2 { return false }
        return true
    }

    /// Clean up user prompt text — strip image references, system tags
    private static func cleanPromptText(_ text: String) -> String {
        var cleaned = text
        // Remove [Image #N] inline references
        while let range = cleaned.range(of: #"\[Image #\d+\]\s*"#, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        // Remove [Image: source: ...] references
        while let range = cleaned.range(of: #"\[Image: source: [^\]]+\]"#, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        // Remove [Image: ...] generic
        while let range = cleaned.range(of: #"\[Image:[^\]]*\]"#, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Result of parsing the last conversation turn from the JSONL transcript
    struct LastTurn {
        let userPrompt: String?
        let assistantResponse: String?
    }

    /// Parse the JSONL transcript to extract the last user prompt and Claude's last text response.
    /// This gives us clean, structured data — no terminal noise.
    static func getLastTurn(from transcriptPath: String) -> LastTurn {
        guard let lines = readLastLines(of: transcriptPath, count: 60) else {
            return LastTurn(userPrompt: nil, assistantResponse: nil)
        }

        var lastUserPrompt: String?
        var lastAssistantText: String?

        // Parse entries - we need to walk backwards to find the last assistant text and the last user prompt
        var entries: [(type: String, json: [String: Any])] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            entries.append((type, json))
        }

        // Find last assistant text response (walking backwards)
        for entry in entries.reversed() {
            guard entry.type == "assistant",
                  let message = entry.json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            // Collect text blocks from this assistant message (skip tool_use, thinking)
            let textBlocks = content.compactMap { block -> String? in
                guard let blockType = block["type"] as? String,
                      blockType == "text",
                      let text = block["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return text
            }

            if !textBlocks.isEmpty {
                lastAssistantText = textBlocks.joined(separator: "\n\n")
                break
            }
        }

        // Find last user text prompt (not tool results) — walk backwards
        for entry in entries.reversed() {
            guard entry.type == "user" else { continue }

            // Skip entries that are just tool results
            if entry.json["toolUseResult"] != nil { continue }

            let message = entry.json["message"]

            // Handle string content (simple prompt)
            if let content = (message as? [String: Any])?["content"] as? String {
                lastUserPrompt = content
                break
            }

            // Handle array content
            if let msg = message as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                // Skip if it's only tool_result blocks
                let hasToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
                let textBlocks = content.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text",
                          let text = block["text"] as? String
                    else { return nil }
                    return text
                }
                if !textBlocks.isEmpty {
                    lastUserPrompt = textBlocks.joined(separator: "\n")
                    break
                }
                if hasToolResult { continue }
            }
        }

        return LastTurn(userPrompt: lastUserPrompt, assistantResponse: lastAssistantText)
    }

    // MARK: - Full Session Context Extraction

    /// Complete context for a session — everything needed for instant context recovery
    struct SessionContext {
        let mission: String?
        let problemStatement: String?
        let currentTask: String?
        let gitBranch: String?
        let promptArc: [String]
        let lastUserPrompt: String?
        let lastResponse: String?
        let claudeQuestion: String?
        let turnCount: Int
        let filesModified: [String]
        let recentExchanges: [Exchange]  // last 3 prompt→response pairs
    }

    /// Extract full session context from the JSONL transcript.
    /// This is the comprehensive one-time parse — run on discovery and on Stop.
    static func extractFullContext(from transcriptPath: String) -> SessionContext {
        // Read the entire file for mission + arc, but optimize: read first 5 lines + last 200 lines
        let firstLines = readFirstLines(of: transcriptPath, count: 5)
        let lastLines = readLastLines(of: transcriptPath, count: 200)

        var mission: String?
        var gitBranch: String?
        var allUserPrompts: [String] = []
        var lastUserPrompt: String?
        var lastAssistantText: String?
        var turnCount = 0
        var filesModified = Set<String>()
        var currentTask: String?

        // Extract mission + branch from first few lines
        if let lines = firstLines {
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // Get branch from any entry
                if gitBranch == nil, let branch = json["gitBranch"] as? String {
                    gitBranch = branch
                }

                // First user text = mission
                if mission == nil, json["type"] as? String == "user" {
                    if let prompt = extractUserText(from: json) {
                        mission = String(prompt.prefix(300))
                    }
                }
            }
        }

        // Process last 200 lines for arc, last turn, files, turn count
        if let lines = lastLines {
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String
                else { continue }

                // Get branch if still missing
                if gitBranch == nil, let branch = json["gitBranch"] as? String {
                    gitBranch = branch
                }

                // Count user turns and collect prompts
                if type == "user" {
                    if let prompt = extractUserText(from: json) {
                        turnCount += 1
                        allUserPrompts.append(prompt)
                        lastUserPrompt = prompt
                    }
                }

                // Track files modified + extract tasks
                if type == "assistant" {
                    if let message = json["message"] as? [String: Any],
                       let content = message["content"] as? [[String: Any]] {
                        for block in content {
                            guard (block["type"] as? String) == "tool_use",
                                  let toolName = block["name"] as? String,
                                  let input = block["input"] as? [String: Any]
                            else { continue }

                            // File tracking
                            if toolName == "Edit" || toolName == "Write" {
                                if let filePath = input["file_path"] as? String {
                                    filesModified.insert((filePath as NSString).lastPathComponent)
                                }
                            }

                            // Task extraction — TaskCreate gives us the current task
                            if toolName == "TaskCreate" {
                                if let subject = input["subject"] as? String {
                                    currentTask = subject
                                }
                            }
                            if toolName == "TaskUpdate" {
                                if let subject = input["subject"] as? String {
                                    currentTask = subject
                                }
                            }
                        }
                    }
                }
            }

            // Find last assistant text response (walk backwards)
            for line in lines.reversed() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let message = json["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]]
                else { continue }

                let textBlocks = content.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text",
                          let text = block["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return nil }
                    return text
                }

                if !textBlocks.isEmpty {
                    lastAssistantText = textBlocks.joined(separator: "\n\n")
                    break
                }
            }
        }

        // Build prompt arc: sample every Nth prompt to show the journey (max 8 entries)
        let arcSampleRate = max(1, allUserPrompts.count / 8)
        let promptArc = stride(from: 0, to: allUserPrompts.count, by: arcSampleRate).map { i in
            String(allUserPrompts[i].prefix(120))
        }

        // Detect if Claude asked a question
        let claudeQuestion = detectQuestion(in: lastAssistantText)

        // Build problem statement from first 2-3 prompts (condensed)
        let problemStatement: String?
        if allUserPrompts.count >= 2 {
            let first2 = allUserPrompts.prefix(2).map { String($0.prefix(150)) }
            problemStatement = first2.joined(separator: " → ")
        } else {
            problemStatement = mission
        }

        // Current task: from TaskCreate if found, otherwise last prompt as proxy
        let resolvedTask = currentTask ?? (lastUserPrompt.map { String($0.prefix(150)) })

        // Build recent exchanges: pair user prompts with their following assistant responses
        var exchanges: [Exchange] = []
        if let lines = lastLines {
            var pendingPrompt: String?
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String
                else { continue }

                if type == "user", let prompt = extractUserText(from: json) {
                    pendingPrompt = prompt
                }
                if type == "assistant", let prompt = pendingPrompt {
                    if let message = json["message"] as? [String: Any],
                       let content = message["content"] as? [[String: Any]] {
                        let texts = content.compactMap { b -> String? in
                            guard (b["type"] as? String) == "text",
                                  let t = b["text"] as? String,
                                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else { return nil }
                            return t
                        }
                        if !texts.isEmpty {
                            exchanges.append(Exchange(
                                userPrompt: prompt,
                                assistantResponse: texts.joined(separator: "\n\n")
                            ))
                            pendingPrompt = nil
                        }
                    }
                }
            }
        }
        // Keep last 3
        let recentExchanges = Array(exchanges.suffix(3))

        return SessionContext(
            mission: mission,
            problemStatement: problemStatement,
            currentTask: resolvedTask,
            gitBranch: gitBranch,
            promptArc: promptArc,
            lastUserPrompt: lastUserPrompt,
            lastResponse: lastAssistantText,
            claudeQuestion: claudeQuestion,
            turnCount: turnCount,
            filesModified: Array(filesModified).sorted(),
            recentExchanges: recentExchanges
        )
    }

    /// Extract user's actual text from a JSONL user entry (skipping tool results and system noise)
    private static func extractUserText(from json: [String: Any]) -> String? {
        guard json["type"] as? String == "user" else { return nil }
        if json["toolUseResult"] != nil { return nil }

        var text: String?
        if let message = json["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                text = content
            }
            if let content = message["content"] as? [[String: Any]] {
                let hasToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
                if hasToolResult { return nil }
                let texts = content.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text",
                          let t = block["text"] as? String
                    else { return nil }
                    return t
                }
                if !texts.isEmpty { text = texts.joined(separator: "\n") }
            }
        }

        guard let result = text, isRealUserPrompt(result) else { return nil }
        let cleaned = cleanPromptText(result)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Detect if Claude asked a question in its response
    private static func detectQuestion(in response: String?) -> String? {
        guard let text = response else { return nil }
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Only check last 3 non-empty lines — the question should be at the very end
        for line in lines.suffix(3).reversed() {
            // Strip markdown bold markers for clean check
            let clean = line.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)

            // Must end with ? AND be a real question (not just a heading or label)
            if clean.hasSuffix("?") && clean.count > 10 {
                // Verify it reads like a question to the user
                let lower = clean.lowercased()
                if lower.contains("want") || lower.contains("shall") || lower.contains("should") ||
                   lower.contains("would you") || lower.contains("do you") || lower.contains("is this") ||
                   lower.contains("are you") || lower.contains("can i") || lower.contains("proceed") ||
                   lower.contains("or") || lower.contains("which") || lower.contains("how") {
                    return clean
                }
            }
        }
        return nil
    }

    /// Read first N lines of a file efficiently
    private static func readFirstLines(of path: String, count: Int) -> [String]? {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fileHandle.closeFile() }

        // Read first ~10KB — should contain first few entries
        let data = fileHandle.readData(ofLength: count * 2048)
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.prefix(count))
    }

    /// Find transcript path for a session by searching the projects directory
    static func findTranscriptPath(sessionId: String) -> String? {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path

        let (output, exitCode) = Shell.run("find \"\(projectsDir)\" -name \"\(sessionId).jsonl\" -type f 2>/dev/null | head -1")
        guard exitCode == 0, !output.isEmpty else { return nil }
        return output
    }

    // MARK: - Helpers

    private static func readLastLines(of path: String, count: Int) -> [String]? {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        // JSONL lines with base64 images can be 500KB+
        // Read progressively larger chunks until we have enough valid JSON lines
        var validLines: [String] = []
        var chunkMultiplier: UInt64 = 1

        while validLines.count < count && chunkMultiplier <= 16 {
            // Each attempt reads more: 500KB, 1MB, 2MB, up to 8MB
            let chunkSize = min(fileSize, 512_000 * chunkMultiplier)
            fileHandle.seek(toFileOffset: fileSize - chunkSize)
            let data = fileHandle.readDataToEndOfFile()

            guard let content = String(data: data, encoding: .utf8) else { break }
            let rawLines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

            // Keep only lines that parse as valid JSON
            validLines = rawLines.filter { line in
                guard let d = line.data(using: .utf8) else { return false }
                return (try? JSONSerialization.jsonObject(with: d)) != nil
            }

            if validLines.count >= count { break }
            chunkMultiplier *= 2
        }

        return validLines.isEmpty ? nil : Array(validLines.suffix(count))
    }

    private static func parseTimestamp(_ value: Any?) -> Date {
        if let ts = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: ts) ?? Date()
        }
        if let ms = value as? Int64 {
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        if let ms = value as? Double {
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        return Date()
    }
}
