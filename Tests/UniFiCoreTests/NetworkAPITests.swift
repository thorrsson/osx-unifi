import Foundation
import XCTest
@testable import UniFiCore

private actor StubTransport: HTTPTransport {
    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    private var replies: [Reply]
    private var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: reply.status,
            httpVersion: nil, headerFields: nil
        )
        return (Data(reply.body.utf8), try XCTUnwrap(response))
    }

    func capturedRequests() -> [URLRequest] { requests }
}

final class NetworkAPITests: XCTestCase {
    private let id = "00000000-0000-0000-0000-000000000001"

    private func api(_ transport: StubTransport) throws -> IntegrationV1API {
        try IntegrationV1API(
            controller: Controller("https://controller.example:8443"),
            apiKey: "test-key", transport: transport
        )
    }

    private func page(_ data: String, offset: Int = 0, count: Int = 1, total: Int = 1) -> String {
        """
        {"offset":\(offset),"limit":200,"count":\(count),"totalCount":\(total),"data":\(data)}
        """
    }

    func testControllerValidationAndCanonicalKeychainOrigin() throws {
        for value in [
            "http://controller", "controller", "https://user:pass@controller",
            "https://controller/network", "https://controller?key=secret",
            "https://controller#fragment", "https://controller:0"
        ] {
            XCTAssertThrowsError(try Controller(value), value)
        }
        XCTAssertEqual(try Controller("HTTPS://Controller.Example:443/").origin.absoluteString,
                       "https://controller.example")
        XCTAssertEqual(try Controller("https://controller:8443").webURL.absoluteString,
                       "https://controller:8443/network")
        XCTAssertThrowsError(try IntegrationV1API(controller: Controller("https://controller"), apiKey: " "))
        XCTAssertThrowsError(try IntegrationV1API(controller: Controller("https://controller"), apiKey: "bad\nkey"))
    }

    func testSitesRequestAuthenticationAndPagination() async throws {
        let transport = StubTransport([
            .init(status: 200, body: page("[{\"id\":\"\(id)\",\"name\":\"Home\",\"extra\":true}]", total: 2)),
            .init(status: 200, body: page(
                "[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Lab\"}]",
                offset: 1, total: 2
            ))
        ])
        let sites = try await api(transport).sites()
        XCTAssertEqual(sites.map(\.name), ["Home", "Lab"])
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-API-Key"), "test-key")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(requests[0].url?.host, "controller.example")
        XCTAssertEqual(requests[0].url?.port, 8443)
        XCTAssertEqual(requests[0].url?.path, "/proxy/network/integration/v1/sites")
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "offset", value: "1"),
            URLQueryItem(name: "limit", value: "200")
        ])
    }

    func testDeviceAndClientParsingPreservesUnknownStatesAndTypes() async throws {
        let transport = StubTransport([
            .init(status: 200, body: page("""
                [{"id":"\(id)","name":"Gateway","model":"UDM Pro","state":"FUTURE_STATE",
                  "ipAddress":"192.168.1.1","macAddress":"00:11:22:33:44:55","supported":true}]
                """)),
            .init(status: 200, body: page("""
                [{"id":"\(id)","type":"FUTURE_TYPE","name":null,"ipAddress":null,"connectedAt":"2026-01-01T00:00:00Z"}]
                """))
        ])
        let client = try api(transport)
        let siteID = try XCTUnwrap(UUID(uuidString: id))
        let devices = try await client.devices(siteID: siteID)
        let clients = try await client.clients(siteID: siteID)
        XCTAssertEqual(devices.first?.model, "UDM Pro")
        XCTAssertEqual(devices.first?.state, "FUTURE_STATE")
        XCTAssertEqual(devices.first?.macAddress, "00:11:22:33:44:55")
        XCTAssertEqual(clients.first?.type, "FUTURE_TYPE")
        XCTAssertNil(clients.first?.name)
        XCTAssertNil(clients.first?.ipAddress)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/proxy/network/integration/v1/sites/\(id)/devices",
            "/proxy/network/integration/v1/sites/\(id)/clients"
        ])
    }

    func testGatewayDetectionFallsBackToModelWhenFeatureIsMissing() throws {
        func device(_ model: String, _ features: [String]) throws -> Device {
            let json = #"{"id":"\#(id)","name":"x","model":"\#(model)","state":"ONLINE","features":[\#(features.map { "\"\($0)\"" }.joined(separator: ","))]}"#
            return try JSONDecoder().decode(Device.self, from: Data(json.utf8))
        }
        for model in [
            "UDM Pro", "UDM SE", "UDM Pro SE", "UDM-Pro-SE", "UDMPROSE", "UDMSE", "UDM Pro Max",
            "Dream Machine Pro SE", "Dream Router 7", "Cloud Gateway Ultra", "Gateway Max", "UniFi Express 7",
            "UDR7", "UCG Ultra", "UXG Max", "USG-Pro-4", "USG3P", "UX", "UX7", "EFG", "UDW"
        ] {
            XCTAssertTrue(try device(model, ["switching"]).isGateway, model)
        }
        for model in ["USW Pro 24", "U6 Pro", "UDB", "UCK G2", "Cloud Key Gen2 Plus", "UAP-AC-Lite", "USW-Flex-Mini"] {
            XCTAssertFalse(try device(model, ["switching", "accessPoint"]).isGateway, model)
        }
        XCTAssertTrue(try device("Third Party", ["gateway"]).isGateway)
    }

    func testGenuineEmptyPageSucceeds() async throws {
        let sites = try await api(StubTransport([
            .init(status: 200, body: page("[]", count: 0, total: 0))
        ])).sites()
        XCTAssertTrue(sites.isEmpty)
    }

    func testApplicationInfoAndRestartUseDocumentedEndpoints() async throws {
        let transport = StubTransport([
            .init(status: 200, body: #"{"applicationVersion":"10.6.106"}"#),
            .init(status: 200, body: "")
        ])
        let api = try api(transport)
        let info = try await api.info()
        XCTAssertEqual(info.applicationVersion, "10.6.106")
        let uuid = try XCTUnwrap(UUID(uuidString: id))
        try await api.restartDevice(siteID: uuid, deviceID: uuid)
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests[0].url?.path, "/proxy/network/integration/v1/info")
        XCTAssertEqual(requests[1].url?.path, "/proxy/network/integration/v1/sites/\(id)/devices/\(id)/actions")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(requests[1].httpBody, Data(#"{"action":"RESTART"}"#.utf8))
    }

    func testGuestActionsAndUnknownOutcomes() async throws {
        let authorization = #"{"authorizationMethod":"API","authorizedAt":"2026-01-01T00:00:00Z","expiresAt":"2026-01-02T00:00:00Z"}"#
        let uuid = try XCTUnwrap(UUID(uuidString: id))
        for action in [GuestAction.authorize, .revoke] {
            let field = action == .authorize ? "grantedAuthorization" : "revokedAuthorization"
            let transport = StubTransport([.init(status: 200, body: """
                {"action":"\(action.rawValue)","\(field)":\(authorization)}
                """)])
            let limits = GuestLimits(timeLimitMinutes: 60, rxRateLimitKbps: 5000)
            try await api(transport).guestAccess(siteID: uuid, clientID: uuid, action: action, limits: limits)
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].url?.path, "/proxy/network/integration/v1/sites/\(id)/clients/\(id)/actions")
            let body = try JSONValue.parse(XCTUnwrap(requests[0].httpBody))
            if action == .authorize {
                XCTAssertEqual(body, ["action": .string(action.rawValue), "timeLimitMinutes": 60, "rxRateLimitKbps": 5000])
            } else {
                XCTAssertEqual(body, ["action": .string(action.rawValue)], "Limits only apply when authorizing")
            }
        }

        for reply in [
            StubTransport.Reply(status: 200, body: #"{"action":"AUTHORIZE_GUEST_ACCESS"}"#),
            .init(status: 403, body: "{}")
        ] {
            let transport = StubTransport([reply])
            do {
                try await api(transport).guestAccess(siteID: uuid, clientID: uuid, action: .authorize, limits: nil)
                XCTFail("Unconfirmed action must fail")
            } catch {
                XCTAssertTrue(error is NetworkAPIError)
            }
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.count, 1, "Mutations must not be retried automatically")
        }
    }

    func testGuestAccessRequiresExplicitAuthorizationState() throws {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(NetworkClient.self, from: Data("""
            {"id":"\(id)","type":"WIRELESS","access":{"type":"GUEST"}}
            """.utf8)))
        let client = try decoder.decode(NetworkClient.self, from: Data("""
            {"id":"\(id)","type":"WIRELESS","access":{"type":"GUEST","authorized":false}}
            """.utf8))
        XCTAssertEqual(client.access?.authorized, false)
    }

    func testHTTPFailuresHaveActionableErrors() async throws {
        for status in [301, 302, 401, 403, 404, 405, 429, 500, 501] {
            do {
                _ = try await api(StubTransport([.init(status: status, body: "private server error")])).sites()
                XCTFail("HTTP \(status) must fail")
            } catch let error as NetworkAPIError {
                switch (status, error) {
                case (300..<400, .redirect), (401, .authentication), (403, .authentication),
                     (404, .unsupported), (405, .unsupported), (501, .unsupported):
                    break
                case (_, .http(let code)):
                    XCTAssertEqual(code, status)
                default: XCTFail("Unexpected error for \(status): \(error)")
                }
                XCTAssertFalse(error.localizedDescription.contains("private server error"))
            }
        }
    }

    func testMalformedAndChangedSchemasNeverBecomeEmptySuccess() async throws {
        for body in [
            "<html>Login</html>", "{}", "{\"data\":[]}",
            page("[{\"id\":\"not-a-uuid\",\"name\":\"Home\"}]"),
            page("[{\"id\":\"\(id)\"}]")
        ] {
            do {
                _ = try await api(StubTransport([.init(status: 200, body: body)])).sites()
                XCTFail("Invalid response must fail")
            } catch NetworkAPIError.incompatibleResponse {
                // Expected: schema failures must not produce an empty inventory.
            }
        }
    }

    func testBrokenPaginationNeverReturnsPartialInventory() async throws {
        let site = "[{\"id\":\"\(id)\",\"name\":\"Home\"}]"
        let bodies = [
            [page("[]", count: 0, total: 1)],
            [page(site, offset: 1)],
            [page(site, count: 0)],
            [page(site, total: 0)],
            [page(site, total: 2), page(site, offset: 1, total: 2)],
            [page(site, total: 2), page("[]", offset: 1, count: 0, total: 2)]
        ]
        for pages in bodies {
            do {
                _ = try await api(StubTransport(pages.map { .init(status: 200, body: $0) })).sites()
                XCTFail("Broken pagination must fail")
            } catch NetworkAPIError.invalidPagination {
                // Expected: caller receives no partial result.
            }
        }
    }

    // MARK: Mutations

    private var uuid: UUID { UUID(uuidString: id)! }
    private let base = "/proxy/network/integration/v1/sites/00000000-0000-0000-0000-000000000001"

    func testCreateAcceptsCreatedAndRequiresIdentifier() async throws {
        let transport = StubTransport([
            .init(status: 201, body: #"{"id":"\#(id)","name":"Lab"}"#),
            .init(status: 200, body: #"{"name":"Lab"}"#)
        ])
        let api = try api(transport)
        let created = try await api.create(.networks, siteID: uuid, body: ["name": "Lab"])
        XCTAssertEqual(created["name"], "Lab")
        do {
            _ = try await api.create(.dnsPolicies, siteID: uuid, body: ["domain": "a.home"])
            XCTFail("A create response without an id cannot be confirmed")
        } catch NetworkAPIError.incompatibleResponse {}
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests[0].url?.path, "\(base)/networks")
        XCTAssertEqual(requests[1].url?.path, "\(base)/dns/policies")
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(requests[0].httpBody)), ["name": "Lab"])
    }

    func testRejectedChangesSurfaceOnlyTheDocumentedMessage() async throws {
        let long = String(repeating: "x", count: 400)
        let cases: [(StubTransport.Reply, String?)] = [
            (.init(status: 400, body: #"{"statusCode":400,"message":"VLAN 20\nalready in use"}"#), "VLAN 20 already in use"),
            (.init(status: 409, body: "<html>conflict</html>"), nil),
            (.init(status: 422, body: #"{"message":"\#(long)"}"#), String(repeating: "x", count: 300) + "...")
        ]
        for (reply, expected) in cases {
            do {
                _ = try await api(StubTransport([reply])).create(.networks, siteID: uuid, body: [:])
                XCTFail("HTTP \(reply.status) must fail")
            } catch NetworkAPIError.rejected(let status, let message) {
                XCTAssertEqual(status, reply.status)
                XCTAssertEqual(message, expected)
            }
        }
    }

    func testResourceScopedNotFoundDistinguishesMissingItemsFromMissingEndpoints() async throws {
        do {
            _ = try await api(StubTransport([.init(status: 404, body: #"{"message":"Network not found"}"#)]))
                .resource(.networks, siteID: uuid, id: uuid)
            XCTFail("Missing item must fail")
        } catch NetworkAPIError.rejected(404, let message) {
            XCTAssertEqual(message, "Network not found")
        }
        do {
            _ = try await api(StubTransport([.init(status: 404, body: "Not Found")])).resource(.networks, siteID: uuid, id: uuid)
            XCTFail("Missing endpoint must fail")
        } catch NetworkAPIError.unsupported {}
        do {
            _ = try await api(StubTransport([.init(status: 200, body: #"{"id":"\#(UUID().apiString)"}"#)]))
                .resource(.networks, siteID: uuid, id: uuid)
            XCTFail("A different item must not be accepted")
        } catch NetworkAPIError.incompatibleResponse {}
    }

    func testReplaceRefusesServerOwnedFieldsAndVerifiesTheEcho() async throws {
        let transport = StubTransport([
            .init(status: 200, body: #"{"id":"\#(id)","name":"New"}"#),
            .init(status: 200, body: #"{"id":"\#(UUID().apiString)"}"#)
        ])
        let api = try api(transport)
        for body: JSONValue in [["id": .string(id), "name": "New"], ["metadata": [:]], "text"] {
            do {
                _ = try await api.replace(.wifiBroadcasts, siteID: uuid, id: uuid, body: body)
                XCTFail("Invalid update body must not be sent")
            } catch NetworkAPIError.incompatibleResponse {}
        }
        var requests = await transport.capturedRequests()
        XCTAssertTrue(requests.isEmpty)

        let updated = try await api.replace(.wifiBroadcasts, siteID: uuid, id: uuid, body: ["name": "New"])
        XCTAssertEqual(updated["name"], "New")
        do {
            _ = try await api.replace(.wifiBroadcasts, siteID: uuid, id: uuid, body: ["name": "New"])
            XCTFail("An update echoing another item must fail")
        } catch NetworkAPIError.incompatibleResponse {}
        requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "PUT"])
        XCTAssertEqual(requests[0].url?.path, "\(base)/wifi/broadcasts/\(id)")
    }

    func testDeleteOnlyForcesDocumentedResources() async throws {
        for (kind, force, expectedQuery) in [
            (EditableResource.networks, true, "force=true"), (.wifiBroadcasts, true, "force=true"),
            (.networks, false, nil), (.firewallPolicies, true, nil), (.dnsPolicies, true, nil)
        ] as [(EditableResource, Bool, String?)] {
            let transport = StubTransport([.init(status: 204, body: "")])
            try await api(transport).delete(kind, siteID: uuid, id: uuid, force: force)
            let captured = await transport.capturedRequests()
            let request = try XCTUnwrap(captured.first)
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.query, expectedQuery, "\(kind)")
        }
    }

    func testPolicyPatchVerifiesTheEchoedValue() async throws {
        let transport = StubTransport([
            .init(status: 200, body: #"{"id":"\#(id)","loggingEnabled":true}"#),
            .init(status: 200, body: #"{"id":"\#(id)","reportFlowEnabled":true}"#)
        ])
        let api = try api(transport)
        try await api.patchFirewallPolicy(siteID: uuid, policyID: uuid, patch: .logging(true))
        do {
            try await api.patchFirewallPolicy(siteID: uuid, policyID: uuid, patch: .flowReporting(false))
            XCTFail("An unconfirmed patch must fail")
        } catch NetworkAPIError.incompatibleResponse {}
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["PATCH", "PATCH"])
        XCTAssertEqual(requests[0].url?.path, "\(base)/firewall/policies/\(id)")
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(requests[0].httpBody)), ["loggingEnabled": true])
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(requests[1].httpBody)), ["reportFlowEnabled": false])
    }

    func testPolicyOrderingRoundTripIsScopedToZonePairAndVerified() async throws {
        let source = UUID(), destination = UUID(), first = UUID(), second = UUID()
        let original = #"{"orderedFirewallPolicyIds":{"beforeSystemDefined":["\#(first.apiString)","\#(second.apiString)"],"afterSystemDefined":[]}}"#
        let reordered = FirewallPolicyOrdering(beforeSystemDefined: [second, first], afterSystemDefined: [])
        let transport = StubTransport([
            .init(status: 200, body: original),
            .init(status: 200, body: String(decoding: try reordered.json.data(), as: UTF8.self)),
            .init(status: 200, body: original)
        ])
        let api = try api(transport)
        let ordering = try await api.firewallPolicyOrdering(siteID: uuid, sourceZoneID: source, destinationZoneID: destination)
        XCTAssertEqual(ordering.beforeSystemDefined, [first, second])
        try await api.reorderFirewallPolicies(siteID: uuid, sourceZoneID: source, destinationZoneID: destination, ordering: reordered)
        do {
            try await api.reorderFirewallPolicies(siteID: uuid, sourceZoneID: source, destinationZoneID: destination, ordering: reordered)
            XCTFail("An order the controller did not apply must fail")
        } catch NetworkAPIError.incompatibleResponse {}

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT", "PUT"])
        for request in requests {
            let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            XCTAssertEqual(components.path, "\(base)/firewall/policies/ordering")
            XCTAssertEqual(components.queryItems, [
                URLQueryItem(name: "sourceFirewallZoneId", value: source.apiString),
                URLQueryItem(name: "destinationFirewallZoneId", value: destination.apiString)
            ])
        }
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(requests[1].httpBody)), reordered.json)
    }

    func testVoucherGenerationAndExpiredCleanup() async throws {
        let voucher = #"{"id":"\#(id)","code":"1234567890","name":"Guest","createdAt":"2026-01-01T00:00:00Z","expired":false,"timeLimitMinutes":60,"authorizedGuestCount":0,"authorizedGuestLimit":1}"#
        let transport = StubTransport([
            .init(status: 201, body: #"{"vouchers":[\#(voucher)]}"#),
            .init(status: 200, body: #"{"vouchersDeleted":3}"#),
            .init(status: 200, body: "{}")
        ])
        let api = try api(transport)
        let created = try await api.generateVouchers(siteID: uuid, request: VoucherRequest(name: "Guest", count: 1, timeLimitMinutes: 60))
        XCTAssertEqual(created.map(\.formattedCode), ["12345-67890"])
        let deleted = try await api.deleteExpiredVouchers(siteID: uuid)
        XCTAssertEqual(deleted, 3)
        do {
            _ = try await api.deleteExpiredVouchers(siteID: uuid)
            XCTFail("An unconfirmed cleanup must fail")
        } catch NetworkAPIError.incompatibleResponse {}

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests[0].url?.path, "\(base)/hotspot/vouchers")
        let body = try JSONValue.parse(XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(body["name"], "Guest")
        XCTAssertEqual(body["count"], 1)
        XCTAssertEqual(body["timeLimitMinutes"], 60)
        XCTAssertEqual(requests[1].httpMethod, "DELETE")
        XCTAssertEqual(requests[1].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems,
                       [URLQueryItem(name: "filter", value: "expired.eq(true)")])
    }

    func testAdoptionSendsDocumentedBody() async throws {
        let transport = StubTransport([.init(status: 200, body: "{}")])
        try await api(transport).adoptDevice(siteID: uuid, macAddress: "AA:BB:CC:DD:EE:FF")
        let captured = await transport.capturedRequests()
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.url?.path, "\(base)/devices")
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(request.httpBody)),
                       ["macAddress": "aa:bb:cc:dd:ee:ff", "ignoreDeviceLimit": false])
    }
}
