import Foundation

/// Network application version reported by `/info`, used to gate version-specific request bodies.
public struct NetworkVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ value: String) {
        let parts = value.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 }
    }

    public init(_ components: Int...) { self.components = components }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: NetworkVersion, rhs: NetworkVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: NetworkVersion, rhs: NetworkVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    /// Official integration v1 documentation this app's contract was checked against:
    /// Network 10.3.58 and 10.6.106 (stable), and 11.0.97 (published ahead of the stable 11 release).
    public static let documented = ["10.3.58", "10.6.106", "11.0.97"]
    public static let oldestVerified = NetworkVersion(10, 3)
    public static let newestVerified = NetworkVersion(11, 0, 97)

    public var isVerified: Bool {
        (self >= Self.oldestVerified && self < NetworkVersion(10, 7))
            || (self >= NetworkVersion(11) && self < NetworkVersion(11, 1))
    }

    /// 11.0 adds `reportFlowEnabled` to firewall policies (create, update, and patch).
    public var supportsFlowReporting: Bool { self >= NetworkVersion(11) }

    /// 10.6 made `channel2gLockedTo6` and `dtimPeriod2gLockedTo3` required when creating WiFi broadcasts.
    public var requiresLegacyRadioLocks: Bool { self >= NetworkVersion(10, 6) }
}

public struct EntityMetadata: Decodable, Sendable, Hashable {
    public let origin: String

    public var isUserDefined: Bool { origin == "USER_DEFINED" }

    public var label: String {
        switch origin {
        case "USER_DEFINED": return "Custom"
        case "SYSTEM_DEFINED": return "Built-in"
        case "DERIVED": return "Derived"
        case "ORCHESTRATED": return "Orchestrated"
        default: return origin.capitalized
        }
    }
}

public struct NetworkSummary: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let enabled: Bool
    public let vlanId: Int
    public let management: String
    public let `default`: Bool
    public let metadata: EntityMetadata

    public var managementLabel: String {
        switch management {
        case "GATEWAY": return "Gateway"
        case "SWITCH": return "Layer 3 switch"
        case "UNMANAGED": return "Third-party gateway"
        default: return management.capitalized
        }
    }
}

public struct NetworkReference: Decodable, Sendable, Hashable {
    public let resourceType: String
    public let referenceCount: Int
}

public struct WiFiBroadcast: Decodable, Identifiable, Sendable, Hashable {
    public struct NetworkReference: Decodable, Sendable, Hashable {
        public let type: String
        public let networkId: UUID?
    }

    public struct Security: Decodable, Sendable, Hashable {
        public let type: String
    }

    public let id: UUID
    public let name: String
    public let type: String
    public let enabled: Bool
    public let network: NetworkReference?
    public let securityConfiguration: Security
    public let metadata: EntityMetadata

    public var securityLabel: String { WiFiSecurity.label(for: securityConfiguration.type) }
}

public enum WiFiSecurity: String, CaseIterable, Sendable, Identifiable {
    case open = "OPEN"
    case wpa2 = "WPA2_PERSONAL"
    case wpa2wpa3 = "WPA2_WPA3_PERSONAL"
    case wpa3 = "WPA3_PERSONAL"

    public var id: String { rawValue }
    public var label: String { Self.label(for: rawValue) }
    public var usesPassphrase: Bool { self != .open }

    public static func label(for type: String) -> String {
        switch type {
        case "OPEN": return "Open"
        case "WPA2_PERSONAL": return "WPA2 Personal"
        case "WPA2_WPA3_PERSONAL": return "WPA2/WPA3 Personal"
        case "WPA3_PERSONAL": return "WPA3 Personal"
        case "WPA2_ENTERPRISE": return "WPA2 Enterprise"
        case "WPA2_WPA3_ENTERPRISE": return "WPA2/WPA3 Enterprise"
        case "WPA3_ENTERPRISE": return "WPA3 Enterprise"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct FirewallZone: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let networkIds: [UUID]
    public let metadata: EntityMetadata
}

public struct FirewallPolicy: Decodable, Identifiable, Sendable, Hashable {
    public struct Action: Decodable, Sendable, Hashable {
        public let type: String
        public let allowReturnTraffic: Bool?
    }

    public struct Endpoint: Decodable, Sendable, Hashable {
        public let zoneId: UUID
        public let trafficFilter: Filter?
    }

    public struct Filter: Decodable, Sendable, Hashable {
        public let type: String
    }

    public struct ProtocolScope: Decodable, Sendable, Hashable {
        public let ipVersion: String
    }

    public let id: UUID
    public let name: String
    public let description: String?
    public let enabled: Bool
    public let index: Int
    public let action: Action
    public let source: Endpoint
    public let destination: Endpoint
    public let ipProtocolScope: ProtocolScope
    public let loggingEnabled: Bool
    /// Present from Network 11.0.
    public let reportFlowEnabled: Bool?
    public let metadata: EntityMetadata
}

public struct DNSPolicy: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let type: String
    public let enabled: Bool
    public let domain: String?
    public let metadata: EntityMetadata
    public let ipv4Address: String?
    public let ipv6Address: String?
    public let targetDomain: String?
    public let text: String?
    public let ipAddress: String?
    public let mailServerDomain: String?
    public let serverDomain: String?
    public let priority: Int?
    public let port: Int?
    public let ttlSeconds: Int?

    public var typeLabel: String { DNSRecordType(rawValue: type)?.label ?? type }

    public var value: String {
        switch type {
        case "A_RECORD": return ipv4Address ?? ""
        case "AAAA_RECORD": return ipv6Address ?? ""
        case "CNAME_RECORD": return targetDomain ?? ""
        case "TXT_RECORD": return text ?? ""
        case "MX_RECORD": return [priority.map(String.init), mailServerDomain].compactMap { $0 }.joined(separator: " ")
        case "SRV_RECORD": return [serverDomain, port.map { ":\($0)" }].compactMap { $0 }.joined()
        case "FORWARD_DOMAIN": return ipAddress ?? ""
        default: return ""
        }
    }
}

public enum DNSRecordType: String, CaseIterable, Sendable, Identifiable {
    case a = "A_RECORD"
    case aaaa = "AAAA_RECORD"
    case cname = "CNAME_RECORD"
    case txt = "TXT_RECORD"
    case mx = "MX_RECORD"
    case srv = "SRV_RECORD"
    case forward = "FORWARD_DOMAIN"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .a: return "A"
        case .aaaa: return "AAAA"
        case .cname: return "CNAME"
        case .txt: return "TXT"
        case .mx: return "MX"
        case .srv: return "SRV"
        case .forward: return "Forward Domain"
        }
    }
}

public struct HotspotVoucher: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let code: String
    public let name: String
    public let createdAt: String
    public let expired: Bool
    public let timeLimitMinutes: Int
    public let authorizedGuestCount: Int
    public let authorizedGuestLimit: Int?
    public let activatedAt: String?
    public let expiresAt: String?
    public let dataUsageLimitMBytes: Int?
    public let rxRateLimitKbps: Int?
    public let txRateLimitKbps: Int?

    public var formattedCode: String {
        guard code.count == 10, code.allSatisfy(\.isNumber) else { return code }
        return "\(code.prefix(5))-\(code.suffix(5))"
    }
}

public struct VoucherRequest: Encodable, Sendable, Equatable {
    public var name: String
    public var count: Int
    public var timeLimitMinutes: Int
    public var authorizedGuestLimit: Int?
    public var dataUsageLimitMBytes: Int?
    public var rxRateLimitKbps: Int?
    public var txRateLimitKbps: Int?

    public init(
        name: String, count: Int = 1, timeLimitMinutes: Int, authorizedGuestLimit: Int? = 1,
        dataUsageLimitMBytes: Int? = nil, rxRateLimitKbps: Int? = nil, txRateLimitKbps: Int? = nil
    ) {
        self.name = name
        self.count = count
        self.timeLimitMinutes = timeLimitMinutes
        self.authorizedGuestLimit = authorizedGuestLimit
        self.dataUsageLimitMBytes = dataUsageLimitMBytes
        self.rxRateLimitKbps = rxRateLimitKbps
        self.txRateLimitKbps = txRateLimitKbps
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter a voucher name.") }
        if !(1...1000).contains(count) { errors.append("Create between 1 and 1000 vouchers at a time.") }
        if let limit = authorizedGuestLimit, limit < 1 { errors.append("Allow at least one guest per voucher.") }
        errors += GuestLimits(
            timeLimitMinutes: timeLimitMinutes, dataUsageLimitMBytes: dataUsageLimitMBytes,
            rxRateLimitKbps: rxRateLimitKbps, txRateLimitKbps: txRateLimitKbps
        ).validationErrors
        return errors
    }
}

public struct GuestLimits: Sendable, Equatable {
    public var timeLimitMinutes: Int?
    public var dataUsageLimitMBytes: Int?
    public var rxRateLimitKbps: Int?
    public var txRateLimitKbps: Int?

    public init(timeLimitMinutes: Int? = nil, dataUsageLimitMBytes: Int? = nil, rxRateLimitKbps: Int? = nil, txRateLimitKbps: Int? = nil) {
        self.timeLimitMinutes = timeLimitMinutes
        self.dataUsageLimitMBytes = dataUsageLimitMBytes
        self.rxRateLimitKbps = rxRateLimitKbps
        self.txRateLimitKbps = txRateLimitKbps
    }

    /// Documented bounds shared by guest authorization and voucher creation.
    public static let timeLimitRange = 1...1_000_000
    public static let dataLimitRange = 1...1_048_576
    public static let rateLimitRange = 2...100_000

    public var validationErrors: [String] {
        var errors: [String] = []
        if let value = timeLimitMinutes, !Self.timeLimitRange.contains(value) {
            errors.append("The time limit must be between 1 and 1,000,000 minutes.")
        }
        if let value = dataUsageLimitMBytes, !Self.dataLimitRange.contains(value) {
            errors.append("The data limit must be between 1 and 1,048,576 MB.")
        }
        if [rxRateLimitKbps, txRateLimitKbps].compactMap({ $0 }).contains(where: { !Self.rateLimitRange.contains($0) }) {
            errors.append("Rate limits must be between 2 and 100,000 Kbps.")
        }
        return errors
    }
}

public struct WAN: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
}

public struct PendingDevice: Decodable, Identifiable, Sendable, Hashable {
    public let macAddress: String
    public let model: String
    public let state: String
    public let ipAddress: String?
    public let firmwareVersion: String?
    public let supported: Bool?
    public let adoptionTargetSiteIds: [UUID]?

    public var id: String { macAddress.lowercased() }
}

public struct DeviceDetails: Decodable, Identifiable, Sendable {
    public struct Interfaces: Decodable, Sendable {
        public let ports: [Port]?
        public let radios: [Radio]?
    }

    public struct Port: Decodable, Identifiable, Sendable, Hashable {
        public let idx: Int
        public let state: String
        public let connector: String
        public let maxSpeedMbps: Int
        public let speedMbps: Int?
        public let poe: PoE?

        public var id: Int { idx }
    }

    public struct PoE: Decodable, Sendable, Hashable {
        public let enabled: Bool
        public let standard: String
        public let state: String
        public let type: Int
    }

    public struct Radio: Decodable, Sendable, Hashable {
        public let frequencyGHz: Double
        public let channel: Int?
        public let channelWidthMHz: Int
        public let wlanStandard: String
        /// Present from Network 11.0.
        public let txPowerMode: String?

        public var bandLabel: String {
            switch frequencyGHz {
            case 0.9: return "900 MHz"
            case 2.4: return "2.4 GHz"
            default: return "\(frequencyGHz.formatted()) GHz"
            }
        }
    }

    public struct Uplink: Decodable, Sendable {
        public let deviceId: UUID
    }

    public let id: UUID
    public let name: String
    public let model: String
    public let state: String
    public let ipAddress: String?
    public let macAddress: String
    public let firmwareVersion: String?
    public let firmwareUpdatable: Bool
    public let supported: Bool
    public let adoptedAt: String?
    public let provisionedAt: String?
    public let interfaces: Interfaces
    public let uplink: Uplink?
}

public struct DeviceStatistics: Decodable, Sendable {
    public struct Uplink: Decodable, Sendable {
        public let rxRateBps: Int?
        public let txRateBps: Int?
    }

    public struct Interfaces: Decodable, Sendable {
        public let radios: [Radio]?
    }

    public struct Radio: Decodable, Sendable, Hashable {
        public let frequencyGHz: Double
        public let txRetriesPct: Double?
    }

    public let uptimeSec: Int?
    public let cpuUtilizationPct: Double?
    public let memoryUtilizationPct: Double?
    public let loadAverage1Min: Double?
    public let loadAverage5Min: Double?
    public let loadAverage15Min: Double?
    public let lastHeartbeatAt: String?
    public let uplink: Uplink?
    public let interfaces: Interfaces?
}

/// Configuration collections the documented integration v1 API can read, create, replace, and delete.
public enum EditableResource: String, CaseIterable, Sendable {
    case networks
    case wifiBroadcasts
    case firewallZones
    case firewallPolicies
    case dnsPolicies

    var path: String {
        switch self {
        case .networks: return "networks"
        case .wifiBroadcasts: return "wifi/broadcasts"
        case .firewallZones: return "firewall/zones"
        case .firewallPolicies: return "firewall/policies"
        case .dnsPolicies: return "dns/policies"
        }
    }

    /// Server-owned fields returned by detail endpoints but absent from the documented update schemas.
    public var readOnlyKeys: Set<String> {
        switch self {
        case .networks: return ["id", "metadata", "default"]
        case .firewallPolicies: return ["id", "metadata", "index"]
        case .wifiBroadcasts, .firewallZones, .dnsPolicies: return ["id", "metadata"]
        }
    }

    public var supportsForcedDelete: Bool { self == .networks || self == .wifiBroadcasts }

    public var displayName: String {
        switch self {
        case .networks: return "network"
        case .wifiBroadcasts: return "WiFi network"
        case .firewallZones: return "firewall zone"
        case .firewallPolicies: return "firewall policy"
        case .dnsPolicies: return "DNS policy"
        }
    }

    /// Converts a detail document into an update body without changing any settings.
    public func updateBody(from detail: JSONValue) throws -> JSONValue {
        guard case .object(var values) = detail else { throw NetworkAPIError.incompatibleResponse }
        for key in readOnlyKeys { values.removeValue(forKey: key) }
        return .object(values)
    }
}

/// Fields the documented firewall policy PATCH accepts. Flow reporting requires Network 11.0.
public enum FirewallPolicyPatch: Sendable, Equatable {
    case logging(Bool)
    case flowReporting(Bool)

    var key: String {
        switch self {
        case .logging: return "loggingEnabled"
        case .flowReporting: return "reportFlowEnabled"
        }
    }

    var enabled: Bool {
        switch self {
        case .logging(let value), .flowReporting(let value): return value
        }
    }
}

/// User-defined policy order for one source/destination zone pair.
/// System-defined policies are evaluated between the two lists.
public struct FirewallPolicyOrdering: Sendable, Equatable {
    public enum Move: Sendable {
        case earlier, later, beforeSystemDefined, afterSystemDefined
    }

    public var beforeSystemDefined: [UUID]
    public var afterSystemDefined: [UUID]

    public init(beforeSystemDefined: [UUID], afterSystemDefined: [UUID]) {
        self.beforeSystemDefined = beforeSystemDefined
        self.afterSystemDefined = afterSystemDefined
    }

    init(json: JSONValue) throws {
        guard let ids = json["orderedFirewallPolicyIds"],
              let before = ids["beforeSystemDefined"]?.array, let after = ids["afterSystemDefined"]?.array else {
            throw NetworkAPIError.incompatibleResponse
        }
        let parse: ([JSONValue]) throws -> [UUID] = { values in
            try values.map { value in
                guard let id = value.string.flatMap(UUID.init(uuidString:)) else { throw NetworkAPIError.incompatibleResponse }
                return id
            }
        }
        beforeSystemDefined = try parse(before)
        afterSystemDefined = try parse(after)
    }

    var json: JSONValue {
        ["orderedFirewallPolicyIds": [
            "beforeSystemDefined": .array(beforeSystemDefined.map { .string($0.apiString) }),
            "afterSystemDefined": .array(afterSystemDefined.map { .string($0.apiString) })
        ]]
    }

    public func isBeforeSystemDefined(_ id: UUID) -> Bool? {
        if beforeSystemDefined.contains(id) { return true }
        if afterSystemDefined.contains(id) { return false }
        return nil
    }

    /// Returns the reordered lists, or `nil` when the policy is absent or already at that position.
    public func applying(_ move: Move, to id: UUID) -> FirewallPolicyOrdering? {
        var result = self
        if let index = beforeSystemDefined.firstIndex(of: id) {
            switch move {
            case .earlier:
                guard index > 0 else { return nil }
                result.beforeSystemDefined.swapAt(index, index - 1)
            case .later:
                guard index < beforeSystemDefined.count - 1 else { return nil }
                result.beforeSystemDefined.swapAt(index, index + 1)
            case .beforeSystemDefined:
                return nil
            case .afterSystemDefined:
                result.beforeSystemDefined.remove(at: index)
                result.afterSystemDefined.insert(id, at: 0)
            }
        } else if let index = afterSystemDefined.firstIndex(of: id) {
            switch move {
            case .earlier:
                guard index > 0 else { return nil }
                result.afterSystemDefined.swapAt(index, index - 1)
            case .later:
                guard index < afterSystemDefined.count - 1 else { return nil }
                result.afterSystemDefined.swapAt(index, index + 1)
            case .beforeSystemDefined:
                result.afterSystemDefined.remove(at: index)
                result.beforeSystemDefined.append(id)
            case .afterSystemDefined:
                return nil
            }
        } else {
            return nil
        }
        return result
    }
}
