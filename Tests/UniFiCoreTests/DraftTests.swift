import Foundation
import XCTest
@testable import UniFiCore

final class DraftTests: XCTestCase {
    private let zoneA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let zoneB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    // MARK: Version gating

    func testVersionParsingAndGates() throws {
        XCTAssertEqual(NetworkVersion("10.6.106")?.description, "10.6.106")
        XCTAssertEqual(NetworkVersion("11.0.97-beta")?.description, "11.0.97")
        XCTAssertNil(NetworkVersion(""))
        XCTAssertNil(NetworkVersion("ten"))

        for verified in ["10.3.58", "10.4.1", "10.6.106", "11.0.97", "11.0.200"] {
            XCTAssertTrue(try XCTUnwrap(NetworkVersion(verified)).isVerified, verified)
        }
        for unverified in ["9.5.21", "10.2.105", "10.7.0", "11.1.0", "12.0"] {
            XCTAssertFalse(try XCTUnwrap(NetworkVersion(unverified)).isVerified, unverified)
        }
        XCTAssertFalse(try XCTUnwrap(NetworkVersion("10.6.106")).supportsFlowReporting)
        XCTAssertTrue(try XCTUnwrap(NetworkVersion("11.0.97")).supportsFlowReporting)
        XCTAssertFalse(try XCTUnwrap(NetworkVersion("10.5.9")).requiresLegacyRadioLocks)
        XCTAssertTrue(try XCTUnwrap(NetworkVersion("10.6.0")).requiresLegacyRadioLocks)
        XCTAssertEqual(NetworkVersion(10, 6), NetworkVersion("10.6.0"))
    }

    // MARK: Update bodies

    func testUpdateBodyStripsOnlyServerOwnedFields() throws {
        let detail = try json(#"{"id":"x","metadata":{"origin":"USER_DEFINED"},"index":3,"name":"A","futureField":{"a":1}}"#)
        let body = try EditableResource.firewallPolicies.updateBody(from: detail)
        XCTAssertNil(body["id"])
        XCTAssertNil(body["metadata"])
        XCTAssertNil(body["index"])
        XCTAssertEqual(body["name"], "A")
        XCTAssertEqual(body["futureField"], ["a": 1])
        XCTAssertThrowsError(try EditableResource.networks.updateBody(from: "not an object"))
        XCTAssertNil(try EditableResource.networks.updateBody(from: try json(#"{"default":true,"name":"LAN"}"#))["default"])
    }

    func testNetworkDraftPreservesUnshownSettings() throws {
        let detail = try json("""
            {"management":"GATEWAY","name":"IoT","enabled":true,"vlanId":20,"internetAccessEnabled":true,
             "isolationEnabled":false,"cellularBackupEnabled":true,"zoneId":"\(zoneA.apiString)","dhcpGuarding":{"x":1},
             "ipv4Configuration":{"hostIpAddress":"10.0.20.1","prefixLength":24,"autoScaleEnabled":false,"natOutboundIpAddressConfiguration":[1],
               "dhcpConfiguration":{"mode":"SERVER","ipAddressRange":{"start":"10.0.20.10","stop":"10.0.20.200"},
                 "leaseTimeSeconds":86400,"pingConflictDetectionEnabled":true,"timeOffsetSeconds":7}}}
            """)
        var draft = NetworkDraft(detail: detail)
        XCTAssertEqual(draft.validationErrors, [])
        XCTAssertEqual(draft.apply(to: detail), detail, "Applying an unchanged form must not change the document")

        draft.name = "Things"
        draft.vlanId = 21
        let edited = draft.apply(to: detail)
        XCTAssertEqual(edited["name"], "Things")
        XCTAssertEqual(edited["vlanId"], 21)
        XCTAssertEqual(edited["dhcpGuarding"], ["x": 1])
        XCTAssertEqual(edited["ipv4Configuration"]?["natOutboundIpAddressConfiguration"], [1])
        XCTAssertEqual(edited["ipv4Configuration"]?["dhcpConfiguration"]?["timeOffsetSeconds"], 7)

        draft.dhcpMode = .none
        XCTAssertNil(draft.apply(to: detail)["ipv4Configuration"]?["dhcpConfiguration"])
    }

    func testNetworkDraftValidationAndCreateBody() {
        var draft = NetworkDraft()
        draft.name = "Lab"
        XCTAssertEqual(draft.validationErrors, [])
        let body = draft.createBody()
        for key in ["management", "name", "enabled", "vlanId"] { XCTAssertNotNil(body[key], key) }
        XCTAssertNil(body["zoneId"], "Omitted zone lets the console choose")
        XCTAssertEqual(body["ipv4Configuration"]?["dhcpConfiguration"]?["mode"], "SERVER")

        draft.vlanId = 4095
        draft.hostIpAddress = "not an ip"
        XCTAssertFalse(draft.validationErrors.isEmpty)
    }

    func testWiFiCreateBodyFollowsVersionRequirements() {
        var draft = WiFiDraft()
        draft.name = "Home"
        draft.passphrase = "correct horse"
        XCTAssertEqual(draft.validationErrors, [])
        let legacy = draft.createBody(version: NetworkVersion("10.5.9"))
        XCTAssertNil(legacy["channel2gLockedTo6"])
        for version in [NetworkVersion("10.6.106"), NetworkVersion("11.0.97"), nil] {
            let body = draft.createBody(version: version)
            XCTAssertEqual(body["channel2gLockedTo6"], false)
            XCTAssertEqual(body["dtimPeriod2gLockedTo3"], false)
            XCTAssertEqual(body["securityConfiguration"]?["passphrase"], "correct horse")
            XCTAssertEqual(body["network"], ["type": "NATIVE"])
        }
        draft.passphrase = "short"
        XCTAssertFalse(draft.validationErrors.isEmpty)
    }

    func testWiFiEditKeepsEnterpriseSecurityAndUnknownFields() throws {
        let detail = try json("""
            {"type":"STANDARD","name":"Corp","enabled":true,"hideName":false,"clientIsolationEnabled":false,
             "network":{"type":"NATIVE"},"broadcastingFrequenciesGHz":[2.4,5],"mloEnabled":true,
             "securityConfiguration":{"type":"WPA2_ENTERPRISE","radiusProfileId":"abc"}}
            """)
        var draft = WiFiDraft(detail: detail)
        XCTAssertFalse(draft.securityEditable)
        XCTAssertEqual(draft.validationErrors, [])
        draft.name = "Corp 2"
        let edited = draft.apply(to: detail)
        XCTAssertEqual(edited["securityConfiguration"], detail["securityConfiguration"])
        XCTAssertEqual(edited["mloEnabled"], true)
        XCTAssertEqual(edited["broadcastingFrequenciesGHz"], [.double(2.4), 5])
    }

    func testFirewallPolicyDraftPreservesFiltersAndGatesFlowReporting() throws {
        let detail = try json("""
            {"name":"Block cams","enabled":true,"action":{"type":"ALLOW","allowReturnTraffic":true},
             "source":{"zoneId":"\(zoneA.apiString)","trafficFilter":{"type":"NETWORK"}},
             "destination":{"zoneId":"\(zoneB.apiString)"},"ipProtocolScope":{"ipVersion":"IPV4"},
             "loggingEnabled":false,"schedule":{"mode":"ALWAYS"}}
            """)
        var draft = FirewallPolicyDraft(detail: detail)
        XCTAssertTrue(draft.hasTrafficFilters)
        XCTAssertNil(draft.reportFlowEnabled)
        XCTAssertEqual(draft.apply(to: detail), detail)

        draft.action = "BLOCK"
        let edited = draft.apply(to: detail)
        XCTAssertEqual(edited["action"], ["type": "BLOCK"])
        XCTAssertEqual(edited["source"]?["trafficFilter"], ["type": "NETWORK"])
        XCTAssertEqual(edited["schedule"], ["mode": "ALWAYS"])
        XCTAssertNil(edited["reportFlowEnabled"])

        var created = FirewallPolicyDraft()
        created.name = "New"
        created.sourceZoneId = zoneA
        created.destinationZoneId = zoneB
        created.reportFlowEnabled = true
        XCTAssertNil(created.createBody(version: NetworkVersion("10.6.106"))["reportFlowEnabled"])
        XCTAssertNil(created.createBody(version: nil)["reportFlowEnabled"])
        XCTAssertEqual(created.createBody(version: NetworkVersion("11.0.97"))["reportFlowEnabled"], true)
        created.destinationZoneId = nil
        XCTAssertFalse(created.validationErrors.isEmpty)
    }

    func testZoneDraftWritesNetworkIDs() throws {
        var draft = FirewallZoneDraft()
        draft.name = "Cameras"
        draft.networkIds = [zoneB, zoneA]
        XCTAssertEqual(draft.createBody(), ["name": "Cameras", "networkIds": [.string(zoneA.apiString), .string(zoneB.apiString)]])
        draft.name = " "
        XCTAssertFalse(draft.validationErrors.isEmpty)
    }

    func testDNSDraftTypeChangeReplacesValueFields() throws {
        let detail = try json(#"{"type":"A_RECORD","enabled":true,"domain":"nas.home","ipv4Address":"10.0.0.5","ttlSeconds":300}"#)
        var draft = DNSPolicyDraft(detail: detail)
        XCTAssertEqual(draft.apply(to: detail), detail)
        draft.type = .srv
        draft.service = "_sip"
        draft.serverDomain = "pbx.home"
        draft.port = 5060
        let edited = draft.apply(to: detail)
        XCTAssertNil(edited["ipv4Address"])
        XCTAssertNil(edited["ttlSeconds"], "SRV records have no TTL in the documented schema")
        XCTAssertEqual(edited["protocol"], "_tcp")
        XCTAssertEqual(edited["type"], "SRV_RECORD")
        XCTAssertEqual(draft.validationErrors, [])

        draft.type = .cname
        draft.targetDomain = "nas.home"
        draft.ttlSeconds = 700_000
        XCTAssertFalse(draft.validationErrors.isEmpty)
    }

    // MARK: Limits

    func testGuestAndVoucherLimitsMatchDocumentedBounds() {
        XCTAssertEqual(GuestLimits().validationErrors, [])
        XCTAssertEqual(GuestLimits(timeLimitMinutes: 1_000_000, dataUsageLimitMBytes: 1_048_576, rxRateLimitKbps: 2, txRateLimitKbps: 100_000).validationErrors, [])
        XCTAssertEqual(GuestLimits(timeLimitMinutes: 0).validationErrors.count, 1)
        XCTAssertEqual(GuestLimits(dataUsageLimitMBytes: 1_048_577).validationErrors.count, 1)
        XCTAssertEqual(GuestLimits(rxRateLimitKbps: 1, txRateLimitKbps: 100_001).validationErrors.count, 1)

        XCTAssertEqual(VoucherRequest(name: "Guest", timeLimitMinutes: 60).validationErrors, [])
        XCTAssertFalse(VoucherRequest(name: " ", timeLimitMinutes: 60).validationErrors.isEmpty)
        XCTAssertFalse(VoucherRequest(name: "Guest", count: 1001, timeLimitMinutes: 60).validationErrors.isEmpty)
        XCTAssertFalse(VoucherRequest(name: "Guest", timeLimitMinutes: 0).validationErrors.isEmpty)
        XCTAssertFalse(VoucherRequest(name: "Guest", timeLimitMinutes: 60, authorizedGuestLimit: 0).validationErrors.isEmpty)
    }

    // MARK: Policy ordering

    func testPolicyOrderingMovesAcrossSystemDefinedPolicies() throws {
        let ids = (1...4).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
        let ordering = FirewallPolicyOrdering(beforeSystemDefined: [ids[0], ids[1]], afterSystemDefined: [ids[2], ids[3]])

        XCTAssertEqual(ordering.applying(.earlier, to: ids[1]), .init(beforeSystemDefined: [ids[1], ids[0]], afterSystemDefined: [ids[2], ids[3]]))
        XCTAssertEqual(ordering.applying(.later, to: ids[2]), .init(beforeSystemDefined: [ids[0], ids[1]], afterSystemDefined: [ids[3], ids[2]]))
        XCTAssertEqual(ordering.applying(.afterSystemDefined, to: ids[1]), .init(beforeSystemDefined: [ids[0]], afterSystemDefined: [ids[1], ids[2], ids[3]]))
        XCTAssertEqual(ordering.applying(.beforeSystemDefined, to: ids[2]), .init(beforeSystemDefined: [ids[0], ids[1], ids[2]], afterSystemDefined: [ids[3]]))

        XCTAssertNil(ordering.applying(.earlier, to: ids[0]))
        XCTAssertNil(ordering.applying(.later, to: ids[1]), "Crossing system-defined policies is an explicit move")
        XCTAssertNil(ordering.applying(.earlier, to: ids[2]))
        XCTAssertNil(ordering.applying(.later, to: ids[3]))
        XCTAssertNil(ordering.applying(.beforeSystemDefined, to: ids[0]))
        XCTAssertNil(ordering.applying(.afterSystemDefined, to: ids[3]))
        XCTAssertNil(ordering.applying(.earlier, to: UUID()))
        XCTAssertEqual(ordering.isBeforeSystemDefined(ids[0]), true)
        XCTAssertEqual(ordering.isBeforeSystemDefined(ids[3]), false)
        XCTAssertNil(ordering.isBeforeSystemDefined(UUID()))
    }

    func testPolicyOrderingRequiresBothDocumentedLists() throws {
        let id = UUID().apiString
        let valid = try json(#"{"orderedFirewallPolicyIds":{"beforeSystemDefined":["\#(id)"],"afterSystemDefined":[]}}"#)
        let ordering = try FirewallPolicyOrdering(json: valid)
        XCTAssertEqual(ordering.json, valid)
        for invalid in [
            #"{"orderedFirewallPolicyIds":{"beforeSystemDefined":[]}}"#,
            #"{"orderedFirewallPolicyIds":{"beforeSystemDefined":["nope"],"afterSystemDefined":[]}}"#,
            #"{"beforeSystemDefined":[],"afterSystemDefined":[]}"#
        ] {
            XCTAssertThrowsError(try FirewallPolicyOrdering(json: json(invalid)), invalid)
        }
    }
}
