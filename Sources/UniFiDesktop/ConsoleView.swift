import SwiftUI
import UniFiCore

enum ConsolePage: String, CaseIterable, Identifiable, Hashable {
    case dashboard, devices, clients, networks, wifi, firewall, dns, hotspot

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .devices: return "UniFi Devices"
        case .clients: return "Client Devices"
        case .networks: return "Networks"
        case .wifi: return "WiFi"
        case .firewall: return "Firewall"
        case .dns: return "DNS"
        case .hotspot: return "Hotspot"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .devices: return "server.rack"
        case .clients: return "laptopcomputer.and.iphone"
        case .networks: return "point.3.connected.trianglepath.dotted"
        case .wifi: return "wifi"
        case .firewall: return "shield.lefthalf.filled"
        case .dns: return "globe"
        case .hotspot: return "ticket"
        }
    }

    /// Controller web UI route used for settings this app does not manage.
    var webPage: String {
        switch self {
        case .dashboard: return "dashboard"
        case .devices: return "devices"
        case .clients: return "clients"
        case .networks: return "settings/networks"
        case .wifi: return "settings/wifi"
        case .firewall, .dns: return "settings"
        case .hotspot: return "hotspot"
        }
    }
}

/// Sheets the console presents on behalf of pages.
enum ConsoleSheet: Identifiable {
    case createVouchers

    var id: Self { self }
}

struct RootView: View {
    @ObservedObject var model: NetworkModel
    @StateObject private var confirm = ConfirmCenter()

    // Dismissing the sheet any other way (Escape, window close) counts as declining.
    private var certificateReview: Binding<CertificateTrustRequest?> {
        Binding(get: { model.certificateRequest }, set: { if $0 == nil { model.declineCertificate() } })
    }

    var body: some View {
        Group {
            if model.connected {
                ConsoleView()
            } else {
                ConnectView()
            }
        }
        .environmentObject(model)
        .environmentObject(confirm)
        .modifier(ConfirmationHost(center: confirm))
        .sheet(item: certificateReview) { request in
            CertificateTrustSheet(
                request: request,
                onTrust: { Task { await model.trustCertificate() } },
                onCancel: { model.declineCertificate() }
            )
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

struct ConnectView: View {
    @EnvironmentObject private var model: NetworkModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UniFi Desktop").font(.title2.weight(.semibold))
                        Text("Sign in to your UniFi console").foregroundStyle(Theme.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Console address").font(.callout.weight(.medium))
                    TextField("https://192.168.1.1", text: $model.address)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("API key").font(.callout.weight(.medium))
                    SecureField("Leave blank to use the key saved in Keychain", text: $model.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.connect() } }
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.red)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.secondary)
                }
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        Task { await model.connect() }
                    } label: {
                        Text("Connect").frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.address.isEmpty)
                }
                Divider()
                Text("Create a key in UniFi Network under Settings > Control Plane > Integrations. The key is stored only in this Mac's Keychain. Self-signed console certificates are shown for review before anything is sent.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(width: 440)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
    }
}

struct ConsoleView: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @Environment(\.openURL) private var openURL
    @SceneStorage("consolePage") private var page: ConsolePage = .dashboard
    @State private var sheet: ConsoleSheet?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(page) }, set: { if let value = $0 { page = value } })) {
                Section {
                    ForEach([ConsolePage.dashboard, .devices, .clients]) { item in
                        row(item)
                    }
                }
                Section("Settings") {
                    ForEach([ConsolePage.networks, .wifi, .firewall, .dns, .hotspot]) { item in
                        row(item)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                banners
                pageView
            }
            .background(Theme.background)
            .navigationTitle(page.title)
            .navigationSubtitle(model.selectedSite?.name ?? "")
            .toolbar { toolbar }
        }
        // Sheets attached inside the detail column don't present until the window has shown a modal from
        // its root view (macOS 26), so pages ask the console to present them from here.
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .createVouchers: VoucherSheet { self.sheet = nil }
            }
        }
    }

    private func row(_ item: ConsolePage) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(badge(for: item))
            .tag(item)
    }

    private func badge(for item: ConsolePage) -> Int {
        switch item {
        case .devices: return model.pendingDevices.value?.count ?? 0
        default: return 0
        }
    }

    @ViewBuilder private var pageView: some View {
        switch page {
        case .dashboard: DashboardPage(page: $page)
        case .devices: DevicesPage()
        case .clients: ClientsPage()
        case .networks: NetworksPage()
        case .wifi: WiFiPage()
        case .firewall: FirewallPage()
        case .dns: DNSPage()
        case .hotspot: HotspotPage(createVouchers: { sheet = .createVouchers })
        }
    }

    @ViewBuilder private var banners: some View {
        if let version = model.networkVersion, !version.isVerified {
            MessageBanner(
                text: "UniFi Network \(version) has not been checked against this app. It was verified with the official API documentation for Network \(NetworkVersion.documented.joined(separator: ", ")). Changes are validated by the controller; review results carefully.",
                isError: true, onDismiss: {}
            )
        } else if model.applicationVersion != nil, model.networkVersion == nil {
            MessageBanner(text: "The controller reported an unrecognized Network version (\(model.applicationVersion ?? "")). Version-specific settings are disabled.", isError: true, onDismiss: {})
        }
        if let error = model.error {
            MessageBanner(text: error, isError: true) { model.dismissMessages() }
        } else if let notice = model.notice {
            MessageBanner(text: notice, isError: false) { model.dismissMessages() }
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(Theme.green).frame(width: 7, height: 7)
                Text(model.controller?.origin.host() ?? "Console").font(.caption.weight(.medium))
            }
            if let version = model.applicationVersion {
                Text("Network \(version)").font(.caption2).foregroundStyle(Theme.tertiary)
            }
            if let date = model.lastRefreshed {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if model.sites.count > 1 {
                Picker("Site", selection: Binding(
                    get: { model.selectedSite?.id },
                    set: { id in if let site = model.sites.first(where: { $0.id == id }) { Task { await model.select(site) } } }
                )) {
                    ForEach(model.sites) { site in Text(site.name).tag(Optional(site.id)) }
                }
                .disabled(model.isBusy)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isLoading || model.isBusy {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBusy || model.isLoading)
            .help("Reload everything from the console (⌘R)")

            Button {
                if let url = model.webURL(page.webPage) { openURL(url) }
            } label: {
                Label("Open in Web UI", systemImage: "safari")
            }
            .help("Open this page in the UniFi Network web UI for settings this app doesn't manage")

            Menu {
                Section(model.controller?.origin.absoluteString ?? "") {
                    Button("Disconnect") { model.disconnect() }
                    Button("Forget API Key...") {
                        confirm.ask("Forget API Key", "Remove the saved API key for this console from Keychain and disconnect?", action: "Forget Key") {
                            model.forgetKey()
                        }
                    }
                    Button("Forget Trusted Certificate...") {
                        confirm.ask("Forget Trusted Certificate", "Remove the trusted certificate for this console? You'll review it again the next time you connect.", action: "Forget Certificate") {
                            model.forgetCertificate()
                        }
                    }
                }
            } label: {
                Label("Account", systemImage: "person.crop.circle")
            }
            .disabled(model.isBusy)
        }
    }
}
