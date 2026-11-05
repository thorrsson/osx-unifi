#!/usr/bin/env ruby
# frozen_string_literal: true

# Throwaway HTTPS controller with a self-signed certificate, used by transport tests.
# Prints {"port": N, "fingerprint": "<sha256 hex>"} once listening and exits when stdin closes.
require "json"
require "openssl"
require "socket"

API_KEY = "fixture-key"
API = "/proxy/network/integration/v1"
SITE_ID = "00000000-0000-0000-0000-000000000001"
DEVICE_ID = "00000000-0000-0000-0000-000000000002"
CLIENT_ID = "00000000-0000-0000-0000-000000000003"

key = OpenSSL::PKey::EC.generate("prime256v1")
name = OpenSSL::X509::Name.parse("/CN=UniFi Desktop Test Controller")
certificate = OpenSSL::X509::Certificate.new
certificate.version = 2
certificate.serial = OpenSSL::BN.rand(64)
certificate.subject = name
certificate.issuer = name
certificate.public_key = key
certificate.not_before = Time.now - 60
certificate.not_after = Time.now + 3600
factory = OpenSSL::X509::ExtensionFactory.new(certificate, certificate)
certificate.add_extension(factory.create_extension("basicConstraints", "CA:FALSE", true))
certificate.add_extension(factory.create_extension("subjectAltName", "IP:127.0.0.1"))
certificate.sign(key, OpenSSL::Digest.new("SHA256"))

context = OpenSSL::SSL::SSLContext.new
context.cert = certificate
context.key = key
context.min_version = OpenSSL::SSL::TLS1_2_VERSION
tcp = TCPServer.new("127.0.0.1", 0)
server = OpenSSL::SSL::SSLServer.new(tcp, context)

def page(items)
  JSON.generate(offset: 0, limit: 200, count: items.length, totalCount: items.length, data: items)
end

def route(method, target, headers)
  path = target.to_s.split("?", 2).first.to_s
  return [302, "{}", { "Location" => "#{API}/info" }] if method == "GET" && path == "/redirect"
  return [404, "{}", {}] unless method == "GET" && path.start_with?("#{API}/")
  return [401, "{}", {}] unless headers["x-api-key"] == API_KEY

  case path.delete_prefix("#{API}/")
  when "info"
    [200, '{"applicationVersion":"10.6.106"}', {}]
  when "sites"
    [200, page([{ id: SITE_ID, name: "Fixture Site" }]), {}]
  when "sites/#{SITE_ID}/devices"
    [200, page([{ id: DEVICE_ID, name: "Fixture Gateway", model: "UDM Pro", state: "ONLINE" }]), {}]
  when "sites/#{SITE_ID}/clients"
    [200, page([{ id: CLIENT_ID, name: "Fixture Laptop", type: "WIRELESS" }]), {}]
  else
    [404, "{}", {}]
  end
end

def serve(connection)
  request_line = connection.gets("\r\n").to_s
  headers = {}
  while (line = connection.gets("\r\n")) && line != "\r\n"
    field, value = line.chomp.split(":", 2)
    headers[field.downcase] = value.to_s.strip
  end
  method, path, = request_line.split(" ")
  status, body, extra = route(method, path, headers)
  head = ["HTTP/1.1 #{status} Fixture", "Content-Type: application/json",
          "Content-Length: #{body.bytesize}", "Connection: close"]
  head.concat(extra.map { |field, value| "#{field}: #{value}" })
  connection.write("#{head.join("\r\n")}\r\n\r\n#{body}")
rescue OpenSSL::SSL::SSLError, SystemCallError, IOError
  nil
ensure
  connection.close unless connection.closed?
end

$stdout.sync = true
puts JSON.generate(port: tcp.addr[1], fingerprint: OpenSSL::Digest::SHA256.hexdigest(certificate.to_der))
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
  Thread.new(connection) { |client| serve(client) }
end
