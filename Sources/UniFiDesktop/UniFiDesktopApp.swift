import SwiftUI
import UniFiCore

@main
struct UniFiDesktopApp: App {
    @StateObject private var model = NetworkModel()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        Settings {
            Form {
                Section("Software Updates") {
                    if updater.isConfigured {
                        Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                        Toggle("Download updates in the background", isOn: $updater.automaticallyDownloads)
                            .disabled(!updater.automaticallyChecks)
                        Text("You approve installation and relaunch in Sparkle's update dialog.")
                            .font(.caption)
                        if let date = updater.lastUpdateCheckDate {
                            Text("Last checked: \(date.formatted())")
                                .foregroundStyle(.secondary)
                        }
                        Button("Check for Updates...") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    } else {
                        Text("Updates are unavailable in this build. A signed release must include its HTTPS update feed and Ed25519 public key.")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 480)
        }
    }
}
