#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo UniFi Network controller used to record documentation screenshots and screencasts.
# Serves fictional data over the documented local integration v1 API with a self-signed
# certificate on 127.0.0.1, keeps edits in memory, and never contacts a real console.
#
# Prints {"port": N, "fingerprint": "<sha256 hex>", "apiKey": "..."} once listening and exits
# when stdin closes.
#
#   ruby Scripts/docs/demo_controller.rb [--port 8443]
require "json"
require "openssl"
require "securerandom"
require "set"
require "socket"
require "time"
require "uri"

API_KEY = "docs-demo-key"
API = "/proxy/network/integration/v1"

module Demo
  module_function

  def id = SecureRandom.uuid
  def ago(seconds) = (Time.now.utc - seconds).iso8601
  def ahead(seconds) = (Time.now.utc + seconds).iso8601
  def user = { origin: "USER_DEFINED" }
  def system = { origin: "SYSTEM_DEFINED" }
  def code = format("%010d", SecureRandom.random_number(10**10))
  def deep(value) = JSON.parse(JSON.generate(value), symbolize_names: true)
end

# Fictional site inventory. Names, addresses, and identifiers are invented for documentation.
class Inventory
  BUILT_IN_INDEX = 10_000
  AFTER_BUILT_IN_INDEX = 20_000

  attr_reader :site, :devices, :pending, :clients, :networks, :wifi, :zones, :policies, :dns, :vouchers, :wans

  def initialize
    @site = { id: Demo.id, name: "Harbor House", internalReference: "default" }
    @after_built_in = Set.new
    build_networks
    build_devices
    build_clients
    build_wifi
    build_zones
    build_policies
    build_dns
    build_vouchers
    @wans = [{ id: Demo.id, name: "Internet 1" }, { id: Demo.id, name: "Internet 2" }]
  end

  def collection(kind)
    { "networks" => @networks, "wifi/broadcasts" => @wifi, "firewall/zones" => @zones,
      "firewall/policies" => @policies, "dns/policies" => @dns }[kind]
  end

  def create(kind, body)
    item = Demo.deep(body).merge(id: Demo.id, metadata: Demo.user)
    item[:default] = false if kind == "networks"
    item[:index] = (user_policies.map { |entry| entry[:index] }.select { |index| index < BUILT_IN_INDEX }.max || 0) + 1 if kind == "firewall/policies"
    collection(kind) << item
    item
  end

  def replace(kind, id, body)
    items = collection(kind)
    position = items.index { |entry| entry[:id] == id } or return nil
    items[position] = Demo.deep(body).merge(items[position].slice(:id, :metadata, :default, :index))
  end

  def ordering(source, destination)
    ids = user_policies.select { |item| item[:source][:zoneId] == source && item[:destination][:zoneId] == destination }
                       .sort_by { |item| item[:index] }.map { |item| item[:id] }
    { beforeSystemDefined: ids.reject { |id| @after_built_in.include?(id) },
      afterSystemDefined: ids.select { |id| @after_built_in.include?(id) } }
  end

  def reorder(source, destination, body)
    requested = body[:orderedFirewallPolicyIds] or return nil
    before = Array(requested[:beforeSystemDefined])
    after = Array(requested[:afterSystemDefined])
    current = ordering(source, destination)
    return nil unless (before + after).sort == (current[:beforeSystemDefined] + current[:afterSystemDefined]).sort

    slots = (before + after).map { |id| policy(id)[:index] }.select { |index| index < BUILT_IN_INDEX }.sort
    slots << ((slots.max || 0) + 1) while slots.length < before.length
    before.each_with_index do |id, position|
      @after_built_in.delete(id)
      policy(id)[:index] = slots[position]
    end
    after.each_with_index do |id, position|
      @after_built_in << id
      policy(id)[:index] = AFTER_BUILT_IN_INDEX + position
    end
    ordering(source, destination)
  end

  def detail(device)
    base = device.merge(supported: true, adoptedAt: Demo.ago(220 * 86_400), provisionedAt: Demo.ago(3 * 86_400))
    base[:uplink] = { deviceId: @uplinks[device[:id]] } if @uplinks[device[:id]]
    base.merge(interfaces: interfaces(device))
  end

  def statistics(device)
    if device[:features].include?("gateway")
      { uptimeSec: 1_814_400 + rand(600), cpuUtilizationPct: (14.2 + rand).round(1), memoryUtilizationPct: 47.8,
        loadAverage1Min: 0.42, loadAverage5Min: 0.38, loadAverage15Min: 0.35, lastHeartbeatAt: Demo.ago(4),
        uplink: { rxRateBps: 286_400_000 + rand(9_000_000), txRateBps: 41_700_000 + rand(2_000_000) } }
    else
      { uptimeSec: 604_800, cpuUtilizationPct: 6.1, memoryUtilizationPct: 38.5, lastHeartbeatAt: Demo.ago(9),
        uplink: { rxRateBps: 18_200_000, txRateBps: 3_400_000 } }
    end
  end

  private

  def user_policies = @policies.select { |item| item[:metadata][:origin] == "USER_DEFINED" }
  def policy(id) = @policies.find { |item| item[:id] == id }

  def build_networks
    @networks = [
      network("Default", 1, "192.168.1.1", default: true, range: %w[192.168.1.6 192.168.1.254]),
      network("IoT", 20, "192.168.20.1", isolation: true, range: %w[192.168.20.6 192.168.20.254]),
      network("Guest", 30, "192.168.30.1", isolation: true, range: %w[192.168.30.6 192.168.30.254]),
      network("Cameras", 40, "192.168.40.1", internet: false, range: %w[192.168.40.6 192.168.40.254]),
      network("Lab", 50, "10.50.0.1", enabled: false, prefix: 16, range: %w[10.50.0.10 10.50.255.254])
    ]
  end

  def network(name, vlan, host, range:, default: false, enabled: true, isolation: false, internet: true, prefix: 24)
    {
      id: Demo.id, name: name, enabled: enabled, management: "GATEWAY", vlanId: vlan, default: default,
      metadata: Demo.user, internetAccessEnabled: internet, isolationEnabled: isolation,
      cellularBackupEnabled: true, mdnsForwardingEnabled: !isolation,
      ipv4Configuration: {
        autoScaleEnabled: false, hostIpAddress: host, prefixLength: prefix,
        dhcpConfiguration: {
          mode: "SERVER", ipAddressRange: { start: range[0], stop: range[1] },
          leaseTimeSeconds: 86_400, pingConflictDetectionEnabled: true
        }
      }
    }
  end

  def network_id(name) = @networks.find { |item| item[:name] == name }[:id]

  def build_devices
    gateway = device("Harbor Gateway", "UDM Pro", "192.168.1.1", "4.3.6", %w[gateway switching], "1c:0b:8b:4e:20:01")
    switch = device("Office Switch", "USW 24 PoE", "192.168.1.2", "7.1.26", %w[switching], "1c:0b:8b:4e:20:02")
    living = device("Living Room AP", "U6 Pro", "192.168.1.10", "6.7.31", %w[accessPoint], "1c:0b:8b:4e:20:10")
    upstairs = device("Upstairs AP", "U6 Lite", "192.168.1.11", "6.6.77", %w[accessPoint], "1c:0b:8b:4e:20:11", updatable: true)
    patio = device("Patio AP", "U6 Mesh", "192.168.1.12", "6.7.31", %w[accessPoint], "1c:0b:8b:4e:20:12", state: "OFFLINE")
    @devices = [gateway, switch, living, upstairs, patio]
    @uplinks = { switch[:id] => gateway[:id], living[:id] => switch[:id], upstairs[:id] => switch[:id], patio[:id] => living[:id] }
    @pending = [{ macAddress: "1c:0b:8b:4e:20:20", model: "U7 Pro", state: "READY_FOR_ADOPTION", ipAddress: "192.168.1.84",
                  firmwareVersion: "7.0.66", supported: true, adoptionTargetSiteIds: [@site[:id]] }]
  end

  def device(name, model, ip, firmware, features, mac, state: "ONLINE", updatable: false)
    { id: Demo.id, name: name, model: model, state: state, ipAddress: ip, macAddress: mac,
      firmwareVersion: firmware, firmwareUpdatable: updatable, features: features }
  end

  def device_id(name) = @devices.find { |item| item[:name] == name }[:id]

  def build_clients
    living = device_id("Living Room AP")
    upstairs = device_id("Upstairs AP")
    switch = device_id("Office Switch")
    @clients = [
      client("Studio MacBook Pro", "WIRELESS", "192.168.1.42", "a4:83:e7:10:00:01", living, 3 * 3600),
      client("Alex's iPhone", "WIRELESS", "192.168.1.57", "a4:83:e7:10:00:02", living, 26 * 3600),
      client("Sam's iPad", "WIRELESS", "192.168.1.61", "a4:83:e7:10:00:03", upstairs, 5 * 3600),
      client("Living Room TV", "WIRELESS", "192.168.20.31", "a4:83:e7:10:00:04", living, 9 * 86_400),
      client("Kitchen Speaker", "WIRELESS", "192.168.20.32", "a4:83:e7:10:00:05", living, 12 * 86_400),
      client("Thermostat", "WIRELESS", "192.168.20.40", "a4:83:e7:10:00:06", upstairs, 30 * 86_400),
      client("Office Printer", "WIRED", "192.168.1.30", "a4:83:e7:10:00:07", switch, 18 * 86_400),
      client("Storage NAS", "WIRED", "192.168.1.20", "a4:83:e7:10:00:08", switch, 41 * 86_400),
      client("Front Door Camera", "WIRED", "192.168.40.11", "a4:83:e7:10:00:09", switch, 41 * 86_400),
      client("Driveway Camera", "WIRED", "192.168.40.12", "a4:83:e7:10:00:0a", switch, 41 * 86_400),
      client("Travel Laptop", "VPN", "192.168.2.2", nil, nil, 2 * 3600),
      client("Guest Phone", "WIRELESS", "192.168.30.15", "a4:83:e7:10:00:0c", living, 40 * 60, guest: false),
      client("Visitor Laptop", "WIRELESS", "192.168.30.16", "a4:83:e7:10:00:0d", upstairs, 95 * 60, guest: true)
    ]
  end

  def client(name, type, ip, mac, uplink, connected, guest: nil)
    access = guest.nil? ? { type: "DEFAULT" } : { type: "GUEST", authorized: guest }
    { id: Demo.id, name: name, type: type, ipAddress: ip, macAddress: mac, connectedAt: Demo.ago(connected),
      uplinkDeviceId: uplink, access: access }.compact
  end

  def build_wifi
    @wifi = [
      broadcast("Harbor", "Default", "WPA2_WPA3_PERSONAL", [2.4, 5.0, 6.0], steering: true),
      broadcast("Harbor IoT", "IoT", "WPA2_PERSONAL", [2.4]),
      broadcast("Harbor Guest", "Guest", "WPA2_PERSONAL", [2.4, 5.0], isolation: true, steering: true),
      broadcast("Harbor Lab", "Lab", "WPA3_PERSONAL", [5.0, 6.0], enabled: false)
    ]
  end

  def broadcast(name, network, security, bands, enabled: true, isolation: false, steering: nil)
    config = { type: security, passphrase: "harbor-demo-passphrase", pmfMode: "OPTIONAL" }
    config[:saeConfiguration] = { anticloggingThresholdSeconds: 5, syncTimeSeconds: 5 } if security.include?("WPA3")
    { id: Demo.id, name: name, type: "STANDARD", enabled: enabled, metadata: Demo.user,
      network: { type: "SPECIFIC", networkId: network_id(network) }, securityConfiguration: config,
      broadcastingFrequenciesGHz: bands, hideName: false, clientIsolationEnabled: isolation,
      bandSteeringEnabled: steering, multicastToUnicastConversionEnabled: false }.compact
  end

  def build_zones
    @zones = [
      zone("Internal", %w[Default], Demo.system),
      zone("External", [], Demo.system),
      zone("Gateway", [], Demo.system),
      zone("VPN", [], Demo.system),
      zone("Hotspot", %w[Guest], Demo.system),
      zone("DMZ", [], Demo.system),
      zone("IoT", %w[IoT], Demo.user),
      zone("Cameras", %w[Cameras Lab], Demo.user)
    ]
  end

  def zone(name, networks, origin)
    { id: Demo.id, name: name, networkIds: networks.map { |item| network_id(item) }, metadata: origin }
  end

  def zone_id(name) = @zones.find { |item| item[:name] == name }[:id]

  def build_policies
    @policies = [
      rule(1, "Allow IoT pairing", "IoT", "Internal", "ALLOW", enabled: false,
                                                               description: "Temporarily let new devices reach the hub"),
      rule(2, "Block IoT to Internal", "IoT", "Internal", "BLOCK", logging: true,
                                                                   description: "Keep smart-home devices away from computers"),
      rule(3, "Allow Internal to IoT", "Internal", "IoT", "ALLOW", description: "Control devices from phones and laptops"),
      rule(4, "Block Cameras to Internet", "Cameras", "External", "BLOCK", logging: true),
      rule(5, "Allow Internal to Cameras", "Internal", "Cameras", "ALLOW"),
      rule(10_000, "Allow All Traffic", "Internal", "Internal", "ALLOW", origin: Demo.system),
      rule(10_001, "Allow Internal to External", "Internal", "External", "ALLOW", origin: Demo.system),
      rule(10_002, "Allow Internal to Gateway", "Internal", "Gateway", "ALLOW", origin: Demo.system),
      rule(10_003, "Block External to Internal", "External", "Internal", "BLOCK", origin: Demo.system),
      rule(10_004, "Isolate Hotspot from Internal", "Hotspot", "Internal", "BLOCK", origin: Demo.system),
      rule(10_005, "Allow Hotspot to External", "Hotspot", "External", "ALLOW", origin: Demo.system)
    ]
  end

  def rule(index, name, source, destination, action, enabled: true, logging: false, description: nil, origin: Demo.user)
    action_value = { type: action }
    action_value[:allowReturnTraffic] = true if action == "ALLOW"
    { id: Demo.id, name: name, description: description, enabled: enabled, index: index, action: action_value,
      source: { zoneId: zone_id(source) }, destination: { zoneId: zone_id(destination) },
      ipProtocolScope: { ipVersion: "IPV4_AND_IPV6" }, loggingEnabled: logging, metadata: origin }.compact
  end

  def build_dns
    @dns = [
      record("A_RECORD", "nas.home.arpa", ipv4Address: "192.168.1.20", ttlSeconds: 3600),
      record("A_RECORD", "hub.home.arpa", ipv4Address: "192.168.20.10", ttlSeconds: 3600),
      record("CNAME_RECORD", "files.home.arpa", targetDomain: "nas.home.arpa", ttlSeconds: 3600),
      record("AAAA_RECORD", "printer.home.arpa", ipv6Address: "fd00:1::30", ttlSeconds: 3600),
      record("TXT_RECORD", "home.arpa", text: "v=demo1", ttlSeconds: 3600, enabled: false),
      record("FORWARD_DOMAIN", "lab.example", ipAddress: "10.50.0.53")
    ]
  end

  def record(type, domain, enabled: true, **values)
    { id: Demo.id, type: type, enabled: enabled, domain: domain, metadata: Demo.user }.merge(values)
  end

  def build_vouchers
    @vouchers = [
      voucher("Weekend guests", 2880, created: 2 * 3600),
      voucher("Weekend guests", 2880, created: 2 * 3600),
      voucher("Weekend guests", 2880, created: 2 * 3600, activated: 90 * 60, guests: 1),
      voucher("Dog walker", 60 * 24 * 30, created: 6 * 86_400, activated: 6 * 86_400, guests: 1, limit: 2),
      voucher("Contractor", 480, created: 3 * 86_400, activated: 3 * 86_400, guests: 1, expired: true)
    ]
  end

  def voucher(name, minutes, created:, activated: nil, guests: 0, limit: 1, expired: false)
    activated_at = activated && Demo.ago(activated)
    expires_at = activated && (Time.parse(activated_at) + minutes * 60).utc.iso8601
    { id: Demo.id, code: Demo.code, name: name, createdAt: Demo.ago(created), expired: expired,
      timeLimitMinutes: minutes, authorizedGuestCount: guests, authorizedGuestLimit: limit,
      activatedAt: activated_at, expiresAt: expires_at }.compact
  end

  def interfaces(device)
    if device[:features].include?("gateway")
      lan = (1..8).map { |idx| port(idx, idx <= 5 ? "UP" : "DOWN", 1000, idx <= 5 ? 1000 : nil) }
      { ports: lan + [port(9, "UP", 1000, 1000), port(10, "UP", 10_000, 10_000, connector: "SFPPLUS"),
                      port(11, "DOWN", 10_000, nil, connector: "SFPPLUS")] }
    elsif device[:features].include?("switching")
      ports = (1..24).map do |idx|
        up = [1, 2, 3, 5, 6, 7, 8, 12, 17].include?(idx)
        poe = { enabled: idx <= 16, standard: "802.3at", state: up && idx <= 16 ? "UP" : "DOWN", type: 2 }
        port(idx, up ? "UP" : "DOWN", 1000, up ? 1000 : nil, poe: poe)
      end
      { ports: ports + [port(25, "UP", 1000, 1000, connector: "SFP"), port(26, "DOWN", 1000, nil, connector: "SFP")] }
    else
      online = device[:state] == "ONLINE"
      { ports: [port(1, online ? "UP" : "DOWN", 2500, online ? 1000 : nil)],
        radios: [{ frequencyGHz: 2.4, channel: 6, channelWidthMHz: 20, wlanStandard: "802.11ax" },
                 { frequencyGHz: 5, channel: 44, channelWidthMHz: 80, wlanStandard: "802.11ax" }] }
    end
  end

  def port(idx, state, max, speed, connector: "RJ45", poe: nil)
    { idx: idx, state: state, connector: connector, maxSpeedMbps: max, speedMbps: speed, poe: poe }.compact
  end
end

# Routes the documented integration v1 endpoints the app uses onto the in-memory inventory.
class DemoController
  ITEM_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def initialize(inventory)
    @data = inventory
    @lock = Mutex.new
  end

  def call(method, target, headers, body)
    path, query = target.to_s.split("?", 2)
    return error(404, "Not found") unless path.to_s.start_with?("#{API}/")
    return error(401, "Unauthorized") unless headers["x-api-key"] == API_KEY

    params = URI.decode_www_form(query.to_s).to_h
    json = body.to_s.empty? ? {} : JSON.parse(body, symbolize_names: true)
    @lock.synchronize { route(method, path.delete_prefix("#{API}/"), params, json) }
  rescue JSON::ParserError
    error(400, "The request body is not valid JSON")
  rescue StandardError => e
    warn "#{method} #{target}: #{e.class}: #{e.message}"
    error(500, "Internal error")
  end

  private

  def ok(value, status = 200) = [status, JSON.generate(value)]
  def error(status, message) = [status, JSON.generate(statusCode: status, statusName: "ERROR", message: message)]

  def page(items, params)
    offset = Integer(params.fetch("offset", "0"))
    limit = Integer(params.fetch("limit", "25"))
    slice = items[offset, limit] || []
    ok(offset: offset, limit: limit, count: slice.length, totalCount: items.length, data: slice)
  end

  def route(method, path, params, json)
    return ok(applicationVersion: "10.6.106") if method == "GET" && path == "info"
    return page([@data.site], params) if method == "GET" && path == "sites"
    return page(@data.pending, params) if method == "GET" && path == "pending-devices"

    prefix = "sites/#{@data.site[:id]}/"
    return error(404, "Site not found") unless path.start_with?(prefix)

    site_route(method, path.delete_prefix(prefix).split("/"), params, json)
  end

  def site_route(method, parts, params, json)
    case parts
    in ["devices"] then devices(method, params, json)
    in ["devices", id] then device(method, id)
    in ["devices", id, "statistics", "latest"] then with_device(id) { |item| ok(@data.statistics(item)) }
    in ["devices", id, "actions"] then with_device(id) { ok(action: json[:action]) }
    in ["devices", id, "interfaces", "ports", _, "actions"] then with_device(id) { ok(action: json[:action]) }
    in ["clients"] then page(@data.clients, params)
    in ["clients", id, "actions"] then guest(id, json)
    in ["wans"] then page(@data.wans, params)
    in ["networks", id, "references"] then references(id)
    in ["firewall", "policies", "ordering"] then ordering(method, params, json)
    in ["hotspot", "vouchers"] then vouchers(method, params, json)
    in ["hotspot", "vouchers", id] then delete_voucher(method, id)
    else resource(method, parts, params, json)
    end
  end

  def devices(method, params, json)
    return page(@data.devices, params) if method == "GET"
    return error(405, "Method not allowed") unless method == "POST"

    pending = @data.pending.find { |item| item[:macAddress] == json[:macAddress] } or return error(404, "Device not found")
    @data.pending.delete(pending)
    adopted = { id: Demo.id, name: pending[:model], model: pending[:model], state: "ADOPTING", ipAddress: pending[:ipAddress],
                macAddress: pending[:macAddress], firmwareVersion: pending[:firmwareVersion], firmwareUpdatable: false,
                features: %w[accessPoint] }
    @data.devices << adopted
    ok(adopted)
  end

  def device(method, id)
    with_device(id) do |item|
      case method
      when "GET" then ok(@data.detail(item))
      when "DELETE" then @data.devices.delete(item) && ok({})
      else error(405, "Method not allowed")
      end
    end
  end

  def with_device(id)
    item = @data.devices.find { |entry| entry[:id] == id } or return error(404, "Device not found")
    yield item
  end

  def guest(id, json)
    item = @data.clients.find { |entry| entry[:id] == id } or return error(404, "Client not found")
    return error(400, "Client is not a guest") unless item.dig(:access, :type) == "GUEST"

    granted = json[:action] == "AUTHORIZE_GUEST_ACCESS"
    item[:access][:authorized] = granted
    authorization = { authorizationMethod: "API", authorizedAt: Demo.ago(0),
                      expiresAt: Demo.ahead((json[:timeLimitMinutes] || 1440) * 60) }
    ok({ action: json[:action] }.merge(granted ? { grantedAuthorization: authorization } : { revokedAuthorization: authorization }))
  end

  def references(id)
    network = @data.networks.find { |item| item[:id] == id } or return error(404, "Network not found")
    wifi = @data.wifi.count { |item| item.dig(:network, :networkId) == id }
    clients = { "Default" => 6, "IoT" => 3, "Guest" => 2, "Cameras" => 2 }.fetch(network[:name], 0)
    ok(referenceResources: [{ resourceType: "CLIENT", referenceCount: clients }, { resourceType: "WIFI", referenceCount: wifi }])
  end

  def ordering(method, params, json)
    source = params["sourceFirewallZoneId"]
    destination = params["destinationFirewallZoneId"]
    return error(400, "Both zones are required") unless source && destination

    case method
    when "GET" then ok(orderedFirewallPolicyIds: @data.ordering(source, destination))
    when "PUT"
      applied = @data.reorder(source, destination, json) or return error(400, "The ordering must list the same policies")
      ok(orderedFirewallPolicyIds: applied)
    else error(405, "Method not allowed")
    end
  end

  def vouchers(method, params, json)
    case method
    when "GET" then page(@data.vouchers, params)
    when "POST"
      created = Array.new(json[:count] || 1) do
        { id: Demo.id, code: Demo.code, name: json[:name], createdAt: Demo.ago(0), expired: false,
          timeLimitMinutes: json[:timeLimitMinutes], authorizedGuestCount: 0, authorizedGuestLimit: json[:authorizedGuestLimit],
          dataUsageLimitMBytes: json[:dataUsageLimitMBytes], rxRateLimitKbps: json[:rxRateLimitKbps],
          txRateLimitKbps: json[:txRateLimitKbps] }.compact
      end
      @data.vouchers.concat(created)
      ok({ vouchers: created }, 201)
    when "DELETE"
      return error(400, "Unsupported filter") unless params["filter"] == "expired.eq(true)"

      expired = @data.vouchers.count { |item| item[:expired] }
      @data.vouchers.reject! { |item| item[:expired] }
      ok(vouchersDeleted: expired)
    else error(405, "Method not allowed")
    end
  end

  def delete_voucher(method, id)
    return error(405, "Method not allowed") unless method == "DELETE"

    @data.vouchers.reject! { |item| item[:id] == id } ? ok({}) : error(404, "Voucher not found")
  end

  def resource(method, parts, params, json)
    id = parts.last if parts.last&.match?(ITEM_ID)
    kind = (id ? parts[0...-1] : parts).join("/")
    items = @data.collection(kind) or return error(404, "Not found")
    return collection(method, kind, items, params, json) unless id

    item = items.find { |entry| entry[:id] == id } or return error(404, "Item not found")
    case method
    when "GET" then ok(item)
    when "PUT" then ok(@data.replace(kind, id, json))
    when "PATCH" then ok(item.merge!(json))
    when "DELETE" then items.delete(item) && ok({})
    else error(405, "Method not allowed")
    end
  end

  def collection(method, kind, items, params, json)
    case method
    when "GET" then page(items, params)
    when "POST" then ok(@data.create(kind, json), 201)
    else error(405, "Method not allowed")
    end
  end
end

def certificate_and_key
  key = OpenSSL::PKey::EC.generate("prime256v1")
  name = OpenSSL::X509::Name.parse("/CN=Harbor Gateway")
  certificate = OpenSSL::X509::Certificate.new
  certificate.version = 2
  certificate.serial = OpenSSL::BN.rand(64)
  certificate.subject = name
  certificate.issuer = name
  certificate.public_key = key
  certificate.not_before = Time.now - 60
  certificate.not_after = Time.now + 30 * 86_400
  factory = OpenSSL::X509::ExtensionFactory.new(certificate, certificate)
  certificate.add_extension(factory.create_extension("basicConstraints", "CA:FALSE", true))
  certificate.add_extension(factory.create_extension("subjectAltName", "IP:127.0.0.1"))
  certificate.sign(key, OpenSSL::Digest.new("SHA256"))
  [certificate, key]
end

def serve(connection, controller)
  request_line = connection.gets("\r\n").to_s
  headers = {}
  while (line = connection.gets("\r\n")) && line != "\r\n"
    field, value = line.chomp.split(":", 2)
    headers[field.downcase] = value.to_s.strip
  end
  method, target, = request_line.split(" ")
  length = headers["content-length"].to_i
  body = length.positive? ? connection.read(length) : nil
  status, payload = controller.call(method, target, headers, body)
  head = ["HTTP/1.1 #{status} Demo", "Content-Type: application/json",
          "Content-Length: #{payload.bytesize}", "Connection: close"]
  connection.write("#{head.join("\r\n")}\r\n\r\n#{payload}")
rescue OpenSSL::SSL::SSLError, SystemCallError, IOError
  nil
ensure
  connection.close unless connection.closed?
end

return unless __FILE__ == $PROGRAM_NAME

requested = ARGV.index("--port")&.then { |index| Integer(ARGV.fetch(index + 1)) } || 0
certificate, key = certificate_and_key
context = OpenSSL::SSL::SSLContext.new
context.cert = certificate
context.key = key
context.min_version = OpenSSL::SSL::TLS1_2_VERSION
tcp = TCPServer.new("127.0.0.1", requested)
server = OpenSSL::SSL::SSLServer.new(tcp, context)
controller = DemoController.new(Inventory.new)

$stdout.sync = true
puts JSON.generate(port: tcp.addr[1], fingerprint: OpenSSL::Digest::SHA256.hexdigest(certificate.to_der), apiKey: API_KEY)
Thread.new do
  $stdin.read
  exit!(0)
end

loop do
  connection = begin
    server.accept
  rescue OpenSSL::SSL::SSLError, SystemCallError, IOError
    next
  end
  Thread.new(connection) { |client| serve(client, controller) }
end
