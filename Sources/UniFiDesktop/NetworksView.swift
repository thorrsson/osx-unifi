import SwiftUI
import UniFiCore

struct NetworksPage: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @State private var selection: NetworkSummary.ID?
    @State private var editor: EditorTarget?

    var body: some View {
        PageContainer("Networks", subtitle: "Virtual networks (VLANs), their subnets, and DHCP.") {
            Button { editor = .create } label: { Label("Create Network", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate)
        } content: {
            SectionStateView(state: model.networks, noun: "networks") { networks in
                if networks.isEmpty {
                    EmptyState(title: "No networks", symbol: "point.3.connected.trianglepath.dotted", message: "This site has no networks.")
                } else {
                    table(networks.sorted { ($0.default ? 0 : 1, $0.vlanId) < ($1.default ? 0 : 1, $1.vlanId) })
                }
            }
        }
        .onChange(of: selection) { _, id in if let id { editor = .edit(id) } }
        .onChange(of: editor) { _, target in if target == nil { selection = nil } }
        .editorInspector($editor) { target in
            NetworkEditor(target: target, summary: summary(target)) { editor = nil }
        }
    }

    private func summary(_ target: EditorTarget) -> NetworkSummary? {
        guard case .edit(let id) = target else { return nil }
        return model.networks.value?.first { $0.id == id }
    }

    private func zoneName(_ network: NetworkSummary) -> String {
        model.firewallZones.value?.first { $0.networkIds.contains(network.id) }?.name ?? "—"
    }

    private func table(_ networks: [NetworkSummary]) -> some View {
        Table(networks, selection: $selection) {
            TableColumn("Name") { network in
                HStack(spacing: 6) {
                    Text(network.name).fontWeight(.medium)
                    if network.default { Pill("Default", color: Theme.link) }
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("VLAN") { Text($0.default ? "—" : "\($0.vlanId)").monospacedDigit() }.width(min: 50, ideal: 70)
            TableColumn("Router") { Text($0.managementLabel).foregroundStyle(Theme.secondary) }.width(min: 90, ideal: 130)
            TableColumn("Zone") { Text(zoneName($0)).foregroundStyle(Theme.secondary) }.width(min: 80, ideal: 110)
            TableColumn("Type") { Status.origin($0.metadata) }.width(min: 70, ideal: 90)
            TableColumn("Enabled") { network in
                EnabledToggle(isOn: network.enabled, editable: !network.metadata.isControllerManaged && !network.default,
                              label: "Enable \(network.name)") { value in
                    await model.setEnabled(.networks, id: network.id, name: network.name, enabled: value)
                }
            }
            .width(60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: NetworkSummary.ID.self) { ids in
            if let id = ids.first, let network = model.networks.value?.first(where: { $0.id == id }) {
                Button("Edit...") { editor = .edit(id) }
                if NetworkActions.canDelete(network) {
                    Button("Delete...", role: .destructive) { Task { await NetworkActions.delete(network, model: model, confirm: confirm) } }
                        .disabled(!model.canMutate)
                }
            }
        }
    }
}

enum NetworkActions {
    static func canDelete(_ network: NetworkSummary) -> Bool {
        network.metadata.isUserDefined && !network.default
    }

    static func referenceLabel(_ type: String) -> String {
        switch type {
        case "CLIENT": return "clients"
        case "DEVICE": return "devices"
        case "STATIC_ROUTE": return "static routes"
        case "OSPF_ROUTE": return "OSPF routes"
        case "WIFI": return "WiFi networks"
        case "NAT_RULE": return "NAT rules"
        case "SD_WAN": return "SD-WAN links"
        case "NEXT_AI": return "Next-AI settings"
        default: return type.replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }

    /// Checks references first; forced deletion is only offered when the controller reports what will be affected.
    @MainActor static func delete(_ network: NetworkSummary, model: NetworkModel, confirm: ConfirmCenter, then: (() -> Void)? = nil) async {
        switch await model.networkReferences(network) {
        case .failure(let failure):
            confirm.ask("Delete \(network.name)?", "\(failure.message) The controller will refuse the deletion if anything still uses this network.", action: "Delete") {
                if await model.delete(.networks, id: network.id, name: network.name) { then?() }
            }
        case .success(let references):
            let used = references.filter { $0.referenceCount > 0 }
            if used.isEmpty {
                confirm.ask("Delete \(network.name)?", "This network isn't used by anything. It will be removed from the console.", action: "Delete") {
                    if await model.delete(.networks, id: network.id, name: network.name) { then?() }
                }
            } else {
                let summary = used.map { "\($0.referenceCount) \(referenceLabel($0.resourceType))" }.joined(separator: ", ")
                confirm.ask("\(network.name) is in use", "It is used by \(summary). Deleting it anyway can disconnect clients and devices and break the settings that refer to it.", action: "Delete Anyway") {
                    if await model.delete(.networks, id: network.id, name: network.name, force: true) { then?() }
                }
            }
        }
    }
}

private struct NetworkEditor: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    let target: EditorTarget
    let summary: NetworkSummary?
    let onClose: () -> Void

    private var readOnlyReason: String? {
        guard let summary, summary.metadata.isControllerManaged else { return nil }
        return "This network is \(summary.metadata.label.lowercased()) and managed by the console."
    }

    private var deleteAction: (() -> Void)? {
        guard let summary, NetworkActions.canDelete(summary) else { return nil }
        return { Task { await NetworkActions.delete(summary, model: model, confirm: confirm, then: onClose) } }
    }

    var body: some View {
        ResourceEditor<NetworkDraft, _>(
            kind: .networks, target: target, readOnlyReason: readOnlyReason, onDelete: deleteAction, onClose: onClose
        ) { draft in
            fields(draft)
        }
    }

    @ViewBuilder private func fields(_ draft: Binding<NetworkDraft>) -> some View {
        Section("General") {
            TextField("Name", text: draft.name)
            Toggle("Enabled", isOn: draft.enabled).disabled(draft.wrappedValue.isDefault)
            if draft.wrappedValue.isDefault {
                LabeledContent("VLAN ID", value: "Untagged (default network)")
            } else {
                IntField("VLAN ID", value: draft.vlanId)
            }
            if !draft.wrappedValue.isGatewayManaged {
                LabeledContent("Router", value: draft.wrappedValue.management == "SWITCH" ? "Layer 3 switch" : "Third-party gateway")
                Text("Subnet and DHCP for this network are managed outside the gateway. Use the web UI for those settings.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        if draft.wrappedValue.isGatewayManaged {
            Section("Gateway") {
                TextField("Gateway IP", text: draft.hostIpAddress)
                Picker("Subnet", selection: draft.prefixLength) {
                    ForEach(8...30, id: \.self) { length in
                        Text("/\(length) · \(Self.hosts(length)) hosts").tag(length)
                    }
                }
                Toggle("Auto-scale subnet", isOn: draft.autoScaleEnabled)
                if let zones = model.firewallZones.value {
                    // Consoles may omit zoneId from network details; show the zone that lists this network
                    // without sending a zone change unless one is picked.
                    let current = summary.flatMap { network in zones.first { $0.networkIds.contains(network.id) }?.id }
                    Picker("Firewall zone", selection: Binding(
                        get: { draft.wrappedValue.zoneId ?? current },
                        set: { draft.wrappedValue.zoneId = $0 }
                    )) {
                        if draft.wrappedValue.zoneId == nil, current == nil { Text("Automatic").tag(UUID?.none) }
                        ForEach(zones.sorted { $0.name < $1.name }) { zone in Text(zone.name).tag(Optional(zone.id)) }
                    }
                }
            }
            Section("Advanced") {
                Toggle("Internet access", isOn: draft.internetAccessEnabled)
                Toggle("Isolate network", isOn: draft.isolationEnabled)
                Toggle("Use cellular backup", isOn: draft.cellularBackupEnabled)
                if draft.wrappedValue.mdnsForwardingEnabled != nil {
                    Toggle("Multicast DNS", isOn: Binding(get: { draft.wrappedValue.mdnsForwardingEnabled ?? false },
                                                          set: { draft.wrappedValue.mdnsForwardingEnabled = $0 }))
                }
            }
            Section("DHCP") {
                Picker("Mode", selection: draft.dhcpMode) {
                    ForEach(NetworkDraft.DHCPMode.allCases) { Text($0.label).tag($0) }
                }
                switch draft.wrappedValue.dhcpMode {
                case .server:
                    TextField("Range start", text: draft.dhcpStart)
                    TextField("Range end", text: draft.dhcpStop)
                    IntField("Lease time", value: draft.leaseTimeSeconds, suffix: "sec")
                    TextField("DNS servers", text: draft.dnsServers, prompt: Text("Automatic"))
                    TextField("Domain name", text: draft.domainName, prompt: Text("None"))
                    Toggle("Ping conflict detection", isOn: draft.pingConflictDetectionEnabled)
                case .relay:
                    TextField("DHCP servers", text: draft.relayServers, prompt: Text("10.0.0.5, 10.0.0.6"))
                case .none:
                    Text("Clients on this network need static addresses.").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
        if !target.isCreate {
            Section {
                Text("IPv6, DHCP guarding, and other settings not shown here are kept as they are. Change them in the web UI.")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            }
        }
    }

    static func hosts(_ prefix: Int) -> String {
        max(0, (1 << (32 - prefix)) - 2).formatted()
    }
}
