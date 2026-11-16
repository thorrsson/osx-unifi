import SwiftUI
import UniFiCore

@main
struct UniFiDesktopApp: App {
    @StateObject private var model = NetworkModel()
    #if !APP_STORE
    @StateObject private var updater = UpdaterModel()
    #endif

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        #if !APP_STORE
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        #endif
        Settings {
            Form {
                Section("Dashboard") {
                    Stepper(value: $model.statisticsPollSeconds, in: NetworkModel.statisticsPollRange) {
                        Text("Update gateway statistics every \(model.statisticsPollSeconds) \(model.statisticsPollSeconds == 1 ? "second" : "seconds")")
                    }
                    Text("Applies while the Dashboard is open. Other counts update when you refresh.")
                        .font(.caption)
                }
                #if !APP_STORE
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
                #endif
            }
            .formStyle(.grouped)
            .frame(width: 480)
        }
    }
}
