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
        // Read the last `count` lines by seeking to end of file and reading backwards
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        // Read last chunk (generous: ~2KB per line should be enough)
        let chunkSize = min(fileSize, UInt64(count * 2048))
        fileHandle.seek(toFileOffset: fileSize - chunkSize)
        let data = fileHandle.readDataToEndOfFile()

        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let allLines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(allLines.suffix(count))
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
