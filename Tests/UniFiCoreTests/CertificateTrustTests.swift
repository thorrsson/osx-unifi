import Foundation
import XCTest
@testable import UniFiCore

final class CertificateTrustPolicyTests: XCTestCase {
    private let first = CertificateFingerprint(hex: String(repeating: "ab", count: 32))!
    private let second = CertificateFingerprint(hex: String(repeating: "cd", count: 32))!

    func testFingerprintParsingNormalizesAndRejectsMalformedValues() throws {
        let colonSeparated = (0..<32).map { _ in "AB" }.joined(separator: ":")
        XCTAssertEqual(CertificateFingerprint(hex: colonSeparated), first)
        XCTAssertEqual(CertificateFingerprint(hex: " \(String(repeating: "AB", count: 32))\n"), first)
        XCTAssertEqual(first.display, colonSeparated)
        XCTAssertEqual(first.hex, String(repeating: "ab", count: 32))
        for invalid in [
            "", "abcd", String(repeating: "ab", count: 31), String(repeating: "ab", count: 33),
            String(repeating: "zz", count: 32), String(repeating: "ａｂ", count: 32)
        ] {
            XCTAssertNil(CertificateFingerprint(hex: invalid), invalid)
        }
    }

    func testFingerprintIsSHA256OfCertificateBytes() {
        XCTAssertEqual(
            CertificateFingerprint(certificateData: Data()).hex,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testTrustDecisionFailsClosedUnlessSystemOrUserTrusted() {
        XCTAssertEqual(CertificateTrust.decide(systemTrusted: true, presented: first, trusted: nil), .systemTrusted)
        XCTAssertEqual(CertificateTrust.decide(systemTrusted: true, presented: first, trusted: second), .systemTrusted)
        XCTAssertEqual(CertificateTrust.decide(systemTrusted: false, presented: first, trusted: first), .userTrusted)
        XCTAssertEqual(CertificateTrust.decide(systemTrusted: false, presented: first, trusted: nil), .untrusted)
        XCTAssertEqual(
            CertificateTrust.decide(systemTrusted: false, presented: first, trusted: second),
            .changed(previouslyTrusted: second)
        )
    }
}

// Exercises real TLS handshakes against a throwaway self-signed HTTPS server.
final class LocalTransportCertificateTests: XCTestCase {
    private final class Fixture {
        let port: Int
        let fingerprint: CertificateFingerprint
        private let process = Process()
        private let input = Pipe()

        init() throws {
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Scripts/tests/tls_fixture.rb")
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ruby", script.path]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            var buffer = Data()
            while !buffer.contains(UInt8(ascii: "\n")) {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else {
                    process.terminate()
                    throw URLError(.cannotConnectToHost)
                }
                buffer.append(chunk)
            }
            let line = try XCTUnwrap(buffer.split(separator: UInt8(ascii: "\n")).first)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            port = try XCTUnwrap(object["port"] as? Int)
            fingerprint = try XCTUnwrap(CertificateFingerprint(hex: try XCTUnwrap(object["fingerprint"] as? String)))
        }

        func stop() {
            try? input.fileHandleForWriting.close()
            process.terminate()
            process.waitUntilExit()
        }

        var controller: Controller { get throws { try Controller("https://127.0.0.1:\(port)") } }

        func request(_ path: String) throws -> URLRequest {
            var request = URLRequest(url: try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)/\(path)")))
            request.setValue("fixture-key", forHTTPHeaderField: "X-API-Key")
            return request
        }
    }

    private var fixture: Fixture!

    override func setUpWithError() throws { fixture = try Fixture() }
    override func tearDown() { fixture.stop() }

    func testSelfSignedControllerIsRejectedWithItsFingerprintForReview() async throws {
        let api = try IntegrationV1API(controller: fixture.controller, apiKey: "fixture-key")
        do {
            _ = try await api.info()
            XCTFail("An untrusted certificate must not connect.")
        } catch NetworkAPIError.untrustedCertificate(let presented) {
            XCTAssertEqual(presented.fingerprint, fixture.fingerprint)
            XCTAssertEqual(presented.subject, "UniFi Desktop Test Controller")
        }
    }

    func testExplicitlyTrustedCertificateConnectsAndSendsTheKey() async throws {
        let api = try IntegrationV1API(
            controller: fixture.controller, apiKey: "fixture-key", trustedCertificate: fixture.fingerprint
        )
        let info = try await api.info()
        XCTAssertEqual(info.applicationVersion, "10.6.106")
    }

    func testDifferentCertificateThanTheTrustedOneIsRejectedAsChanged() async throws {
        let other = try XCTUnwrap(CertificateFingerprint(hex: String(repeating: "ab", count: 32)))
        let api = try IntegrationV1API(
            controller: fixture.controller, apiKey: "fixture-key", trustedCertificate: other
        )
        do {
            _ = try await api.info()
            XCTFail("A changed certificate must not connect.")
        } catch NetworkAPIError.changedCertificate(let presented, let trusted) {
            XCTAssertEqual(presented.fingerprint, fixture.fingerprint)
            XCTAssertEqual(trusted, other)
        }
    }

    func testPinnedControllerServesTheInventoryOverRealTLS() async throws {
        let api = try IntegrationV1API(
            controller: fixture.controller, apiKey: "fixture-key", trustedCertificate: fixture.fingerprint
        )
        let sites = try await api.sites()
        XCTAssertEqual(sites.map(\.name), ["Fixture Site"])
        let site = try XCTUnwrap(sites.first)
        let devices = try await api.devices(siteID: site.id)
        XCTAssertEqual(devices.map(\.name), ["Fixture Gateway"])
        XCTAssertEqual(devices.map(\.model), ["UDM Pro"])
        let clients = try await api.clients(siteID: site.id)
        XCTAssertEqual(clients.map(\.name), ["Fixture Laptop"])
    }

    func testRejectedKeyOverTrustedTLSIsReportedAsAuthenticationFailure() async throws {
        let api = try IntegrationV1API(
            controller: fixture.controller, apiKey: "wrong-key", trustedCertificate: fixture.fingerprint
        )
        do {
            _ = try await api.sites()
            XCTFail("A rejected key must not look like an empty inventory.")
        } catch NetworkAPIError.authentication {}
    }

    func testRedirectsAreNotFollowedEvenForATrustedController() async throws {
        let transport = LocalTransport(trustedCertificate: fixture.fingerprint)
        let (_, response) = try await transport.data(for: fixture.request("redirect"))
        XCTAssertEqual(response.statusCode, 302)
    }

    func testRejectedCertificateDoesNotLeakIntoLaterRequests() async throws {
        let rejected = LocalTransport()
        do {
            _ = try await rejected.data(for: fixture.request("proxy/network/integration/v1/info"))
            XCTFail("An untrusted certificate must not connect.")
        } catch NetworkAPIError.untrustedCertificate {}
        let trusted = LocalTransport(trustedCertificate: fixture.fingerprint)
        let (_, response) = try await trusted.data(for: fixture.request("proxy/network/integration/v1/info"))
        XCTAssertEqual(response.statusCode, 200)
    }
}
