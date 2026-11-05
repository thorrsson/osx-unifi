import SwiftUI
import UniFiCore

struct CertificateTrustSheet: View {
    let request: CertificateTrustRequest
    let onTrust: () -> Void
    let onCancel: () -> Void

    private var isChange: Bool { request.previous != nil }

    private var explanation: String {
        if isChange {
            return "The certificate this controller presents is different from the one you trusted. This is expected if the controller regenerated its certificate, but it can also mean someone is intercepting the connection. Continue only if you expect the change."
        }
        return "macOS does not trust the certificate this controller presented. That is normal for a UniFi console using its built-in certificate. Your API key is sent only after you trust this exact certificate, and the app asks again if the certificate ever changes."
    }

    // Two fixed lines of 16 bytes are easier to compare than an arbitrary soft wrap.
    private static func twoLines(_ fingerprint: CertificateFingerprint) -> String {
        let bytes = fingerprint.display.split(separator: ":")
        return [bytes.prefix(16), bytes.suffix(16)]
            .map { $0.joined(separator: ":") }
            .joined(separator: "\n")
    }

    private var verifyCommand: String? {
        guard let url = URL(string: request.origin), let host = url.host else { return nil }
        let target = host.contains(":") ? "[\(host)]" : host
        return "echo | openssl s_client -connect \(target):\(url.port ?? 443) 2>/dev/null | openssl x509 -noout -fingerprint -sha256"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isChange ? "exclamationmark.triangle.fill" : "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(isChange ? Color.red : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(isChange ? "The controller's certificate changed" : "Trust this controller's certificate?")
                        .font(.headline)
                    Text(explanation)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                detail("Controller", request.origin)
                detail("Certificate", request.presented.subject ?? "Not reported")
                detail(isChange ? "New SHA-256" : "SHA-256", Self.twoLines(request.presented.fingerprint), monospaced: true)
                if let previous = request.previous {
                    detail("Trusted SHA-256", Self.twoLines(previous), monospaced: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("To verify independently, run this in Terminal and compare the fingerprints:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = verifyCommand {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                if isChange {
                    Button("Trust New Certificate", role: .destructive, action: onTrust)
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Trust and Connect", action: onTrust)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func detail(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
