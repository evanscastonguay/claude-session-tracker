# Claude Session Tracker — Implementation Plan

**Goal:** macOS menu bar app that tracks parallel Claude Code sessions, provides context recovery, and alerts when sessions need attention.

**Architecture:** SwiftUI `MenuBarExtra` app + embedded HTTP server. Claude Code hooks POST events to `localhost:7429`. App aggregates state, displays dashboard, sends alerts, enables quick-switch via tmux.

---

## Scope & Deliverables

1. **Menu bar icon** with dynamic badge (idle/attention/working)
2. **Popup dashboard** showing all active sessions with status, project, context %, last activity
3. **Context trajectory** per session: last user prompt, current task, conversation trajectory from JSONL
4. **Differentiated alerts**: distinct sounds + native notifications for idle, permission prompt, error
5. **Quick switch**: click session card → `tmux select-window` to that pane
6. **Auto-start**: LaunchAgent for login startup
7. **Claude hooks config**: `settings.json` hooks that POST events to the app

---

## Confirmed Technical Foundation

From experiments:

- **Hook payload**: `{ session_id, transcript_path, cwd, permission_mode, hook_event_name, tool_name, tool_input, tool_response, tool_use_id }`
- **Stop payload**: `{ session_id, transcript_path, cwd, permission_mode, hook_event_name, stop_hook_active }`
- **Notification hook**: fires with query `idle_prompt` when Claude waits for user input
- **Session files**: `~/.claude/sessions/{pid}.json` → `{ pid, sessionId, cwd, startedAt, kind, entrypoint }`
- **PID correlation**: Claude PID → `ps -o ppid=` → tmux pane PID → `tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}'`
- **Conversation JSONL**: `~/.claude/projects/{project-path}/{session-id}.jsonl` — contains messages, tool use, timestamps, model, branch, slug
- **history.jsonl**: `~/.claude/history.jsonl` — `{ display, sessionId, timestamp, project }`
- **Hooks are global**: single `settings.json` config captures events from ALL concurrent sessions
- **tmux capture-pane**: can read last N lines from any pane, shows `❯` prompt when idle
- **macOS**: Swift 6.3, Xcode 26.4, arm64-apple-macosx26.0

---

## Phase 1: Project Skeleton + Menu Bar Icon
**Goal:** A running .app bundle that shows an icon in the menu bar with a static popup.

### Steps
1. Create SPM project at `~/project/claude-session-tracker/`
   - `Package.swift` targeting macOS 14+
   - `Sources/ClaudeTracker/App.swift` with `@main` struct
   - `Sources/ClaudeTracker/ContentView.swift` — static "Hello" popup
2. Create `Info.plist` with `LSUIElement = true` (no dock icon)
3. Create `Makefile` with:
   - `build`: `swift build -c release`
   - `bundle`: creates `ClaudeTracker.app/Contents/{MacOS,Resources,Info.plist}`
   - `run`: `open ClaudeTracker.app`
   - `install`: copies to `/Applications/` or `~/Applications/`
4. `MenuBarExtra` with `.menuBarExtraStyle(.window)`, SF Symbol `brain.head.profile`
5. Static `ContentView` with placeholder text, `.frame(width: 380, height: 500)`

### Validation
- `make build && make bundle && make run` → icon appears in menu bar
- Click icon → popup appears with placeholder content
- No dock icon visible
- Click away → popup dismisses

### Checkpoint: Menu bar app runs, shows icon and popup.

---

## Phase 2: HTTP Server + Hook Events
**Goal:** App receives real-time events from Claude Code via HTTP hooks.

### Steps
1. Create `Sources/ClaudeTracker/Server/HTTPServer.swift`
   - `NWListener` on `127.0.0.1:7429`
   - Parse POST body as JSON
   - Route: `POST /events` → decode `HookEvent`, emit to state manager
   - Route: `GET /health` → return `{"status": "ok"}`
2. Create `Sources/ClaudeTracker/Models/HookEvent.swift`
   - `struct HookEvent: Codable` matching the confirmed payload schema
   - `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`
   - Optional: `tool_name`, `tool_input`, `tool_response`, `tool_use_id`, `stop_hook_active`
3. Start server in `App.init()` or `.task {}` on the MenuBarExtra
4. Create hook config script: `scripts/install-hooks.sh`
   - Reads current `~/.claude/settings.json`
   - Adds HTTP hooks for: `Stop`, `Notification`, `UserPromptSubmit`, `PostToolUse` (filtered to Edit|Write|Bash), `SessionStart`, `SessionEnd`
   - Each hook: `type: "command"`, runs `curl -s -X POST http://localhost:7429/events -d @-` (receives JSON on stdin, POSTs to app)
   - Why command+curl not HTTP type: command hooks are proven to work; HTTP hook type behavior is less tested. curl piping stdin is simple and reliable.
   - Backs up settings before modifying

### Hook Configuration
```json
{
  "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -s -X POST http://localhost:7429/events -H 'Content-Type: application/json' -d @- > /dev/null 2>&1 &" }] }],
  "Notification": [{ "matcher": "idle_prompt", "hooks": [{ "type": "command", "command": "curl -s -X POST http://localhost:7429/events -H 'Content-Type: application/json' -d @- > /dev/null 2>&1 &" }] }],
  "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -s -X POST http://localhost:7429/events -H 'Content-Type: application/json' -d @- > /dev/null 2>&1 &" }] }],
  "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -s -X POST http://localhost:7429/events -H 'Content-Type: application/json' -d @- > /dev/null 2>&1 &" }] }],
  "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -s -X POST http://localhost:7429/events -H 'Content-Type: application/json' -d @- > /dev/null 2>&1 &" }] }]
}
```

### Validation
- Start app, run `curl -X POST http://localhost:7429/events -d '{"session_id":"test","hook_event_name":"Stop","cwd":"/tmp"}' -H 'Content-Type: application/json'` → 200 OK
- Install hooks, interact with a Claude session → events appear in app logs (print to console initially)
- Verify existing hooks (superpowers SessionStart, Notification sound) still work (our hooks are additive, not replacing)

### Checkpoint: App receives and logs hook events from live Claude sessions.

---

## Phase 3: State Management + Session Discovery
**Goal:** Aggregate hook events into a coherent per-session state model. Discover sessions from filesystem.

### Steps
1. Create `Sources/ClaudeTracker/Models/SessionState.swift`
   ```swift
   struct SessionState: Identifiable, Codable {
       let id: String              // session_id UUID
       var cwd: String             // working directory
       var projectName: String     // basename of cwd
       var transcriptPath: String  // path to JSONL
       var status: SessionStatus   // .working, .idle, .waitingForInput, .error, .ended
       var lastEvent: String       // last hook_event_name
       var lastEventTime: Date
       var lastUserPrompt: String? // from UserPromptSubmit or history.jsonl
       var lastToolName: String?   // from PostToolUse
       var lastToolDescription: String? // tool_input.description
       var contextPercent: Int?    // from tmux capture-pane status line
       var tmuxWindow: String?     // "0:2" format
       var tmuxWindowName: String? // human-readable name
       var slug: String?           // session slug from JSONL
       var pid: Int?               // Claude process PID
       var conversationTrajectory: [TrajectoryEntry] // last N significant events
   }

   enum SessionStatus: String, Codable {
       case working, idle, waitingForInput, error, ended
   }

   struct TrajectoryEntry: Codable, Identifiable {
       let id: UUID
       let timestamp: Date
       let type: String            // "prompt", "tool", "response", "milestone"
       let summary: String         // 1-line description
   }
   ```

2. Create `Sources/ClaudeTracker/State/SessionManager.swift`
   - `@MainActor class SessionManager: ObservableObject`
   - `@Published var sessions: [SessionState]`
   - `func handleEvent(_ event: HookEvent)` — updates or creates session state
   - Status transitions:
     - `UserPromptSubmit` → `.working`
     - `PostToolUse` → `.working` (update lastTool*)
     - `Stop` → `.idle`
     - `Notification:idle_prompt` → `.waitingForInput`
     - `SessionEnd` → `.ended`
     - `SessionStart` → `.working` (or creates new entry)
   - Builds `conversationTrajectory` by appending significant events (prompts, milestones)
   - Prunes ended sessions after 5 minutes

3. Create `Sources/ClaudeTracker/State/SessionDiscovery.swift`
   - On startup and every 30s: scan `~/.claude/sessions/*.json`
   - For each: read PID, sessionId, cwd, startedAt
   - Correlate to tmux: `ps -o ppid= -p {pid}` → tmux pane PID
   - Run `tmux list-panes -a -F '{pane_pid} {session_name}:{window_index} {window_name}'`
   - Match pane PID → get tmux window info
   - Run `tmux capture-pane -t {window} -p -S -3` → extract context % from status line
   - Merge into existing SessionManager state (don't overwrite hook-derived data)

4. Create `Sources/ClaudeTracker/State/TrajectoryBuilder.swift`
   - On session discovery or when trajectory is empty: read last 50 entries from `transcript_path` (JSONL)
   - Extract: user prompts (type=user with non-tool-result content), tool use summaries, assistant milestones
   - Build trajectory entries with timestamps and 1-line summaries
   - For user prompts: use the `display` field from `history.jsonl` if available (cleaner text)

5. JSON persistence: save `sessions` array to `~/.claude-tracker/state.json` on every state change (debounced to 1s)

### Validation
- Launch app → discovers existing 4 sessions from `~/.claude/sessions/`
- Each session shows correct cwd, projectName, tmux window
- Send a prompt in another Claude session → status transitions to `.working`
- Claude finishes → status transitions to `.waitingForInput`
- Trajectory shows last N user prompts and tool activities

### Checkpoint: App maintains accurate real-time state for all Claude sessions.

---

## Phase 4: Session Dashboard View
**Goal:** Rich SwiftUI popup showing all sessions with status, context, and trajectory.

### Steps
1. Create `Sources/ClaudeTracker/Views/DashboardView.swift`
   - Header: "Claude Sessions" + session count badge + settings gear icon
   - ScrollView with session cards
   - Footer: "Quit" button + app version

2. Create `Sources/ClaudeTracker/Views/SessionCardView.swift`
   - Project name (bold) + status badge (colored dot: green=working, yellow=idle, red=waitingForInput, gray=ended)
   - Working directory (truncated, monospace)
   - tmux window name + context % bar
   - Last activity: "2m ago — Editing foo.swift" or "Waiting for input"
   - Last user prompt (1 line, dimmed)
   - Click → calls `tmux select-window -t {window}` + brings Terminal.app to front

3. Create `Sources/ClaudeTracker/Views/SessionDetailView.swift` (expandable or sheet)
   - Full conversation trajectory (scrollable list of TrajectoryEntry)
   - Last 5 user prompts with timestamps
   - Last 5 tool uses with descriptions
   - Session metadata: started at, context %, model, branch, slug
   - "Copy Context Summary" button (copies a text summary to clipboard)

4. Dynamic menu bar icon:
   - Default: `brain.head.profile` (no sessions need attention)
   - Attention: `brain.head.profile.fill` + badge (at least one session waiting for input)
   - Use `@Published var needsAttention: Bool` on SessionManager

5. Color coding for session status:
   - `.working` → blue pulse
   - `.idle` → green
   - `.waitingForInput` → orange/amber
   - `.error` → red
   - `.ended` → gray

### Validation
- Click menu bar icon → popup shows all 4 current sessions
- Each card shows correct project name, status, tmux window
- Click a session card → terminal switches to that tmux window
- When a session becomes idle → icon changes to attention state
- Expand a card → shows trajectory

### Checkpoint: Fully functional dashboard with session cards and quick-switch.

---

## Phase 5: Alerts (Audio + Notifications)
**Goal:** Differentiated alerts when sessions need attention.

### Steps
1. Create `Sources/ClaudeTracker/Alerts/AlertManager.swift`
   - `func alert(session: SessionState, event: HookEvent)`
   - Alert types:
     - **Idle/waiting for input**: gentle notification + distinct sound
     - **Permission prompt**: urgent notification + attention sound
     - **Error/failure**: error notification + error sound
     - **Session completed**: completion chime
   - Cooldown: don't re-alert for the same session within 60s
   - Track which sessions have been alerted and cleared

2. Native notifications via `UNUserNotificationCenter`:
   - Title: "Claude — {projectName}"
   - Body: "Waiting for input" / "Permission needed" / "Task complete"
   - Category actions: "Switch to Session" (actionable notification)
   - Request permission on first launch

3. Audio differentiation:
   - Idle: `/System/Library/Sounds/Glass.aiff` (gentle)
   - Permission: `/System/Library/Sounds/Ping.aiff` (attention)
   - Error: `/System/Library/Sounds/Basso.aiff` (warning)
   - Completion: `/System/Library/Sounds/Hero.aiff` (success)
   - Use `AVAudioPlayer` or `NSSound` for playback
   - **Important**: Remove or coordinate with existing Notification hook sound in `settings.json` to avoid double-play

4. Notification tap action: clicking the notification should call `tmux select-window` + activate Terminal

### Validation
- Claude session finishes and goes idle → notification appears with correct project name + glass sound
- Clicking the notification → switches to correct tmux window
- Multiple alerts don't stack (cooldown works)
- Different events produce different sounds

### Checkpoint: Alerts work reliably with audio + visual differentiation.

---

## Phase 6: Context Trajectory + Recovery
**Goal:** When switching to a session, show rich context to minimize re-reading scrollback.

### Steps
1. Enhance `TrajectoryBuilder` to read full JSONL on demand:
   - Parse assistant messages for key outputs (not just tool use)
   - Identify "milestone" messages: MR created, tests passed, deployment started, errors encountered
   - Extract current task from TaskCreate/TaskUpdate tool uses if present
   - Summarize conversation arc: "Started with X → did Y → currently at Z"

2. Add "Context Panel" to SessionDetailView:
   - **Current Task**: from latest TaskCreate/TaskUpdate, or last user prompt
   - **Trajectory**: timeline of significant events with relative timestamps
   - **Last Claude Output**: last ~5 lines of Claude's response (from capture-pane)
   - **Key Files Modified**: from Edit/Write tool uses in last N events
   - **Open Questions**: if Claude asked a question (from capture-pane `❯` detection)

3. Add "Copy Context" button:
   - Generates a text block:
     ```
     Session: {projectName} ({slug})
     Branch: {branch}
     Status: {status}
     Last prompt: "{lastUserPrompt}"
     Current task: {currentTask}
     Trajectory: {trajectory summary}
     ```
   - Useful for pasting into a new Claude session if you need to continue elsewhere

4. Add tmux pane preview:
   - When hovering over a session card, capture last 10 lines from the pane
   - Show in a tooltip or expandable section
   - Refresh on hover (not continuously — to avoid polling overhead)

### Validation
- Open session detail → trajectory shows meaningful chronological summary
- "Current Task" accurately reflects what the session is doing
- "Copy Context" produces a useful summary
- Pane preview shows current terminal state

### Checkpoint: Context recovery takes <5 seconds instead of reading scrollback.

---

## Phase 7: Polish + Auto-Start
**Goal:** Production-ready personal tool.

### Steps
1. **LaunchAgent**: Create `~/Library/LaunchAgents/com.evanscastonguay.claude-tracker.plist`
   - `RunAtLoad: true`, `KeepAlive: { SuccessfulExit: false }`
   - Points to installed .app bundle
   - Add `make install-launchagent` target

2. **Error handling**:
   - Server port already in use → retry with backoff, show error in popup
   - Claude session file deleted → remove from state
   - Malformed hook payload → log and skip
   - tmux not running → graceful degradation (no window info, no quick-switch)

3. **Settings view** (in popup footer):
   - Alert sound on/off per event type
   - Notification on/off
   - Cooldown duration slider
   - Port number

4. **Performance**:
   - Debounce state saves to 1s
   - Debounce tmux queries to 5s
   - JSONL reading: only read new entries (track file offset)
   - Limit trajectory to last 50 entries

5. **Hook installation**: `make install-hooks` merges tracker hooks into existing `settings.json` without breaking existing hooks

6. **Uninstall**: `make uninstall` removes hooks from settings, stops LaunchAgent, removes app

### Validation
- Reboot → app auto-starts and discovers sessions
- Kill app → LaunchAgent restarts it
- `make install && make install-hooks && make install-launchagent` → everything works
- `make uninstall` → clean removal

### Checkpoint: Ship it. Daily driver ready.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `NWListener` requires entitlements or triggers firewall dialog | App can't receive events | Bind strictly to `127.0.0.1` (loopback) — confirmed this avoids firewall dialog |
| `UNUserNotificationCenter` requires bundle ID | Notifications don't work | Use `.app` bundle with `Info.plist` containing `CFBundleIdentifier` |
| Hook curl commands add latency to Claude operations | Slows down Claude | Use `& ` (background) and `> /dev/null` — fire-and-forget, zero blocking |
| JSONL files are large (MB+) for long sessions | Slow trajectory loading | Read only last 50 lines via `tail`, track file offset for incremental reads |
| Settings.json modification breaks existing hooks | Superpowers plugin or sound hook stops working | Install script merges hooks (appends to arrays), never replaces. Backup before modify. |
| Multiple app instances on same port | Port conflict | Check `lsof -i :7429` on startup, kill existing or exit with message |
| tmux not running | No window correlation | Graceful degradation — show sessions without tmux metadata, disable quick-switch |
| Swift compilation time | Slow iteration | SPM incremental builds are fast (~2s). Only full rebuild on dependency changes. |

---

## File Structure

```
~/project/claude-session-tracker/
├── Package.swift
├── Makefile
├── Info.plist
├── PLAN.md
├── README.md                    # (only if needed)
├── scripts/
│   ├── install-hooks.sh         # merges tracker hooks into settings.json
│   ├── uninstall-hooks.sh
│   └── com.evanscastonguay.claude-tracker.plist
├── Sources/
│   └── ClaudeTracker/
│       ├── App.swift                           # @main, MenuBarExtra
│       ├── Models/
│       │   ├── HookEvent.swift                 # Codable hook payload
│       │   ├── SessionState.swift              # Per-session state model
│       │   └── TrajectoryEntry.swift           # Conversation trajectory item
│       ├── Server/
│       │   └── HTTPServer.swift                # NWListener HTTP server
│       ├── State/
│       │   ├── SessionManager.swift            # Central state aggregator
│       │   ├── SessionDiscovery.swift          # Filesystem + tmux scanner
���       │   └── TrajectoryBuilder.swift         # JSONL parser + trajectory
│       ├── Alerts/
│       │   └─�� AlertManager.swift              # Notifications + audio
│       ├── Views/
│       │   ├── DashboardView.swift             # Main popup view
│       │   ├── SessionCardView.swift           # Individual session card
│       │   └── SessionDetailView.swift         # Expanded trajectory view
│       └── Utilities/
│           ├── Shell.swift                     # Process wrapper for tmux
│           └── JSONStore.swift                 # JSON file persistence
└── ClaudeTracker.app/                          # Built by `make bundle`
    └── Contents/
        ├── MacOS/ClaudeTracker
        ├── Resources/
        └── Info.plist
```

---

## First Concrete Action

**Phase 1, Step 1**: Create the SPM project with `Package.swift`, minimal `App.swift` with `MenuBarExtra`, `Info.plist`, and `Makefile`. Build and run to verify the icon appears in the menu bar.

---

## Checkpoints Summary

| Phase | Checkpoint | Go/No-Go Criteria |
|---|---|---|
| 1 | Menu bar app runs | Icon visible, popup opens, no dock icon |
| 2 | Receives hook events | curl test + live Claude session events arrive |
| 3 | State management works | Accurate real-time session status for all 4 sessions |
| 4 | Dashboard functional | Session cards with status, quick-switch works |
| 5 | Alerts work | Differentiated audio + notifications, cooldown, tap-to-switch |
| 6 | Context recovery | Trajectory + current task + pane preview < 5s to orient |
| 7 | Production ready | Auto-start, install/uninstall, error handling |
