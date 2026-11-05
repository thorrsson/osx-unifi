import SwiftUI
import UniFiCore

/// Visual language modeled on the UniFi console: dark surfaces, blue accent, compact status pills.
enum Theme {
    static let background = Color(hex: 0x131417)
    static let sidebar = Color(hex: 0x1A1B1F)
    static let card = Color(hex: 0x1F2126)
    static let raised = Color(hex: 0x272A30)
    static let border = Color.white.opacity(0.07)
    static let accent = Color(hex: 0x006FFF)
    static let link = Color(hex: 0x4797FF)
    static let green = Color(hex: 0x38CC65)
    static let warning = Color(hex: 0xF5A623)
    static let red = Color(hex: 0xEE4B4B)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.42)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.secondary

    init(_ text: String, color: Color = Theme.secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct StatusLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

enum Status {
    static func device(_ state: String) -> (String, Color) {
        let label = state.replacingOccurrences(of: "_", with: " ").capitalized
        switch state {
        case "ONLINE": return ("Online", Theme.green)
        case "OFFLINE", "CONNECTION_INTERRUPTED", "ISOLATED", "U5G_INCORRECT_TOPOLOGY": return (label, Theme.red)
        default: return (label, Theme.warning)
        }
    }

    static func origin(_ metadata: EntityMetadata) -> Pill {
        Pill(metadata.label, color: metadata.isUserDefined ? Theme.link : Theme.secondary)
    }

    static func action(_ type: String) -> Pill {
        switch type {
        case "ALLOW": return Pill("Allow", color: Theme.green)
        case "REJECT": return Pill("Reject", color: Theme.warning)
        default: return Pill(type.capitalized, color: Theme.red)
        }
    }
}

enum DeviceIcon {
    static func name(for device: Device) -> String {
        if device.isGateway { return "server.rack" }
        if device.isAccessPoint { return "wifi" }
        if device.isSwitch { return "rectangle.split.3x1" }
        return "shippingbox"
    }
}

extension EntityMetadata {
    /// Derived and orchestrated items are managed by the controller itself.
    var isControllerManaged: Bool { origin == "DERIVED" || origin == "ORCHESTRATED" }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

enum Format {
    static func duration(seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }

    static func minutes(_ minutes: Int) -> String { duration(seconds: minutes * 60) }

    static func bitsPerSecond(_ bps: Int?) -> String {
        guard let bps else { return "—" }
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var value = Double(bps)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return "\(value.formatted(.number.precision(.fractionLength(index == 0 ? 0 : 1)))) \(units[index])"
    }

    static func speed(mbps: Int?) -> String {
        guard let mbps, mbps > 0 else { return "—" }
        return mbps >= 1000 ? "\((Double(mbps) / 1000).formatted()) GbE" : "\(mbps) MbE"
    }

    static func date(_ iso: String?) -> String {
        guard let iso else { return "—" }
        return parse(iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }

    /// A table-friendly date that leaves out the year when it's the current one.
    static func shortDate(_ iso: String?, now: Date = Date()) -> String {
        guard let iso else { return "—" }
        guard let date = parse(iso) else { return iso }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? style : style.year())
    }

    private static func parse(_ iso: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0))))%"
    }
}
