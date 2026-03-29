import SwiftUI

struct SessionTab: View {
    let session: SessionState
    let isFocused: Bool
    let onTap: () -> Void
    let onRename: (String) -> Void

    @State private var dotPhase: CGFloat = 0
    @State private var isEditing = false
    @State private var editText = ""

    private var needsAction: Bool {
        session.needsAttention || session.status == .waitingForInput
    }

    private var isWorking: Bool {
        session.status == .working
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(session.tabIndex)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(numberColor)

                    // Name — either editable TextField or static Text
                    if isEditing {
                        TextField("", text: $editText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .onSubmit { commitRename() }
                            .onExitCommand { cancelRename() }
                            .onChange(of: isFocused) { if !isFocused { cancelRename() } }
                    } else {
                        Text(session.tmuxWindowName ?? session.projectName)
                            .font(.system(size: 11, weight: isFocused ? .medium : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(nameColor)
                            .onTapGesture(count: 2) { startRename() }
                    }

                    Spacer()

                    stateIndicator
                }

                if isFocused, let problem = session.problemStatement {
                    Text(problem)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { startAnimation() }
        .onChange(of: session.status) { startAnimation() }
    }

    // MARK: - Rename

    private func startRename() {
        editText = session.tmuxWindowName ?? session.projectName
        isEditing = true
    }

    private func commitRename() {
        let name = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !name.isEmpty else { return }
        onRename(name)
    }

    private func cancelRename() {
        isEditing = false
    }

    // MARK: - State Indicator

    @ViewBuilder
    private var stateIndicator: some View {
        if isWorking {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
        } else if needsAction {
            Text(session.timeSinceStatusChange)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(isFocused ? Color.primary : Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isFocused ? Color.primary.opacity(0.08) : Color.accentColor)
                .clipShape(Capsule())
        } else if session.status == .idle {
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

    private func startAnimation() {
        if session.status == .working {
            dotPhase = 0
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                dotPhase = 1
            }
        }
    }
}
