import Foundation

/// An in-memory UniFi Network console with fictional data, served through the same integration v1
/// client the app uses for real consoles. Demo mode (and App Review) uses it so the app can be
/// explored without a controller. Edits stay in memory and nothing is sent over the network.
/// The inventory and routes mirror `Scripts/docs/demo_controller.rb`; keep the two in step.
public actor DemoTransport: HTTPTransport {
    public static let origin = "https://demo.invalid"
    public static let apiKey = "demo"
    public static let siteName = "Harbor House"

    private let latency: Duration
    private let console = DemoConsole()

    /// - Parameter latency: Delay added to each response so the interface behaves as it does with a real console.
    public init(latency: Duration = .zero) {
        self.latency = latency
    }

    /// An API client connected to a fresh demo console.
    public static func makeAPI(latency: Duration = .zero) throws -> IntegrationV1API {
        try IntegrationV1API(controller: Controller(origin), apiKey: apiKey, transport: DemoTransport(latency: latency))
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if latency > .zero { try await Task.sleep(for: latency) }
        guard let url = request.url else { throw NetworkAPIError.transport }
        let (status, body) = console.handle(request, url: url)
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ) else { throw NetworkAPIError.transport }
        return (try body.data(), response)
    }
}

/// The demo console's state and routes. Only used from `DemoTransport`, which serializes access.
private final class DemoConsole {
    static let applicationVersion = "10.6.106"
    private static let apiPrefix = "/proxy/network/integration/v1/"
    private static let builtInIndex = 10_000
    private static let afterBuiltInIndex = 20_000
    static let user: JSONValue = ["origin": "USER_DEFINED"]
    static let system: JSONValue = ["origin": "SYSTEM_DEFINED"]

    private let site: JSONValue
    private var devices: [JSONValue] = []
    private var uplinks: [String: String] = [:]
    private var pending: [JSONValue] = []
    private var clients: [JSONValue] = []
    private var vouchers: [JSONValue] = []
    private var wans: [JSONValue] = []
    private var resources: [String: [JSONValue]] = [:]
    private var afterBuiltIn = Set<String>()

    init() {
        site = ["id": .string(Self.newID()), "name": .string(DemoTransport.siteName), "internalReference": "default"]
        resources["networks"] = Self.buildNetworks()
        buildDevices()
        buildClients()
        resources["wifi/broadcasts"] = buildWiFi()
        resources["firewall/zones"] = buildZones()
        resources["firewall/policies"] = buildPolicies()
        resources["dns/policies"] = Self.buildDNS()
        vouchers = Self.buildVouchers()
        wans = [["id": .string(Self.newID()), "name": "Internet 1"], ["id": .string(Self.newID()), "name": "Internet 2"]]
    }

    // MARK: Routing

    typealias Reply = (Int, JSONValue)

    func handle(_ request: URLRequest, url: URL) -> Reply {
        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path ?? url.path
        guard path.hasPrefix(Self.apiPrefix) else { return error(404, "Not found") }
        guard request.value(forHTTPHeaderField: "X-API-Key") == DemoTransport.apiKey else { return error(401, "Unauthorized") }
        var params: [String: String] = [:]
        for item in components?.queryItems ?? [] { params[item.name] = item.value ?? "" }
        let json: JSONValue
        if let body = request.httpBody, !body.isEmpty {
            guard let parsed = try? JSONValue.parse(body) else { return error(400, "The request body is not valid JSON") }
            json = parsed
        } else {
            json = [:]
        }
        let route = String(path.dropFirst(Self.apiPrefix.count))
        if method == "GET", route == "info" { return ok(["applicationVersion": .string(Self.applicationVersion)]) }
        if method == "GET", route == "sites" { return page([site], params) }
        if method == "GET", route == "pending-devices" { return page(pending, params) }
        let sitePrefix = "sites/\(site["id"]?.string ?? "")/"
        guard route.hasPrefix(sitePrefix) else { return error(404, "Site not found") }
        let parts = route.dropFirst(sitePrefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return siteRoute(method, parts, params, json)
    }

    private func siteRoute(_ method: String, _ parts: [String], _ params: [String: String], _ json: JSONValue) -> Reply {
        switch parts.count {
        case 1 where parts[0] == "devices":
            return devicesRoute(method, params, json)
        case 1 where parts[0] == "clients":
            return page(clients, params)
        case 1 where parts[0] == "wans":
            return page(wans, params)
        case 2 where parts[0] == "devices":
            return deviceRoute(method, parts[1])
        case 2 where parts == ["hotspot", "vouchers"]:
            return vouchersRoute(method, params, json)
        case 3 where parts[0] == "devices" && parts[2] == "actions":
            return withDevice(parts[1]) { _ in ok(["action": json["action"] ?? nil]) }
        case 3 where parts[0] == "clients" && parts[2] == "actions":
            return guest(parts[1], json)
        case 3 where parts[0] == "networks" && parts[2] == "references":
            return references(parts[1])
        case 3 where parts == ["firewall", "policies", "ordering"]:
            return orderingRoute(method, params, json)
        case 3 where parts[0] == "hotspot" && parts[1] == "vouchers":
            return deleteVoucher(method, parts[2])
        case 4 where parts[0] == "devices" && parts[2] == "statistics" && parts[3] == "latest":
            return withDevice(parts[1]) { ok(statistics($0)) }
        case 6 where parts[0] == "devices" && parts[2] == "interfaces" && parts[3] == "ports" && parts[5] == "actions":
            return withDevice(parts[1]) { _ in ok(["action": json["action"] ?? nil]) }
        default:
            return resourceRoute(method, parts, params, json)
        }
    }

    private func ok(_ value: JSONValue, _ status: Int = 200) -> Reply { (status, value) }

    private func error(_ status: Int, _ message: String) -> Reply {
        (status, ["statusCode": .int(status), "statusName": "ERROR", "message": .string(message)])
    }

    private func page(_ items: [JSONValue], _ params: [String: String]) -> Reply {
        guard let offset = Int(params["offset"] ?? "0"), let limit = Int(params["limit"] ?? "25"),
              offset >= 0, limit >= 0 else { return error(400, "Invalid pagination") }
        let slice = offset < items.count ? Array(items[offset..<min(items.count, offset + limit)]) : []
        return ok([
            "offset": .int(offset), "limit": .int(limit), "count": .int(slice.count),
            "totalCount": .int(items.count), "data": .array(slice)
        ])
    }

    private func devicesRoute(_ method: String, _ params: [String: String], _ json: JSONValue) -> Reply {
        if method == "GET" { return page(devices, params) }
        guard method == "POST" else { return error(405, "Method not allowed") }
        guard let position = pending.firstIndex(where: { $0["macAddress"] == json["macAddress"] }) else {
            return error(404, "Device not found")
        }
        let device = pending.remove(at: position)
        let adopted: JSONValue = [
            "id": .string(Self.newID()), "name": device["model"] ?? nil, "model": device["model"] ?? nil,
            "state": "ADOPTING", "ipAddress": device["ipAddress"] ?? nil, "macAddress": device["macAddress"] ?? nil,
            "firmwareVersion": device["firmwareVersion"] ?? nil, "firmwareUpdatable": false, "features": ["accessPoint"]
        ]
        devices.append(adopted)
        return ok(adopted)
    }

    private func deviceRoute(_ method: String, _ id: String) -> Reply {
        withDevice(id) { item in
            switch method {
            case "GET": return ok(detail(item))
            case "DELETE":
                devices.removeAll { $0["id"]?.string == id }
                return ok([:])
            default: return error(405, "Method not allowed")
            }
        }
    }

    private func withDevice(_ id: String, _ body: (JSONValue) -> Reply) -> Reply {
        guard let item = devices.first(where: { $0["id"]?.string == id }) else { return error(404, "Device not found") }
        return body(item)
    }

    private func guest(_ id: String, _ json: JSONValue) -> Reply {
        guard let position = clients.firstIndex(where: { $0["id"]?.string == id }) else { return error(404, "Client not found") }
        guard clients[position]["access"]?["type"]?.string == "GUEST" else { return error(400, "Client is not a guest") }
        let granted = json["action"]?.string == "AUTHORIZE_GUEST_ACCESS"
        clients[position]["access"]?["authorized"] = .bool(granted)
        let authorization: JSONValue = [
            "authorizationMethod": "API", "authorizedAt": Self.ago(0),
            "expiresAt": Self.ahead(Double((json["timeLimitMinutes"]?.int ?? 1440) * 60))
        ]
        var reply: JSONValue = ["action": json["action"] ?? nil]
        reply[granted ? "grantedAuthorization" : "revokedAuthorization"] = authorization
        return ok(reply)
    }

    private func references(_ id: String) -> Reply {
        guard let network = resources["networks"]?.first(where: { $0["id"]?.string == id }) else {
            return error(404, "Network not found")
        }
        let wifi = resources["wifi/broadcasts"]?.filter { $0["network"]?["networkId"]?.string == id }.count ?? 0
        let clientCounts = ["Default": 6, "IoT": 3, "Guest": 2, "Cameras": 2]
        let clients = clientCounts[network["name"]?.string ?? ""] ?? 0
        return ok(["referenceResources": [
            ["resourceType": "CLIENT", "referenceCount": .int(clients)],
            ["resourceType": "WIFI", "referenceCount": .int(wifi)]
        ]])
    }

    private func orderingRoute(_ method: String, _ params: [String: String], _ json: JSONValue) -> Reply {
        guard let source = params["sourceFirewallZoneId"], let destination = params["destinationFirewallZoneId"] else {
            return error(400, "Both zones are required")
        }
        switch method {
        case "GET":
            return ok(["orderedFirewallPolicyIds": ordering(source, destination)])
        case "PUT":
            guard let applied = reorder(source, destination, json) else {
                return error(400, "The ordering must list the same policies")
            }
            return ok(["orderedFirewallPolicyIds": applied])
        default:
            return error(405, "Method not allowed")
        }
    }

    private func vouchersRoute(_ method: String, _ params: [String: String], _ json: JSONValue) -> Reply {
        switch method {
        case "GET":
            return page(vouchers, params)
        case "POST":
            let created: [JSONValue] = (0..<max(json["count"]?.int ?? 1, 0)).map { _ in
                Self.compact([
                    "id": .string(Self.newID()), "code": .string(Self.voucherCode()), "name": json["name"] ?? nil,
                    "createdAt": Self.ago(0), "expired": false, "timeLimitMinutes": json["timeLimitMinutes"] ?? nil,
                    "authorizedGuestCount": 0, "authorizedGuestLimit": json["authorizedGuestLimit"] ?? nil,
                    "dataUsageLimitMBytes": json["dataUsageLimitMBytes"] ?? nil,
                    "rxRateLimitKbps": json["rxRateLimitKbps"] ?? nil, "txRateLimitKbps": json["txRateLimitKbps"] ?? nil
                ])
            }
            vouchers.append(contentsOf: created)
            return ok(["vouchers": .array(created)], 201)
        case "DELETE":
            guard params["filter"] == "expired.eq(true)" else { return error(400, "Unsupported filter") }
            let expired = vouchers.filter { $0["expired"]?.bool == true }.count
            vouchers.removeAll { $0["expired"]?.bool == true }
            return ok(["vouchersDeleted": .int(expired)])
        default:
            return error(405, "Method not allowed")
        }
    }

    private func deleteVoucher(_ method: String, _ id: String) -> Reply {
        guard method == "DELETE" else { return error(405, "Method not allowed") }
        guard vouchers.contains(where: { $0["id"]?.string == id }) else { return error(404, "Voucher not found") }
        vouchers.removeAll { $0["id"]?.string == id }
        return ok([:])
    }

    private func resourceRoute(_ method: String, _ parts: [String], _ params: [String: String], _ json: JSONValue) -> Reply {
        let id = parts.last.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let kind = (id == nil ? parts : Array(parts.dropLast())).joined(separator: "/")
        guard var items = resources[kind] else { return error(404, "Not found") }
        guard let id else {
            switch method {
            case "GET": return page(items, params)
            case "POST":
                let created = create(kind, json)
                resources[kind, default: []].append(created)
                return ok(created, 201)
            default: return error(405, "Method not allowed")
            }
        }
        guard let position = items.firstIndex(where: { $0["id"]?.string == id }) else { return error(404, "Item not found") }
        switch method {
        case "GET":
            return ok(items[position])
        case "PUT":
            var replaced = json
            for key in ["id", "metadata", "default", "index"] {
                if let value = items[position][key] { replaced[key] = value }
            }
            items[position] = replaced
        case "PATCH":
            guard case .object(let changes) = json else { return error(400, "The request body must be an object") }
            for (key, value) in changes { items[position][key] = value }
        case "DELETE":
            items.remove(at: position)
            resources[kind] = items
            return ok([:])
        default:
            return error(405, "Method not allowed")
        }
        resources[kind] = items
        return ok(items[position])
    }

    // MARK: Inventory behavior

    private func create(_ kind: String, _ body: JSONValue) -> JSONValue {
        var item = body
        item["id"] = .string(Self.newID())
        item["metadata"] = Self.user
        if kind == "networks" { item["default"] = false }
        if kind == "firewall/policies" {
            let highest = userPolicies.compactMap { $0["index"]?.int }.filter { $0 < Self.builtInIndex }.max() ?? 0
            item["index"] = .int(highest + 1)
        }
        return item
    }

    private var userPolicies: [JSONValue] {
        (resources["firewall/policies"] ?? []).filter { $0["metadata"]?["origin"]?.string == "USER_DEFINED" }
    }

    private func policyIndex(_ id: String) -> Int? {
        resources["firewall/policies"]?.first(where: { $0["id"]?.string == id })?["index"]?.int
    }

    private func setPolicyIndex(_ id: String, _ index: Int) {
        guard let position = resources["firewall/policies"]?.firstIndex(where: { $0["id"]?.string == id }) else { return }
        resources["firewall/policies"]?[position]["index"] = .int(index)
    }

    private func ordering(_ source: String, _ destination: String) -> JSONValue {
        let ids = userPolicies
            .filter { $0["source"]?["zoneId"]?.string == source && $0["destination"]?["zoneId"]?.string == destination }
            .sorted { ($0["index"]?.int ?? 0) < ($1["index"]?.int ?? 0) }
            .compactMap { $0["id"]?.string }
        return [
            "beforeSystemDefined": .array(ids.filter { !afterBuiltIn.contains($0) }.map(JSONValue.string)),
            "afterSystemDefined": .array(ids.filter { afterBuiltIn.contains($0) }.map(JSONValue.string))
        ]
    }

    private func reorder(_ source: String, _ destination: String, _ body: JSONValue) -> JSONValue? {
        guard let requested = body["orderedFirewallPolicyIds"] else { return nil }
        let before = requested["beforeSystemDefined"]?.array?.compactMap(\.string) ?? []
        let after = requested["afterSystemDefined"]?.array?.compactMap(\.string) ?? []
        let current = ordering(source, destination)
        let currentIDs = ((current["beforeSystemDefined"]?.array ?? []) + (current["afterSystemDefined"]?.array ?? []))
            .compactMap(\.string)
        guard (before + after).sorted() == currentIDs.sorted() else { return nil }
        var slots = (before + after).compactMap(policyIndex).filter { $0 < Self.builtInIndex }.sorted()
        while slots.count < before.count { slots.append((slots.max() ?? 0) + 1) }
        for (position, id) in before.enumerated() {
            afterBuiltIn.remove(id)
            setPolicyIndex(id, slots[position])
        }
        for (position, id) in after.enumerated() {
            afterBuiltIn.insert(id)
            setPolicyIndex(id, Self.afterBuiltInIndex + position)
        }
        return ordering(source, destination)
    }

    private func detail(_ device: JSONValue) -> JSONValue {
        var detail = device
        detail["supported"] = true
        detail["adoptedAt"] = Self.ago(220 * 86_400)
        detail["provisionedAt"] = Self.ago(3 * 86_400)
        if let id = device["id"]?.string, let uplink = uplinks[id] { detail["uplink"] = ["deviceId": .string(uplink)] }
        detail["interfaces"] = Self.interfaces(device)
        return detail
    }

    private func statistics(_ device: JSONValue) -> JSONValue {
        if Self.features(device).contains("gateway") {
            return [
                "uptimeSec": .int(1_814_400 + Int.random(in: 0..<600)),
                "cpuUtilizationPct": .double(((14.2 + Double.random(in: 0..<1)) * 10).rounded() / 10),
                "memoryUtilizationPct": .double(47.8), "loadAverage1Min": .double(0.42),
                "loadAverage5Min": .double(0.38), "loadAverage15Min": .double(0.35), "lastHeartbeatAt": Self.ago(4),
                "uplink": [
                    "rxRateBps": .int(286_400_000 + Int.random(in: 0..<9_000_000)),
                    "txRateBps": .int(41_700_000 + Int.random(in: 0..<2_000_000))
                ]
            ]
        }
        return [
            "uptimeSec": 604_800, "cpuUtilizationPct": .double(6.1), "memoryUtilizationPct": .double(38.5),
            "lastHeartbeatAt": Self.ago(9), "uplink": ["rxRateBps": 18_200_000, "txRateBps": 3_400_000]
        ]
    }

    // MARK: Fictional inventory

    private static func newID() -> String { UUID().apiString }
    private static func ago(_ seconds: Double) -> JSONValue { timestamp(-seconds) }
    private static func ahead(_ seconds: Double) -> JSONValue { timestamp(seconds) }
    private static func timestamp(_ offset: Double) -> JSONValue {
        .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset)))
    }
    private static func voucherCode() -> String { String(format: "%010d", Int.random(in: 0..<10_000_000_000)) }
    private static func features(_ device: JSONValue) -> [String] { device["features"]?.array?.compactMap(\.string) ?? [] }

    private static func compact(_ value: JSONValue) -> JSONValue {
        guard case .object(let values) = value else { return value }
        return .object(values.filter { $0.value != .null })
    }

    private static func buildNetworks() -> [JSONValue] {
        [
            network("Default", 1, "192.168.1.1", range: ("192.168.1.6", "192.168.1.254"), isDefault: true),
            network("IoT", 20, "192.168.20.1", range: ("192.168.20.6", "192.168.20.254"), isolation: true),
            network("Guest", 30, "192.168.30.1", range: ("192.168.30.6", "192.168.30.254"), isolation: true),
            network("Cameras", 40, "192.168.40.1", range: ("192.168.40.6", "192.168.40.254"), internet: false),
            network("Lab", 50, "10.50.0.1", range: ("10.50.0.10", "10.50.255.254"), enabled: false, prefix: 16)
        ]
    }

    private static func network(
        _ name: String, _ vlan: Int, _ host: String, range: (String, String), isDefault: Bool = false,
        enabled: Bool = true, isolation: Bool = false, internet: Bool = true, prefix: Int = 24
    ) -> JSONValue {
        [
            "id": .string(newID()), "name": .string(name), "enabled": .bool(enabled), "management": "GATEWAY",
            "vlanId": .int(vlan), "default": .bool(isDefault), "metadata": user,
            "internetAccessEnabled": .bool(internet), "isolationEnabled": .bool(isolation),
            "cellularBackupEnabled": true, "mdnsForwardingEnabled": .bool(!isolation),
            "ipv4Configuration": [
                "autoScaleEnabled": false, "hostIpAddress": .string(host), "prefixLength": .int(prefix),
                "dhcpConfiguration": [
                    "mode": "SERVER", "ipAddressRange": ["start": .string(range.0), "stop": .string(range.1)],
                    "leaseTimeSeconds": 86_400, "pingConflictDetectionEnabled": true
                ]
            ]
        ]
    }

    private func id(named name: String, in items: [JSONValue]) -> JSONValue {
        items.first(where: { $0["name"]?.string == name })?["id"] ?? nil
    }

    private func networkID(_ name: String) -> JSONValue { id(named: name, in: resources["networks"] ?? []) }
    private func deviceID(_ name: String) -> JSONValue { id(named: name, in: devices) }
    private func zoneID(_ name: String) -> JSONValue { id(named: name, in: resources["firewall/zones"] ?? []) }

    private func buildDevices() {
        let gateway = Self.device("Harbor Gateway", "UDM Pro", "192.168.1.1", "4.3.6", ["gateway", "switching"], "1c:0b:8b:4e:20:01")
        let office = Self.device("Office Switch", "USW 24 PoE", "192.168.1.2", "7.1.26", ["switching"], "1c:0b:8b:4e:20:02")
        let living = Self.device("Living Room AP", "U6 Pro", "192.168.1.10", "6.7.31", ["accessPoint"], "1c:0b:8b:4e:20:10")
        let upstairs = Self.device("Upstairs AP", "U6 Lite", "192.168.1.11", "6.6.77", ["accessPoint"], "1c:0b:8b:4e:20:11", updatable: true)
        let patio = Self.device("Patio AP", "U6 Mesh", "192.168.1.12", "6.7.31", ["accessPoint"], "1c:0b:8b:4e:20:12", state: "OFFLINE")
        devices = [gateway, office, living, upstairs, patio]
        func id(_ device: JSONValue) -> String { device["id"]?.string ?? "" }
        uplinks = [id(office): id(gateway), id(living): id(office), id(upstairs): id(office), id(patio): id(living)]
        pending = [[
            "macAddress": "1c:0b:8b:4e:20:20", "model": "U7 Pro", "state": "READY_FOR_ADOPTION",
            "ipAddress": "192.168.1.84", "firmwareVersion": "7.0.66", "supported": true,
            "adoptionTargetSiteIds": [site["id"] ?? nil]
        ]]
    }

    private static func device(
        _ name: String, _ model: String, _ ip: String, _ firmware: String, _ features: [String], _ mac: String,
        state: String = "ONLINE", updatable: Bool = false
    ) -> JSONValue {
        [
            "id": .string(newID()), "name": .string(name), "model": .string(model), "state": .string(state),
            "ipAddress": .string(ip), "macAddress": .string(mac), "firmwareVersion": .string(firmware),
            "firmwareUpdatable": .bool(updatable), "features": .array(features.map(JSONValue.string))
        ]
    }

    private func buildClients() {
        let living = deviceID("Living Room AP")
        let upstairs = deviceID("Upstairs AP")
        let office = deviceID("Office Switch")
        clients = [
            Self.client("Studio MacBook Pro", "WIRELESS", "192.168.1.42", "a4:83:e7:10:00:01", living, 3 * 3600),
            Self.client("Alex's iPhone", "WIRELESS", "192.168.1.57", "a4:83:e7:10:00:02", living, 26 * 3600),
            Self.client("Sam's iPad", "WIRELESS", "192.168.1.61", "a4:83:e7:10:00:03", upstairs, 5 * 3600),
            Self.client("Living Room TV", "WIRELESS", "192.168.20.31", "a4:83:e7:10:00:04", living, 9 * 86_400),
            Self.client("Kitchen Speaker", "WIRELESS", "192.168.20.32", "a4:83:e7:10:00:05", living, 12 * 86_400),
            Self.client("Thermostat", "WIRELESS", "192.168.20.40", "a4:83:e7:10:00:06", upstairs, 30 * 86_400),
            Self.client("Office Printer", "WIRED", "192.168.1.30", "a4:83:e7:10:00:07", office, 18 * 86_400),
            Self.client("Storage NAS", "WIRED", "192.168.1.20", "a4:83:e7:10:00:08", office, 41 * 86_400),
            Self.client("Front Door Camera", "WIRED", "192.168.40.11", "a4:83:e7:10:00:09", office, 41 * 86_400),
            Self.client("Driveway Camera", "WIRED", "192.168.40.12", "a4:83:e7:10:00:0a", office, 41 * 86_400),
            Self.client("Travel Laptop", "VPN", "192.168.2.2", nil, nil, 2 * 3600),
            Self.client("Guest Phone", "WIRELESS", "192.168.30.15", "a4:83:e7:10:00:0c", living, 40 * 60, guest: false),
            Self.client("Visitor Laptop", "WIRELESS", "192.168.30.16", "a4:83:e7:10:00:0d", upstairs, 95 * 60, guest: true)
        ]
    }

    private static func client(
        _ name: String, _ type: String, _ ip: String, _ mac: String?, _ uplink: JSONValue?, _ connected: Double,
        guest: Bool? = nil
    ) -> JSONValue {
        let access: JSONValue = guest.map { ["type": "GUEST", "authorized": .bool($0)] } ?? ["type": "DEFAULT"]
        return compact([
            "id": .string(newID()), "name": .string(name), "type": .string(type), "ipAddress": .string(ip),
            "macAddress": mac.map(JSONValue.string) ?? nil, "connectedAt": ago(connected),
            "uplinkDeviceId": uplink ?? nil, "access": access
        ])
    }

    private func buildWiFi() -> [JSONValue] {
        [
            broadcast("Harbor", "Default", "WPA2_WPA3_PERSONAL", [2.4, 5.0, 6.0], steering: true),
            broadcast("Harbor IoT", "IoT", "WPA2_PERSONAL", [2.4]),
            broadcast("Harbor Guest", "Guest", "WPA2_PERSONAL", [2.4, 5.0], isolation: true, steering: true),
            broadcast("Harbor Lab", "Lab", "WPA3_PERSONAL", [5.0, 6.0], enabled: false)
        ]
    }

    private func broadcast(
        _ name: String, _ network: String, _ security: String, _ bands: [Double],
        enabled: Bool = true, isolation: Bool = false, steering: Bool? = nil
    ) -> JSONValue {
        var config: JSONValue = ["type": .string(security), "passphrase": "harbor-demo-passphrase", "pmfMode": "OPTIONAL"]
        if security.contains("WPA3") { config["saeConfiguration"] = ["anticloggingThresholdSeconds": 5, "syncTimeSeconds": 5] }
        return Self.compact([
            "id": .string(Self.newID()), "name": .string(name), "type": "STANDARD", "enabled": .bool(enabled),
            "metadata": Self.user, "network": ["type": "SPECIFIC", "networkId": networkID(network)],
            "securityConfiguration": config, "broadcastingFrequenciesGHz": .array(bands.map(JSONValue.double)),
            "hideName": false, "clientIsolationEnabled": .bool(isolation),
            "bandSteeringEnabled": steering.map(JSONValue.bool) ?? nil, "multicastToUnicastConversionEnabled": false
        ])
    }

    private func buildZones() -> [JSONValue] {
        [
            zone("Internal", ["Default"], Self.system), zone("External", [], Self.system),
            zone("Gateway", [], Self.system), zone("VPN", [], Self.system),
            zone("Hotspot", ["Guest"], Self.system), zone("DMZ", [], Self.system),
            zone("IoT", ["IoT"], Self.user), zone("Cameras", ["Cameras", "Lab"], Self.user)
        ]
    }

    private func zone(_ name: String, _ networks: [String], _ origin: JSONValue) -> JSONValue {
        ["id": .string(Self.newID()), "name": .string(name), "networkIds": .array(networks.map(networkID)), "metadata": origin]
    }

    private func buildPolicies() -> [JSONValue] {
        [
            rule(1, "Allow IoT pairing", "IoT", "Internal", "ALLOW", enabled: false,
                 description: "Temporarily let new devices reach the hub"),
            rule(2, "Block IoT to Internal", "IoT", "Internal", "BLOCK", logging: true,
                 description: "Keep smart-home devices away from computers"),
            rule(3, "Allow Internal to IoT", "Internal", "IoT", "ALLOW", description: "Control devices from phones and laptops"),
            rule(4, "Block Cameras to Internet", "Cameras", "External", "BLOCK", logging: true),
            rule(5, "Allow Internal to Cameras", "Internal", "Cameras", "ALLOW"),
            rule(10_000, "Allow All Traffic", "Internal", "Internal", "ALLOW", origin: Self.system),
            rule(10_001, "Allow Internal to External", "Internal", "External", "ALLOW", origin: Self.system),
            rule(10_002, "Allow Internal to Gateway", "Internal", "Gateway", "ALLOW", origin: Self.system),
            rule(10_003, "Block External to Internal", "External", "Internal", "BLOCK", origin: Self.system),
            rule(10_004, "Isolate Hotspot from Internal", "Hotspot", "Internal", "BLOCK", origin: Self.system),
            rule(10_005, "Allow Hotspot to External", "Hotspot", "External", "ALLOW", origin: Self.system)
        ]
    }

    private func rule(
        _ index: Int, _ name: String, _ source: String, _ destination: String, _ action: String,
        enabled: Bool = true, logging: Bool = false, description: String? = nil, origin: JSONValue = DemoConsole.user
    ) -> JSONValue {
        var actionValue: JSONValue = ["type": .string(action)]
        if action == "ALLOW" { actionValue["allowReturnTraffic"] = true }
        return Self.compact([
            "id": .string(Self.newID()), "name": .string(name), "description": description.map(JSONValue.string) ?? nil,
            "enabled": .bool(enabled), "index": .int(index), "action": actionValue,
            "source": ["zoneId": zoneID(source)], "destination": ["zoneId": zoneID(destination)],
            "ipProtocolScope": ["ipVersion": "IPV4_AND_IPV6"], "loggingEnabled": .bool(logging), "metadata": origin
        ])
    }

    private static func buildDNS() -> [JSONValue] {
        [
            record("A_RECORD", "nas.home.arpa", ["ipv4Address": "192.168.1.20", "ttlSeconds": 3600]),
            record("A_RECORD", "hub.home.arpa", ["ipv4Address": "192.168.20.10", "ttlSeconds": 3600]),
            record("CNAME_RECORD", "files.home.arpa", ["targetDomain": "nas.home.arpa", "ttlSeconds": 3600]),
            record("AAAA_RECORD", "printer.home.arpa", ["ipv6Address": "fd00:1::30", "ttlSeconds": 3600]),
            record("TXT_RECORD", "home.arpa", ["text": "v=demo1", "ttlSeconds": 3600], enabled: false),
            record("FORWARD_DOMAIN", "lab.example", ["ipAddress": "10.50.0.53"])
        ]
    }

    private static func record(_ type: String, _ domain: String, _ values: [String: JSONValue], enabled: Bool = true) -> JSONValue {
        var item: JSONValue = [
            "id": .string(newID()), "type": .string(type), "enabled": .bool(enabled),
            "domain": .string(domain), "metadata": user
        ]
        for (key, value) in values { item[key] = value }
        return item
    }

    private static func buildVouchers() -> [JSONValue] {
        [
            voucher("Weekend guests", 2880, created: 2 * 3600),
            voucher("Weekend guests", 2880, created: 2 * 3600),
            voucher("Weekend guests", 2880, created: 2 * 3600, activated: 90 * 60, guests: 1),
            voucher("Dog walker", 60 * 24 * 30, created: 6 * 86_400, activated: 6 * 86_400, guests: 1, limit: 2),
            voucher("Contractor", 480, created: 3 * 86_400, activated: 3 * 86_400, guests: 1, expired: true)
        ]
    }

    private static func voucher(
        _ name: String, _ minutes: Int, created: Double, activated: Double? = nil,
        guests: Int = 0, limit: Int = 1, expired: Bool = false
    ) -> JSONValue {
        compact([
            "id": .string(newID()), "code": .string(voucherCode()), "name": .string(name), "createdAt": ago(created),
            "expired": .bool(expired), "timeLimitMinutes": .int(minutes), "authorizedGuestCount": .int(guests),
            "authorizedGuestLimit": .int(limit), "activatedAt": activated.map(ago) ?? nil,
            "expiresAt": activated.map { timestamp(Double(minutes * 60) - $0) } ?? nil
        ])
    }

    private static func interfaces(_ device: JSONValue) -> JSONValue {
        let features = features(device)
        if features.contains("gateway") {
            let lan = (1...8).map { port($0, $0 <= 5 ? "UP" : "DOWN", 1000, $0 <= 5 ? 1000 : nil) }
            return ["ports": .array(lan + [
                port(9, "UP", 1000, 1000), port(10, "UP", 10_000, 10_000, connector: "SFPPLUS"),
                port(11, "DOWN", 10_000, nil, connector: "SFPPLUS")
            ])]
        }
        if features.contains("switching") {
            let connected: Set = [1, 2, 3, 5, 6, 7, 8, 12, 17]
            let ports = (1...24).map { index -> JSONValue in
                let up = connected.contains(index)
                let poe: JSONValue = [
                    "enabled": .bool(index <= 16), "standard": "802.3at",
                    "state": up && index <= 16 ? "UP" : "DOWN", "type": 2
                ]
                return port(index, up ? "UP" : "DOWN", 1000, up ? 1000 : nil, poe: poe)
            }
            return ["ports": .array(ports + [
                port(25, "UP", 1000, 1000, connector: "SFP"), port(26, "DOWN", 1000, nil, connector: "SFP")
            ])]
        }
        let online = device["state"]?.string == "ONLINE"
        return [
            "ports": [port(1, online ? "UP" : "DOWN", 2500, online ? 1000 : nil)],
            "radios": [
                ["frequencyGHz": .double(2.4), "channel": 6, "channelWidthMHz": 20, "wlanStandard": "802.11ax"],
                ["frequencyGHz": 5, "channel": 44, "channelWidthMHz": 80, "wlanStandard": "802.11ax"]
            ]
        ]
    }

    private static func port(
        _ index: Int, _ state: String, _ max: Int, _ speed: Int?, connector: String = "RJ45", poe: JSONValue? = nil
    ) -> JSONValue {
        compact([
            "idx": .int(index), "state": .string(state), "connector": .string(connector), "maxSpeedMbps": .int(max),
            "speedMbps": speed.map(JSONValue.int) ?? nil, "poe": poe ?? nil
        ])
    }
}
