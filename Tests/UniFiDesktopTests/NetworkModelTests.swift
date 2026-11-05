import Foundation
import Security
import XCTest
import UniFiCore
@testable import UniFiDesktop

private final class MemoryCredentials: CredentialStore {
    var key: String?
    var failure: Error?
    var saveFailure: Error?
    var savedAccount: String?
    func read(account: String) throws -> String? {
        if let failure { throw failure }
        return key
    }
    func save(_ key: String, account: String) throws {
        if let failure { throw failure }
        if let saveFailure { throw saveFailure }
        self.key = key
        savedAccount = account
    }
    func delete(account: String) throws {
        if let failure { throw failure }
        key = nil
    }
}

private final class PinRecorder {
    var pins: [CertificateFingerprint?] = []
}

private let presentedCertificate = PresentedCertificate(
    fingerprint: CertificateFingerprint(hex: String(repeating: "ab", count: 32))!,
    subject: "UniFi OS"
)
private let previousFingerprint = CertificateFingerprint(hex: String(repeating: "cd", count: 32))!

private let siteID = "00000000-0000-0000-0000-000000000001"
private let zoneA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let zoneB = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
private let policyA = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
private let policyB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
private let unorderedPolicy = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!

private actor ModelAPI: NetworkAPI {
    var failClients = false
    var failActions = false
    var emptySites = false
    var infoFailure: NetworkAPIError?
    var actionFailure: NetworkAPIError?
    var detailFailure: NetworkAPIError?
    var version = "10.6.106"
    var ordering = FirewallPolicyOrdering(beforeSystemDefined: [policyA, policyB], afterSystemDefined: [])
    private(set) var calls: [String] = []
    private(set) var replacedBody: JSONValue?
    private(set) var appliedOrdering: FirewallPolicyOrdering?
    let id = siteID

    func configure(
        failClients: Bool = false, failActions: Bool = false, emptySites: Bool = false,
        infoFailure: NetworkAPIError? = nil, actionFailure: NetworkAPIError? = nil,
        detailFailure: NetworkAPIError? = nil, version: String = "10.6.106"
    ) {
        self.failClients = failClients
        self.failActions = failActions
        self.emptySites = emptySites
        self.infoFailure = infoFailure
        self.actionFailure = actionFailure
        self.detailFailure = detailFailure
        self.version = version
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// Records one change request and fails it when configured to.
    private func mutate(_ name: String) throws {
        calls.append(name)
        if let actionFailure { throw actionFailure }
        if failActions { throw URLError(.timedOut) }
    }

    func actionCount() -> Int { calls.filter { $0 != "resource" && $0 != "ordering" }.count }

    func info() async throws -> ApplicationInfo {
        if let infoFailure { throw infoFailure }
        return try decode(#"{"applicationVersion":"\#(version)"}"#)
    }
    func sites() async throws -> [Site] {
        try decode(emptySites ? "[]" : "[{\"id\":\"\(id)\",\"name\":\"Home\"}]")
    }
    func devices(siteID: UUID) async throws -> [Device] {
        try decode("[{\"id\":\"\(id)\",\"name\":\"Gateway\",\"model\":\"UDM Pro\",\"state\":\"ONLINE\"}]")
    }
    func clients(siteID: UUID) async throws -> [NetworkClient] {
        if failClients { throw NetworkAPIError.authentication }
        return try decode("[{\"id\":\"\(id)\",\"name\":\"Guest\",\"type\":\"WIRELESS\",\"access\":{\"type\":\"GUEST\",\"authorized\":false}}]")
    }
    func networks(siteID: UUID) async throws -> [NetworkSummary] { [] }
    func wifiBroadcasts(siteID: UUID) async throws -> [WiFiBroadcast] { [] }
    func firewallZones(siteID: UUID) async throws -> [FirewallZone] { [] }
    func firewallPolicies(siteID: UUID) async throws -> [FirewallPolicy] {
        try decode("[" + [policyA, policyB, unorderedPolicy].enumerated().map { index, policy in
            """
            {"id":"\(policy.apiString)","name":"Policy \(index + 1)","enabled":true,"index":\(index),
             "action":{"type":"ALLOW"},"source":{"zoneId":"\(zoneA.apiString)"},"destination":{"zoneId":"\(zoneB.apiString)"},
             "ipProtocolScope":{"ipVersion":"IPV4_AND_IPV6"},"loggingEnabled":false,"metadata":{"origin":"USER_DEFINED"}}
            """
        }.joined(separator: ",") + "]")
    }
    func dnsPolicies(siteID: UUID) async throws -> [DNSPolicy] { [] }
    func vouchers(siteID: UUID) async throws -> [HotspotVoucher] { [] }
    func wans(siteID: UUID) async throws -> [WAN] { [] }
    func pendingDevices() async throws -> [PendingDevice] { [] }
    func deviceDetails(siteID: UUID, deviceID: UUID) async throws -> DeviceDetails { throw NetworkAPIError.unsupported }
    func deviceStatistics(siteID: UUID, deviceID: UUID) async throws -> DeviceStatistics { throw NetworkAPIError.unsupported }
    func networkReferences(siteID: UUID, networkID: UUID) async throws -> [NetworkReference] { [] }

    func resource(_ kind: EditableResource, siteID: UUID, id: UUID) async throws -> JSONValue {
        calls.append("resource")
        if let detailFailure { throw detailFailure }
        return ["id": .string(id.apiString), "metadata": ["origin": "USER_DEFINED"], "default": false,
                "name": "Thing", "enabled": true, "futureSetting": ["kept": true]]
    }
    func create(_ kind: EditableResource, siteID: UUID, body: JSONValue) async throws -> JSONValue {
        try mutate("create")
        return ["id": .string(UUID().apiString)]
    }
    func replace(_ kind: EditableResource, siteID: UUID, id: UUID, body: JSONValue) async throws -> JSONValue {
        try mutate("replace")
        replacedBody = body
        return body
    }
    func delete(_ kind: EditableResource, siteID: UUID, id: UUID, force: Bool) async throws { try mutate("delete") }
    func patchFirewallPolicy(siteID: UUID, policyID: UUID, patch: FirewallPolicyPatch) async throws { try mutate("patch") }
    func firewallPolicyOrdering(siteID: UUID, sourceZoneID: UUID, destinationZoneID: UUID) async throws -> FirewallPolicyOrdering {
        calls.append("ordering")
        if let detailFailure { throw detailFailure }
        return ordering
    }
    func reorderFirewallPolicies(siteID: UUID, sourceZoneID: UUID, destinationZoneID: UUID, ordering: FirewallPolicyOrdering) async throws {
        try mutate("reorder")
        appliedOrdering = ordering
    }
    func generateVouchers(siteID: UUID, request: VoucherRequest) async throws -> [HotspotVoucher] {
        try mutate("generate")
        return []
    }
    func deleteVoucher(siteID: UUID, voucherID: UUID) async throws { try mutate("deleteVoucher") }
    func deleteExpiredVouchers(siteID: UUID) async throws -> Int {
        try mutate("deleteExpired")
        return 2
    }
    func restartDevice(siteID: UUID, deviceID: UUID) async throws { try mutate("restart") }
    func powerCyclePort(siteID: UUID, deviceID: UUID, portIndex: Int) async throws { try mutate("powerCycle") }
    func adoptDevice(siteID: UUID, macAddress: String) async throws { try mutate("adopt") }
    func removeDevice(siteID: UUID, deviceID: UUID) async throws { try mutate("remove") }
    func guestAccess(siteID: UUID, clientID: UUID, action: GuestAction, limits: GuestLimits?) async throws {
        try mutate("guest")
    }
}

@MainActor
final class NetworkModelTests: XCTestCase {
    private func model(
        _ api: ModelAPI,
        credentials: MemoryCredentials = MemoryCredentials(),
        certificates: MemoryCredentials = MemoryCredentials(),
        recorder: PinRecorder = PinRecorder()
    ) -> NetworkModel {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = NetworkModel(
            keychain: credentials, certificates: certificates, defaults: defaults,
            makeAPI: { _, _, pin in
                recorder.pins.append(pin)
                return api
            }
        )
        model.address = "https://controller.example"
        model.apiKey = "test-key"
        return model
    }

    private func accepted(_ result: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result, "The change should have been accepted", file: file, line: line)
    }
    
    private func refused(_ result: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result, "The change should not have been accepted", file: file, line: line)
    }
    
    func testConnectSavesKeyAndPublishesCompleteInventory() async throws {
        let credentials = MemoryCredentials()
        let model = model(ModelAPI(), credentials: credentials)
        await model.connect()
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.devices.value?.count, 1)
        XCTAssertEqual(model.clients.value?.count, 1)
        XCTAssertEqual(model.firewallPolicies.value?.count, 3)
        XCTAssertEqual(model.networks.value?.count, 0, "A genuinely empty list is loaded, not failed")
        XCTAssertEqual(model.applicationVersion, "10.6.106")
        XCTAssertEqual(credentials.key, "test-key")
        XCTAssertEqual(credentials.savedAccount, "https://controller.example")
        XCTAssertTrue(model.apiKey.isEmpty)
        XCTAssertNotNil(model.lastRefreshed)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    func testFailedSectionIsShownAsFailureWithoutHidingOtherSections() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        await api.configure(failClients: true)
        await model.refresh()
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.devices.value?.count, 1)
        XCTAssertNil(model.clients.value, "A failed section must not keep stale or empty results")
        XCTAssertTrue(try XCTUnwrap(model.clients.failure).contains("API key"))
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isLoading)
    }

    func testRefreshFailureMarksEverySectionFailed() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        await api.configure(infoFailure: .authentication)
        await model.refresh()
        XCTAssertTrue(try XCTUnwrap(model.error).hasPrefix("Refresh failed."))
        XCTAssertNil(model.devices.value)
        XCTAssertNotNil(model.devices.failure)
        XCTAssertNotNil(model.firewallPolicies.failure)
        XCTAssertNil(model.lastRefreshed)
        XCTAssertFalse(model.isLoading)
    }

    func testKeychainFailureIsNotReportedAsConnected() async {
        let credentials = MemoryCredentials()
        credentials.failure = NetworkAPIError.authentication
        let model = model(ModelAPI(), credentials: credentials)
        await model.connect()
        XCTAssertFalse(model.connected)
        XCTAssertTrue(model.sites.isEmpty)
        XCTAssertNotNil(model.error)
    }

    func testDeniedSavedKeyAccessPreservesCredentialsAndDoesNotAttemptConnection() async {
        let credentials = MemoryCredentials()
        credentials.key = "saved-key"
        credentials.failure = KeychainError(status: errSecAuthFailed)
        let recorder = PinRecorder()
        let model = model(ModelAPI(), credentials: credentials, recorder: recorder)
        model.apiKey = ""
        await model.connect()
        XCTAssertFalse(model.connected)
        XCTAssertTrue(recorder.pins.isEmpty)
        XCTAssertEqual(credentials.key, "saved-key")
        XCTAssertTrue(model.error?.contains("Mac login/keychain password") == true)
        XCTAssertFalse(model.isBusy)
    }

    func testDeniedKeySaveKeepsEnteredKeyAvailableForRetry() async {
        let credentials = MemoryCredentials()
        credentials.key = "previous-key"
        credentials.saveFailure = KeychainError(status: errSecAuthFailed)
        let model = model(ModelAPI(), credentials: credentials)
        await model.connect()
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.devices.value)
        XCTAssertEqual(credentials.key, "previous-key")
        XCTAssertEqual(model.apiKey, "test-key")
        XCTAssertTrue(model.error?.contains("Mac login/keychain password") == true)
        XCTAssertFalse(model.isBusy)
    }

    func testSavedKeyReconnectDisconnectAndForget() async {
        let credentials = MemoryCredentials()
        credentials.key = "saved-key"
        let model = model(ModelAPI(), credentials: credentials)
        model.apiKey = ""
        await model.connect()
        XCTAssertTrue(model.connected)
        model.disconnect()
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.devices.value)
        XCTAssertNil(model.applicationVersion)
        XCTAssertEqual(credentials.key, "saved-key")
        model.forgetKey()
        XCTAssertNil(credentials.key)
    }

    func testManagementIsSingleShotAndReloadsOnlyAffectedSections() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        let device = try XCTUnwrap(model.devices.value?.first)
        let client = try XCTUnwrap(model.clients.value?.first)
        await api.configure(failClients: true)
        accepted(await model.restart(device))
        XCTAssertEqual(model.clients.value?.count, 1, "A device restart does not reload clients")
        XCTAssertNotNil(model.notice)
        XCTAssertNil(model.error)

        accepted(await model.guestAccess(client, action: .authorize))
        let count = await api.actionCount()
        XCTAssertEqual(count, 2)
        XCTAssertNotNil(model.notice, "The accepted change is still reported")
        XCTAssertNotNil(model.clients.failure, "The failed reload is shown on the affected section")
    }

    func testUnconfirmedMutationWarnsBeforeRetryAndDoesNotRetry() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        await api.configure(failActions: true)
        refused(await model.restart(try XCTUnwrap(model.devices.value?.first)))
        let count = await api.actionCount()
        XCTAssertEqual(count, 1)
        XCTAssertNil(model.notice)
        XCTAssertTrue(try XCTUnwrap(model.error).contains("outcome may be unknown"))
        XCTAssertFalse(model.isBusy)
    }

    func testRejectedChangeReportsThatNothingChanged() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        await api.configure(actionFailure: .rejected(status: 400, message: "VLAN 20 is already in use"))
        refused(await model.create(.networks, body: ["name": "Lab"], name: "Lab"))
        let message = try XCTUnwrap(model.error)
        XCTAssertTrue(message.contains("VLAN 20 is already in use"))
        XCTAssertTrue(message.hasSuffix("Nothing was changed."))
        XCTAssertFalse(message.contains("outcome may be unknown"))
    }

    func testGuestActionAndEmptySiteState() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        accepted(await model.guestAccess(try XCTUnwrap(model.clients.value?.first), action: .authorize))
        let count = await api.actionCount()
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(model.notice)
        model.disconnect()
        await api.configure(emptySites: true)
        await model.connect()
        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.sites.isEmpty)
        XCTAssertNil(model.devices.value)
        XCTAssertNil(model.devices.failure)
        XCTAssertNil(model.error)
    }

    func testInvalidGuestLimitsAreNeverSent() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        let client = try XCTUnwrap(model.clients.value?.first)
        refused(await model.guestAccess(client, action: .authorize, limits: GuestLimits(timeLimitMinutes: 0)))
        let count = await api.actionCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try XCTUnwrap(model.error).hasPrefix("Nothing was changed."))
    }

    func testRefreshReloadsVersionAndSitesWithoutRetainingRemovedSite() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        await api.configure(emptySites: true, version: "11.0.97")
        await model.refresh()
        XCTAssertTrue(model.sites.isEmpty)
        XCTAssertNil(model.selectedSite)
        XCTAssertNil(model.devices.value)
        XCTAssertNil(model.lastRefreshed)
        XCTAssertEqual(model.applicationVersion, "11.0.97")
        XCTAssertTrue(model.supportsFlowReporting)
    }

    // MARK: Configuration changes

    func testSetEnabledSendsTheControllerDocumentWithOnlyEnabledChanged() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        accepted(await model.setEnabled(.networks, id: UUID(), name: "Lab", enabled: false))
        let calls = await api.calls
        XCTAssertEqual(calls, ["resource", "replace"])
        let body = await api.replacedBody
        XCTAssertEqual(body, ["name": "Thing", "enabled": false, "futureSetting": ["kept": true]])
        XCTAssertEqual(model.notice, "Disabled network Lab.")
    }

    func testChangeConfirmationsDismissThemselves() async throws {
        let api = ModelAPI()
        let model = model(api)
        model.confirmationLifetime = .milliseconds(50)
        await model.connect()
        accepted(await model.setEnabled(.networks, id: UUID(), name: "Lab", enabled: false))
        XCTAssertEqual(model.notice, "Disabled network Lab.")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.notice)
    }

    func testSetEnabledSendsNothingWhenCurrentSettingsCannotBeRead() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        await api.configure(detailFailure: .unsupported)
        refused(await model.setEnabled(.wifiBroadcasts, id: UUID(), name: "Home", enabled: false))
        let calls = await api.calls
        XCTAssertEqual(calls, ["resource"])
        XCTAssertTrue(try XCTUnwrap(model.error).hasPrefix("Nothing was changed."))
    }

    func testUpdateRemovesServerOwnedFieldsBeforeSending() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        let edited: JSONValue = ["id": "x", "metadata": [:], "index": 4, "name": "Renamed"]
        accepted(await model.update(.firewallPolicies, id: UUID(), edited: edited, name: "Renamed"))
        let body = await api.replacedBody
        XCTAssertEqual(body, ["name": "Renamed"])
    }

    func testMoveReadsCurrentOrderThenSendsOneReorderedCopy() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        let policy = try XCTUnwrap(model.firewallPolicies.value?.first { $0.id == policyB })
        accepted(await model.move(policy, .earlier))
        let calls = await api.calls
        XCTAssertEqual(calls, ["ordering", "reorder"])
        let applied = await api.appliedOrdering
        XCTAssertEqual(applied, FirewallPolicyOrdering(beforeSystemDefined: [policyB, policyA], afterSystemDefined: []))
        XCTAssertEqual(model.notice, "Moved Policy 2.")
    }

    func testImpossibleMovesAreNotSent() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        let policies = try XCTUnwrap(model.firewallPolicies.value)
        refused(await model.move(try XCTUnwrap(policies.first { $0.id == policyA }), .earlier))
        XCTAssertTrue(try XCTUnwrap(model.error).contains("already in that position"))
        refused(await model.move(try XCTUnwrap(policies.first { $0.id == unorderedPolicy }), .later))
        XCTAssertTrue(try XCTUnwrap(model.error).contains("isn't in the console's user-defined order"))
        await api.configure(detailFailure: .authentication)
        refused(await model.move(try XCTUnwrap(policies.first { $0.id == policyB }), .earlier))
        XCTAssertTrue(try XCTUnwrap(model.error).contains("Could not load the current policy order"))
        let count = await api.actionCount()
        XCTAssertEqual(count, 0)
    }

    func testFlowReportingRequiresNetwork11() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        let policy = try XCTUnwrap(model.firewallPolicies.value?.first)
        XCTAssertFalse(model.supportsFlowReporting)
        refused(await model.patch(policy, .flowReporting(true)))
        XCTAssertTrue(try XCTUnwrap(model.error).contains("11.0"))
        var count = await api.actionCount()
        XCTAssertEqual(count, 0)

        accepted(await model.patch(policy, .logging(true)))
        await api.configure(version: "11.0.97")
        await model.refresh()
        accepted(await model.patch(policy, .flowReporting(true)))
        count = await api.actionCount()
        XCTAssertEqual(count, 2)
    }

    func testVoucherValidationAndExpiredCleanup() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        let invalid = await model.generateVouchers(VoucherRequest(name: "Guest", count: 0, timeLimitMinutes: 60))
        XCTAssertNil(invalid)
        var count = await api.actionCount()
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(model.error)

        accepted(await model.deleteExpiredVouchers())
        XCTAssertEqual(model.notice, "Deleted 2 expired vouchers.")
        count = await api.actionCount()
        XCTAssertEqual(count, 1)
    }

    func testUntrustedCertificateRequestsReviewAndSavesNothing() async throws {
        let api = ModelAPI()
        await api.configure(infoFailure: .untrustedCertificate(presentedCertificate))
        let credentials = MemoryCredentials()
        let certificates = MemoryCredentials()
        let model = model(api, credentials: credentials, certificates: certificates)
        await model.connect()
        let request = try XCTUnwrap(model.certificateRequest)
        XCTAssertEqual(request.origin, "https://controller.example")
        XCTAssertEqual(request.presented, presentedCertificate)
        XCTAssertNil(request.previous)
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.error)
        XCTAssertNil(credentials.key)
        XCTAssertNil(certificates.key)
        XCTAssertEqual(model.apiKey, "test-key")
        XCTAssertFalse(model.isBusy)
    }

    func testTrustingCertificateSavesItThenConnectsUsingIt() async throws {
        let api = ModelAPI()
        await api.configure(infoFailure: .untrustedCertificate(presentedCertificate))
        let credentials = MemoryCredentials()
        let certificates = MemoryCredentials()
        let recorder = PinRecorder()
        let model = model(api, credentials: credentials, certificates: certificates, recorder: recorder)
        await model.connect()
        await api.configure()
        await model.trustCertificate()
        XCTAssertNil(model.certificateRequest)
        XCTAssertEqual(certificates.key, presentedCertificate.fingerprint.hex)
        XCTAssertEqual(certificates.savedAccount, "https://controller.example")
        XCTAssertTrue(model.connected)
        XCTAssertNotNil(model.devices.value)
        XCTAssertEqual(model.trustedCertificate, presentedCertificate.fingerprint)
        XCTAssertEqual(credentials.key, "test-key")
        XCTAssertEqual(recorder.pins, [nil, presentedCertificate.fingerprint])
        XCTAssertNil(model.error)
    }

    func testDecliningCertificateLeavesTheControllerUntrusted() async throws {
        let api = ModelAPI()
        await api.configure(infoFailure: .untrustedCertificate(presentedCertificate))
        let credentials = MemoryCredentials()
        let certificates = MemoryCredentials()
        let model = model(api, credentials: credentials, certificates: certificates)
        await model.connect()
        model.declineCertificate()
        XCTAssertNil(model.certificateRequest)
        XCTAssertFalse(model.connected)
        XCTAssertTrue(try XCTUnwrap(model.error).contains("not trusted"))
        await model.trustCertificate()
        XCTAssertNil(certificates.key)
        XCTAssertNil(credentials.key)
        XCTAssertFalse(model.connected)
    }

    func testChangedCertificateIsNotReplacedUntilReviewed() async throws {
        let api = ModelAPI()
        await api.configure(infoFailure: .changedCertificate(presented: presentedCertificate, trusted: previousFingerprint))
        let certificates = MemoryCredentials()
        certificates.key = previousFingerprint.hex
        let recorder = PinRecorder()
        let model = model(api, certificates: certificates, recorder: recorder)
        await model.connect()
        let request = try XCTUnwrap(model.certificateRequest)
        XCTAssertEqual(request.previous, previousFingerprint)
        XCTAssertEqual(request.presented, presentedCertificate)
        XCTAssertEqual(certificates.key, previousFingerprint.hex)
        XCTAssertEqual(recorder.pins, [previousFingerprint])
        XCTAssertFalse(model.connected)
        await api.configure()
        await model.trustCertificate()
        XCTAssertEqual(certificates.key, presentedCertificate.fingerprint.hex)
        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.trustedCertificate, presentedCertificate.fingerprint)
    }

    func testForgetCertificateRemovesPinAndDisconnects() async throws {
        let certificates = MemoryCredentials()
        certificates.key = previousFingerprint.hex
        let recorder = PinRecorder()
        let model = model(ModelAPI(), certificates: certificates, recorder: recorder)
        await model.connect()
        XCTAssertEqual(model.trustedCertificate, previousFingerprint)
        XCTAssertEqual(recorder.pins, [previousFingerprint])
        model.forgetCertificate()
        XCTAssertNil(certificates.key)
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.trustedCertificate)
        XCTAssertNotNil(model.notice)
        XCTAssertNil(model.error)
    }

    func testUnreadableSavedCertificateFailsExplicitlyAndCanBeForgotten() async throws {
        let certificates = MemoryCredentials()
        certificates.key = "not a fingerprint"
        let recorder = PinRecorder()
        let model = model(ModelAPI(), certificates: certificates, recorder: recorder)
        await model.connect()
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.certificateRequest)
        XCTAssertTrue(try XCTUnwrap(model.error).contains("unreadable"))
        XCTAssertTrue(recorder.pins.isEmpty)
        model.forgetCertificate()
        XCTAssertNil(certificates.key)
        XCTAssertEqual(model.apiKey, "test-key")
        XCTAssertNil(model.error)
        await model.connect()
        XCTAssertTrue(model.connected)
        XCTAssertNil(model.trustedCertificate)
    }

    func testTrustIsDiscardedIfTheAddressChangedDuringReview() async throws {
        let api = ModelAPI()
        await api.configure(infoFailure: .untrustedCertificate(presentedCertificate))
        let certificates = MemoryCredentials()
        let model = model(api, certificates: certificates)
        await model.connect()
        model.address = "https://other.example"
        await model.trustCertificate()
        XCTAssertNil(certificates.key)
        XCTAssertNil(model.certificateRequest)
        XCTAssertFalse(model.connected)
        XCTAssertTrue(try XCTUnwrap(model.error).contains("address changed"))
    }

    func testCertificateThatCannotBeSavedIsNotTrusted() async throws {
        let api = ModelAPI()
        await api.configure(infoFailure: .untrustedCertificate(presentedCertificate))
        let credentials = MemoryCredentials()
        let certificates = MemoryCredentials()
        let model = model(api, credentials: credentials, certificates: certificates)
        await model.connect()
        certificates.saveFailure = NetworkAPIError.transport
        await model.trustCertificate()
        XCTAssertNil(certificates.key)
        XCTAssertNil(credentials.key)
        XCTAssertNil(model.certificateRequest)
        XCTAssertFalse(model.connected)
        XCTAssertTrue(try XCTUnwrap(model.error).contains("could not be saved"))
    }

    func testCertificateFailureDuringAnActionIsReportedAsNotSent() async throws {
        let api = ModelAPI()
        let model = model(api)
        await model.connect()
        await api.configure(actionFailure: .changedCertificate(presented: presentedCertificate, trusted: previousFingerprint))
        await model.restart(try XCTUnwrap(model.devices.value?.first))
        let message = try XCTUnwrap(model.error)
        XCTAssertTrue(message.contains("not sent"))
        XCTAssertFalse(message.contains("outcome may be unknown"))
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isBusy)
    }

    func testUpdaterRejectsIncompleteOrUnsafeConfiguration() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertTrue(UpdaterModel.validConfiguration(feed: "https://example.com/appcast.xml", publicKey: key))
        for feed in [nil, "", "http://example.com", "https://user:pass@example.com", "https://example.com/#fragment"] {
            XCTAssertFalse(UpdaterModel.validConfiguration(feed: feed, publicKey: key))
        }
        XCTAssertFalse(UpdaterModel.validConfiguration(feed: "https://example.com", publicKey: "bad"))
    }
}
