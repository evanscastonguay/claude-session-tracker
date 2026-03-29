import Foundation

/// All tracker settings — launch config, notifications, UI preferences
struct LaunchSettings: Codable {
    // Launch
    var permissionMode: PermissionMode = .bypass
    var model: ModelChoice = .default_
    var teams: TeamsMode = .off
    var claudeBinary: String = "claude"

    // UI
    var terminalApp: TerminalApp = .ghostty

    // Notifications
    var soundEnabled: Bool = true
    var notificationSound: NotificationSound = .glass
    var autoSummarize: Bool = true
    var discoveryInterval: Int = 10

    // MARK: - Enums

    enum PermissionMode: String, Codable, CaseIterable, Identifiable {
        case bypass, plan, default_
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .bypass: return "Bypass (skip all)"
            case .plan: return "Plan mode"
            case .default_: return "Default (ask)"
            }
        }
        var cliArgs: [String] {
            switch self {
            case .bypass: return ["--dangerously-skip-permissions"]
            case .plan: return ["--permission-mode", "plan"]
            case .default_: return []
            }
        }
    }

    enum ModelChoice: String, Codable, CaseIterable, Identifiable {
        case default_, opus, sonnet, haiku
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .default_: return "Default"
            case .opus: return "Opus"
            case .sonnet: return "Sonnet"
            case .haiku: return "Haiku"
            }
        }
        var cliArgs: [String] {
            switch self {
            case .default_: return []
            case .opus: return ["--model", "claude-opus-4-6"]
            case .sonnet: return ["--model", "claude-sonnet-4-6"]
            case .haiku: return ["--model", "claude-haiku-4-5"]
            }
        }
    }

    enum TeamsMode: String, Codable, CaseIterable, Identifiable {
        case off, inProcess, tmux, auto
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .off: return "Off"
            case .inProcess: return "In-process"
            case .tmux: return "tmux"
            case .auto: return "Auto"
            }
        }
        var envVars: [String: String] {
            self == .off ? [:] : ["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"]
        }
        var settingsArg: String? {
            switch self {
            case .off: return nil
            case .inProcess: return "{\"teammateMode\":\"in-process\"}"
            case .tmux: return "{\"teammateMode\":\"tmux\"}"
            case .auto: return "{\"teammateMode\":\"auto\"}"
            }
        }
    }

    enum TerminalApp: String, Codable, CaseIterable, Identifiable {
        case ghostty = "Ghostty"
        case terminal = "Terminal"
        case iterm = "iTerm"
        case alacritty = "Alacritty"
        case wezterm = "WezTerm"
        var id: String { rawValue }
        var displayName: String { rawValue }
    }

    enum NotificationSound: String, Codable, CaseIterable, Identifiable {
        case glass = "Glass"
        case ping = "Ping"
        case hero = "Hero"
        case pop = "Pop"
        case purr = "Purr"
        case tink = "Tink"
        case blow = "Blow"
        case bottle = "Bottle"
        case funk = "Funk"
        case morse = "Morse"
        case submarine = "Submarine"
        case basso = "Basso"
        case sosumi = "Sosumi"
        case frog = "Frog"
        var id: String { rawValue }
        var displayName: String { rawValue }
        var path: String { "/System/Library/Sounds/\(rawValue).aiff" }
    }

    // MARK: - Build launch command

    func buildCommand() -> (env: [String: String], args: [String]) {
        var env: [String: String] = [:]
        var args = [claudeBinary]
        args.append(contentsOf: permissionMode.cliArgs)
        args.append(contentsOf: model.cliArgs)
        env.merge(teams.envVars) { _, new in new }
        if let settingsArg = teams.settingsArg {
            args.append(contentsOf: ["--settings", settingsArg])
        }
        return (env, args)
    }

    // MARK: - Persistence

    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-tracker")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("launch-settings.json")
    }()

    static func load() -> LaunchSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(LaunchSettings.self, from: data)
        else { return LaunchSettings() }
        return settings
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
