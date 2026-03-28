import SwiftUI

struct SessionDetailView: View {
    let session: SessionState
    @ObservedObject var sessionManager: SessionManager
    @State private var panePreview: String?
    @State private var loadingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Action bar
            HStack(spacing: 6) {
                if session.tmuxWindow != nil {
                    Button(action: { sessionManager.switchToSession(session) }) {
                        Label("Switch", systemImage: "arrow.right.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: loadPanePreview) {
                        Label(loadingPreview ? "..." : "Preview", systemImage: "eye")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(loadingPreview)
                }

                Button(action: copyContext) {
                    Label("Copy", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                // Compact metadata
                Text(session.cwd.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Pane preview (if loaded)
            if let preview = panePreview {
                Text(preview)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Trajectory (last few events, always visible)
            if !session.trajectory.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.trajectory.suffix(8).reversed()) { entry in
                        HStack(alignment: .top, spacing: 5) {
                            Text(entryIcon(entry.type))
                                .font(.system(size: 10))
                            Text(entry.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(relativeTime(entry.timestamp))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear {
            sessionManager.loadTrajectory(for: session.id)
        }
    }

    private func loadPanePreview() {
        loadingPreview = true
        Task {
            panePreview = await sessionManager.getPanePreview(for: session)
            loadingPreview = false
        }
    }

    private func copyContext() {
        let tab = session.tabIndex
        let name = session.tmuxWindowName ?? session.projectName
        var ctx = "Tab [\(tab)] \(name)\nProject: \(session.projectName)\nStatus: \(session.statusSummary)\n\(session.currentActivity)"
        if !session.trajectory.isEmpty {
            ctx += "\n\nRecent:"
            for entry in session.trajectory.suffix(5) {
                ctx += "\n  \(entryIcon(entry.type)) \(entry.summary)"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ctx, forType: .string)
    }

    private func entryIcon(_ type: String) -> String {
        switch type {
        case "prompt": return ">"
        case "tool": return "$"
        case "response": return "<"
        case "stop": return "."
        case "notification": return "!"
        case "session_start": return "^"
        default: return " "
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
