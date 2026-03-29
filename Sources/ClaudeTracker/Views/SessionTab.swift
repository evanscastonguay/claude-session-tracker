import SwiftUI

struct SessionTab: View {
    let session: SessionState
    let isFocused: Bool
    let onTap: () -> Void

    @State private var dotPhase: CGFloat = 0

    private var needsAction: Bool {
        session.needsAttention || session.status == .waitingForInput
    }

    private var isWorking: Bool {
        session.status == .working
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Number
                Text("\(session.tabIndex)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(numberColor)

                // Name
                Text(session.tmuxWindowName ?? session.projectName)
                    .font(.system(size: 11, weight: isFocused ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(nameColor)

                // State indicator (right side)
                stateIndicator
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { startAnimation() }
        .onChange(of: session.status) { startAnimation() }
    }

    // MARK: - State Indicator (compact, right-aligned)

    @ViewBuilder
    private var stateIndicator: some View {
        if isWorking {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
        } else if needsAction {
            // Needs your input — accent badge
            Text(session.timeSinceStatusChange)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(isFocused ? Color.primary : Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isFocused ? Color.primary.opacity(0.08) : Color.accentColor)
                .clipShape(Capsule())
        } else if session.status == .idle {
            // Idle — dim time
            Text(session.timeSinceStatusChange)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.gray.opacity(0.4))
        } else {
            EmptyView()
        }
    }

    // MARK: - Colors

    private var numberColor: Color {
        if isFocused { return .primary }
        if needsAction { return .accentColor }
        return .secondary
    }

    private var nameColor: Color {
        if isFocused { return .primary }
        if needsAction { return .accentColor.opacity(0.8) }
        if isWorking { return .secondary }
        return Color.gray.opacity(0.5)
    }

    @ViewBuilder
    private var background: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.12))
        } else {
            Color.clear
        }
    }

    // MARK: - Animation

    private func dotOpacity(for index: Int) -> Double {
        let phase = (dotPhase * 3 + Double(index)).truncatingRemainder(dividingBy: 3)
        return phase < 1 ? 0.6 : 0.12
    }

    private func startAnimation() {
        if session.status == .working {
            dotPhase = 0
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                dotPhase = 1
            }
        }
    }
}
