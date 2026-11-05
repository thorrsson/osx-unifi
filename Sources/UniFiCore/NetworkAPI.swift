import Foundation

public struct Site: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    /// Short site name used in controller web UI routes, such as `default`.
    public let internalReference: String?
}

public struct Device: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let model: String
    public let state: String
    public let ipAddress: String?
    public let macAddress: String?
    public let firmwareVersion: String?
    public let firmwareUpdatable: Bool?
    public let features: [String]?

    public var isGateway: Bool { features?.contains("gateway") == true }
    public var isSwitch: Bool { features?.contains("switching") == true }
    public var isAccessPoint: Bool { features?.contains("accessPoint") == true }
    public var isOnline: Bool { state == "ONLINE" }
}

public struct NetworkClient: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String?
    public let type: String
    public let ipAddress: String?
    public let macAddress: String?
    public let connectedAt: String?
    public let uplinkDeviceId: UUID?
    public let access: ClientAccess?

    public var isGuest: Bool { access?.type == "GUEST" }
}

public struct ClientAccess: Decodable, Sendable, Hashable {
    public let type: String
    public let authorized: Bool?

    private enum CodingKeys: String, CodingKey { case type, authorized }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        if type == "GUEST" {
            authorized = try container.decode(Bool.self, forKey: .authorized)
        } else {
            authorized = try container.decodeIfPresent(Bool.self, forKey: .authorized)
        }
    }
}

public struct ApplicationInfo: Decodable, Sendable {
    public let applicationVersion: String
}

public enum GuestAction: String, Encodable, Sendable {
    case authorize = "AUTHORIZE_GUEST_ACCESS"
    case revoke = "UNAUTHORIZE_GUEST_ACCESS"
}

public enum NetworkAPIError: LocalizedError {
    case invalidController, missingKey, authentication, unsupported, http(Int)
    case rejected(status: Int, message: String?)
    case incompatibleResponse, invalidPagination, redirect, transport
    case untrustedCertificate(PresentedCertificate)
    case changedCertificate(presented: PresentedCertificate, trusted: CertificateFingerprint)

    public var isCertificateFailure: Bool {
        switch self {
        case .untrustedCertificate, .changedCertificate: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .untrustedCertificate:
            return "macOS does not trust the controller's certificate. Disconnect, then connect again to review and trust it."
        case .changedCertificate:
            return "The controller's certificate changed since you trusted it. Disconnect, then connect again to review the new certificate before continuing."
        case .invalidController:
            return "Enter an HTTPS controller origin, such as https://192.168.1.1, without a path, credentials, query, or fragment."
        case .missingKey:
            return "Enter a local Network API key from the controller's Integrations settings."
        case .authentication:
            return "The controller rejected the API key or its permissions (401/403). Check the local Network integration key."
        case .unsupported:
            return "The official Network integration v1 endpoint is unavailable (404/405/501). Check the controller address and the API documentation in Network Settings > Integrations."
        case .rejected(let status, let message):
            let detail = message.map { " The controller said: \($0)" } ?? ""
            return "The controller rejected the request (HTTP \(status)).\(detail)"
        case .http(let code):
            return "The controller returned HTTP \(code). Check its permissions and API documentation before trying again."
        case .incompatibleResponse:
            return "The controller response does not match the supported Network integration v1 contract. Check the API documentation for your installed Network version."
        case .invalidPagination:
            return "The controller returned inconsistent or incomplete pagination. Refresh the inventory; no partial results were accepted."
        case .redirect:
            return "The controller redirected the request. Use its direct HTTPS origin; API keys are never forwarded to redirects."
        case .transport:
            return "The controller returned an invalid HTTP response."
        }
    }
}

public struct Controller: Sendable {
    public let origin: URL

    public init(_ value: String) throws {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw NetworkAPIError.invalidController
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { throw NetworkAPIError.invalidController }
        origin = url
    }

    public var webURL: URL { origin.appendingPathComponent("network") }
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

// Rejects redirects so an API key never leaves the configured origin, and applies the
// certificate trust policy to this request's TLS handshake. Evidence is kept per request.
private final class RequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trusted: CertificateFingerprint?
    private let lock = NSLock()
    private var recordedFailure: NetworkAPIError?

    init(trusted: CertificateFingerprint?) { self.trusted = trusted }

    var certificateFailure: NetworkAPIError? {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailure
    }

    private func reject(_ failure: NetworkAPIError) {
        lock.lock()
        recordedFailure = failure
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let presented = PresentedCertificate(trust: trust) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch CertificateTrust.decide(
            systemTrusted: SecTrustEvaluateWithError(trust, nil),
            presented: presented.fingerprint, trusted: trusted
        ) {
        case .systemTrusted:
            completionHandler(.performDefaultHandling, nil)
        case .userTrusted:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .untrusted:
            reject(.untrustedCertificate(presented))
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .changed(let previous):
            reject(.changedCertificate(presented: presented, trusted: previous))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public final class LocalTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let trustedCertificate: CertificateFingerprint?

    public init(trustedCertificate: CertificateFingerprint? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        self.trustedCertificate = trustedCertificate
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = RequestDelegate(trusted: trustedCertificate)
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let response = response as? HTTPURLResponse else { throw NetworkAPIError.transport }
            return (data, response)
        } catch {
            if let failure = delegate.certificateFailure { throw failure }
            throw error
        }
    }
}

public protocol NetworkAPI: Sendable {
    func info() async throws -> ApplicationInfo
    func sites() async throws -> [Site]
    func devices(siteID: UUID) async throws -> [Device]
    func clients(siteID: UUID) async throws -> [NetworkClient]
    func networks(siteID: UUID) async throws -> [NetworkSummary]
    func wifiBroadcasts(siteID: UUID) async throws -> [WiFiBroadcast]
    func firewallZones(siteID: UUID) async throws -> [FirewallZone]
    func firewallPolicies(siteID: UUID) async throws -> [FirewallPolicy]
    func dnsPolicies(siteID: UUID) async throws -> [DNSPolicy]
    func vouchers(siteID: UUID) async throws -> [HotspotVoucher]
    func wans(siteID: UUID) async throws -> [WAN]
    func pendingDevices() async throws -> [PendingDevice]
    func deviceDetails(siteID: UUID, deviceID: UUID) async throws -> DeviceDetails
    func deviceStatistics(siteID: UUID, deviceID: UUID) async throws -> DeviceStatistics
    func networkReferences(siteID: UUID, networkID: UUID) async throws -> [NetworkReference]

    func resource(_ kind: EditableResource, siteID: UUID, id: UUID) async throws -> JSONValue
    func create(_ kind: EditableResource, siteID: UUID, body: JSONValue) async throws -> JSONValue
    func replace(_ kind: EditableResource, siteID: UUID, id: UUID, body: JSONValue) async throws -> JSONValue
    func delete(_ kind: EditableResource, siteID: UUID, id: UUID, force: Bool) async throws
    func patchFirewallPolicy(siteID: UUID, policyID: UUID, patch: FirewallPolicyPatch) async throws
    func firewallPolicyOrdering(siteID: UUID, sourceZoneID: UUID, destinationZoneID: UUID) async throws -> FirewallPolicyOrdering
    func reorderFirewallPolicies(siteID: UUID, sourceZoneID: UUID, destinationZoneID: UUID, ordering: FirewallPolicyOrdering) async throws

    func generateVouchers(siteID: UUID, request: VoucherRequest) async throws -> [HotspotVoucher]
    func deleteVoucher(siteID: UUID, voucherID: UUID) async throws
    func deleteExpiredVouchers(siteID: UUID) async throws -> Int

    func restartDevice(siteID: UUID, deviceID: UUID) async throws
    func powerCyclePort(siteID: UUID, deviceID: UUID, portIndex: Int) async throws
    func adoptDevice(siteID: UUID, macAddress: String) async throws
    func removeDevice(siteID: UUID, deviceID: UUID) async throws
    func guestAccess(siteID: UUID, clientID: UUID, action: GuestAction, limits: GuestLimits?) async throws
}

extension UUID {
    /// Lowercase canonical form used in request paths and bodies.
    public var apiString: String { uuidString.lowercased() }
}

// This adapter is deliberately limited to the documented local integration v1 contract.
public struct IntegrationV1API: NetworkAPI {
    private let controller: Controller
    private let key: String
    private let transport: any HTTPTransport

    public init(
        controller: Controller, apiKey: String,
        trustedCertificate: CertificateFingerprint? = nil,
        transport: (any HTTPTransport)? = nil
    ) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw NetworkAPIError.missingKey
        }
        self.controller = controller
        self.key = key
        self.transport = transport ?? LocalTransport(trustedCertificate: trustedCertificate)
    }

    private func site(_ id: UUID) -> String { "sites/\(id.apiString)" }

    public func sites() async throws -> [Site] { try await list("sites") }
    public func info() async throws -> ApplicationInfo {
        try decode(await request("GET", "info"))
    }
    public func devices(siteID: UUID) async throws -> [Device] { try await list("\(site(siteID))/devices") }
    public func clients(siteID: UUID) async throws -> [NetworkClient] { try await list("\(site(siteID))/clients") }
    public func networks(siteID: UUID) async throws -> [NetworkSummary] { try await list("\(site(siteID))/networks") }
    public func wifiBroadcasts(siteID: UUID) async throws -> [WiFiBroadcast] {
        try await list("\(site(siteID))/wifi/broadcasts")
    }
    public func firewallZones(siteID: UUID) async throws -> [FirewallZone] {
        try await list("\(site(siteID))/firewall/zones")
    }
    public func firewallPolicies(siteID: UUID) async throws -> [FirewallPolicy] {
        try await list("\(site(siteID))/firewall/policies")
    }
    public func dnsPolicies(siteID: UUID) async throws -> [DNSPolicy] { try await list("\(site(siteID))/dns/policies") }
    public func vouchers(siteID: UUID) async throws -> [HotspotVoucher] {
        try await list("\(site(siteID))/hotspot/vouchers", pageSize: 1000)
    }
    public func wans(siteID: UUID) async throws -> [WAN] { try await list("\(site(siteID))/wans") }
    public func pendingDevices() async throws -> [PendingDevice] { try await list("pending-devices") }

    public func deviceDetails(siteID: UUID, deviceID: UUID) async throws -> DeviceDetails {
        try decode(await request("GET", "\(site(siteID))/devices/\(deviceID.apiString)", resourceScoped: true))
    }

    public func deviceStatistics(siteID: UUID, deviceID: UUID) async throws -> DeviceStatistics {
        try decode(await request("GET", "\(site(siteID))/devices/\(deviceID.apiString)/statistics/latest", resourceScoped: true))
    }

    public func networkReferences(siteID: UUID, networkID: UUID) async throws -> [NetworkReference] {
        struct References: Decodable { let referenceResources: [NetworkReference] }
        let response: References = try decode(await request(
            "GET", "\(site(siteID))/networks/\(networkID.apiString)/references", resourceScoped: true
        ))
        return response.referenceResources
    }

    public func resource(_ kind: EditableResource, siteID: UUID, id: UUID) async throws -> JSONValue {
        let detail = try JSONValue.parse(await request("GET", "\(site(siteID))/\(kind.path)/\(id.apiString)", resourceScoped: true))
        guard detail["id"]?.string.flatMap(UUID.init(uuidString:)) == id else { throw NetworkAPIError.incompatibleResponse }
        return detail
    }

    public func create(_ kind: EditableResource, siteID: UUID, body: JSONValue) async throws -> JSONValue {
        let created = try JSONValue.parse(await request(
            "POST", "\(site(siteID))/\(kind.path)", body: body.data(), accept: [200, 201]
        ))
        guard created["id"]?.string.flatMap(UUID.init(uuidString:)) != nil else { throw NetworkAPIError.incompatibleResponse }
        return created
    }

    public func replace(_ kind: EditableResource, siteID: UUID, id: UUID, body: JSONValue) async throws -> JSONValue {
        guard body.isObject, body["id"] == nil, body["metadata"] == nil else { throw NetworkAPIError.incompatibleResponse }
        let updated = try JSONValue.parse(await request(
            "PUT", "\(site(siteID))/\(kind.path)/\(id.apiString)", body: body.data(), resourceScoped: true
        ))
        guard updated["id"]?.string.flatMap(UUID.init(uuidString:)) == id else { throw NetworkAPIError.incompatibleResponse }
        return updated
    }

    public func delete(_ kind: EditableResource, siteID: UUID, id: UUID, force: Bool) async throws {
        let query = force && kind.supportsForcedDelete ? [URLQueryItem(name: "force", value: "true")] : []
        _ = try await request("DELETE", "\(site(siteID))/\(kind.path)/\(id.apiString)", query: query, resourceScoped: true)
    }

    public func patchFirewallPolicy(siteID: UUID, policyID: UUID, patch: FirewallPolicyPatch) async throws {
        let body: JSONValue = [patch.key: .bool(patch.enabled)]
        let updated = try JSONValue.parse(await request(
            "PATCH", "\(site(siteID))/firewall/policies/\(policyID.apiString)", body: body.data(), resourceScoped: true
        ))
        guard updated[patch.key]?.bool == patch.enabled else { throw NetworkAPIError.incompatibleResponse }
    }

    private func orderingQuery(_ source: UUID, _ destination: UUID) -> [URLQueryItem] {
        [URLQueryItem(name: "sourceFirewallZoneId", value: source.apiString),
         URLQueryItem(name: "destinationFirewallZoneId", value: destination.apiString)]
    }

    public func firewallPolicyOrdering(siteID: UUID, sourceZoneID: UUID, destinationZoneID: UUID) async throws -> FirewallPolicyOrdering {
        try FirewallPolicyOrdering(json: JSONValue.parse(await request(
            "GET", "\(site(siteID))/firewall/policies/ordering",
            query: orderingQuery(sourceZoneID, destinationZoneID), resourceScoped: true
        )))
    }

    public func reorderFirewallPolicies(
        siteID: UUID, sourceZoneID: UUID, destinationZoneID: UUID, ordering: FirewallPolicyOrdering
    ) async throws {
        let applied = try FirewallPolicyOrdering(json: JSONValue.parse(await request(
            "PUT", "\(site(siteID))/firewall/policies/ordering",
            query: orderingQuery(sourceZoneID, destinationZoneID), body: ordering.json.data(), resourceScoped: true
        )))
        guard applied == ordering else { throw NetworkAPIError.incompatibleResponse }
    }

    public func generateVouchers(siteID: UUID, request voucher: VoucherRequest) async throws -> [HotspotVoucher] {
        struct Created: Decodable { let vouchers: [HotspotVoucher] }
        let created: Created = try decode(await request(
            "POST", "\(site(siteID))/hotspot/vouchers", body: JSONEncoder().encode(voucher), accept: [200, 201]
        ))
        return created.vouchers
    }

    public func deleteVoucher(siteID: UUID, voucherID: UUID) async throws {
        _ = try await request("DELETE", "\(site(siteID))/hotspot/vouchers/\(voucherID.apiString)", resourceScoped: true)
    }

    public func deleteExpiredVouchers(siteID: UUID) async throws -> Int {
        struct Deleted: Decodable { let vouchersDeleted: Int }
        let deleted: Deleted = try decode(await request(
            "DELETE", "\(site(siteID))/hotspot/vouchers",
            query: [URLQueryItem(name: "filter", value: "expired.eq(true)")]
        ))
        return deleted.vouchersDeleted
    }

    public func restartDevice(siteID: UUID, deviceID: UUID) async throws {
        _ = try await request(
            "POST", "\(site(siteID))/devices/\(deviceID.apiString)/actions",
            body: Data(#"{"action":"RESTART"}"#.utf8), resourceScoped: true
        )
    }

    public func powerCyclePort(siteID: UUID, deviceID: UUID, portIndex: Int) async throws {
        _ = try await request(
            "POST", "\(site(siteID))/devices/\(deviceID.apiString)/interfaces/ports/\(portIndex)/actions",
            body: Data(#"{"action":"POWER_CYCLE"}"#.utf8), resourceScoped: true
        )
    }

    public func adoptDevice(siteID: UUID, macAddress: String) async throws {
        let body: JSONValue = ["macAddress": .string(macAddress.lowercased()), "ignoreDeviceLimit": false]
        _ = try await request("POST", "\(site(siteID))/devices", body: body.data(), accept: [200, 201])
    }

    public func removeDevice(siteID: UUID, deviceID: UUID) async throws {
        _ = try await request("DELETE", "\(site(siteID))/devices/\(deviceID.apiString)", resourceScoped: true)
    }

    public func guestAccess(siteID: UUID, clientID: UUID, action: GuestAction, limits: GuestLimits?) async throws {
        struct ActionBody: Encodable {
            let action: GuestAction
            let timeLimitMinutes: Int?
            let dataUsageLimitMBytes: Int?
            let rxRateLimitKbps: Int?
            let txRateLimitKbps: Int?
        }
        struct Authorization: Decodable {
            let authorizationMethod: String
            let authorizedAt: String
            let expiresAt: String
        }
        struct Response: Decodable {
            let action: String
            let grantedAuthorization: Authorization?
            let revokedAuthorization: Authorization?
        }
        let limits = action == .authorize ? limits : nil
        let body = ActionBody(
            action: action, timeLimitMinutes: limits?.timeLimitMinutes,
            dataUsageLimitMBytes: limits?.dataUsageLimitMBytes,
            rxRateLimitKbps: limits?.rxRateLimitKbps, txRateLimitKbps: limits?.txRateLimitKbps
        )
        let response: Response = try decode(await request(
            "POST", "\(site(siteID))/clients/\(clientID.apiString)/actions",
            body: JSONEncoder().encode(body), resourceScoped: true
        ))
        guard response.action == action.rawValue,
              action == .authorize ? response.grantedAuthorization != nil : response.revokedAuthorization != nil else {
            throw NetworkAPIError.incompatibleResponse
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw NetworkAPIError.incompatibleResponse }
    }

    private struct ErrorMessage: Decodable { let message: String? }

    // Only a documented JSON error message is surfaced; arbitrary bodies are never shown.
    private static func controllerMessage(_ data: Data) -> String? {
        guard let message = try? JSONDecoder().decode(ErrorMessage.self, from: data).message else { return nil }
        let cleaned = message.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > 300 ? String(cleaned.prefix(300)) + "..." : cleaned
    }

    private func request(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
        accept: Set<Int> = [200], resourceScoped: Bool = false
    ) async throws -> Data {
        try Task.checkCancellation()
        let url = controller.origin.appendingPathComponent("proxy/network/integration/v1/\(path)")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NetworkAPIError.invalidController
        }
        if !query.isEmpty { components.queryItems = query }
        guard let requestURL = components.url else { throw NetworkAPIError.invalidController }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport.data(for: request)
        let status = response.statusCode
        if accept.contains(status) || (method != "GET" && method != "POST" && status == 204) { return data }
        switch status {
        case 300..<400: throw NetworkAPIError.redirect
        case 401, 403: throw NetworkAPIError.authentication
        case 400, 409, 412, 422: throw NetworkAPIError.rejected(status: status, message: Self.controllerMessage(data))
        case 404 where resourceScoped:
            // A documented error body means the endpoint exists but the item does not.
            guard let message = Self.controllerMessage(data) else { throw NetworkAPIError.unsupported }
            throw NetworkAPIError.rejected(status: status, message: message)
        case 404, 405, 501: throw NetworkAPIError.unsupported
        default: throw NetworkAPIError.http(status)
        }
    }

    private struct Page<Item: Decodable>: Decodable {
        let offset: Int
        let limit: Int
        let count: Int
        let totalCount: Int
        let data: [Item]
    }

    private func list<Item: Decodable & Identifiable>(_ path: String, pageSize: Int = 200) async throws -> [Item] {
        var items: [Item] = []
        var seen = Set<Item.ID>()
        var offset = 0
        for _ in 0..<1_000 {
            let data = try await request("GET", path, query: [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: String(pageSize))
            ])
            let page: Page<Item> = try decode(data)
            guard page.offset == offset, page.limit > 0,
                  page.count == page.data.count, page.count <= page.limit,
                  page.totalCount >= offset, page.count <= page.totalCount - offset else {
                throw NetworkAPIError.invalidPagination
            }
            for item in page.data {
                guard seen.insert(item.id).inserted else { throw NetworkAPIError.invalidPagination }
            }
            items.append(contentsOf: page.data)
            offset += page.count
            if offset == page.totalCount { return items }
            guard page.count > 0 else { throw NetworkAPIError.invalidPagination }
        }
        throw NetworkAPIError.invalidPagination
    }
}
