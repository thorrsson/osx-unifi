import SwiftUI
import UniFiCore

struct DNSPage: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @State private var selection: DNSPolicy.ID?
    @State private var editor: EditorTarget?
    @State private var search = ""

    var body: some View {
        PageContainer("DNS", subtitle: "Local DNS records and domain forwarding served by the gateway.") {
            Button { editor = .create } label: { Label("Create Record", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate)
        } content: {
            SectionStateView(state: model.dnsPolicies, noun: "DNS records") { policies in
                let rows = filtered(policies)
                if rows.isEmpty {
                    EmptyState(title: "No DNS records", symbol: "globe",
                               message: policies.isEmpty ? "Create a record to resolve local names through the gateway." : "No records match.")
                } else {
                    table(rows)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search records")
        .onChange(of: selection) { _, id in if let id { editor = .edit(id) } }
        .onChange(of: editor) { _, target in if target == nil { selection = nil } }
        .editorInspector($editor) { target in
            DNSEditor(target: target, summary: summary(target)) { editor = nil }
        }
    }

    private func summary(_ target: EditorTarget) -> DNSPolicy? {
        guard case .edit(let id) = target else { return nil }
        return model.dnsPolicies.value?.first { $0.id == id }
    }

    private func filtered(_ policies: [DNSPolicy]) -> [DNSPolicy] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return policies
            .filter { query.isEmpty || ($0.domain ?? "").localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.domain ?? "", $0.type) < ($1.domain ?? "", $1.type) }
    }

    private func table(_ policies: [DNSPolicy]) -> some View {
        Table(policies, selection: $selection) {
            TableColumn("Record") { Pill($0.typeLabel, color: Theme.link) }.width(min: 60, ideal: 110)
            TableColumn("Domain") { Text($0.domain ?? "—").fontWeight(.medium).textSelection(.enabled) }.width(min: 140, ideal: 220)
            TableColumn("Value") { Text($0.value.isEmpty ? "—" : $0.value).foregroundStyle(Theme.secondary).monospaced() }.width(min: 140, ideal: 220)
            TableColumn("TTL") { policy in
                Text(policy.ttlSeconds.map { Format.duration(seconds: $0) } ?? "—").foregroundStyle(Theme.secondary)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Type") { Status.origin($0.metadata) }.width(min: 70, ideal: 90)
            TableColumn("Enabled") { policy in
                EnabledToggle(isOn: policy.enabled, editable: policy.metadata.isUserDefined, label: "Enable \(policy.domain ?? "record")") { value in
                    await model.setEnabled(.dnsPolicies, id: policy.id, name: policy.domain ?? policy.typeLabel, enabled: value)
                }
            }
            .width(56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: DNSPolicy.ID.self) { ids in
            if let id = ids.first, let policy = model.dnsPolicies.value?.first(where: { $0.id == id }) {
                Button(policy.metadata.isUserDefined ? "Edit..." : "View...") { editor = .edit(id) }
                Button("Copy Domain") { Clipboard.copy(policy.domain ?? "") }.disabled(policy.domain == nil)
                if policy.metadata.isUserDefined {
                    Divider()
                    Button("Delete...", role: .destructive) { DNSEditor.confirmDelete(policy, model: model, confirm: confirm) }
                }
            }
        }
    }
}

private struct DNSEditor: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    let target: EditorTarget
    let summary: DNSPolicy?
    let onClose: () -> Void

    private static let protocols = ["_tcp", "_udp", "_tls"]

    @MainActor static func confirmDelete(_ policy: DNSPolicy, model: NetworkModel, confirm: ConfirmCenter, then: (() -> Void)? = nil) {
        let name = policy.domain ?? policy.typeLabel
        confirm.ask("Delete \(policy.typeLabel) record for \(name)?", "Clients will stop resolving it through the gateway.", action: "Delete") {
            if await model.delete(.dnsPolicies, id: policy.id, name: name) { then?() }
        }
    }

    private var readOnlyReason: String? {
        guard let summary, !summary.metadata.isUserDefined else { return nil }
        return "This record is managed by the controller."
    }

    private var deleteAction: (() -> Void)? {
        guard let summary, summary.metadata.isUserDefined else { return nil }
        return { Self.confirmDelete(summary, model: model, confirm: confirm, then: onClose) }
    }

    var body: some View {
        ResourceEditor<DNSPolicyDraft, _>(
            kind: .dnsPolicies, target: target, readOnlyReason: readOnlyReason, onDelete: deleteAction, onClose: onClose
        ) { draft in
            fields(draft)
        }
    }

    @ViewBuilder private func fields(_ draft: Binding<DNSPolicyDraft>) -> some View {
        Section("Record") {
            Picker("Type", selection: draft.type) {
                ForEach(DNSRecordType.allCases) { Text($0.label).tag($0) }
            }
            if !target.isCreate, summary.map({ $0.type != draft.wrappedValue.type.rawValue }) == true {
                Label("Changing the type replaces the record's value.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            TextField(draft.wrappedValue.type == .forward ? "Domain to forward" : "Domain", text: draft.domain, prompt: Text("host.example.com"))
            Toggle("Enabled", isOn: draft.enabled)
        }
        Section("Value") {
            switch draft.wrappedValue.type {
            case .a:
                TextField("IPv4 address", text: draft.ipv4Address, prompt: Text("192.168.1.10"))
            case .aaaa:
                TextField("IPv6 address", text: draft.ipv6Address, prompt: Text("2001:db8::10"))
            case .cname:
                TextField("Target domain", text: draft.targetDomain, prompt: Text("server.example.com"))
            case .txt:
                TextField("Text", text: draft.text, axis: .vertical).lineLimit(2...6)
            case .mx:
                TextField("Mail server", text: draft.mailServerDomain, prompt: Text("mail.example.com"))
                IntField("Priority", value: draft.priority)
            case .srv:
                TextField("Service", text: draft.service, prompt: Text("_ldap"))
                Picker("Protocol", selection: draft.serviceProtocol) {
                    ForEach(protocolOptions(draft.wrappedValue.serviceProtocol), id: \.self) { Text($0).tag($0) }
                }
                TextField("Target server", text: draft.serverDomain, prompt: Text("server.example.com"))
                IntField("Port", value: draft.port)
                IntField("Priority", value: draft.priority)
                IntField("Weight", value: draft.weight)
            case .forward:
                TextField("DNS server", text: draft.ipAddress, prompt: Text("10.0.0.53"))
            }
            if draft.wrappedValue.usesTTL {
                IntField("TTL", value: draft.ttlSeconds, suffix: "seconds")
            }
        }
    }

    private func protocolOptions(_ current: String) -> [String] {
        Self.protocols.contains(current) ? Self.protocols : Self.protocols + [current]
    }
}
