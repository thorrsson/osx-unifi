import SwiftUI
import UniFiCore

struct HotspotPage: View {
    @EnvironmentObject private var model: NetworkModel
    @EnvironmentObject private var confirm: ConfirmCenter
    /// Presents `VoucherSheet` from the console, which hosts sheets for pages.
    let createVouchers: () -> Void
    @State private var selection = Set<HotspotVoucher.ID>()
    @State private var search = ""

    var body: some View {
        PageContainer("Hotspot", subtitle: "Guest vouchers for hotspot networks.") {
            Button("Delete Expired...") { confirmDeleteExpired() }
                .disabled(!model.canMutate || !(model.vouchers.value?.contains(where: \.expired) ?? false))
            Button(action: createVouchers) { Label("Create Vouchers", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMutate)
        } content: {
            SectionStateView(state: model.vouchers, noun: "vouchers") { vouchers in
                let rows = filtered(vouchers)
                if rows.isEmpty {
                    EmptyState(title: "No vouchers", symbol: "ticket",
                               message: vouchers.isEmpty ? "Create vouchers to give guests time-limited access." : "No vouchers match.")
                } else {
                    table(rows)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search vouchers")
    }

    private func filtered(_ vouchers: [HotspotVoucher]) -> [HotspotVoucher] {
        let query = search.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "")
        return vouchers
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.code.contains(query) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func table(_ vouchers: [HotspotVoucher]) -> some View {
        Table(vouchers, selection: $selection) {
            TableColumn("Code") { Text($0.formattedCode).monospaced().fontWeight(.medium).textSelection(.enabled) }.width(min: 100, ideal: 120)
            TableColumn("Name") { Text($0.name) }.width(min: 100, ideal: 150)
            TableColumn("Status") { VoucherStatus(voucher: $0) }.width(min: 70, ideal: 90)
            TableColumn("Duration") { Text(Format.minutes($0.timeLimitMinutes)).foregroundStyle(Theme.secondary) }.width(min: 60, ideal: 70)
            TableColumn("Guests") { voucher in
                Text("\(voucher.authorizedGuestCount) / \(voucher.authorizedGuestLimit.map(String.init) ?? "∞")")
                    .monospacedDigit().foregroundStyle(Theme.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Limits") { Text(limits($0)).foregroundStyle(Theme.tertiary) }.width(min: 70, ideal: 120)
            TableColumn("Created") { Text(Format.shortDate($0.createdAt)).foregroundStyle(Theme.secondary) }.width(min: 100, ideal: 120)
            TableColumn("Expires") { Text(Format.shortDate($0.expiresAt)).foregroundStyle(Theme.secondary) }.width(min: 100, ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: HotspotVoucher.ID.self) { ids in
            let chosen = (model.vouchers.value ?? []).filter { ids.contains($0.id) }
            if !chosen.isEmpty {
                Button(chosen.count == 1 ? "Copy Code" : "Copy \(chosen.count) Codes") {
                    Clipboard.copy(chosen.map(\.formattedCode).joined(separator: "\n"))
                }
                Divider()
                Button(chosen.count == 1 ? "Delete..." : "Delete \(chosen.count) Vouchers...", role: .destructive) { confirmDelete(chosen) }
            }
        }
        .onDeleteCommand {
            let chosen = (model.vouchers.value ?? []).filter { selection.contains($0.id) }
            if !chosen.isEmpty { confirmDelete(chosen) }
        }
    }

    private func limits(_ voucher: HotspotVoucher) -> String {
        var parts: [String] = []
        if let data = voucher.dataUsageLimitMBytes { parts.append("\(data.formatted()) MB") }
        if let down = voucher.rxRateLimitKbps { parts.append("↓ \(Format.bitsPerSecond(down * 1000))") }
        if let up = voucher.txRateLimitKbps { parts.append("↑ \(Format.bitsPerSecond(up * 1000))") }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    private func confirmDelete(_ vouchers: [HotspotVoucher]) {
        let title = vouchers.count == 1 ? "Delete voucher \(vouchers[0].formattedCode)?" : "Delete \(vouchers.count) vouchers?"
        confirm.ask(title, "Guests already using \(vouchers.count == 1 ? "it" : "them") may be disconnected.", action: "Delete") {
            for voucher in vouchers {
                guard await model.deleteVoucher(voucher) else { break }
            }
            selection.removeAll()
        }
    }

    private func confirmDeleteExpired() {
        confirm.ask("Delete all expired vouchers?", "This removes every expired voucher on this site.", action: "Delete Expired") {
            await model.deleteExpiredVouchers()
        }
    }
}

private struct VoucherStatus: View {
    let voucher: HotspotVoucher

    var body: some View {
        if voucher.expired {
            StatusLabel(text: "Expired", color: Theme.tertiary)
        } else if voucher.activatedAt != nil {
            StatusLabel(text: "Active", color: Theme.green)
        } else {
            StatusLabel(text: "Unused", color: Theme.link)
        }
    }
}

/// Shows the voucher form, then the generated codes, in a single sheet.
struct VoucherSheet: View {
    let onClose: () -> Void
    @State private var created: [HotspotVoucher]?

    var body: some View {
        if let created {
            CreatedVouchersSheet(vouchers: created, onDone: onClose)
        } else {
            VoucherForm { vouchers in
                if let vouchers, !vouchers.isEmpty { created = vouchers } else { onClose() }
            }
        }
    }
}

private struct VoucherForm: View {
    @EnvironmentObject private var model: NetworkModel
    let onFinish: ([HotspotVoucher]?) -> Void

    private static let durations: [(String, Int)] = [
        ("1 hour", 60), ("8 hours", 480), ("1 day", 1440), ("3 days", 4320), ("1 week", 10_080), ("30 days", 43_200)
    ]

    @State private var request = VoucherRequest(name: "Guest", timeLimitMinutes: 1440)
    @State private var customDuration = false
    @State private var unlimitedGuests = false
    @State private var attempted = false
    @State private var failure: String?
    @State private var saving = false

    private var effective: VoucherRequest {
        var value = request
        if unlimitedGuests { value.authorizedGuestLimit = nil }
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Vouchers").font(.headline).padding(14)
            Form {
                Section {
                    TextField("Name", text: $request.name)
                    IntField("Quantity", value: $request.count)
                }
                Section("Access") {
                    Picker("Duration", selection: Binding(
                        get: { customDuration ? -1 : request.timeLimitMinutes },
                        set: { value in
                            customDuration = value == -1
                            if value != -1 { request.timeLimitMinutes = value }
                        }
                    )) {
                        ForEach(Self.durations, id: \.1) { Text($0.0).tag($0.1) }
                        Divider()
                        Text("Custom").tag(-1)
                    }
                    if customDuration || !Self.durations.contains(where: { $0.1 == request.timeLimitMinutes }) {
                        IntField("Minutes", value: $request.timeLimitMinutes, suffix: "min")
                    }
                    Toggle("Unlimited guests per voucher", isOn: $unlimitedGuests)
                    if !unlimitedGuests {
                        IntField("Guests per voucher", value: Binding(get: { request.authorizedGuestLimit ?? 1 }, set: { request.authorizedGuestLimit = $0 }))
                    }
                }
                Section("Limits") {
                    OptionalIntField(title: "Data", value: $request.dataUsageLimitMBytes, defaultValue: 1024, suffix: "MB")
                    OptionalIntField(title: "Download", value: $request.rxRateLimitKbps, defaultValue: 10_000, suffix: "Kbps")
                    OptionalIntField(title: "Upload", value: $request.txRateLimitKbps, defaultValue: 5_000, suffix: "Kbps")
                }
                if attempted, !effective.validationErrors.isEmpty {
                    Section {
                        ForEach(effective.validationErrors, id: \.self) {
                            Label($0, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning)
                        }
                    }
                }
                if let failure {
                    Section { Label(failure, systemImage: "xmark.octagon").foregroundStyle(Theme.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onFinish(nil) }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !model.canMutate)
            }
            .padding(12)
        }
        .frame(width: 440, height: 560)
        .background(Theme.sidebar)
    }

    private func create() async {
        attempted = true
        guard effective.validationErrors.isEmpty else { return }
        saving = true
        defer { saving = false }
        failure = nil
        if let vouchers = await model.generateVouchers(effective) {
            onFinish(vouchers)
        } else {
            failure = model.error
        }
    }
}

private struct CreatedVouchersSheet: View {
    let vouchers: [HotspotVoucher]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vouchers.count == 1 ? "Voucher Created" : "\(vouchers.count) Vouchers Created").font(.headline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                    ForEach(vouchers) { voucher in
                        Text(voucher.formattedCode)
                            .font(.title3.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Button("Copy All") { Clipboard.copy(vouchers.map(\.formattedCode).joined(separator: "\n")) }
                Spacer()
                Button("Done", action: onDone).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.sidebar)
    }
}
