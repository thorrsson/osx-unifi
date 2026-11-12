import SwiftUI
import UniFiCore

// MARK: - ACL rules

struct ACLRulesView: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @Binding var tab: FirewallPage.Tab
    @State private var selection: ACLRule.ID?
    @State private var editor: EditorTarget?
    @State private var search = ""

    var body: some View {
        PageContainer("Firewall", subtitle: "Switch ACL rules, evaluated in order.") {
            TabPicker(tab: $tab)
            Button { editor = .create } label: { Label("Create Rule", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate)
        } content: {
            SectionStateView(state: model.aclRules, noun: "ACL rules") { rules in
                let rows = filtered(rules)
                if rows.isEmpty {
                    EmptyState(title: "No ACL rules", symbol: "list.bullet.rectangle", message: rules.isEmpty ? "This site has no ACL rules." : "No rules match.")
                } else {
                    table(rows)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search ACL rules")
        .onChange(of: selection) { _, id in if let id { editor = .edit(id) } }
        .onChange(of: editor) { _, target in if target == nil { selection = nil } }
        .editorInspector($editor) { target in
            ACLRuleEditor(target: target, summary: summary(target)) { editor = nil }
        }
    }

    private func summary(_ target: EditorTarget) -> ACLRule? {
        guard case .edit(let id) = target else { return nil }
        return model.aclRules.value?.first { $0.id == id }
    }

    private func filtered(_ rules: [ACLRule]) -> [ACLRule] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return rules
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || describe($0).localizedCaseInsensitiveContains(query) }
            .sorted { $0.index < $1.index }
    }

    private func network(_ id: UUID) -> String {
        model.networks.value?.first { $0.id == id }?.name ?? "Unknown network"
    }

    private func describe(_ filter: ACLRule.EndpointFilter?) -> String {
        guard let filter else { return "Any" }
        var parts: [String] = []
        if let values = filter.ipAddressesOrSubnets ?? filter.macAddresses { parts.append(values.joined(separator: ", ")) }
        if let ids = filter.networkIds { parts.append(ids.map(network).sorted().joined(separator: ", ")) }
        if let prefix = filter.prefixLength { parts.append("/\(prefix)") }
        if let ports = filter.portFilter { parts.append("port \(ports.map(String.init).joined(separator: ", "))") }
        return parts.isEmpty ? ACLEndpointDraft.label(for: filter.type) : parts.joined(separator: " ")
    }

    private func describe(_ rule: ACLRule) -> String { "\(describe(rule.sourceFilter)) → \(describe(rule.destinationFilter))" }

    private func table(_ rules: [ACLRule]) -> some View {
        Table(rules, selection: $selection) {
            TableColumn("#") { Text(verbatim: String($0.index)).monospacedDigit().foregroundStyle(Theme.tertiary) }.width(min: 40, ideal: 50)
            TableColumn("Name") { Text($0.name).fontWeight(.medium) }.width(min: 140, ideal: 200)
            TableColumn("Action") { Status.action($0.action) }.width(min: 60, ideal: 70)
            TableColumn("Type") { rule in
                Text(rule.type == "MAC" ? "MAC · \(rule.networkIdFilter.map(network) ?? "")" : rule.typeLabel)
                    .foregroundStyle(Theme.secondary)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Source → Destination") { Text(describe($0)).foregroundStyle(Theme.secondary).lineLimit(1) }
                .width(min: 160, ideal: 280)
            TableColumn("Protocol") { Text($0.protocolFilter?.sorted().joined(separator: ", ") ?? "Any").foregroundStyle(Theme.secondary) }
                .width(min: 60, ideal: 80)
            TableColumn("Origin") { Status.origin($0.metadata) }.width(min: 70, ideal: 80)
            TableColumn("Enabled") { rule in
                EnabledToggle(isOn: rule.enabled, editable: rule.metadata.isUserDefined, label: "Enable \(rule.name)") { value in
                    await model.setEnabled(.aclRules, id: rule.id, name: rule.name, enabled: value)
                }
            }
            .width(56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: ACLRule.ID.self) { ids in
            if let id = ids.first, let rule = model.aclRules.value?.first(where: { $0.id == id }) {
                Button(rule.metadata.isUserDefined ? "Edit..." : "View...") { editor = .edit(id) }
                Divider()
                Button("Move Up") { Task { await model.move(rule, .earlier) } }.disabled(!model.canMutate)
                Button("Move Down") { Task { await model.move(rule, .later) } }.disabled(!model.canMutate)
                if rule.metadata.isUserDefined {
                    Divider()
                    Button("Delete...", role: .destructive) { ACLRuleEditor.confirmDelete(rule, model: model, confirm: confirm) }
                }
            }
        }
    }
}

private struct ACLRuleEditor: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    let target: EditorTarget
    let summary: ACLRule?
    let onClose: () -> Void

    @MainActor static func confirmDelete(_ rule: ACLRule, model: NetworkModel, confirm: ConfirmCenter, then: (() -> Void)? = nil) {
        confirm.ask("Delete \(rule.name)?", "Traffic it matches will be handled by the next rule in order.", action: "Delete") {
            if await model.delete(.aclRules, id: rule.id, name: rule.name) { then?() }
        }
    }

    private var readOnlyReason: String? {
        guard let summary, !summary.metadata.isUserDefined else { return nil }
        return "This rule is derived from other settings and can't be edited here."
    }

    private var deleteAction: (() -> Void)? {
        guard let summary, summary.metadata.isUserDefined else { return nil }
        return { Self.confirmDelete(summary, model: model, confirm: confirm, then: onClose) }
    }

    var body: some View {
        ResourceEditor<ACLRuleDraft, _>(
            kind: .aclRules, target: target, readOnlyReason: readOnlyReason, onDelete: deleteAction, onClose: onClose
        ) { draft in
            fields(draft)
        }
    }

    @ViewBuilder private func fields(_ draft: Binding<ACLRuleDraft>) -> some View {
        let networks = (model.networks.value ?? []).sorted { $0.vlanId < $1.vlanId }
        Section("General") {
            TextField("Name", text: draft.name)
            Toggle("Enabled", isOn: draft.enabled)
            Picker("Action", selection: draft.action) {
                ForEach(ACLRuleDraft.actions, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Match", selection: draft.type) {
                ForEach(ACLRuleDraft.types, id: \.self) { Text(ACLRuleDraft.label(forType: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            if draft.wrappedValue.type == "MAC" {
                Picker("Network", selection: draft.networkIdFilter) {
                    if draft.wrappedValue.networkIdFilter == nil { Text("Choose...").tag(UUID?.none) }
                    ForEach(networks) { Text($0.name).tag(Optional($0.id)) }
                }
            } else {
                ForEach(ACLRuleDraft.protocols, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { draft.wrappedValue.protocols.contains(name) },
                        set: { on in
                            if on { draft.wrappedValue.protocols.insert(name) } else { draft.wrappedValue.protocols.remove(name) }
                        }
                    ))
                }
                Text("Leave both protocols off to match all traffic.").font(.caption).foregroundStyle(Theme.tertiary)
            }
        }
        endpoint("Source", draft.source, ruleType: draft.wrappedValue.type, networks: networks)
        endpoint("Destination", draft.destination, ruleType: draft.wrappedValue.type, networks: networks)
        if draft.wrappedValue.hasDeviceFilter {
            Section {
                Label("This rule is limited to specific switches. That limit is kept as it is.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private func endpoint(_ title: String, _ endpoint: Binding<ACLEndpointDraft>, ruleType: String, networks: [NetworkSummary]) -> some View {
        Section(title) {
            Picker("Match", selection: endpoint.type) {
                ForEach(ACLEndpointDraft.types(forRule: ruleType), id: \.self) { Text(ACLEndpointDraft.label(for: $0)).tag($0) }
            }
            if endpoint.wrappedValue.usesAddresses {
                TextField("Addresses", text: endpoint.addresses,
                          prompt: Text(ruleType == "MAC" ? "aa:bb:cc:dd:ee:ff" : "192.168.1.10, 10.0.0.0/24"), axis: .vertical)
                    .lineLimit(1...5)
            }
            if endpoint.wrappedValue.usesPrefixLength {
                OptionalIntField(title: "Prefix length", value: endpoint.prefixLength, defaultValue: 24, suffix: "bits")
            }
            if endpoint.wrappedValue.usesNetworks {
                ForEach(networks) { network in
                    Toggle(network.name, isOn: Binding(
                        get: { endpoint.wrappedValue.networkIds.contains(network.id) },
                        set: { on in
                            if on { endpoint.wrappedValue.networkIds.insert(network.id) } else { endpoint.wrappedValue.networkIds.remove(network.id) }
                        }
                    ))
                }
            }
            if endpoint.wrappedValue.usesPorts {
                TextField("Ports", text: endpoint.ports,
                          prompt: Text(endpoint.wrappedValue.type == "PORTS" ? "80, 443" : "Optional, e.g. 80, 443"))
            }
        }
    }
}

// MARK: - Traffic matching lists

struct TrafficListsView: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @Binding var tab: FirewallPage.Tab
    @State private var selection: TrafficMatchingList.ID?
    @State private var editor: EditorTarget?

    var body: some View {
        PageContainer("Firewall", subtitle: "Reusable address and port lists for firewall policies.") {
            TabPicker(tab: $tab)
            Button { editor = .create } label: { Label("Create List", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate)
        } content: {
            SectionStateView(state: model.trafficMatchingLists, noun: "traffic matching lists") { lists in
                if lists.isEmpty {
                    EmptyState(title: "No lists", symbol: "list.bullet", message: "This site has no traffic matching lists.")
                } else {
                    table(lists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
                }
            }
        }
        .onChange(of: selection) { _, id in if let id { editor = .edit(id) } }
        .onChange(of: editor) { _, target in if target == nil { selection = nil } }
        .editorInspector($editor) { target in
            TrafficListEditor(target: target, summary: summary(target)) { editor = nil }
        }
    }

    private func summary(_ target: EditorTarget) -> TrafficMatchingList? {
        guard case .edit(let id) = target else { return nil }
        return model.trafficMatchingLists.value?.first { $0.id == id }
    }

    private func table(_ lists: [TrafficMatchingList]) -> some View {
        Table(lists, selection: $selection) {
            TableColumn("Name") { Text($0.name).fontWeight(.medium) }.width(min: 140, ideal: 200)
            TableColumn("Type") { Text($0.typeLabel).foregroundStyle(Theme.secondary) }.width(min: 90, ideal: 120)
            TableColumn("Entries") { list in
                Text(list.items.map(\.text).joined(separator: ", ")).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .width(min: 200, ideal: 360)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: TrafficMatchingList.ID.self) { ids in
            if let id = ids.first, let list = model.trafficMatchingLists.value?.first(where: { $0.id == id }) {
                Button("Edit...") { editor = .edit(id) }
                Button("Delete...", role: .destructive) { TrafficListEditor.confirmDelete(list, model: model, confirm: confirm) }
            }
        }
    }
}

private struct TrafficListEditor: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    let target: EditorTarget
    let summary: TrafficMatchingList?
    let onClose: () -> Void

    @MainActor static func confirmDelete(_ list: TrafficMatchingList, model: NetworkModel, confirm: ConfirmCenter, then: (() -> Void)? = nil) {
        confirm.ask("Delete \(list.name)?", "The console refuses the deletion while firewall policies still use this list.", action: "Delete") {
            if await model.delete(.trafficMatchingLists, id: list.id, name: list.name) { then?() }
        }
    }

    private var deleteAction: (() -> Void)? {
        guard let summary else { return nil }
        return { Self.confirmDelete(summary, model: model, confirm: confirm, then: onClose) }
    }

    private func footer(_ type: String) -> String {
        switch type {
        case TrafficMatchingListType.ports.rawValue: return "One port or range (start-stop) per line."
        case TrafficMatchingListType.ipv6.rawValue: return "One address or subnet (CIDR) per line."
        default: return "One address, subnet (CIDR), or range (start-stop) per line."
        }
    }

    var body: some View {
        ResourceEditor<TrafficMatchingListDraft, _>(
            kind: .trafficMatchingLists, target: target, onDelete: deleteAction, onClose: onClose
        ) { draft in
            Section("General") {
                TextField("Name", text: draft.name)
                Picker("Type", selection: draft.type) {
                    ForEach(TrafficMatchingListType.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section {
                TextField("Entries", text: draft.items, prompt: Text(draft.wrappedValue.placeholder), axis: .vertical)
                    .lineLimit(4...12)
                    .font(.body.monospaced())
            } header: {
                Text("Entries")
            } footer: {
                Text(footer(draft.wrappedValue.type))
                    .font(.caption).foregroundStyle(Theme.tertiary)
            }
        }
    }
}
