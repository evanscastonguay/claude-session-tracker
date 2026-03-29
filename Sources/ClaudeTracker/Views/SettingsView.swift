import SwiftUI
import AVFoundation

struct SettingsView: View {
    @State private var settings = LaunchSettings.load()
    @State private var audioPlayer: AVAudioPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Launch settings
                    settingsSection("New Session") {
                        pickerRow("Permissions", selection: $settings.permissionMode) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                        pickerRow("Model", selection: $settings.model) { model in
                            Text(model.displayName).tag(model)
                        }
                        pickerRow("Agent Teams", selection: $settings.teams) { teams in
                            Text(teams.displayName).tag(teams)
                        }
                        textRow("Claude binary", value: $settings.claudeBinary)
                    }

                    // UI settings
                    settingsSection("Interface") {
                        pickerRow("Terminal app", selection: $settings.terminalApp) { app in
                            Text(app.displayName).tag(app)
                        }
                        HStack {
                            Text("Discovery interval")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $settings.discoveryInterval) {
                                Text("5s").tag(5)
                                Text("10s").tag(10)
                                Text("15s").tag(15)
                                Text("30s").tag(30)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                    }

                    // Notification settings
                    settingsSection("Notifications") {
                        Toggle("Sound enabled", isOn: $settings.soundEnabled)
                            .font(.system(size: 12))

                        if settings.soundEnabled {
                            HStack {
                                Text("Sound")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Picker("", selection: $settings.notificationSound) {
                                    ForEach(LaunchSettings.NotificationSound.allCases) { sound in
                                        Text(sound.displayName).tag(sound)
                                    }
                                }
                                .frame(width: 140)

                                Button(action: { previewSound(settings.notificationSound) }) {
                                    Image(systemName: "speaker.wave.2")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Preview sound")
                            }
                        }

                        Toggle("Auto-summarize (uses Haiku)", isOn: $settings.autoSummarize)
                            .font(.system(size: 12))
                    }
                }
                .padding()
            }
        }
        .frame(width: 420, height: 460)
        .onChange(of: settings.permissionMode) { save() }
        .onChange(of: settings.model) { save() }
        .onChange(of: settings.teams) { save() }
        .onChange(of: settings.terminalApp) { save() }
        .onChange(of: settings.claudeBinary) { save() }
        .onChange(of: settings.soundEnabled) { save() }
        .onChange(of: settings.notificationSound) { save() }
        .onChange(of: settings.autoSummarize) { save() }
        .onChange(of: settings.discoveryInterval) { save() }
    }

    // MARK: - Helpers

    private func save() {
        settings.save()
    }

    private func previewSound(_ sound: LaunchSettings.NotificationSound) {
        guard let url = URL(string: "file://\(sound.path)") else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }

    // MARK: - Reusable Rows

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

    private func pickerRow<T: Hashable & CaseIterable & Identifiable, Label: View>(
        _ title: String,
        selection: Binding<T>,
        @ViewBuilder label: @escaping (T) -> Label
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(Array(T.allCases) as! [T]) { item in
                    label(item)
                }
            }
            .frame(width: 160)
        }
    }

    private func textRow(_ title: String, value: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            TextField("", text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 160)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
