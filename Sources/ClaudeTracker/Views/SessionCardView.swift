import SwiftUI

struct SessionCardView: View {
    let session: SessionState
    let onSwitch: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 4)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                // Line 1: [tab] window-name                    ctx%
                HStack(spacing: 6) {
                    Text("[\(session.tabIndex)]")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                    Text(session.tmuxWindowName ?? session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if let ctx = session.contextPercent {
                        contextBadge(ctx)
                    }
                }

                // Line 2: project · Status duration
                HStack(spacing: 4) {
                    Text(session.projectName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(session.statusSummary)
                        .font(.system(size: 11, weight: session.needsAttention ? .semibold : .regular))
                        .foregroundStyle(statusColor)
                }

                // Line 3: Current activity (compact)
                if !session.needsAttention {
                    Text(session.currentActivity)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // COMPLETION CONTEXT — auto-expanded when session just finished
                if session.needsAttention {
                    completionView
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 6)
            .padding(.trailing, 8)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: session.needsAttention ? 1.5 : 0.5)
        )
    }

    // MARK: - Completion Context View

    @ViewBuilder
    private var completionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Last user prompt
            if let prompt = session.lastUserPrompt {
                HStack(alignment: .top, spacing: 4) {
                    Text("You:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .italic()
                }
            }

            // Claude's response
            if let response = session.lastResponse {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(response)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Action: Switch
            Button(action: onSwitch) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Switch to Tab \(session.tabIndex)")
                }
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(statusColor)
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func contextBadge(_ ctx: Int) -> some View {
        let color: Color = ctx > 80 ? .red : ctx > 50 ? .orange : .secondary
        Text("\(ctx)%")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var statusColor: Color {
        switch session.status {
        case .working: return .blue
        case .idle: return session.needsAttention ? .orange : .green
        case .waitingForInput: return .orange
        case .error: return .red
        case .ended: return .gray
        }
    }

    private var cardBackground: Color {
        session.needsAttention ? Color.orange.opacity(0.04) : Color.primary.opacity(0.02)
    }

    private var borderColor: Color {
        session.needsAttention ? Color.orange.opacity(0.4) : Color.primary.opacity(0.08)
    }
}
