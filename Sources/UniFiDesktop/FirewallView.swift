import SwiftUI
import UniFiCore

struct FirewallPage: View {
    enum Tab: String, CaseIterable, Identifiable {
        case policies = "Policies", zones = "Zones", aclRules = "ACL Rules", lists = "Lists"
        var id: Self { self }
    }

    @EnvironmentObject private var model: NetworkModel
    @State private var tab = Tab.policies

    var body: some View {
        Group {
            switch tab {
            case .policies: PoliciesView(tab: $tab)
            case .zones: ZonesView(tab: $tab)
            case .aclRules: ACLRulesView(tab: $tab)
            case .lists: TrafficListsView(tab: $tab)
            }
        }
    }
}

struct TabPicker: View {
    @Binding var tab: FirewallPage.Tab

    var body: some View {
        Picker("View", selection: $tab) {
            ForEach(FirewallPage.Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 340)
    }
}

// MARK: - Policies

private struct PoliciesView: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @Binding var tab: FirewallPage.Tab
    @State private var selection: FirewallPolicy.ID?
    @State private var editor: EditorTarget?
    @State private var showBuiltIn = true
    @State private var search = ""

    var body: some View {
        PageContainer("Firewall", subtitle: "Zone-based policies, evaluated in order.") {
            TabPicker(tab: $tab)
            Toggle("Built-in", isOn: $showBuiltIn).toggleStyle(.checkbox).help("Show system-defined policies")
            Button { editor = .create } label: { Label("Create Policy", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate || model.firewallZones.value == nil)
        } content: {
            SectionStateView(state: model.firewallPolicies, noun: "firewall policies") { policies in
                let rows = filtered(policies)
                if rows.isEmpty {
                    EmptyState(title: "No policies", symbol: "shield", message: policies.isEmpty ? "This site has no firewall policies." : "No policies match.")
                } else {
                    table(rows)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search policies")
        .onChange(of: selection) { _, id in if let id { editor = .edit(id) } }
        .onChange(of: editor) { _, target in if target == nil { selection = nil } }
        .editorInspector($editor) { target in
            PolicyEditor(target: target, summary: summary(target)) { editor = nil }
        }
    }

    private func summary(_ target: EditorTarget) -> FirewallPolicy? {
        guard case .edit(let id) = target else { return nil }
        return model.firewallPolicies.value?.first { $0.id == id }
    }

    private func filtered(_ policies: [FirewallPolicy]) -> [FirewallPolicy] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return policies
            .filter { showBuiltIn || $0.metadata.isUserDefined }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || zone($0.source.zoneId).localizedCaseInsensitiveContains(query) || zone($0.destination.zoneId).localizedCaseInsensitiveContains(query) }
            .sorted { $0.index < $1.index }
    }

    private func zone(_ id: UUID) -> String {
        model.firewallZones.value?.first { $0.id == id }?.name ?? "Unknown zone"
    }

    private func table(_ policies: [FirewallPolicy]) -> some View {
        Table(policies, selection: $selection) {
            TableColumn("#") { Text(verbatim: String($0.index)).monospacedDigit().foregroundStyle(Theme.tertiary) }.width(min: 50, ideal: 56)
            TableColumn("Name") { policy in
                VStack(alignment: .leading, spacing: 1) {
                    Text(policy.name).fontWeight(.medium)
                    if let description = policy.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Action") { Status.action($0.action.type) }.width(min: 60, ideal: 70)
            TableColumn("Source → Destination") { policy in
                Text("\(zone(policy.source.zoneId)) → \(zone(policy.destination.zoneId))").foregroundStyle(Theme.secondary)
            }
            .width(min: 140, ideal: 200)
            TableColumn("IP") { Text(FirewallPolicyDraft.label(forIPVersion: $0.ipProtocolScope.ipVersion)).foregroundStyle(Theme.secondary) }
                .width(min: 50, ideal: 90)
            TableColumn("Type") { Status.origin($0.metadata) }.width(min: 70, ideal: 80)
            TableColumn("Logging") { policy in
                EnabledToggle(isOn: policy.loggingEnabled, label: "Log \(policy.name)") { value in
                    await model.patch(policy, .logging(value))
                }
            }
            .width(56)
            TableColumn("Enabled") { policy in
                EnabledToggle(isOn: policy.enabled, editable: policy.metadata.isUserDefined, label: "Enable \(policy.name)") { value in
                    await model.setEnabled(.firewallPolicies, id: policy.id, name: policy.name, enabled: value)
                }
            }
            .width(56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: FirewallPolicy.ID.self) { ids in
            if let id = ids.first, let policy = model.firewallPolicies.value?.first(where: { $0.id == id }) {
                Button(policy.metadata.isUserDefined ? "Edit..." : "View...") { editor = .edit(id) }
                if model.supportsFlowReporting, let reporting = policy.reportFlowEnabled {
                    Button(reporting ? "Stop Reporting Flows" : "Report Flows") {
                        Task { await model.patch(policy, .flowReporting(!reporting)) }
                    }
                    .disabled(!model.canMutate)
                }
                if policy.metadata.isUserDefined {
                    Divider()
                    Button("Move Up") { Task { await model.move(policy, .earlier) } }
                    Button("Move Down") { Task { await model.move(policy, .later) } }
                    Button("Evaluate Before Built-in Policies") { Task { await model.move(policy, .beforeSystemDefined) } }
                    Button("Evaluate After Built-in Policies") { Task { await model.move(policy, .afterSystemDefined) } }
                    Divider()
                    Button("Delete...", role: .destructive) { PolicyEditor.confirmDelete(policy, model: model, confirm: confirm) }
                }
            }
        }
    }
}

private struct PolicyEditor: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @Environment(\.openURL) private var openURL
    let target: EditorTarget
    let summary: FirewallPolicy?
    let onClose: () -> Void

    @MainActor static func confirmDelete(_ policy: FirewallPolicy, model: NetworkModel, confirm: ConfirmCenter, then: (() -> Void)? = nil) {
        confirm.ask("Delete \(policy.name)?", "Traffic it matches will be handled by the next policy in order.", action: "Delete") {
            if await model.delete(.firewallPolicies, id: policy.id, name: policy.name) { then?() }
        }
    }

    private var readOnlyReason: String? {
        guard let summary, !summary.metadata.isUserDefined else { return nil }
        return "Built-in policies can't be edited. Logging\(model.supportsFlowReporting ? " and flow reporting" : "") can be changed from the policy list."
    }

    private var deleteAction: (() -> Void)? {
        guard let summary, summary.metadata.isUserDefined else { return nil }
        return { Self.confirmDelete(summary, model: model, confirm: confirm, then: onClose) }
    }

    var body: some View {
        ResourceEditor<FirewallPolicyDraft, _>(
            kind: .firewallPolicies, target: target, readOnlyReason: readOnlyReason,
            prepare: { draft in
                if model.supportsFlowReporting { draft.reportFlowEnabled = true }
                let zones = model.firewallZones.value ?? []
                draft.sourceZoneId = zones.first { $0.name.localizedCaseInsensitiveCompare("Internal") == .orderedSame }?.id ?? zones.first?.id
                draft.destinationZoneId = zones.first { $0.name.localizedCaseInsensitiveCompare("External") == .orderedSame }?.id ?? zones.last?.id
            },
            onDelete: deleteAction, onClose: onClose
        ) { draft in
            fields(draft)
        }
    }

    @ViewBuilder private func fields(_ draft: Binding<FirewallPolicyDraft>) -> some View {
        let zones = (model.firewallZones.value ?? []).sorted { $0.name < $1.name }
        Section("General") {
            TextField("Name", text: draft.name)
            TextField("Description", text: draft.description, prompt: Text("Optional"))
            Toggle("Enabled", isOn: draft.enabled)
        }
        Section("Traffic") {
            Picker("Source zone", selection: draft.sourceZoneId) {
                if draft.wrappedValue.sourceZoneId == nil { Text("Choose...").tag(UUID?.none) }
                ForEach(zones) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Destination zone", selection: draft.destinationZoneId) {
                if draft.wrappedValue.destinationZoneId == nil { Text("Choose...").tag(UUID?.none) }
                ForEach(zones) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("IP version", selection: draft.ipVersion) {
                ForEach(FirewallPolicyDraft.ipVersions, id: \.self) { Text(FirewallPolicyDraft.label(forIPVersion: $0)).tag($0) }
            }
            if !target.isCreate, draft.wrappedValue.sourceZoneId != summary?.source.zoneId || draft.wrappedValue.destinationZoneId != summary?.destination.zoneId {
                Label("Changing zones moves this policy to that zone pair's order.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        Section("Action") {
            Picker("Action", selection: draft.action) {
                ForEach(FirewallPolicyDraft.actions, id: \.self) { Text(FirewallPolicyDraft.label(forAction: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            if draft.wrappedValue.action == "ALLOW" {
                Toggle("Allow return traffic", isOn: draft.allowReturnTraffic)
            }
            Toggle("Syslog logging", isOn: draft.loggingEnabled)
            if model.supportsFlowReporting, draft.wrappedValue.reportFlowEnabled != nil {
                Toggle("Report flows", isOn: Binding(get: { draft.wrappedValue.reportFlowEnabled ?? true },
                                                     set: { draft.wrappedValue.reportFlowEnabled = $0 }))
            }
        }
        Section {
            if draft.wrappedValue.hasTrafficFilters {
                Label("This policy has address, port, application, or schedule filters. They're kept as they are; change them in the web UI.", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.callout).foregroundStyle(Theme.secondary)
            } else {
                Text("This policy matches all traffic between the zones. Add address, port, application, or schedule filters in the web UI.")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            }
            if let url = model.webURL("settings") {
                Button("Open Firewall Settings in Web UI") { openURL(url) }.buttonStyle(.link)
            }
        }
    }
}

// MARK: - Zones

private struct ZonesView: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @Binding var tab: FirewallPage.Tab
    @State private var selection: FirewallZone.ID?
    @State private var editor: EditorTarget?

    var body: some View {
        PageContainer("Firewall", subtitle: "Zones group networks so policies can apply to all of them.") {
            TabPicker(tab: $tab)
            Button { editor = .create } label: { Label("Create Zone", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate || model.networks.value == nil)
        } content: {
            SectionStateView(state: model.firewallZones, noun: "firewall zones") { zones in
                if zones.isEmpty {
                    EmptyState(title: "No zones", symbol: "square.dashed", message: "This site reports no firewall zones.")
                } else {
                    table(zones.sorted { ($0.metadata.isUserDefined ? 1 : 0, $0.name) < ($1.metadata.isUserDefined ? 1 : 0, $1.name) })
                }
            }
        }
        .onChange(of: selection) { _, id in if let id { editor = .edit(id) } }
        .onChange(of: editor) { _, target in if target == nil { selection = nil } }
        .editorInspector($editor) { target in
            ZoneEditor(target: target, summary: summary(target)) { editor = nil }
        }
    }

    private func summary(_ target: EditorTarget) -> FirewallZone? {
        guard case .edit(let id) = target else { return nil }
        return model.firewallZones.value?.first { $0.id == id }
    }

    private func networkNames(_ zone: FirewallZone) -> String {
        guard !zone.networkIds.isEmpty else { return "—" }
        let networks = model.networks.value ?? []
        return zone.networkIds.map { id in networks.first { $0.id == id }?.name ?? "Unknown" }.sorted().joined(separator: ", ")
    }

    private func table(_ zones: [FirewallZone]) -> some View {
        Table(zones, selection: $selection) {
            TableColumn("Name") { Text($0.name).fontWeight(.medium) }.width(min: 140, ideal: 180)
            TableColumn("Networks") { Text(networkNames($0)).foregroundStyle(Theme.secondary) }.width(min: 200, ideal: 360)
            TableColumn("Type") { Status.origin($0.metadata) }.width(min: 70, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: FirewallZone.ID.self) { ids in
            if let id = ids.first, let zone = model.firewallZones.value?.first(where: { $0.id == id }) {
                Button(zone.metadata.isUserDefined ? "Edit..." : "View...") { editor = .edit(id) }
                if zone.metadata.isUserDefined {
                    Button("Delete...", role: .destructive) { ZoneEditor.confirmDelete(zone, model: model, confirm: confirm) }
                }
            }
        }
    }
}

private struct ZoneEditor: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    let target: EditorTarget
    let summary: FirewallZone?
    let onClose: () -> Void

    @MainActor static func confirmDelete(_ zone: FirewallZone, model: NetworkModel, confirm: ConfirmCenter, then: (() -> Void)? = nil) {
        confirm.ask("Delete \(zone.name)?", "Its networks return to their default zones. The console refuses the deletion while policies still use this zone.", action: "Delete") {
            if await model.delete(.firewallZones, id: zone.id, name: zone.name) { then?() }
        }
    }

    private var readOnlyReason: String? {
        guard let summary, !summary.metadata.isUserDefined else { return nil }
        return "Built-in zones can't be edited here. To move a network into this zone, choose the zone in the network's settings."
    }

    private var deleteAction: (() -> Void)? {
        guard let summary, summary.metadata.isUserDefined else { return nil }
        return { Self.confirmDelete(summary, model: model, confirm: confirm, then: onClose) }
    }

    var body: some View {
        ResourceEditor<FirewallZoneDraft, _>(
            kind: .firewallZones, target: target, readOnlyReason: readOnlyReason, onDelete: deleteAction, onClose: onClose
        ) { draft in
            Section("General") {
                TextField("Name", text: draft.name)
            }
            Section("Networks") {
                let networks = (model.networks.value ?? []).sorted { $0.vlanId < $1.vlanId }
                ForEach(networks) { network in
                    Toggle(isOn: Binding(
                        get: { draft.wrappedValue.networkIds.contains(network.id) },
                        set: { on in
                            if on { draft.wrappedValue.networkIds.insert(network.id) } else { draft.wrappedValue.networkIds.remove(network.id) }
                        }
                    )) {
                        HStack {
                            Text(network.name)
                            if let other = otherZone(for: network) {
                                Text("in \(other)").font(.caption).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func otherZone(for network: NetworkSummary) -> String? {
        model.firewallZones.value?.first { $0.id != summary?.id && $0.networkIds.contains(network.id) }?.name
    }
}
