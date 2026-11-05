import SwiftUI
import UniFiCore

struct WiFiPage: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @State private var selection: WiFiBroadcast.ID?
    @State private var editor: EditorTarget?

    var body: some View {
        PageContainer("WiFi", subtitle: "Wireless networks broadcast by your access points.") {
            Button { editor = .create } label: { Label("Create WiFi", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate || model.networks.value == nil)
        } content: {
            SectionStateView(state: model.wifiBroadcasts, noun: "WiFi networks") { broadcasts in
                if broadcasts.isEmpty {
                    EmptyState(title: "No WiFi networks", symbol: "wifi", message: "Create a WiFi network to start broadcasting.")
                } else {
                    table(broadcasts.sorted { $0.name.lowercased() < $1.name.lowercased() })
                }
            }
        }
        .onChange(of: selection) { _, id in if let id { editor = .edit(id) } }
        .onChange(of: editor) { _, target in if target == nil { selection = nil } }
        .editorInspector($editor) { target in
            WiFiEditor(target: target, summary: summary(target)) { editor = nil }
        }
    }

    private func summary(_ target: EditorTarget) -> WiFiBroadcast? {
        guard case .edit(let id) = target else { return nil }
        return model.wifiBroadcasts.value?.first { $0.id == id }
    }

    private func networkName(_ broadcast: WiFiBroadcast) -> String {
        guard let id = broadcast.network?.networkId else {
            return model.networks.value?.first(where: \.default)?.name ?? "Default"
        }
        return model.networks.value?.first { $0.id == id }?.name ?? "—"
    }

    private func table(_ broadcasts: [WiFiBroadcast]) -> some View {
        Table(broadcasts, selection: $selection) {
            TableColumn("Name") { broadcast in
                HStack(spacing: 8) {
                    Image(systemName: broadcast.enabled ? "wifi" : "wifi.slash")
                        .foregroundStyle(broadcast.enabled ? Theme.link : Theme.tertiary).frame(width: 18)
                    Text(broadcast.name).fontWeight(.medium)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Network") { Text(networkName($0)).foregroundStyle(Theme.secondary) }.width(min: 90, ideal: 140)
            TableColumn("Security") { Text($0.securityLabel).foregroundStyle(Theme.secondary) }.width(min: 100, ideal: 150)
            TableColumn("Type") { Status.origin($0.metadata) }.width(min: 70, ideal: 90)
            TableColumn("Enabled") { broadcast in
                EnabledToggle(isOn: broadcast.enabled, editable: broadcast.metadata.isUserDefined, label: "Enable \(broadcast.name)") { value in
                    await model.setEnabled(.wifiBroadcasts, id: broadcast.id, name: broadcast.name, enabled: value)
                }
            }
            .width(60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: WiFiBroadcast.ID.self) { ids in
            if let id = ids.first, let broadcast = model.wifiBroadcasts.value?.first(where: { $0.id == id }) {
                Button("Edit...") { editor = .edit(id) }
                if broadcast.metadata.isUserDefined {
                    Button("Delete...", role: .destructive) { WiFiEditor.confirmDelete(broadcast, model: model, confirm: confirm) }
                        .disabled(!model.canMutate)
                }
            }
        }
    }
}

private struct WiFiEditor: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    let target: EditorTarget
    let summary: WiFiBroadcast?
    let onClose: () -> Void
    @State private var revealPassword = false

    private var readOnlyReason: String? {
        guard let summary, !summary.metadata.isUserDefined else { return nil }
        return "This WiFi network is \(summary.metadata.label.lowercased()) and managed by the console."
    }

    private var deleteAction: (() -> Void)? {
        guard let summary, summary.metadata.isUserDefined else { return nil }
        return { Self.confirmDelete(summary, model: model, confirm: confirm, then: onClose) }
    }

    @MainActor static func confirmDelete(_ broadcast: WiFiBroadcast, model: NetworkModel, confirm: ConfirmCenter, then: (() -> Void)? = nil) {
        confirm.ask("Delete \(broadcast.name)?", "Access points stop broadcasting it and its clients are disconnected.", action: "Delete") {
            if await model.delete(.wifiBroadcasts, id: broadcast.id, name: broadcast.name) { then?() }
        }
    }

    var body: some View {
        ResourceEditor<WiFiDraft, _>(
            kind: .wifiBroadcasts, target: target, readOnlyReason: readOnlyReason, onDelete: deleteAction, onClose: onClose
        ) { draft in
            fields(draft)
        }
    }

    @ViewBuilder private func fields(_ draft: Binding<WiFiDraft>) -> some View {
        Section("General") {
            TextField("Name", text: draft.name)
            Toggle("Enabled", isOn: draft.enabled)
            if draft.wrappedValue.securityEditable {
                Picker("Security", selection: draft.securityType) {
                    ForEach(WiFiSecurity.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if draft.wrappedValue.security?.usesPassphrase == true {
                    LabeledContent("Password") {
                        HStack(spacing: 6) {
                            Group {
                                if revealPassword {
                                    TextField("Password", text: draft.passphrase)
                                } else {
                                    SecureField("Password", text: draft.passphrase)
                                }
                            }
                            .labelsHidden()
                            Button { revealPassword.toggle() } label: {
                                Image(systemName: revealPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
                        }
                    }
                }
            } else {
                LabeledContent("Security", value: WiFiSecurity.label(for: draft.wrappedValue.securityType))
                Text("Enterprise security is kept as configured. Change it in the web UI.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            if let networks = model.networks.value {
                let defaultNetwork = networks.first(where: \.default)
                // A broadcast can name the default network explicitly; show that as the default choice.
                Picker("Network", selection: Binding(
                    get: { draft.wrappedValue.networkId == defaultNetwork?.id ? nil : draft.wrappedValue.networkId },
                    set: { draft.wrappedValue.networkId = $0 }
                )) {
                    Text(defaultNetwork?.name ?? "Default network").tag(UUID?.none)
                    ForEach(networks.filter { !$0.default }.sorted { $0.vlanId < $1.vlanId }) { network in
                        Text("\(network.name) (VLAN \(network.vlanId))").tag(Optional(network.id))
                    }
                }
            }
        }
        if draft.wrappedValue.isStandard {
            Section("Broadcasting") {
                LabeledContent("Bands") {
                    HStack(spacing: 6) {
                        ForEach(WiFiDraft.frequencies, id: \.self) { band in
                            Toggle(band == 2.4 ? "2.4 GHz" : "\(Int(band)) GHz", isOn: Binding(
                                get: { draft.wrappedValue.broadcastingFrequenciesGHz.contains(band) },
                                set: { on in
                                    if on { draft.wrappedValue.broadcastingFrequenciesGHz.insert(band) }
                                    else { draft.wrappedValue.broadcastingFrequenciesGHz.remove(band) }
                                }
                            ))
                            .toggleStyle(.button)
                        }
                    }
                }
                if draft.wrappedValue.bandSteeringEnabled != nil {
                    Toggle("Band steering", isOn: Binding(get: { draft.wrappedValue.bandSteeringEnabled ?? false },
                                                          set: { draft.wrappedValue.bandSteeringEnabled = $0 }))
                }
                if draft.wrappedValue.broadcastingFrequenciesGHz.contains(6),
                   draft.wrappedValue.security == .wpa2 || draft.wrappedValue.security == .open {
                    Label("6 GHz requires WPA3 security. The console may reject this combination.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
        }
        Section("Advanced") {
            Toggle("Hide WiFi name", isOn: draft.hideName)
            Toggle("Client device isolation", isOn: draft.clientIsolationEnabled)
            Text(target.isCreate
                 ? "Uses the console's standard defaults for roaming, multicast, and power saving. Fine-tune them in the web UI."
                 : "Roaming, rate control, schedules, and other settings not shown here are kept as they are.")
                .font(.caption).foregroundStyle(Theme.tertiary)
        }
    }
}
