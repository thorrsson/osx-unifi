import SwiftUI
import UniFiCore

struct DashboardPage: View {
    @EnvironmentObject private var model: NetworkModel
    @Binding var page: ConsolePage

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                gatewayCard
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    devicesCard
                    clientsCard
                    networksCard
                    securityCard
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .task(id: PollKey(site: model.selectedSite?.id, seconds: model.statisticsPollSeconds)) {
            await model.pollGatewayStatistics()
        }
    }

    /// Restarts polling when the site or the chosen interval changes.
    private struct PollKey: Hashable {
        let site: UUID?
        let seconds: Int
    }

    private var gateway: Device? { model.devices.value?.first(where: \.isGateway) }

    private var gatewayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(Theme.link)
                    .frame(width: 44, height: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(gateway?.name ?? model.selectedSite?.name ?? "Gateway").font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        if let gateway {
                            let status = Status.device(gateway.state)
                            StatusLabel(text: status.0, color: status.1)
                            Text(gateway.model).foregroundStyle(Theme.secondary)
                            if let ip = gateway.ipAddress { Text(ip).foregroundStyle(Theme.secondary) }
                        } else if let failure = model.devices.failure {
                            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red).lineLimit(2)
                        } else if model.devices.isLoading {
                            Text("Loading...").foregroundStyle(Theme.secondary)
                        } else {
                            Text("No gateway reported for this site").foregroundStyle(Theme.secondary)
                        }
                    }
                    .font(.callout)
                }
                Spacer()
                if let version = model.applicationVersion {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("UniFi Network").font(.caption).foregroundStyle(Theme.tertiary)
                        Text(version).font(.callout.monospacedDigit())
                    }
                }
            }
            if gateway != nil {
                Divider()
                gatewayStats
            }
        }
        .card(padding: 18)
    }

    @ViewBuilder private var gatewayStats: some View {
        switch model.gatewayStatistics {
        case .loaded(let stats):
            HStack(spacing: 0) {
                metric("Download", Format.bitsPerSecond(stats.uplink?.rxRateBps), symbol: "arrow.down")
                metric("Upload", Format.bitsPerSecond(stats.uplink?.txRateBps), symbol: "arrow.up")
                metric("Uptime", stats.uptimeSec.map(Format.duration(seconds:)) ?? "—", symbol: "clock")
                metric("CPU", Format.percent(stats.cpuUtilizationPct), symbol: "cpu")
                metric("Memory", Format.percent(stats.memoryUtilizationPct), symbol: "memorychip")
            }
        case .failed(let message):
            Label("Gateway statistics unavailable. \(message)", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.warning)
        case .loading:
            ProgressView().controlSize(.small)
        case .idle:
            EmptyView()
        }
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(Theme.secondary)
            Text(value).font(.title3.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var devicesCard: some View {
        summaryCard("UniFi Devices", symbol: "server.rack", destination: .devices, state: model.devices) { devices in
            let online = devices.filter(\.isOnline).count
            countRow(online, "Online", Theme.green)
            countRow(devices.count - online, "Offline or other", devices.count == online ? Theme.secondary : Theme.red)
            let updates = devices.filter { $0.firmwareUpdatable == true }.count
            if updates > 0 { countRow(updates, "Firmware updates", Theme.warning) }
            if let pending = model.pendingDevices.value, !pending.isEmpty {
                countRow(pending.count, "Pending adoption", Theme.link)
            }
        }
    }

    private var clientsCard: some View {
        summaryCard("Client Devices", symbol: "laptopcomputer.and.iphone", destination: .clients, state: model.clients) { clients in
            countRow(clients.filter { $0.type == "WIRELESS" }.count, "WiFi", Theme.link)
            countRow(clients.filter { $0.type == "WIRED" }.count, "Wired", Theme.green)
            let other = clients.filter { $0.type != "WIRELESS" && $0.type != "WIRED" }.count
            if other > 0 { countRow(other, "VPN and other", Theme.secondary) }
            let guests = clients.filter(\.isGuest)
            if !guests.isEmpty { countRow(guests.count, "Guests", Theme.warning) }
        }
    }

    private var networksCard: some View {
        summaryCard("Networks", symbol: "point.3.connected.trianglepath.dotted", destination: .networks, state: model.networks) { networks in
            countRow(networks.filter(\.enabled).count, "Enabled networks", Theme.green)
            if let wifi = model.wifiBroadcasts.value {
                countRow(wifi.filter(\.enabled).count, "Broadcasting WiFi", Theme.link)
            }
            if let wans = model.wans.value {
                countRow(wans.count, wans.count == 1 ? "WAN" : "WANs", Theme.secondary)
            }
        }
    }

    private var securityCard: some View {
        summaryCard("Firewall", symbol: "shield.lefthalf.filled", destination: .firewall, state: model.firewallPolicies) { policies in
            countRow(policies.filter { $0.metadata.isUserDefined }.count, "Custom policies", Theme.link)
            countRow(policies.filter { $0.enabled && $0.action.type != "ALLOW" }.count, "Active block rules", Theme.red)
            if let zones = model.firewallZones.value {
                countRow(zones.count, "Zones", Theme.secondary)
            }
        }
    }

    private func summaryCard<Value, Rows: View>(
        _ title: String, symbol: String, destination: ConsolePage, state: LoadState<Value>,
        @ViewBuilder rows: @escaping (Value) -> Rows
    ) -> some View {
        Button { page = destination } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(title, systemImage: symbol).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.tertiary)
                }
                switch state {
                case .loaded(let value): rows(value)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.red).lineLimit(4)
                case .loading: ProgressView().controlSize(.small)
                case .idle: Text("Not loaded").foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .contentShape(Rectangle())
            .card()
        }
        .buttonStyle(.plain)
    }

    private func countRow(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(Theme.secondary)
            Spacer()
            Text(count, format: .number).font(.body.monospacedDigit().weight(.medium))
        }
        .font(.callout)
    }
}
