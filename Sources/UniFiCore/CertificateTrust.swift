import CryptoKit
import Foundation
import Security

public struct CertificateFingerprint: Hashable, Sendable {
    public let hex: String

    public init?(hex value: String) {
        let compact = value.filter { $0 != ":" && !$0.isWhitespace }.lowercased()
        guard compact.count == 64, compact.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        hex = compact
    }

    public init(certificateData: Data) {
        hex = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
    }

    // Matches the form shown by browsers and `openssl x509 -noout -fingerprint -sha256`.
    public var display: String {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return hex[start..<hex.index(start, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
    }
}

public struct PresentedCertificate: Equatable, Sendable {
    public let fingerprint: CertificateFingerprint
    public let subject: String?

    public init(fingerprint: CertificateFingerprint, subject: String?) {
        self.fingerprint = fingerprint
        self.subject = subject
    }

    init?(trust: SecTrust) {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        self.init(
            fingerprint: CertificateFingerprint(certificateData: SecCertificateCopyData(leaf) as Data),
            subject: SecCertificateCopySubjectSummary(leaf) as String?
        )
    }
}

// A certificate macOS does not trust is accepted only when it is exactly the one the user
// explicitly trusted for this controller. Anything else fails closed.
public enum CertificateTrust {
    public enum Decision: Equatable, Sendable {
        case systemTrusted
        case userTrusted
        case untrusted
        case changed(previouslyTrusted: CertificateFingerprint)
    }

    public static func decide(
        systemTrusted: Bool,
        presented: CertificateFingerprint,
        trusted: CertificateFingerprint?
    ) -> Decision {
        if systemTrusted { return .systemTrusted }
        guard let trusted else { return .untrusted }
        return presented == trusted ? .userTrusted : .changed(previouslyTrusted: trusted)
    }
}
