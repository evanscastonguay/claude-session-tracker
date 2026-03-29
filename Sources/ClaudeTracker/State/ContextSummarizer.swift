import Foundation

/// Uses Claude (haiku) to generate problem statement + current task from conversation history
enum ContextSummarizer {

    struct Summary {
        let problem: String
        let task: String
    }

    /// Summarize a session's conversation arc into problem + task using Claude haiku
    static func summarize(transcriptPath: String, projectName: String, cwd: String) -> Summary? {
        // Extract last 10 real user prompts
        guard let prompts = extractRecentPrompts(from: transcriptPath, count: 10),
              !prompts.isEmpty
        else { return nil }

        let arc = prompts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let prompt = """
        Given these user prompts from a developer's Claude Code session, respond with EXACTLY two lines:
        PROBLEM: one sentence describing the overall goal of this session
        TASK: one sentence describing what is being worked on right now

        Project: \(projectName)
        Directory: \(cwd)

        User prompts (chronological, most recent last):
        \(arc)

        PROBLEM and TASK only:
        """

        // Call claude -p with haiku for speed
        let (output, exitCode) = Shell.run(
            "claude -p --model haiku --max-turns 1 --no-session-persistence \"\(prompt.replacingOccurrences(of: "\"", with: "\\\""))\" 2>/dev/null"
        )

        guard exitCode == 0, !output.isEmpty else { return nil }

        // Parse PROBLEM: and TASK: lines
        var problem: String?
        var task: String?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PROBLEM:") {
                problem = String(trimmed.dropFirst("PROBLEM:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("TASK:") {
                task = String(trimmed.dropFirst("TASK:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let p = problem, let t = task, !p.isEmpty, !t.isEmpty else { return nil }
        return Summary(problem: p, task: t)
    }

    /// Extract recent real user prompts from JSONL (cleaned of noise)
    private static func extractRecentPrompts(from transcriptPath: String, count: Int) -> [String]? {
        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { fileHandle.closeFile() }

        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        // Read last 2MB — enough for recent conversation
        let chunkSize = min(fileSize, 2_000_000)
        fileHandle.seek(toFileOffset: fileSize - chunkSize)
        let data = fileHandle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        var prompts: [String] = []
        let lines = content.components(separatedBy: "\n")

        for line in lines.reversed() {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "user",
                  json["toolUseResult"] == nil
            else { continue }

            let message = json["message"]
            var text: String?

            if let msg = message as? [String: Any] {
                if let c = msg["content"] as? String {
                    text = c
                } else if let c = msg["content"] as? [[String: Any]] {
                    let hasToolResult = c.contains { ($0["type"] as? String) == "tool_result" }
                    if hasToolResult { continue }
                    let texts = c.compactMap { b -> String? in
                        guard (b["type"] as? String) == "text", let t = b["text"] as? String else { return nil }
                        return t
                    }
                    if !texts.isEmpty { text = texts.joined(separator: " ") }
                }
            }

            guard var t = text else { continue }

            // Filter noise
            if t.hasPrefix("<task-notification>") || t.hasPrefix("<command-") ||
               t.hasPrefix("Base directory for this skill:") || t.hasPrefix("[Image: source:") { continue }

            // Clean
            t = t.replacingOccurrences(of: #"\[Image #\d+\]\s*"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\[Image:[^\]]*\]"#, with: "", options: .regularExpression)
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)

            if !t.isEmpty {
                prompts.append(String(t.prefix(300)))
            }
            if prompts.count >= count { break }
        }

        prompts.reverse()
        return prompts.isEmpty ? nil : prompts
    }
}
