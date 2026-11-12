import Foundation

/// Address checks used by editors before anything is sent to the controller.
public enum Address {
    public static func ipv4(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let octet = UInt8(part) else { return nil }
            result = result << 8 | UInt32(octet)
        }
        return result
    }

    public static func isIPv4(_ value: String) -> Bool { ipv4(value) != nil }

    public static func isIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        return value.contains(":") && inet_pton(AF_INET6, value, &address) == 1
    }

    public static func isIP(_ value: String) -> Bool { isIPv4(value) || isIPv6(value) }

    public static func isDomain(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 253 && !value.contains(where: { $0.isWhitespace || $0 == "/" })
    }

    public static func sameSubnet(_ first: String, _ second: String, prefixLength: Int) -> Bool {
        guard let first = ipv4(first), let second = ipv4(second), (0...32).contains(prefixLength) else { return false }
        let mask: UInt32 = prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
        return first & mask == second & mask
    }

    static func list(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    /// `address/prefix` in CIDR notation.
    public static func isIPv4Subnet(_ value: String) -> Bool { isSubnet(value, address: isIPv4, maxPrefix: 32) }
    public static func isIPv6Subnet(_ value: String) -> Bool { isSubnet(value, address: isIPv6, maxPrefix: 128) }

    private static func isSubnet(_ value: String, address: (String) -> Bool, maxPrefix: Int) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...maxPrefix).contains(prefix) else { return false }
        return address(String(parts[0]))
    }

    public static func isMAC(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }

    /// Splits `start-stop`; IPv6 addresses never contain `-`, so the first hyphen is the separator.
    static func range(_ value: String) -> (start: String, stop: String)? {
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension JSONValue {
    var uuid: UUID? { string.flatMap(UUID.init(uuidString:)) }
    var strings: [String] { array?.compactMap(\.string) ?? [] }
    var object: [String: JSONValue] {
        if case .object(let values) = self { return values }
        return [:]
    }
}

// MARK: - Networks

public struct NetworkDraft: Equatable, Sendable {
    public enum DHCPMode: String, CaseIterable, Identifiable, Sendable {
        case server = "SERVER", relay = "RELAY", none = "NONE"
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .server: return "DHCP Server"
            case .relay: return "DHCP Relay"
            case .none: return "None"
            }
        }
    }

    public var management = "GATEWAY"
    public var isDefault = false
    public var name = ""
    public var enabled = true
    public var vlanId = 2
    public var internetAccessEnabled = true
    public var isolationEnabled = false
    public var cellularBackupEnabled = true
    public var mdnsForwardingEnabled: Bool?
    public var zoneId: UUID?
    public var hostIpAddress = "192.168.2.1"
    public var prefixLength = 24
    public var autoScaleEnabled = false
    public var dhcpMode = DHCPMode.server
    public var dhcpStart = "192.168.2.6"
    public var dhcpStop = "192.168.2.254"
    public var leaseTimeSeconds = 86_400
    public var dnsServers = ""
    public var domainName = ""
    public var pingConflictDetectionEnabled = true
    public var relayServers = ""

    public init() {}

    public init(detail: JSONValue) {
        management = detail["management"]?.string ?? management
        isDefault = detail["default"]?.bool ?? false
        name = detail["name"]?.string ?? ""
        enabled = detail["enabled"]?.bool ?? enabled
        vlanId = detail["vlanId"]?.int ?? vlanId
        internetAccessEnabled = detail["internetAccessEnabled"]?.bool ?? internetAccessEnabled
        isolationEnabled = detail["isolationEnabled"]?.bool ?? isolationEnabled
        cellularBackupEnabled = detail["cellularBackupEnabled"]?.bool ?? cellularBackupEnabled
        mdnsForwardingEnabled = detail["mdnsForwardingEnabled"]?.bool
        zoneId = detail["zoneId"]?.uuid
        let ipv4 = detail["ipv4Configuration"] ?? [:]
        hostIpAddress = ipv4["hostIpAddress"]?.string ?? ""
        prefixLength = ipv4["prefixLength"]?.int ?? prefixLength
        autoScaleEnabled = ipv4["autoScaleEnabled"]?.bool ?? false
        let dhcp = ipv4["dhcpConfiguration"]
        dhcpMode = dhcp?["mode"]?.string.flatMap(DHCPMode.init(rawValue:)) ?? .none
        dhcpStart = dhcp?["ipAddressRange"]?["start"]?.string ?? ""
        dhcpStop = dhcp?["ipAddressRange"]?["stop"]?.string ?? ""
        leaseTimeSeconds = dhcp?["leaseTimeSeconds"]?.int ?? leaseTimeSeconds
        dnsServers = dhcp?["dnsServerIpAddressesOverride"]?.strings.joined(separator: ", ") ?? ""
        domainName = dhcp?["domainName"]?.string ?? ""
        pingConflictDetectionEnabled = dhcp?["pingConflictDetectionEnabled"]?.bool ?? pingConflictDetectionEnabled
        relayServers = dhcp?["dhcpServerIpAddresses"]?.strings.joined(separator: ", ") ?? ""
    }

    public var isGatewayManaged: Bool { management == "GATEWAY" }

    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmed.isEmpty { errors.append("Enter a network name.") }
        if !isDefault, !(1...4009).contains(vlanId) { errors.append("VLAN ID must be between 1 and 4009.") }
        guard isGatewayManaged else { return errors }
        if !Address.isIPv4(hostIpAddress.trimmed) { errors.append("Enter a valid gateway IPv4 address.") }
        if !(8...30).contains(prefixLength) { errors.append("The subnet prefix must be between /8 and /30.") }
        switch dhcpMode {
        case .server:
            let start = dhcpStart.trimmed, stop = dhcpStop.trimmed
            if let first = Address.ipv4(start), let last = Address.ipv4(stop) {
                if first > last { errors.append("The DHCP range must start before it ends.") }
                if !Address.sameSubnet(start, hostIpAddress.trimmed, prefixLength: prefixLength)
                    || !Address.sameSubnet(stop, hostIpAddress.trimmed, prefixLength: prefixLength) {
                    errors.append("The DHCP range must be inside the network's subnet.")
                }
            } else {
                errors.append("Enter a valid DHCP range.")
            }
            if !(0...31_536_000).contains(leaseTimeSeconds) { errors.append("Lease time must be between 0 and 31,536,000 seconds.") }
            let dns = Address.list(dnsServers)
            if dns.count > 4 || !dns.allSatisfy(Address.isIPv4) { errors.append("Enter up to four valid DNS server IPv4 addresses.") }
        case .relay:
            let servers = Address.list(relayServers)
            if servers.isEmpty || !servers.allSatisfy(Address.isIPv4) { errors.append("Enter at least one valid DHCP relay server address.") }
        case .none:
            break
        }
        return errors
    }

    /// Applies only this form's fields to the controller's own detail document.
    public func apply(to detail: JSONValue) -> JSONValue {
        var result = detail
        result["name"] = .string(name.trimmed)
        result["enabled"] = .bool(enabled)
        if !isDefault { result["vlanId"] = .int(vlanId) }
        guard isGatewayManaged else { return result }
        result["internetAccessEnabled"] = .bool(internetAccessEnabled)
        result["isolationEnabled"] = .bool(isolationEnabled)
        result["cellularBackupEnabled"] = .bool(cellularBackupEnabled)
        if let mdnsForwardingEnabled { result["mdnsForwardingEnabled"] = .bool(mdnsForwardingEnabled) }
        if let zoneId { result["zoneId"] = .string(zoneId.apiString) }
        result["ipv4Configuration"] = ipv4Configuration(existing: detail["ipv4Configuration"] ?? [:])
        return result
    }

    public func createBody() -> JSONValue {
        var body: JSONValue = [
            "management": "GATEWAY", "name": .string(name.trimmed), "enabled": .bool(enabled), "vlanId": .int(vlanId),
            "internetAccessEnabled": .bool(internetAccessEnabled), "isolationEnabled": .bool(isolationEnabled),
            "cellularBackupEnabled": .bool(cellularBackupEnabled),
            "ipv4Configuration": ipv4Configuration(existing: [:])
        ]
        if let mdnsForwardingEnabled { body["mdnsForwardingEnabled"] = .bool(mdnsForwardingEnabled) }
        if let zoneId { body["zoneId"] = .string(zoneId.apiString) }
        return body
    }

    private func ipv4Configuration(existing: JSONValue) -> JSONValue {
        var ipv4 = existing.isObject ? existing : [:]
        ipv4["hostIpAddress"] = .string(hostIpAddress.trimmed)
        ipv4["prefixLength"] = .int(prefixLength)
        ipv4["autoScaleEnabled"] = .bool(autoScaleEnabled)
        let previous = existing["dhcpConfiguration"]
        let sameMode = previous?["mode"]?.string == dhcpMode.rawValue
        switch dhcpMode {
        case .none:
            ipv4["dhcpConfiguration"] = nil
        case .server:
            var dhcp: JSONValue = sameMode ? previous ?? [:] : [:]
            dhcp["mode"] = "SERVER"
            dhcp["ipAddressRange"] = ["start": .string(dhcpStart.trimmed), "stop": .string(dhcpStop.trimmed)]
            dhcp["leaseTimeSeconds"] = .int(leaseTimeSeconds)
            dhcp["pingConflictDetectionEnabled"] = .bool(pingConflictDetectionEnabled)
            let dns = Address.list(dnsServers)
            dhcp["dnsServerIpAddressesOverride"] = dns.isEmpty ? nil : .array(dns.map(JSONValue.string))
            dhcp["domainName"] = domainName.trimmed.isEmpty ? nil : .string(domainName.trimmed)
            ipv4["dhcpConfiguration"] = dhcp
        case .relay:
            var dhcp: JSONValue = sameMode ? previous ?? [:] : [:]
            dhcp["mode"] = "RELAY"
            dhcp["dhcpServerIpAddresses"] = .array(Address.list(relayServers).map(JSONValue.string))
            ipv4["dhcpConfiguration"] = dhcp
        }
        return ipv4
    }
}

// MARK: - WiFi

public struct WiFiDraft: Equatable, Sendable {
    public static let frequencies: [Double] = [2.4, 5, 6]

    public var type = "STANDARD"
    public var name = ""
    public var enabled = true
    public var hideName = false
    public var clientIsolationEnabled = false
    public var bandSteeringEnabled: Bool?
    public var networkId: UUID?
    public var securityType = WiFiSecurity.wpa2.rawValue
    public var passphrase = ""
    public var broadcastingFrequenciesGHz: Set<Double> = [2.4, 5]
    private var originalSecurityType: String?
    private var hadPassphrase = false

    public init() {}

    public init(detail: JSONValue) {
        type = detail["type"]?.string ?? type
        name = detail["name"]?.string ?? ""
        enabled = detail["enabled"]?.bool ?? enabled
        hideName = detail["hideName"]?.bool ?? false
        clientIsolationEnabled = detail["clientIsolationEnabled"]?.bool ?? false
        bandSteeringEnabled = detail["bandSteeringEnabled"]?.bool
        networkId = detail["network"]?["networkId"]?.uuid
        let security = detail["securityConfiguration"] ?? [:]
        securityType = security["type"]?.string ?? securityType
        originalSecurityType = securityType
        passphrase = security["passphrase"]?.string ?? ""
        hadPassphrase = !passphrase.isEmpty
        if let bands = detail["broadcastingFrequenciesGHz"]?.array?.compactMap(\.double) {
            broadcastingFrequenciesGHz = Set(bands)
        }
    }

    public var isStandard: Bool { type == "STANDARD" }
    public var security: WiFiSecurity? { WiFiSecurity(rawValue: securityType) }
    /// Enterprise and other unrecognized security modes are preserved and only editable in the web UI.
    public var securityEditable: Bool { security != nil }
    private var securityChanged: Bool { securityType != originalSecurityType }

    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmed.isEmpty { errors.append("Enter a WiFi name.") }
        if name.utf8.count > 32 { errors.append("WiFi names can be at most 32 bytes.") }
        if isStandard, broadcastingFrequenciesGHz.isEmpty { errors.append("Choose at least one band.") }
        if let security, security.usesPassphrase, securityChanged || hadPassphrase || !passphrase.isEmpty {
            if !(8...63).contains(passphrase.count) { errors.append("The password must be 8 to 63 characters.") }
        }
        return errors
    }

    public func apply(to detail: JSONValue) -> JSONValue {
        var result = detail
        result["name"] = .string(name.trimmed)
        result["enabled"] = .bool(enabled)
        result["hideName"] = .bool(hideName)
        result["clientIsolationEnabled"] = .bool(clientIsolationEnabled)
        result["network"] = networkReference
        if isStandard {
            result["broadcastingFrequenciesGHz"] = frequencyList
            if let bandSteeringEnabled { result["bandSteeringEnabled"] = .bool(bandSteeringEnabled) }
        }
        if securityEditable {
            result["securityConfiguration"] = securityConfiguration(existing: detail["securityConfiguration"] ?? [:])
        }
        return result
    }

    public func createBody(version: NetworkVersion?) -> JSONValue {
        var body: JSONValue = [
            "type": "STANDARD", "name": .string(name.trimmed), "enabled": .bool(enabled),
            "hideName": .bool(hideName), "clientIsolationEnabled": .bool(clientIsolationEnabled),
            "advertiseDeviceName": false, "arpProxyEnabled": false, "bssTransitionEnabled": true,
            "uapsdEnabled": false, "multicastToUnicastConversionEnabled": false,
            "broadcastingFrequenciesGHz": frequencyList, "network": networkReference,
            "securityConfiguration": securityConfiguration(existing: [:])
        ]
        if let bandSteeringEnabled { body["bandSteeringEnabled"] = .bool(bandSteeringEnabled) }
        if version?.requiresLegacyRadioLocks ?? true {
            body["channel2gLockedTo6"] = false
            body["dtimPeriod2gLockedTo3"] = false
        }
        return body
    }

    private var frequencyList: JSONValue {
        .array(broadcastingFrequenciesGHz.sorted().map { $0 == $0.rounded() ? .int(Int($0)) : .double($0) })
    }

    private var networkReference: JSONValue {
        guard let networkId else { return ["type": "NATIVE"] }
        return ["type": "SPECIFIC", "networkId": .string(networkId.apiString)]
    }

    private func securityConfiguration(existing: JSONValue) -> JSONValue {
        guard let security else { return existing }
        var config: JSONValue = securityChanged || !existing.isObject ? ["type": .string(security.rawValue)] : existing
        guard security.usesPassphrase else { return config }
        if !passphrase.isEmpty || securityChanged { config["passphrase"] = .string(passphrase) }
        let sae: JSONValue = existing["saeConfiguration"] ?? ["anticloggingThresholdSeconds": 5, "syncTimeSeconds": 5]
        switch security {
        case .wpa2:
            if config["pmfMode"] == nil { config["pmfMode"] = existing["pmfMode"] ?? "OPTIONAL" }
        case .wpa2wpa3:
            if config["pmfMode"] == nil { config["pmfMode"] = existing["pmfMode"] ?? "OPTIONAL" }
            if config["saeConfiguration"] == nil { config["saeConfiguration"] = sae }
            if config["wpa3FastRoamingEnabled"] == nil { config["wpa3FastRoamingEnabled"] = false }
        case .wpa3:
            if config["saeConfiguration"] == nil { config["saeConfiguration"] = sae }
        case .open:
            break
        }
        return config
    }
}

// MARK: - Firewall

public struct FirewallZoneDraft: Equatable, Sendable {
    public var name = ""
    public var networkIds: Set<UUID> = []

    public init() {}

    public init(detail: JSONValue) {
        name = detail["name"]?.string ?? ""
        networkIds = Set(detail["networkIds"]?.array?.compactMap(\.uuid) ?? [])
    }

    public var validationErrors: [String] {
        name.trimmed.isEmpty ? ["Enter a zone name."] : []
    }

    public func apply(to detail: JSONValue) -> JSONValue {
        var result = detail
        result["name"] = .string(name.trimmed)
        result["networkIds"] = .array(networkIds.map(\.apiString).sorted().map(JSONValue.string))
        return result
    }

    public func createBody() -> JSONValue { apply(to: [:]) }
}

public struct FirewallPolicyDraft: Equatable, Sendable {
    public static let actions = ["ALLOW", "BLOCK", "REJECT"]
    public static let ipVersions = ["IPV4_AND_IPV6", "IPV4", "IPV6"]

    public var name = ""
    public var description = ""
    public var enabled = true
    public var action = "BLOCK"
    public var allowReturnTraffic = true
    public var sourceZoneId: UUID?
    public var destinationZoneId: UUID?
    public var ipVersion = "IPV4_AND_IPV6"
    public var loggingEnabled = false
    /// Only offered by Network 11.0 and later; `nil` leaves the field untouched.
    public var reportFlowEnabled: Bool?
    public private(set) var hasTrafficFilters = false

    public init() {}

    public init(detail: JSONValue) {
        name = detail["name"]?.string ?? ""
        description = detail["description"]?.string ?? ""
        enabled = detail["enabled"]?.bool ?? enabled
        action = detail["action"]?["type"]?.string ?? action
        allowReturnTraffic = detail["action"]?["allowReturnTraffic"]?.bool ?? allowReturnTraffic
        sourceZoneId = detail["source"]?["zoneId"]?.uuid
        destinationZoneId = detail["destination"]?["zoneId"]?.uuid
        ipVersion = detail["ipProtocolScope"]?["ipVersion"]?.string ?? ipVersion
        loggingEnabled = detail["loggingEnabled"]?.bool ?? false
        reportFlowEnabled = detail["reportFlowEnabled"]?.bool
        hasTrafficFilters = detail["source"]?["trafficFilter"] != nil || detail["destination"]?["trafficFilter"] != nil
            || detail["ipProtocolScope"]?["protocolFilter"] != nil || detail["schedule"] != nil
            || detail["connectionStateFilter"] != nil || detail["ipsecFilter"] != nil
    }

    public static func label(forAction action: String) -> String { action.capitalized }

    public static func label(forIPVersion version: String) -> String {
        switch version {
        case "IPV4": return "IPv4"
        case "IPV6": return "IPv6"
        default: return "IPv4 and IPv6"
        }
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmed.isEmpty { errors.append("Enter a policy name.") }
        if sourceZoneId == nil || destinationZoneId == nil { errors.append("Choose source and destination zones.") }
        return errors
    }

    public func apply(to detail: JSONValue) -> JSONValue {
        var result = detail
        result["name"] = .string(name.trimmed)
        result["description"] = description.trimmed.isEmpty ? nil : .string(description.trimmed)
        result["enabled"] = .bool(enabled)
        result["loggingEnabled"] = .bool(loggingEnabled)
        if let reportFlowEnabled { result["reportFlowEnabled"] = .bool(reportFlowEnabled) }
        var actionValue = detail["action"]?["type"]?.string == action ? detail["action"] ?? [:] : [:]
        actionValue["type"] = .string(action)
        actionValue["allowReturnTraffic"] = action == "ALLOW" ? .bool(allowReturnTraffic) : nil
        result["action"] = actionValue
        var source = detail["source"] ?? [:]
        if let sourceZoneId { source["zoneId"] = .string(sourceZoneId.apiString) }
        result["source"] = source
        var destination = detail["destination"] ?? [:]
        if let destinationZoneId { destination["zoneId"] = .string(destinationZoneId.apiString) }
        result["destination"] = destination
        var scope = detail["ipProtocolScope"] ?? [:]
        scope["ipVersion"] = .string(ipVersion)
        result["ipProtocolScope"] = scope
        return result
    }

    public func createBody(version: NetworkVersion?) -> JSONValue {
        var body = apply(to: [:])
        if version?.supportsFlowReporting != true { body["reportFlowEnabled"] = nil }
        return body
    }
}

// MARK: - DNS

public struct DNSPolicyDraft: Equatable, Sendable {
    public var type = DNSRecordType.a
    public var enabled = true
    public var domain = ""
    public var ipv4Address = ""
    public var ipv6Address = ""
    public var targetDomain = ""
    public var text = ""
    public var mailServerDomain = ""
    public var serverDomain = ""
    public var service = ""
    public var serviceProtocol = "_tcp"
    public var ipAddress = ""
    public var priority = 10
    public var weight = 0
    public var port = 0
    public var ttlSeconds = 3600
    private var originalType: String?

    public init() {}

    public init(detail: JSONValue) {
        originalType = detail["type"]?.string
        type = originalType.flatMap(DNSRecordType.init(rawValue:)) ?? .a
        enabled = detail["enabled"]?.bool ?? enabled
        domain = detail["domain"]?.string ?? ""
        ipv4Address = detail["ipv4Address"]?.string ?? ""
        ipv6Address = detail["ipv6Address"]?.string ?? ""
        targetDomain = detail["targetDomain"]?.string ?? ""
        text = detail["text"]?.string ?? ""
        mailServerDomain = detail["mailServerDomain"]?.string ?? ""
        serverDomain = detail["serverDomain"]?.string ?? ""
        service = detail["service"]?.string ?? ""
        serviceProtocol = detail["protocol"]?.string ?? serviceProtocol
        ipAddress = detail["ipAddress"]?.string ?? ""
        priority = detail["priority"]?.int ?? priority
        weight = detail["weight"]?.int ?? weight
        port = detail["port"]?.int ?? port
        ttlSeconds = detail["ttlSeconds"]?.int ?? ttlSeconds
    }

    public var usesTTL: Bool { [.a, .aaaa, .cname].contains(type) }
    public var maximumTTL: Int { type == .cname ? 604_800 : 86_400 }

    public var validationErrors: [String] {
        var errors: [String] = []
        if !Address.isDomain(domain.trimmed) { errors.append("Enter a valid domain name.") }
        switch type {
        case .a: if !Address.isIPv4(ipv4Address.trimmed) { errors.append("Enter a valid IPv4 address.") }
        case .aaaa: if !Address.isIPv6(ipv6Address.trimmed) { errors.append("Enter a valid IPv6 address.") }
        case .cname: if !Address.isDomain(targetDomain.trimmed) { errors.append("Enter a valid target domain.") }
        case .txt: if text.isEmpty { errors.append("Enter the TXT record text.") }
        case .mx: if !Address.isDomain(mailServerDomain.trimmed) { errors.append("Enter a valid mail server.") }
        case .srv:
            if service.trimmed.isEmpty { errors.append("Enter the SRV service, such as _sip.") }
            if !Address.isDomain(serverDomain.trimmed) { errors.append("Enter a valid target server.") }
            if !(0...65_535).contains(port) || !(0...65_535).contains(weight) {
                errors.append("Port and weight must be between 0 and 65535.")
            }
        case .forward: if !Address.isIP(ipAddress.trimmed) { errors.append("Enter a valid DNS server IP address.") }
        }
        if [.mx, .srv].contains(type), !(0...65_535).contains(priority) { errors.append("Priority must be between 0 and 65535.") }
        if usesTTL, !(0...maximumTTL).contains(ttlSeconds) { errors.append("TTL must be between 0 and \(maximumTTL) seconds.") }
        return errors
    }

    public func apply(to detail: JSONValue) -> JSONValue {
        // A record type change replaces every type-specific field.
        var result: JSONValue = originalType == type.rawValue ? detail : [:]
        for key in ["ipv4Address", "ipv6Address", "targetDomain", "text", "mailServerDomain", "serverDomain",
                    "service", "protocol", "ipAddress", "priority", "weight", "port", "ttlSeconds"] {
            result[key] = nil
        }
        result["type"] = .string(type.rawValue)
        result["enabled"] = .bool(enabled)
        result["domain"] = .string(domain.trimmed)
        switch type {
        case .a: result["ipv4Address"] = .string(ipv4Address.trimmed)
        case .aaaa: result["ipv6Address"] = .string(ipv6Address.trimmed)
        case .cname: result["targetDomain"] = .string(targetDomain.trimmed)
        case .txt: result["text"] = .string(text)
        case .mx:
            result["mailServerDomain"] = .string(mailServerDomain.trimmed)
            result["priority"] = .int(priority)
        case .srv:
            result["service"] = .string(service.trimmed)
            result["protocol"] = .string(serviceProtocol)
            result["serverDomain"] = .string(serverDomain.trimmed)
            result["priority"] = .int(priority)
            result["weight"] = .int(weight)
            result["port"] = .int(port)
        case .forward: result["ipAddress"] = .string(ipAddress.trimmed)
        }
        if usesTTL { result["ttlSeconds"] = .int(ttlSeconds) }
        return result
    }

    public func createBody() -> JSONValue {
        var draft = self
        draft.originalType = nil
        return draft.apply(to: [:])
    }
}

// MARK: - ACL rules

/// One side of an ACL rule. `ANY` leaves the filter out so the rule matches all traffic on that side.
public struct ACLEndpointDraft: Equatable, Sendable {
    public static let any = "ANY"

    public var type = ACLEndpointDraft.any
    /// IPv4 addresses and subnets, or MAC addresses, separated by commas or new lines.
    public var addresses = ""
    public var networkIds: Set<UUID> = []
    public var ports = ""
    /// MAC rules only: match addresses sharing this many leading bits.
    public var prefixLength: Int?

    public init() {}

    init(filter: JSONValue?) {
        guard let filter, let type = filter["type"]?.string else { return }
        self.type = type
        addresses = (filter["ipAddressesOrSubnets"] ?? filter["macAddresses"])?.strings.joined(separator: ", ") ?? ""
        networkIds = Set(filter["networkIds"]?.array?.compactMap(\.uuid) ?? [])
        ports = filter["portFilter"]?.array?.compactMap(\.int).map(String.init).joined(separator: ", ") ?? ""
        prefixLength = filter["prefixLength"]?.int
    }

    public static func types(forRule ruleType: String) -> [String] {
        ruleType == "MAC" ? [any, "MAC_ADDRESSES"] : [any, "IP_ADDRESSES_OR_SUBNETS", "NETWORKS", "PORTS"]
    }

    public static func label(for type: String) -> String {
        switch type {
        case any: return "Any"
        case "IP_ADDRESSES_OR_SUBNETS": return "IP Addresses or Subnets"
        case "NETWORKS": return "Networks"
        case "PORTS": return "Ports"
        case "MAC_ADDRESSES": return "MAC Addresses"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var usesAddresses: Bool { type == "IP_ADDRESSES_OR_SUBNETS" || type == "MAC_ADDRESSES" }
    public var usesNetworks: Bool { type == "NETWORKS" }
    public var usesPorts: Bool { ["IP_ADDRESSES_OR_SUBNETS", "NETWORKS", "PORTS"].contains(type) }
    public var usesPrefixLength: Bool { type == "MAC_ADDRESSES" }

    /// Unique ports in entry order, or `nil` when any entry is not a port number.
    var portNumbers: [Int]? {
        let values = Address.list(ports)
        let numbers = values.compactMap { Int($0) }
        guard numbers.count == values.count, numbers.allSatisfy((1...65535).contains) else { return nil }
        return Array(Set(numbers)).sorted()
    }

    func errors(_ side: String, ruleType: String) -> [String] {
        guard type != Self.any else { return [] }
        let lower = side.lowercased()
        guard Self.types(forRule: ruleType).contains(type) else { return ["Choose a \(lower) match for this rule type."] }
        var errors: [String] = []
        let values = Address.list(addresses)
        switch type {
        case "IP_ADDRESSES_OR_SUBNETS":
            if values.isEmpty {
                errors.append("Enter \(lower) IPv4 addresses or subnets.")
            } else if !values.allSatisfy({ Address.isIPv4($0) || Address.isIPv4Subnet($0) }) {
                errors.append("\(side) addresses must be IPv4 addresses or subnets such as 192.168.1.0/24.")
            }
        case "NETWORKS":
            if networkIds.isEmpty { errors.append("Choose at least one \(lower) network.") }
        case "PORTS":
            if Address.list(ports).isEmpty { errors.append("Enter \(lower) ports.") }
        case "MAC_ADDRESSES":
            if values.isEmpty {
                errors.append("Enter \(lower) MAC addresses.")
            } else if !values.allSatisfy(Address.isMAC) {
                errors.append("\(side) MAC addresses must look like aa:bb:cc:dd:ee:ff.")
            }
            if let prefixLength, !(1...48).contains(prefixLength) {
                errors.append("\(side) MAC prefix length must be from 1 to 48.")
            }
        default:
            break
        }
        if usesPorts, portNumbers == nil { errors.append("\(side) ports must be numbers from 1 to 65535.") }
        return errors
    }

    func json(existing: JSONValue?) -> JSONValue? {
        guard type != Self.any else { return nil }
        var result: JSONValue = existing?["type"]?.string == type ? existing ?? [:] : [:]
        result["type"] = .string(type)
        let values = Address.list(addresses)
        switch type {
        case "IP_ADDRESSES_OR_SUBNETS":
            result["ipAddressesOrSubnets"] = .array(values.map(JSONValue.string))
        case "NETWORKS":
            result["networkIds"] = .array(networkIds.map(\.apiString).sorted().map(JSONValue.string))
        case "MAC_ADDRESSES":
            result["macAddresses"] = .array(values.map { .string($0.lowercased()) })
            result["prefixLength"] = prefixLength.map(JSONValue.int)
        default:
            break
        }
        if usesPorts {
            let numbers = portNumbers ?? []
            result["portFilter"] = numbers.isEmpty ? nil : .array(numbers.map(JSONValue.int))
        }
        return result
    }
}

public struct ACLRuleDraft: Equatable, Sendable {
    public static let types = ["IPV4", "MAC"]
    public static let actions = ["ALLOW", "BLOCK"]
    public static let protocols = ["TCP", "UDP"]

    public var name = ""
    public var enabled = true
    public var action = "BLOCK"
    public var type = "IPV4" {
        didSet {
            guard type != oldValue else { return }
            let allowed = ACLEndpointDraft.types(forRule: type)
            if !allowed.contains(source.type) { source = ACLEndpointDraft() }
            if !allowed.contains(destination.type) { destination = ACLEndpointDraft() }
        }
    }
    /// IPv4 rules only; empty matches every protocol.
    public var protocols: Set<String> = []
    /// MAC rules only: the network whose traffic the rule matches.
    public var networkIdFilter: UUID?
    public var source = ACLEndpointDraft()
    public var destination = ACLEndpointDraft()
    /// Rules limited to specific switches keep that limit; the editor doesn't change it.
    public private(set) var hasDeviceFilter = false

    public init() {}

    public init(detail: JSONValue) {
        name = detail["name"]?.string ?? ""
        enabled = detail["enabled"]?.bool ?? enabled
        action = detail["action"]?.string ?? action
        type = detail["type"]?.string ?? type
        protocols = Set(detail["protocolFilter"]?.strings ?? [])
        networkIdFilter = detail["networkIdFilter"]?.uuid
        source = ACLEndpointDraft(filter: detail["sourceFilter"])
        destination = ACLEndpointDraft(filter: detail["destinationFilter"])
        hasDeviceFilter = detail["enforcingDeviceFilter"] != nil
    }

    public static func label(forType type: String) -> String { type == "IPV4" ? "IPv4" : type }

    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmed.isEmpty { errors.append("Enter a rule name.") }
        if type == "MAC", networkIdFilter == nil { errors.append("Choose the network this MAC rule applies to.") }
        errors += source.errors("Source", ruleType: type)
        errors += destination.errors("Destination", ruleType: type)
        return errors
    }

    public func apply(to detail: JSONValue) -> JSONValue {
        var result = detail
        let sameType = detail["type"]?.string == type
        result["name"] = .string(name.trimmed)
        result["enabled"] = .bool(enabled)
        result["action"] = .string(action)
        result["type"] = .string(type)
        if type == "IPV4" {
            result["protocolFilter"] = protocols.isEmpty ? nil : .array(protocols.sorted().map(JSONValue.string))
            result["networkIdFilter"] = nil
        } else {
            result["protocolFilter"] = nil
            result["networkIdFilter"] = networkIdFilter.map { .string($0.apiString) }
        }
        result["sourceFilter"] = source.json(existing: sameType ? detail["sourceFilter"] : nil)
        result["destinationFilter"] = destination.json(existing: sameType ? detail["destinationFilter"] : nil)
        return result
    }

    public func createBody() -> JSONValue { apply(to: [:]) }
}

// MARK: - Traffic matching lists

public struct TrafficMatchingListDraft: Equatable, Sendable {
    public var name = ""
    public var type = TrafficMatchingListType.ipv4.rawValue
    /// Entries separated by commas or new lines. Ranges are written `start-stop`.
    public var items = ""

    public init() {}

    public init(detail: JSONValue) {
        name = detail["name"]?.string ?? ""
        type = detail["type"]?.string ?? type
        items = detail["items"]?.array?.compactMap(Self.text(for:)).joined(separator: "\n") ?? ""
    }

    private static func text(for item: JSONValue) -> String? {
        func scalar(_ value: JSONValue?) -> String? { value?.string ?? value?.int.map(String.init) }
        if let start = scalar(item["start"]), let stop = scalar(item["stop"]) { return "\(start)-\(stop)" }
        return scalar(item["value"])
    }

    public var placeholder: String {
        switch type {
        case TrafficMatchingListType.ipv6.rawValue: return "2001:db8::1\n2001:db8:1::/64"
        case TrafficMatchingListType.ports.rawValue: return "443\n8000-8080"
        default: return "192.168.1.10\n10.0.0.0/8\n172.16.0.1-172.16.0.50"
        }
    }

    private var entries: [String] { Address.list(items) }

    /// The documented item for one entry, or `nil` when it isn't valid for this list type.
    private func item(_ entry: String) -> JSONValue? {
        switch type {
        case TrafficMatchingListType.ipv4.rawValue:
            if Address.isIPv4(entry) { return ["type": "IP_ADDRESS", "value": .string(entry)] }
            if Address.isIPv4Subnet(entry) { return ["type": "SUBNET", "value": .string(entry)] }
            if let range = Address.range(entry), let start = Address.ipv4(range.start), let stop = Address.ipv4(range.stop), start <= stop {
                return ["type": "IP_ADDRESS_RANGE", "start": .string(range.start), "stop": .string(range.stop)]
            }
        case TrafficMatchingListType.ipv6.rawValue:
            if Address.isIPv6(entry) { return ["type": "IP_ADDRESS", "value": .string(entry)] }
            if Address.isIPv6Subnet(entry) { return ["type": "SUBNET", "value": .string(entry)] }
        case TrafficMatchingListType.ports.rawValue:
            let ports = 1...65535
            if let port = Int(entry), ports.contains(port) { return ["type": "PORT_NUMBER", "value": .int(port)] }
            if let range = Address.range(entry), let start = Int(range.start), let stop = Int(range.stop),
               ports.contains(start), ports.contains(stop), start <= stop {
                return ["type": "PORT_NUMBER_RANGE", "start": .int(start), "stop": .int(stop)]
            }
        default:
            break
        }
        return nil
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmed.isEmpty { errors.append("Enter a list name.") }
        if TrafficMatchingListType(rawValue: type) == nil { errors.append("Choose a list type.") }
        let entries = entries
        if entries.isEmpty {
            errors.append("Add at least one entry.")
        } else {
            let invalid = entries.filter { item($0) == nil }
            if !invalid.isEmpty {
                errors.append("Not valid for \(TrafficMatchingListType.label(for: type)): \(invalid.prefix(3).joined(separator: ", "))")
            }
        }
        return errors
    }

    public func apply(to detail: JSONValue) -> JSONValue {
        var result = detail
        result["name"] = .string(name.trimmed)
        result["type"] = .string(type)
        result["items"] = .array(entries.compactMap(item))
        return result
    }

    public func createBody() -> JSONValue { apply(to: [:]) }
}
