import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Use tmux for session persistence", isOn: $settings.tmuxEnabled)

                if settings.tmuxEnabled {
                    HStack {
                        TextField("tmux path", text: $settings.tmuxPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Button("Browse…") {
                            browseForTmux()
                        }
                    }

                    if FileManager.default.isExecutableFile(atPath: settings.tmuxPath) {
                        Label("Found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Not found at this path", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    Toggle("Standard tmux mode (status bar + prefix shortcuts)", isOn: $settings.tmuxPlayNice)
                        .onChange(of: settings.tmuxPlayNice) { _, _ in
                            TerminalCache.shared.applySettingsToRunningServer()
                        }
                }

                Text("Standard mode changes apply live to running terminals. Toggling tmux on/off only affects new terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label {
                    Text("Muster runs its own isolated tmux server (`-L muster`). Your personal tmux sessions in Terminal/iTerm are never touched.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Terminal")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: settings.tmuxEnabled ? 300 : 180)
    }

    private func browseForTmux() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            settings.tmuxPath = url.path
        }
    }
}

#Preview {
    SettingsView()
}
