import SwiftUI
import UniFiCore

struct ClientsPage: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", wifi = "WiFi", wired = "Wired", guests = "Guests"
        var id: Self { self }
    }

    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @State private var selection: NetworkClient.ID?
    @State private var search = ""
    @State private var filter = Filter.all

    var body: some View {
        PageContainer("Client Devices", subtitle: model.clients.value.map { "\($0.count) connected" }) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
        } content: {
            SectionStateView(state: model.clients, noun: "clients") { clients in
                if clients.isEmpty {
                    EmptyState(title: "No clients", symbol: "laptopcomputer.and.iphone", message: "No clients are connected to this site.")
                } else {
                    table(filtered(clients))
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search clients")
        .inspector(isPresented: Binding(get: { selectedClient != nil }, set: { if !$0 { selection = nil } })) {
            Group {
                if let client = selectedClient {
                    ClientInspector(client: client) { selection = nil }.id(client.id)
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
    }

    private var selectedClient: NetworkClient? {
        guard let selection else { return nil }
        return model.clients.value?.first { $0.id == selection }
    }

    private func filtered(_ clients: [NetworkClient]) -> [NetworkClient] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return clients
            .filter { client in
                switch filter {
                case .all: return true
                case .wifi: return client.type == "WIRELESS"
                case .wired: return client.type == "WIRED"
                case .guests: return client.isGuest
                }
            }
            .filter { client in
                query.isEmpty || [client.name, client.ipAddress, client.macAddress].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted { ($0.name ?? $0.macAddress ?? "").lowercased() < ($1.name ?? $1.macAddress ?? "").lowercased() }
    }

    private func uplinkName(_ client: NetworkClient) -> String {
        guard let id = client.uplinkDeviceId else { return "—" }
        return model.devices.value?.first { $0.id == id }?.name ?? "—"
    }

    private func table(_ clients: [NetworkClient]) -> some View {
        Table(clients, selection: $selection) {
            TableColumn("Name") { client in
                HStack(spacing: 8) {
                    Image(systemName: ClientStyle.symbol(client)).foregroundStyle(Theme.link).frame(width: 18)
                    Text(client.name ?? client.macAddress ?? "Unknown").fontWeight(.medium)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Connection") { Text(ClientStyle.type($0)).foregroundStyle(Theme.secondary) }.width(min: 70, ideal: 90)
            TableColumn("IP Address") { Text($0.ipAddress ?? "—").monospacedDigit() }.width(min: 100, ideal: 120)
            TableColumn("MAC Address") { Text($0.macAddress ?? "—").monospacedDigit().foregroundStyle(Theme.secondary) }
                .width(min: 120, ideal: 140)
            TableColumn("Uplink") { Text(uplinkName($0)) }.width(min: 90, ideal: 140)
            TableColumn("Access") { client in
                if client.isGuest {
                    Pill(client.access?.authorized == true ? "Guest · Authorized" : "Guest · Unauthorized",
                         color: client.access?.authorized == true ? Theme.green : Theme.warning)
                } else {
                    Text("Default").foregroundStyle(Theme.tertiary)
                }
            }
            .width(min: 90, ideal: 150)
            TableColumn("Connected") { Text(Format.shortDate($0.connectedAt)).foregroundStyle(Theme.secondary) }.width(min: 100, ideal: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: NetworkClient.ID.self) { ids in
            if let id = ids.first, let client = model.clients.value?.first(where: { $0.id == id }) {
                Button("Show Details") { selection = id }
                if client.isGuest {
                    Divider()
                    if client.access?.authorized == true {
                        Button("Revoke Guest Access...") { ClientStyle.revoke(client, model: model, confirm: confirm) }
                            .disabled(!model.canMutate)
                    } else {
                        Button("Authorize Guest") { Task { await model.guestAccess(client, action: .authorize) } }
                            .disabled(!model.canMutate)
                    }
                }
                Divider()
                if let ip = client.ipAddress { Button("Copy IP Address") { Clipboard.copy(ip) } }
                if let mac = client.macAddress { Button("Copy MAC Address") { Clipboard.copy(mac) } }
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }
}

enum ClientStyle {
    static func symbol(_ client: NetworkClient) -> String {
        switch client.type {
        case "WIRELESS": return "wifi"
        case "WIRED": return "cable.connector"
        case "VPN": return "lock.shield"
        default: return "desktopcomputer"
        }
    }

    static func type(_ client: NetworkClient) -> String {
        switch client.type {
        case "WIRELESS": return "WiFi"
        case "WIRED": return "Wired"
        case "VPN": return "VPN"
        case "TELEPORT": return "Teleport"
        default: return client.type.capitalized
        }
    }

    @MainActor static func revoke(_ client: NetworkClient, model: NetworkModel, confirm: ConfirmCenter) {
        confirm.ask("Revoke guest access?", "\(client.name ?? "This guest") will lose network access until authorized again.", action: "Revoke") {
            await model.guestAccess(client, action: .revoke)
        }
    }
}

private struct ClientInspector: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    let client: NetworkClient
    let onClose: () -> Void
    @State private var limits = GuestLimits()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: ClientStyle.symbol(client)).font(.title3).foregroundStyle(Theme.link)
                Text(client.name ?? client.macAddress ?? "Client").font(.headline).lineLimit(1)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            .padding(14)
            Divider()
            Form {
                Section("Overview") {
                    DetailRow("Connection", ClientStyle.type(client))
                    DetailRow("IP Address", client.ipAddress ?? "—")
                    DetailRow("MAC Address", client.macAddress ?? "—")
                    if let id = client.uplinkDeviceId {
                        DetailRow("Uplink", model.devices.value?.first { $0.id == id }?.name ?? id.uuidString)
                    }
                    DetailRow("Connected Since", Format.date(client.connectedAt))
                }
                if client.isGuest {
                    guestSection
                } else {
                    Section {
                        Text("Blocking, renaming, and fixed IPs aren't part of the documented local API. Use the web UI for those.")
                            .font(.callout).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder private var guestSection: some View {
        let authorized = client.access?.authorized == true
        Section("Guest Access") {
            LabeledContent("Status") {
                Pill(authorized ? "Authorized" : "Not authorized", color: authorized ? Theme.green : Theme.warning)
            }
            if authorized {
                Button("Revoke Access...", role: .destructive) { ClientStyle.revoke(client, model: model, confirm: confirm) }
                    .disabled(!model.canMutate)
            }
        }
        Section {
            OptionalIntField(title: "Time limit", value: $limits.timeLimitMinutes, defaultValue: 1440, suffix: "min")
            OptionalIntField(title: "Data limit", value: $limits.dataUsageLimitMBytes, defaultValue: 1024, suffix: "MB")
            OptionalIntField(title: "Download limit", value: $limits.rxRateLimitKbps, defaultValue: 10_000, suffix: "Kbps")
            OptionalIntField(title: "Upload limit", value: $limits.txRateLimitKbps, defaultValue: 5_000, suffix: "Kbps")
            if !limitErrors.isEmpty {
                Label(limitErrors, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning)
            }
            Button(authorized ? "Re-authorize with These Limits" : "Authorize Guest") {
                if authorized {
                    confirm.ask("Re-authorize guest?", "The current authorization is replaced with these limits and the guest's usage counters are reset.", action: "Re-authorize", destructive: false) {
                        await model.guestAccess(client, action: .authorize, limits: limits)
                    }
                } else {
                    Task { await model.guestAccess(client, action: .authorize, limits: limits) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canMutate || !limitErrors.isEmpty)
        } header: {
            Text(authorized ? "Change Limits" : "Authorize")
        } footer: {
            Text("Limits that are off use the site's hotspot defaults.").foregroundStyle(Theme.tertiary)
        }
    }

    private var limitErrors: String { limits.validationErrors.joined(separator: " ") }
}
