import Foundation
import XCTest
@testable import UniFiCore

/// Demo mode must stay readable by the real integration v1 client, so every route is exercised through it.
final class DemoTransportTests: XCTestCase {
    private func connect() async throws -> (IntegrationV1API, UUID) {
        let api = try DemoTransport.makeAPI()
        let sites = try await api.sites()
        XCTAssertEqual(sites.map(\.name), [DemoTransport.siteName])
        return (api, try XCTUnwrap(sites.first).id)
    }

    func testEveryInventorySectionDecodesThroughTheRealClient() async throws {
        let (api, site) = try await connect()
        let info = try await api.info()
        XCTAssertEqual(NetworkVersion(info.applicationVersion)?.isVerified, true)
        let devices = try await api.devices(siteID: site)
        XCTAssertEqual(devices.count, 5)
        for device in devices {
            let details = try await api.deviceDetails(siteID: site, deviceID: device.id)
            XCTAssertFalse(details.interfaces.ports?.isEmpty ?? true)
            _ = try await api.deviceStatistics(siteID: site, deviceID: device.id)
        }
        let clients = try await api.clients(siteID: site)
        XCTAssertEqual(clients.count, 13)
        XCTAssertTrue(clients.contains(where: \.isGuest))
        let networks = try await api.networks(siteID: site)
        let wifi = try await api.wifiBroadcasts(siteID: site)
        let zones = try await api.firewallZones(siteID: site)
        let policies = try await api.firewallPolicies(siteID: site)
        let dns = try await api.dnsPolicies(siteID: site)
        let vouchers = try await api.vouchers(siteID: site)
        let wans = try await api.wans(siteID: site)
        let pending = try await api.pendingDevices()
        XCTAssertEqual(
            [networks.count, wifi.count, zones.count, policies.count, dns.count, vouchers.count, wans.count, pending.count],
            [5, 4, 8, 11, 6, 5, 2, 1]
        )
        let references = try await api.networkReferences(siteID: site, networkID: networks[0].id)
        XCTAssertFalse(references.isEmpty)
        let firstIDs: [EditableResource: UUID] = [
            .networks: networks[0].id, .wifiBroadcasts: wifi[0].id, .firewallZones: zones[0].id,
            .firewallPolicies: policies[0].id, .dnsPolicies: dns[0].id
        ]
        for kind in EditableResource.allCases {
            let id = try XCTUnwrap(firstIDs[kind])
            let detail = try await api.resource(kind, siteID: site, id: id)
            XCTAssertEqual(detail["id"]?.string, id.apiString)
        }
    }

    func testEditsStayInMemoryAndRoundTrip() async throws {
        let (api, site) = try await connect()
        let allNetworks = try await api.networks(siteID: site)
        let original = try XCTUnwrap(allNetworks.first(where: { $0.name == "IoT" }))
        let current = try await api.resource(.networks, siteID: site, id: original.id)
        var body = try EditableResource.networks.updateBody(from: current)
        body["name"] = "Smart Home"
        let replaced = try await api.replace(.networks, siteID: site, id: original.id, body: body)
        XCTAssertEqual(replaced["metadata"]?["origin"]?.string, "USER_DEFINED")
        let renamed = try await api.networks(siteID: site).first(where: { $0.id == original.id })
        XCTAssertEqual(renamed?.name, "Smart Home")

        let created = try await api.create(.dnsPolicies, siteID: site, body: [
            "type": "A_RECORD", "enabled": true, "domain": "demo.home.arpa", "ipv4Address": "192.168.1.99", "ttlSeconds": 60
        ])
        let createdID = try XCTUnwrap(created["id"]?.string.flatMap(UUID.init(uuidString:)))
        let withCreated = try await api.dnsPolicies(siteID: site)
        XCTAssertEqual(withCreated.count, 7)
        try await api.delete(.dnsPolicies, siteID: site, id: createdID, force: false)
        let afterDelete = try await api.dnsPolicies(siteID: site)
        XCTAssertEqual(afterDelete.count, 6)

        let allPolicies = try await api.firewallPolicies(siteID: site)
        let policy = try XCTUnwrap(allPolicies.first(where: { $0.name == "Allow IoT pairing" }))
        try await api.patchFirewallPolicy(siteID: site, policyID: policy.id, patch: .logging(true))
        let ordering = try await api.firewallPolicyOrdering(
            siteID: site, sourceZoneID: policy.source.zoneId, destinationZoneID: policy.destination.zoneId
        )
        XCTAssertEqual(ordering.beforeSystemDefined.count, 2)
        let moved = FirewallPolicyOrdering(
            beforeSystemDefined: [ordering.beforeSystemDefined[1]], afterSystemDefined: [ordering.beforeSystemDefined[0]]
        )
        try await api.reorderFirewallPolicies(
            siteID: site, sourceZoneID: policy.source.zoneId, destinationZoneID: policy.destination.zoneId, ordering: moved
        )
    }

    func testDeviceClientAndVoucherActions() async throws {
        let (api, site) = try await connect()
        let initialDevices = try await api.devices(siteID: site)
        let gateway = try XCTUnwrap(initialDevices.first)
        try await api.restartDevice(siteID: site, deviceID: gateway.id)
        try await api.powerCyclePort(siteID: site, deviceID: gateway.id, portIndex: 1)
        let initialPending = try await api.pendingDevices()
        let pending = try XCTUnwrap(initialPending.first)
        try await api.adoptDevice(siteID: site, macAddress: pending.macAddress)
        let stillPending = try await api.pendingDevices()
        let devices = try await api.devices(siteID: site)
        XCTAssertTrue(stillPending.isEmpty)
        XCTAssertEqual(devices.count, 6)

        let initialClients = try await api.clients(siteID: site)
        let guest = try XCTUnwrap(initialClients.first(where: { $0.access?.authorized == false }))
        try await api.guestAccess(siteID: site, clientID: guest.id, action: .authorize, limits: GuestLimits(timeLimitMinutes: 60))
        let authorized = try await api.clients(siteID: site).first(where: { $0.id == guest.id })
        XCTAssertEqual(authorized?.access?.authorized, true)

        let vouchers = try await api.generateVouchers(siteID: site, request: VoucherRequest(name: "Demo", count: 3, timeLimitMinutes: 60))
        XCTAssertEqual(vouchers.count, 3)
        let deleted = try await api.deleteExpiredVouchers(siteID: site)
        XCTAssertEqual(deleted, 1)
        try await api.deleteVoucher(siteID: site, voucherID: vouchers[0].id)
        let remaining = try await api.vouchers(siteID: site)
        XCTAssertEqual(remaining.count, 6)
    }

    func testRequestsWithoutTheDemoKeyAreRejected() async throws {
        let api = try IntegrationV1API(controller: Controller(DemoTransport.origin), apiKey: "other", transport: DemoTransport())
        do {
            _ = try await api.sites()
            XCTFail("Expected an authentication failure")
        } catch NetworkAPIError.authentication {}
    }
}
