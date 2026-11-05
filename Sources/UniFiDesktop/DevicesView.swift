import SwiftUI
import UniFiCore

struct DevicesPage: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @State private var selection: Device.ID?
    @State private var search = ""

    var body: some View {
        PageContainer("UniFi Devices", subtitle: subtitle) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                pendingSection
                SectionStateView(state: model.devices, noun: "devices") { devices in
                    let rows = filtered(devices)
                    if devices.isEmpty {
                        EmptyState(title: "No UniFi devices", symbol: "server.rack", message: "This site has no adopted devices.")
                    } else {
                        table(rows)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search devices")
        .inspector(isPresented: Binding(get: { selectedDevice != nil }, set: { if !$0 { selection = nil } })) {
            Group {
                if let device = selectedDevice {
                    DeviceInspector(device: device) { selection = nil }.id(device.id)
                }
            }
            .inspectorColumnWidth(min: 340, ideal: 400, max: 520)
        }
    }

    private var subtitle: String? {
        guard let devices = model.devices.value else { return nil }
        return "\(devices.filter(\.isOnline).count) of \(devices.count) online"
    }

    private var selectedDevice: Device? {
        guard let selection else { return nil }
        return model.devices.value?.first { $0.id == selection }
    }

    private func filtered(_ devices: [Device]) -> [Device] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let sorted = devices.sorted { ($0.isGateway ? 0 : 1, $0.name.lowercased()) < ($1.isGateway ? 0 : 1, $1.name.lowercased()) }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { device in
            [device.name, device.model, device.ipAddress, device.macAddress].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func table(_ devices: [Device]) -> some View {
        Table(devices, selection: $selection) {
            TableColumn("Name") { device in
                HStack(spacing: 8) {
                    Image(systemName: DeviceIcon.name(for: device)).foregroundStyle(Theme.link).frame(width: 18)
                    Text(device.name).fontWeight(.medium)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Status") { device in
                let status = Status.device(device.state)
                StatusLabel(text: status.0, color: status.1)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Model", value: \.model).width(min: 80, ideal: 120)
            TableColumn("IP Address") { Text($0.ipAddress ?? "—").monospacedDigit() }.width(min: 100, ideal: 120)
            TableColumn("MAC Address") { Text($0.macAddress ?? "—").monospacedDigit().foregroundStyle(Theme.secondary) }
                .width(min: 120, ideal: 140)
            TableColumn("Firmware") { device in
                HStack(spacing: 6) {
                    Text(device.firmwareVersion ?? "—").monospacedDigit()
                    if device.firmwareUpdatable == true { Pill("Update", color: Theme.warning) }
                }
            }
            .width(min: 100, ideal: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Device.ID.self) { ids in
            if let id = ids.first, let device = model.devices.value?.first(where: { $0.id == id }) {
                Button("Show Details") { selection = id }
                Divider()
                Button("Restart...") { DeviceActions.restart(device, model: model, confirm: confirm) }
                    .disabled(!model.canMutate)
                Button("Remove...", role: .destructive) { DeviceActions.remove(device, model: model, confirm: confirm) }
                    .disabled(!model.canMutate)
                Divider()
                if let ip = device.ipAddress { Button("Copy IP Address") { Clipboard.copy(ip) } }
                if let mac = device.macAddress { Button("Copy MAC Address") { Clipboard.copy(mac) } }
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }

    @ViewBuilder private var pendingSection: some View {
        switch model.pendingDevices {
        case .loaded(let pending) where !pending.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready to Adopt").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(pending) { device in
                            PendingDeviceCard(device: device)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        case .failed(let message):
            Label("Devices waiting for adoption couldn't be loaded. \(message)", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.warning)
        default:
            EmptyView()
        }
    }
}

private struct PendingDeviceCard: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    let device: PendingDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.title2).foregroundStyle(Theme.link)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.model).fontWeight(.medium)
                Text(device.macAddress).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                if let ip = device.ipAddress { Text(ip).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 16)
            Button("Adopt") {
                confirm.ask("Adopt \(device.model)?", "The device at \(device.macAddress) will be adopted into \(model.selectedSite?.name ?? "this site") and provisioned by the console.", action: "Adopt", destructive: false) {
                    await model.adopt(device)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canMutate || device.supported == false)
            .help(device.supported == false ? "This console reports the device as unsupported." : "Adopt this device")
        }
        .frame(minWidth: 280)
        .card(padding: 12)
    }
}

enum DeviceActions {
    @MainActor static func restart(_ device: Device, model: NetworkModel, confirm: ConfirmCenter) {
        let warning = device.isGateway
            ? "Restarting the gateway interrupts internet access and may disconnect this Mac from the console."
            : "Clients connected through \(device.name) will be briefly disconnected."
        confirm.ask("Restart \(device.name)?", warning, action: "Restart") {
            await model.restart(device)
        }
    }

    @MainActor static func remove(_ device: Device, model: NetworkModel, confirm: ConfirmCenter) {
        confirm.ask(
            "Remove \(device.name)?",
            "The device will be unadopted from this site. If it is online it will also be reset to factory defaults, and anything connected through it may lose connectivity. This cannot be undone.",
            action: "Remove Device"
        ) {
            await model.remove(device)
        }
    }
}

enum Clipboard {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct DeviceInspector: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    @Environment(\.openURL) private var openURL
    let device: Device
    let onClose: () -> Void

    @State private var details: LoadState<(DeviceDetails, LoadState<DeviceStatistics>)> = .loading

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: DeviceIcon.name(for: device)).font(.title3).foregroundStyle(Theme.link)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.headline).lineLimit(1)
                    Text(device.model).font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            .padding(14)
            Divider()
            content
            Divider()
            HStack {
                Button("Remove...", role: .destructive) { DeviceActions.remove(device, model: model, confirm: confirm) }
                    .disabled(!model.canMutate)
                Spacer()
                Button("Open in Web UI") { if let url = model.webURL("devices") { openURL(url) } }
                Button("Restart...") { DeviceActions.restart(device, model: model, confirm: confirm) }
                    .disabled(!model.canMutate)
            }
            .padding(12)
        }
        .background(Theme.sidebar)
        .task(id: device) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch details {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Details unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
            .frame(maxHeight: .infinity)
        case .loaded(let (detail, statistics)):
            Form {
                Section("Overview") {
                    let status = Status.device(detail.state)
                    LabeledContent("Status") { StatusLabel(text: status.0, color: status.1) }
                    DetailRow("IP Address", detail.ipAddress ?? "—")
                    DetailRow("MAC Address", detail.macAddress)
                    LabeledContent("Firmware") {
                        HStack {
                            Text(detail.firmwareVersion ?? "—").textSelection(.enabled)
                            if detail.firmwareUpdatable { Pill("Update available", color: Theme.warning) }
                        }
                    }
                    if let uplink = detail.uplink, let parent = model.devices.value?.first(where: { $0.id == uplink.deviceId }) {
                        DetailRow("Uplink", parent.name)
                    }
                    DetailRow("Adopted", Format.date(detail.adoptedAt))
                }
                statisticsSection(statistics)
                if let ports = detail.interfaces.ports, !ports.isEmpty {
                    Section("Ports") {
                        ForEach(ports) { port in portRow(port) }
                    }
                }
                if let radios = detail.interfaces.radios, !radios.isEmpty {
                    Section("Radios") {
                        ForEach(radios, id: \.self) { radio in
                            LabeledContent(radio.bandLabel) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Channel \(radio.channel.map(String.init) ?? "Auto") · \(radio.channelWidthMHz) MHz")
                                    Text([radio.wlanStandard, radio.txPowerMode.map { "Power \($0.capitalized)" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    }
                }
                if detail.firmwareUpdatable {
                    Section {
                        Text("Firmware updates aren't part of the documented local API. Update from the web UI.")
                            .font(.callout).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private func statisticsSection(_ statistics: LoadState<DeviceStatistics>) -> some View {
        Section("Statistics") {
            switch statistics {
            case .loaded(let stats):
                DetailRow("Uptime", stats.uptimeSec.map(Format.duration(seconds:)) ?? "—")
                DetailRow("CPU", Format.percent(stats.cpuUtilizationPct))
                DetailRow("Memory", Format.percent(stats.memoryUtilizationPct))
                if let load = stats.loadAverage1Min {
                    DetailRow("Load", [load, stats.loadAverage5Min, stats.loadAverage15Min].compactMap { $0 }
                        .map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "  "))
                }
                if let uplink = stats.uplink {
                    DetailRow("Uplink ↓ / ↑", "\(Format.bitsPerSecond(uplink.rxRateBps)) / \(Format.bitsPerSecond(uplink.txRateBps))")
                }
                DetailRow("Last Seen", Format.date(stats.lastHeartbeatAt))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            case .idle, .loading:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func portRow(_ port: DeviceDetails.Port) -> some View {
        HStack(spacing: 10) {
            Text("\(port.idx)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 26, height: 20)
                .background(port.state == "UP" ? Theme.green.opacity(0.22) : Theme.raised, in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(port.state == "UP" ? Format.speed(mbps: port.speedMbps) : port.state.capitalized)
                Text("\(port.connector) · max \(Format.speed(mbps: port.maxSpeedMbps))")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if let poe = port.poe {
                Pill(poe.enabled ? "PoE \(poe.standard)" : "PoE off", color: poe.enabled && poe.state == "UP" ? Theme.warning : Theme.secondary)
                if poe.enabled {
                    Button {
                        confirm.ask("Power cycle port \(port.idx)?", "PoE power on port \(port.idx) of \(device.name) will be cut briefly, restarting whatever it powers.", action: "Power Cycle") {
                            await model.powerCycle(device, port: port.idx)
                        }
                    } label: {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canMutate)
                    .help("Power cycle PoE on this port")
                    .accessibilityLabel("Power cycle port \(port.idx)")
                }
            }
        }
    }

    private func load() async {
        details = .loading
        switch await model.deviceDetails(device) {
        case .success(let value): details = .loaded(value)
        case .failure(let error): details = .failed(error.message)
        }
    }
}
