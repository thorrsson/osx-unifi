import Foundation
import SwiftUI
import UniFiCore

struct CertificateTrustRequest: Identifiable, Equatable {
    let id = UUID()
    let origin: String
    let presented: PresentedCertificate
    let previous: CertificateFingerprint?
}

private enum CertificateStoreError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "The saved trusted certificate for this controller is unreadable. Choose Forget Trusted Certificate, then connect again to review the certificate."
    }
}

/// The state of one independently loaded inventory section. A failure is always shown as a failure,
/// never as an empty list.
enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

enum InventorySection: CaseIterable, Hashable {
    case devices, clients, networks, wifi, zones, policies, dns, vouchers, wans, pending
}

@MainActor
final class NetworkModel: ObservableObject {
    @Published var address: String
    @Published var apiKey = ""
    @Published private(set) var certificateRequest: CertificateTrustRequest?
    @Published private(set) var trustedCertificate: CertificateFingerprint?
    @Published private(set) var sites: [Site] = []
    @Published private(set) var selectedSite: Site?
    @Published private(set) var devices: LoadState<[Device]> = .idle
    @Published private(set) var clients: LoadState<[NetworkClient]> = .idle
    @Published private(set) var networks: LoadState<[NetworkSummary]> = .idle
    @Published private(set) var wifiBroadcasts: LoadState<[WiFiBroadcast]> = .idle
    @Published private(set) var firewallZones: LoadState<[FirewallZone]> = .idle
    @Published private(set) var firewallPolicies: LoadState<[FirewallPolicy]> = .idle
    @Published private(set) var dnsPolicies: LoadState<[DNSPolicy]> = .idle
    @Published private(set) var vouchers: LoadState<[HotspotVoucher]> = .idle
    @Published private(set) var wans: LoadState<[WAN]> = .idle
    @Published private(set) var pendingDevices: LoadState<[PendingDevice]> = .idle
    @Published private(set) var gatewayStatistics: LoadState<DeviceStatistics> = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var isLoading = false
    @Published private(set) var connected = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    /// How long a change confirmation stays visible. Errors stay until dismissed.
    var confirmationLifetime: Duration = .seconds(6)
    private var confirmationDismissal: Task<Void, Never>?
    /// How often the dashboard refreshes gateway statistics while it is visible.
    var statisticsPollInterval: Duration = .seconds(NetworkModel.defaultStatisticsPollSeconds)
    static let statisticsPollRange = 1...30
    static let defaultStatisticsPollSeconds = 3
    static func clampedPollSeconds(_ seconds: Int) -> Int {
        min(max(seconds, statisticsPollRange.lowerBound), statisticsPollRange.upperBound)
    }
    /// The user's chosen statistics refresh interval, in seconds. Saved, and kept within `statisticsPollRange`.
    @Published var statisticsPollSeconds = NetworkModel.defaultStatisticsPollSeconds {
        didSet {
            // Reassigning a @Published value re-runs didSet, so only do it when clamping changes the value.
            let clamped = Self.clampedPollSeconds(statisticsPollSeconds)
            guard clamped == statisticsPollSeconds else {
                statisticsPollSeconds = clamped
                return
            }
            statisticsPollInterval = .seconds(statisticsPollSeconds)
            defaults.set(statisticsPollSeconds, forKey: "statisticsPollSeconds")
        }
    }
    @Published private(set) var applicationVersion: String?
    @Published private(set) var lastRefreshed: Date?
    private var api: (any NetworkAPI)?
    private var loadGeneration = 0
    private let keychain: any CredentialStore
    private let certificates: any CredentialStore
    private let defaults: UserDefaults
    private let makeAPI: (Controller, String, CertificateFingerprint?) throws -> any NetworkAPI

    init(
        keychain: any CredentialStore = KeychainStore(service: KeychainStore.apiKeyService),
        certificates: any CredentialStore = KeychainStore(service: KeychainStore.certificateService),
        defaults: UserDefaults = .standard,
        makeAPI: @escaping (Controller, String, CertificateFingerprint?) throws -> any NetworkAPI = {
            try IntegrationV1API(controller: $0, apiKey: $1, trustedCertificate: $2)
        }
    ) {
        self.keychain = keychain
        self.certificates = certificates
        self.defaults = defaults
        self.makeAPI = makeAPI
        address = defaults.string(forKey: "controllerOrigin") ?? ""
        if let saved = defaults.object(forKey: "statisticsPollSeconds") as? Int {
            let seconds = Self.clampedPollSeconds(saved)
            statisticsPollSeconds = seconds
            statisticsPollInterval = .seconds(seconds)
        }
    }

    var controller: Controller? { try? Controller(address) }
    var networkVersion: NetworkVersion? { applicationVersion.flatMap(NetworkVersion.init) }
    var isVersionVerified: Bool { networkVersion?.isVerified ?? false }
    var supportsFlowReporting: Bool { networkVersion?.supportsFlowReporting ?? false }
    var canMutate: Bool { connected && !isBusy && selectedSite != nil }

    /// Opens the controller web UI for settings this app does not manage.
    func webURL(_ page: String = "dashboard") -> URL? {
        guard let origin = controller?.origin else { return nil }
        let site = selectedSite?.internalReference ?? "default"
        return URL(string: "\(origin.absoluteString)/network/\(site)/\(page)")
    }

    // MARK: Connection

    func connect() async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        notice = nil
        certificateRequest = nil
        clearInventory()
        defer { isBusy = false }
        do {
            let controller = try Controller(address)
            let account = controller.origin.absoluteString
            let key: String
            if apiKey.isEmpty {
                guard let saved = try keychain.read(account: account) else { throw NetworkAPIError.missingKey }
                key = saved
            } else {
                key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let pinned = try pinnedCertificate(for: account)
            let client = try makeAPI(controller, key, pinned)
            let info = try await client.info()
            let loadedSites = try await client.sites()
            try keychain.save(key, account: account)
            apiKey = ""
            address = account
            defaults.set(account, forKey: "controllerOrigin")
            api = client
            sites = loadedSites
            connected = true
            trustedCertificate = pinned
            applicationVersion = info.applicationVersion
            if let first = loadedSites.first {
                selectedSite = first
                await loadInventory(first, using: client)
            }
        } catch let failure as NetworkAPIError {
            switch failure {
            case .untrustedCertificate(let presented):
                requestReview(of: presented, previous: nil)
            case .changedCertificate(let presented, let previous):
                requestReview(of: presented, previous: previous)
            default:
                self.error = Self.describe(failure)
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    private func pinnedCertificate(for account: String) throws -> CertificateFingerprint? {
        guard let stored = try certificates.read(account: account) else { return nil }
        guard let fingerprint = CertificateFingerprint(hex: stored) else { throw CertificateStoreError.unreadable }
        return fingerprint
    }

    // Nothing is saved until the user explicitly trusts the certificate. The API key stays in
    // memory so the connection can be retried, but it is never sent to an unreviewed certificate.
    private func requestReview(of presented: PresentedCertificate, previous: CertificateFingerprint?) {
        guard let controller = try? Controller(address) else {
            error = NetworkAPIError.invalidController.localizedDescription
            return
        }
        certificateRequest = CertificateTrustRequest(
            origin: controller.origin.absoluteString, presented: presented, previous: previous
        )
    }

    func trustCertificate() async {
        guard !isBusy, let request = certificateRequest else { return }
        certificateRequest = nil
        do {
            guard try Controller(address).origin.absoluteString == request.origin else {
                error = "The controller address changed while its certificate was under review. Connect again to review the certificate."
                return
            }
            try certificates.save(request.presented.fingerprint.hex, account: request.origin)
        } catch {
            self.error = "The certificate was not trusted because it could not be saved. \(Self.describe(error))"
            return
        }
        await connect()
    }

    func declineCertificate() {
        guard certificateRequest != nil else { return }
        certificateRequest = nil
        error = "Not connected. The controller's certificate was not trusted."
    }

    func forgetCertificate() {
        guard !isBusy else { return }
        do {
            let origin = try Controller(address).origin.absoluteString
            try certificates.delete(account: origin)
            if connected { disconnect() }
            error = nil
            notice = "Removed the trusted certificate for \(origin). It will be reviewed again the next time you connect."
        } catch {
            self.error = Self.describe(error)
        }
    }

    func disconnect() {
        guard !isBusy else { return }
        clearInventory()
        apiKey = ""
        error = nil
        notice = nil
    }

    func forgetKey() {
        guard !isBusy else { return }
        do {
            let controller = try Controller(address)
            try keychain.delete(account: controller.origin.absoluteString)
            disconnect()
        } catch {
            self.error = Self.describe(error)
        }
    }

    func dismissMessages() {
        error = nil
        notice = nil
    }

    // MARK: Inventory

    func select(_ site: Site) async {
        guard !isBusy, let api, site.id != selectedSite?.id else { return }
        error = nil
        notice = nil
        selectedSite = site
        await loadInventory(site, using: api)
    }

    func refresh() async {
        guard !isBusy, !isLoading, let api else { return }
        error = nil
        notice = nil
        isLoading = true
        do {
            let info = try await api.info()
            let loadedSites = try await api.sites()
            applicationVersion = info.applicationVersion
            sites = loadedSites
            guard let site = loadedSites.first(where: { $0.id == selectedSite?.id }) ?? loadedSites.first else {
                selectedSite = nil
                resetSections(to: .idle)
                lastRefreshed = nil
                isLoading = false
                return
            }
            selectedSite = site
            isLoading = false
            await loadInventory(site, using: api)
        } catch {
            isLoading = false
            self.error = "Refresh failed. \(Self.describe(error))"
            resetSections(to: .failed("Not refreshed: \(Self.describe(error))"))
            lastRefreshed = nil
        }
    }

    private func loadInventory(_ site: Site, using api: any NetworkAPI, only sections: Set<InventorySection>? = nil) async {
        loadGeneration += 1
        let generation = loadGeneration
        let wanted = sections ?? Set(InventorySection.allCases)
        isLoading = true
        for section in wanted { setLoading(section) }
        if wanted.contains(.devices) { gatewayStatistics = .loading }

        let siteID = site.id
        @Sendable func load<Value>(_ section: InventorySection, _ operation: @escaping @Sendable () async throws -> Value) async -> LoadState<Value>? {
            guard wanted.contains(section) else { return nil }
            do { return .loaded(try await operation()) }
            catch { return .failed(NetworkModel.describe(error)) }
        }
        async let devices = load(.devices) { try await api.devices(siteID: siteID) }
        async let clients = load(.clients) { try await api.clients(siteID: siteID) }
        async let networks = load(.networks) { try await api.networks(siteID: siteID) }
        async let wifi = load(.wifi) { try await api.wifiBroadcasts(siteID: siteID) }
        async let zones = load(.zones) { try await api.firewallZones(siteID: siteID) }
        async let policies = load(.policies) { try await api.firewallPolicies(siteID: siteID) }
        async let dns = load(.dns) { try await api.dnsPolicies(siteID: siteID) }
        async let vouchers = load(.vouchers) { try await api.vouchers(siteID: siteID) }
        async let wans = load(.wans) { try await api.wans(siteID: siteID) }
        async let pending = load(.pending) {
            try await api.pendingDevices().filter { $0.adoptionTargetSiteIds?.contains(siteID) ?? true }
        }
        let results = await (devices, clients, networks, wifi, zones, policies, dns, vouchers, wans, pending)

        // A newer load (for example, a site switch) supersedes this one; its results are discarded.
        guard generation == loadGeneration, selectedSite?.id == siteID else { return }
        if let value = results.0 { self.devices = value }
        if let value = results.1 { self.clients = value }
        if let value = results.2 { self.networks = value }
        if let value = results.3 { self.wifiBroadcasts = value }
        if let value = results.4 { self.firewallZones = value }
        if let value = results.5 { self.firewallPolicies = value }
        if let value = results.6 { self.dnsPolicies = value }
        if let value = results.7 { self.vouchers = value }
        if let value = results.8 { self.wans = value }
        if let value = results.9 { self.pendingDevices = value }
        lastRefreshed = Date()
        isLoading = false

        if wanted.contains(.devices) { await loadGatewayStatistics(site, using: api, generation: generation) }
    }

    private func loadGatewayStatistics(_ site: Site, using api: any NetworkAPI, generation: Int) async {
        guard let gateway = devices.value?.first(where: \.isGateway) else {
            gatewayStatistics = devices.failure.map { .failed($0) } ?? .idle
            return
        }
        let state: LoadState<DeviceStatistics>
        do { state = .loaded(try await api.deviceStatistics(siteID: site.id, deviceID: gateway.id)) }
        catch { state = .failed(Self.describe(error)) }
        guard generation == loadGeneration, selectedSite?.id == site.id else { return }
        gatewayStatistics = state
    }

    /// Refreshes the gateway statistics every `statisticsPollInterval` until the calling task is
    /// cancelled. Only statistics are read; inventory sections are not reloaded.
    func pollGatewayStatistics() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: statisticsPollInterval) } catch { return }
            await updateGatewayStatistics()
        }
    }

    /// Reloads the gateway statistics in place, without showing a loading state. Skipped while a
    /// full load is in progress, since that load fetches statistics itself.
    func updateGatewayStatistics() async {
        guard connected, !isLoading, let api, let site = selectedSite,
              let gateway = devices.value?.first(where: \.isGateway) else { return }
        let generation = loadGeneration
        let state: LoadState<DeviceStatistics>
        do { state = .loaded(try await api.deviceStatistics(siteID: site.id, deviceID: gateway.id)) }
        catch { state = .failed(Self.describe(error)) }
        guard !Task.isCancelled, generation == loadGeneration, !isLoading, selectedSite?.id == site.id else { return }
        gatewayStatistics = state
    }

    private func setLoading(_ section: InventorySection) {
        switch section {
        case .devices: devices = .loading
        case .clients: clients = .loading
        case .networks: networks = .loading
        case .wifi: wifiBroadcasts = .loading
        case .zones: firewallZones = .loading
        case .policies: firewallPolicies = .loading
        case .dns: dnsPolicies = .loading
        case .vouchers: vouchers = .loading
        case .wans: wans = .loading
        case .pending: pendingDevices = .loading
        }
    }

    private func resetSections(to state: LoadState<Void>) {
        func map<Value>(_: Value.Type) -> LoadState<Value> {
            switch state {
            case .idle, .loaded: return .idle
            case .loading: return .loading
            case .failed(let message): return .failed(message)
            }
        }
        devices = map([Device].self)
        clients = map([NetworkClient].self)
        networks = map([NetworkSummary].self)
        wifiBroadcasts = map([WiFiBroadcast].self)
        firewallZones = map([FirewallZone].self)
        firewallPolicies = map([FirewallPolicy].self)
        dnsPolicies = map([DNSPolicy].self)
        vouchers = map([HotspotVoucher].self)
        wans = map([WAN].self)
        pendingDevices = map([PendingDevice].self)
        gatewayStatistics = map(DeviceStatistics.self)
    }

    private func clearInventory() {
        loadGeneration += 1
        api = nil
        connected = false
        isLoading = false
        selectedSite = nil
        sites = []
        resetSections(to: .idle)
        applicationVersion = nil
        lastRefreshed = nil
        trustedCertificate = nil
    }

    // MARK: Details

    /// Loads the controller's own detail document for an editor. Nothing is changed.
    func detail(_ kind: EditableResource, id: UUID) async -> Result<JSONValue, MessageError> {
        guard let api, let site = selectedSite else { return .failure(MessageError("Not connected.")) }
        do { return .success(try await api.resource(kind, siteID: site.id, id: id)) }
        catch { return .failure(MessageError("Could not load the current settings. \(Self.describe(error))")) }
    }

    func deviceDetails(_ device: Device) async -> Result<(DeviceDetails, LoadState<DeviceStatistics>), MessageError> {
        guard let api, let site = selectedSite else { return .failure(MessageError("Not connected.")) }
        do {
            let details = try await api.deviceDetails(siteID: site.id, deviceID: device.id)
            let statistics: LoadState<DeviceStatistics>
            do { statistics = .loaded(try await api.deviceStatistics(siteID: site.id, deviceID: device.id)) }
            catch { statistics = .failed(Self.describe(error)) }
            return .success((details, statistics))
        } catch {
            return .failure(MessageError("Could not load device details. \(Self.describe(error))"))
        }
    }

    func networkReferences(_ network: NetworkSummary) async -> Result<[NetworkReference], MessageError> {
        guard let api, let site = selectedSite else { return .failure(MessageError("Not connected.")) }
        do { return .success(try await api.networkReferences(siteID: site.id, networkID: network.id)) }
        catch { return .failure(MessageError("Could not check what uses this network. \(Self.describe(error))")) }
    }

    // MARK: Configuration changes

    @discardableResult
    func create(_ kind: EditableResource, body: JSONValue, name: String) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        return await perform("Created \(kind.displayName) \(name).", reload: kind.sections) {
            _ = try await api.create(kind, siteID: site.id, body: body)
        }
    }

    /// Sends the edited detail document back, without read-only fields, preserving settings the form does not show.
    @discardableResult
    func update(_ kind: EditableResource, id: UUID, edited: JSONValue, name: String) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        let body: JSONValue
        do { body = try kind.updateBody(from: edited) }
        catch {
            self.error = "Nothing was changed. \(Self.describe(error))"
            return false
        }
        return await perform("Saved \(kind.displayName) \(name).", reload: kind.sections) {
            _ = try await api.replace(kind, siteID: site.id, id: id, body: body)
        }
    }

    @discardableResult
    func setEnabled(_ kind: EditableResource, id: UUID, name: String, enabled: Bool) async -> Bool {
        guard canMutate else { return false }
        switch await detail(kind, id: id) {
        case .failure(let failure):
            error = "Nothing was changed. \(failure.message)"
            return false
        case .success(var current):
            current["enabled"] = .bool(enabled)
            let verb = enabled ? "Enabled" : "Disabled"
            guard let api, let site = selectedSite else { return false }
            let body: JSONValue
            do { body = try kind.updateBody(from: current) }
            catch {
                self.error = "Nothing was changed. \(Self.describe(error))"
                return false
            }
            return await perform("\(verb) \(kind.displayName) \(name).", reload: kind.sections) {
                _ = try await api.replace(kind, siteID: site.id, id: id, body: body)
            }
        }
    }

    @discardableResult
    func delete(_ kind: EditableResource, id: UUID, name: String, force: Bool = false) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        return await perform("Deleted \(kind.displayName) \(name).", reload: kind.sections) {
            try await api.delete(kind, siteID: site.id, id: id, force: force)
        }
    }

    @discardableResult
    func patch(_ policy: FirewallPolicy, _ patch: FirewallPolicyPatch) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        if case .flowReporting = patch, !supportsFlowReporting {
            error = "Flow reporting requires UniFi Network 11.0 or later. Nothing was changed."
            return false
        }
        let message: String
        switch patch {
        case .logging(let on): message = "\(on ? "Enabled" : "Disabled") logging for \(policy.name)."
        case .flowReporting(let on): message = "\(on ? "Enabled" : "Disabled") flow reporting for \(policy.name)."
        }
        return await perform(message, reload: [.policies]) {
            try await api.patchFirewallPolicy(siteID: site.id, policyID: policy.id, patch: patch)
        }
    }

    /// Reads the zone pair's current order, then sends one reordered copy.
    @discardableResult
    func move(_ policy: FirewallPolicy, _ move: FirewallPolicyOrdering.Move) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        let source = policy.source.zoneId, destination = policy.destination.zoneId
        let current: FirewallPolicyOrdering
        do {
            current = try await api.firewallPolicyOrdering(siteID: site.id, sourceZoneID: source, destinationZoneID: destination)
        } catch {
            self.error = "Nothing was changed. Could not load the current policy order. \(Self.describe(error))"
            return false
        }
        guard let reordered = current.applying(move, to: policy.id) else {
            error = current.isBeforeSystemDefined(policy.id) == nil
                ? "\(policy.name) isn't in the console's user-defined order for its zones. Nothing was changed."
                : "\(policy.name) is already in that position. Nothing was changed."
            return false
        }
        return await perform("Moved \(policy.name).", reload: [.policies]) {
            try await api.reorderFirewallPolicies(siteID: site.id, sourceZoneID: source, destinationZoneID: destination, ordering: reordered)
        }
    }

    // MARK: Hotspot

    func generateVouchers(_ request: VoucherRequest) async -> [HotspotVoucher]? {
        guard canMutate, let api, let site = selectedSite else { return nil }
        let errors = request.validationErrors
        guard errors.isEmpty else {
            error = errors.joined(separator: " ")
            return nil
        }
        var created: [HotspotVoucher] = []
        let accepted = await perform("Created \(request.count) voucher\(request.count == 1 ? "" : "s").", reload: [.vouchers]) {
            created = try await api.generateVouchers(siteID: site.id, request: request)
        }
        return accepted ? created : nil
    }

    @discardableResult
    func deleteVoucher(_ voucher: HotspotVoucher) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        return await perform("Deleted voucher \(voucher.formattedCode).", reload: [.vouchers]) {
            try await api.deleteVoucher(siteID: site.id, voucherID: voucher.id)
        }
    }

    @discardableResult
    func deleteExpiredVouchers() async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        var count = 0
        let accepted = await perform("", reload: [.vouchers]) {
            count = try await api.deleteExpiredVouchers(siteID: site.id)
        }
        if accepted { confirm("Deleted \(count) expired voucher\(count == 1 ? "" : "s").") }
        return accepted
    }

    // MARK: Devices and clients

    @discardableResult
    func restart(_ device: Device) async -> Bool {
        guard canMutate, let api, let site = selectedSite, devices.value?.contains(where: { $0.id == device.id }) == true else { return false }
        return await perform("Restart request accepted for \(device.name). Connectivity may be interrupted.", reload: [.devices]) {
            try await api.restartDevice(siteID: site.id, deviceID: device.id)
        }
    }

    @discardableResult
    func powerCycle(_ device: Device, port: Int) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        return await perform("Power cycle accepted for port \(port) on \(device.name).", reload: [.devices, .clients]) {
            try await api.powerCyclePort(siteID: site.id, deviceID: device.id, portIndex: port)
        }
    }

    @discardableResult
    func adopt(_ pending: PendingDevice) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        return await perform("Adoption started for \(pending.model) (\(pending.macAddress)).", reload: [.devices, .pending]) {
            try await api.adoptDevice(siteID: site.id, macAddress: pending.macAddress)
        }
    }

    @discardableResult
    func remove(_ device: Device) async -> Bool {
        guard canMutate, let api, let site = selectedSite else { return false }
        return await perform("Removed \(device.name). If it was online, it is resetting to factory defaults.", reload: [.devices, .pending]) {
            try await api.removeDevice(siteID: site.id, deviceID: device.id)
        }
    }

    @discardableResult
    func guestAccess(_ client: NetworkClient, action: GuestAction, limits: GuestLimits? = nil) async -> Bool {
        guard canMutate, let api, let site = selectedSite,
              clients.value?.contains(where: { $0.id == client.id }) == true, client.isGuest else { return false }
        if let errors = limits?.validationErrors, !errors.isEmpty {
            error = "Nothing was changed. \(errors.joined(separator: " "))"
            return false
        }
        let accepted = action == .authorize
            ? (limits == nil || limits == GuestLimits() ? "Authorized \(client.name ?? "guest") using the site's default limits." : "Authorized \(client.name ?? "guest") with custom limits.")
            : "Revoked guest access for \(client.name ?? "guest")."
        return await perform(accepted, reload: [.clients]) {
            try await api.guestAccess(siteID: site.id, clientID: client.id, action: action, limits: limits)
        }
    }

    /// Runs one change exactly once. Failures are never retried and never reported as success.
    private func perform(_ accepted: String, reload: Set<InventorySection>, operation: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        error = nil
        notice = nil
        do {
            try await operation()
        } catch let failure as NetworkAPIError where failure.isCertificateFailure {
            // The handshake is rejected before any request bytes are sent, so nothing was changed.
            isBusy = false
            error = "The change was not sent. \(failure.localizedDescription)"
            return false
        } catch let failure as NetworkAPIError {
            isBusy = false
            if case .rejected = failure {
                error = "\(failure.localizedDescription) Nothing was changed."
            } else {
                error = "The change was not confirmed. \(Self.describe(failure)) Its outcome may be unknown. Refresh before trying again."
            }
            return false
        } catch {
            isBusy = false
            self.error = "The change was not confirmed. \(Self.describe(error)) Its outcome may be unknown. Refresh before trying again."
            return false
        }
        isBusy = false
        if !accepted.isEmpty { confirm(accepted) }
        if let site = selectedSite, let api { await loadInventory(site, using: api, only: reload) }
        return true
    }

    /// Shows a change confirmation briefly, like the console's toasts.
    private func confirm(_ text: String) {
        notice = text
        confirmationDismissal?.cancel()
        let lifetime = confirmationLifetime
        confirmationDismissal = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.notice == text else { return }
            self.notice = nil
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed:
                return "The secure connection to the controller failed: \(urlError.localizedDescription) Check the controller address and its certificate. A certificate is accepted only when macOS trusts it or you have reviewed and trusted it in this app."
            default:
                return "Cannot reach the controller: \(urlError.localizedDescription) Check LAN/VPN access and macOS Local Network permission."
            }
        }
        if let message = error as? MessageError { return message.message }
        return error.localizedDescription
    }
}

struct MessageError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

extension EditableResource {
    var sections: Set<InventorySection> {
        switch self {
        case .networks: return [.networks, .zones, .wifi]
        case .wifiBroadcasts: return [.wifi]
        case .firewallZones: return [.zones, .policies]
        case .firewallPolicies: return [.policies]
        case .dnsPolicies: return [.dns]
        }
    }
}
