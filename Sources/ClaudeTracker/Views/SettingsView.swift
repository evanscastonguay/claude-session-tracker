import SwiftUI
import AVFoundation

struct SettingsView: View {
    @State private var settings = LaunchSettings.load()
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("New Session") {
                row("Permissions") {
                    Picker("", selection: $settings.permissionMode) {
                        ForEach(LaunchSettings.PermissionMode.allCases) { Text($0.displayName).tag($0) }
                    }.frame(width: 160)
                }
                row("Model") {
                    Picker("", selection: $settings.model) {
                        ForEach(LaunchSettings.ModelChoice.allCases) { Text($0.displayName).tag($0) }
                    }.frame(width: 160)
                }
                row("Teams") {
                    Picker("", selection: $settings.teams) {
                        ForEach(LaunchSettings.TeamsMode.allCases) { Text($0.displayName).tag($0) }
                    }.frame(width: 160)
                }
            }

            section("When Session Completes") {
                row("Sound") {
                    HStack(spacing: 6) {
                        Picker("", selection: $settings.notificationSound) {
                            ForEach(LaunchSettings.NotificationSound.allCases) { Text($0.displayName).tag($0) }
                        }.frame(width: 120)
                        Button(action: { previewSound() }) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        Toggle("", isOn: $settings.soundEnabled)
                            .toggleStyle(.switch).controlSize(.small)
                    }
                }
                row("Dock bounce") {
                    Toggle("", isOn: $settings.dockBounce)
                        .toggleStyle(.switch).controlSize(.small)
                }
            }

            section("Advanced") {
                row("Terminal") {
                    Picker("", selection: $settings.terminalApp) {
                        ForEach(LaunchSettings.TerminalApp.allCases) { Text($0.displayName).tag($0) }
                    }.frame(width: 160)
                }
                row("Summarize") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Toggle("", isOn: $settings.autoSummarize)
                            .toggleStyle(.switch).controlSize(.small)
                        Text("Uses Haiku per session")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                row("Poll interval") {
                    Picker("", selection: $settings.discoveryInterval) {
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                        Text("15s").tag(15)
                        Text("30s").tag(30)
                    }
                    .pickerStyle(.segmented).frame(width: 160)
                }
            }
        }
        .padding()
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.permissionMode) { save() }
        .onChange(of: settings.model) { save() }
        .onChange(of: settings.teams) { save() }
        .onChange(of: settings.terminalApp) { save() }
        .onChange(of: settings.soundEnabled) { save() }
        .onChange(of: settings.notificationSound) { save() }
        .onChange(of: settings.autoSummarize) { save() }
        .onChange(of: settings.discoveryInterval) { save() }
        .onChange(of: settings.dockBounce) { save() }
    }

    private func save() { settings.save() }

    private func previewSound() {
        let url = URL(fileURLWithPath: settings.notificationSound.path)
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            VStack(spacing: 8) {
                content()
            }
            .padding(12)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            content()
            Spacer()
        }
    }
}
