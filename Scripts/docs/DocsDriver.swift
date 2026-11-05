// Drives a running copy of UniFi Desktop through the documentation tour using the macOS
// Accessibility API, taking window screenshots along the way. Scripts/docs/capture.rb builds
// and runs it against the fictional demo controller; it is not part of the app.
//
// Usage:
//   docs-driver place <bundle-id>                       Size and centre the window, print its frame.
//   docs-driver tour <bundle-id> <address> <key> <dir>   Run the tour, writing PNGs into <dir>.
//   docs-driver dump <bundle-id>                        Print the window's accessibility tree.
//   docs-driver connect|sidebar|click <bundle-id> ...   Single steps, for debugging the tour.
//   docs-driver quit <bundle-id>                        Quit the app.

import AppKit
import ApplicationServices

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func pause(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func waitFor<T>(_ what: String, timeout: TimeInterval = 15, _ probe: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let value = probe() { return value }
        pause(0.15)
    } while Date() < deadline
    throw DriverError("Timed out waiting for \(what)")
}

// MARK: - Accessibility helpers

extension AXUIElement {
    func raw(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    func string(_ name: String) -> String? { raw(name) as? String }
    var role: String { string(kAXRoleAttribute) ?? "" }
    var subrole: String { string(kAXSubroleAttribute) ?? "" }
    var children: [AXUIElement] { (raw(kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    var parent: AXUIElement? {
        guard let value = raw(kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Every human-readable name SwiftUI may expose for a control.
    var names: [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute]
            .compactMap { string($0) }
    }

    var frame: CGRect? {
        guard let position = raw(kAXPositionAttribute), let size = raw(kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    func set(_ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    func hasAncestor(role wanted: Set<String>) -> Bool {
        var node = parent
        while let current = node {
            if wanted.contains(current.role) { return true }
            node = current.parent
        }
        return false
    }

    func all(depth: Int = 60, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(self, 0)]
        while !queue.isEmpty {
            let (node, level) = queue.removeFirst()
            if match(node) { found.append(node) }
            if level < depth { queue.append(contentsOf: node.children.map { ($0, level + 1) }) }
        }
        return found
    }

    func dump(indent: Int = 0, limit: Int = 30) {
        let names = names.map { "\"\($0.prefix(60))\"" }.joined(separator: " ")
        print(String(repeating: "  ", count: indent) + "\(role)\(subrole.isEmpty ? "" : "/\(subrole)") \(names)")
        if indent < limit { children.forEach { $0.dump(indent: indent + 1, limit: limit) } }
    }
}

// MARK: - Input

enum Input {
    static func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Eased cursor movement so the screencast is easy to follow.
    static func move(to target: CGPoint, duration: TimeInterval = 0.45) {
        let start = location
        let steps = max(Int(duration * 60), 1)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let point = CGPoint(x: start.x + (target.x - start.x) * eased, y: start.y + (target.y - start.y) * eased)
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
            usleep(useconds_t(duration / Double(steps) * 1_000_000))
        }
    }

    static func click(at point: CGPoint) {
        move(to: point)
        usleep(80_000)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
        usleep(60_000)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        post(down)
        usleep(30_000)
        post(up)
        usleep(60_000)
    }

    static func type(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event)
            }
            usleep(55_000)
        }
    }

    static func selectAll() { key(0, flags: .maskCommand) }
}

// MARK: - App driver

final class Driver {
    let bundleID: String
    let output: URL?
    let app: NSRunningApplication
    let root: AXUIElement

    init(bundleID: String, output: URL? = nil) throws {
        self.bundleID = bundleID
        self.output = output
        app = try waitFor("\(bundleID) to launch", timeout: 30) {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 5)
    }

    func window() throws -> AXUIElement {
        try waitFor("the main window", timeout: 30) {
            ((root.raw(kAXWindowsAttribute) as? [AXUIElement]) ?? []).first { $0.subrole == kAXStandardWindowSubrole }
        }
    }

    func activate() {
        app.activate()
        pause(0.4)
    }

    func place() throws -> CGRect {
        let window = try window()
        let size = CGSize(width: 1280, height: 820)
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var origin = CGPoint(x: ((screen.width - size.width) / 2).rounded(), y: ((screen.height - size.height) / 2).rounded())
        var extent = size
        window.set(kAXPositionAttribute, AXValueCreate(.cgPoint, &origin)!)
        window.set(kAXSizeAttribute, AXValueCreate(.cgSize, &extent)!)
        pause(0.5)
        return window.frame ?? CGRect(origin: origin, size: size)
    }

    // MARK: Finding

    func find(_ name: String, role: String? = nil, in scope: AXUIElement? = nil, timeout: TimeInterval = 15,
              filter: (AXUIElement) -> Bool = { _ in true }) throws -> AXUIElement {
        try waitFor("“\(name)”\(role.map { " (\($0))" } ?? "")", timeout: timeout) {
            let base = (scope ?? (try? window())) ?? root
            return base.all { element in
                (role == nil || element.role == role) && element.names.contains(name) && filter(element)
            }
            .filter { ($0.frame?.width ?? 0) > 0 }
            .first
        }
    }

    func sheet(containing name: String, timeout: TimeInterval = 15) throws -> AXUIElement {
        try waitFor("a sheet containing “\(name)”", timeout: timeout) {
            guard let window = try? window() else { return nil }
            return window.children.first { sheet in
                sheet.role == kAXSheetRole && !sheet.all { $0.names.contains(name) }.isEmpty
            }
        }
    }

    /// Clicks a button that presents a sheet, retrying once if the first click didn't land.
    func presentSheet(with button: String, containing name: String) throws -> AXUIElement {
        try click(button, role: kAXButtonRole)
        if let presented = try? sheet(containing: name, timeout: 5) { return presented }
        FileHandle.standardError.write(Data("docs-driver: “\(button)” didn't present a sheet; clicking again\n".utf8))
        activate()
        try click(button, role: kAXButtonRole)
        return try sheet(containing: name)
    }

    func waitForSheetToClose() throws {
        _ = try waitFor("the sheet to close") { (try? window())?.children.contains { $0.role == kAXSheetRole } == false ? true : nil }
    }

    /// Waits for a change confirmation to dismiss itself so it doesn't appear on later pages.
    func waitForConfirmationToClear(_ text: String) throws {
        _ = try waitFor("“\(text)” to clear", timeout: 15) {
            (try? window())?.all { $0.names.contains(text) && ($0.frame?.width ?? 0) > 0 }.isEmpty == true ? true : nil
        }
    }

    /// Waits until no progress indicators remain, so screenshots show loaded content.
    func settle(_ extra: TimeInterval = 0.6) throws {
        var quietSince: Date?
        _ = try waitFor("the console to finish loading", timeout: 20) { () -> Bool? in
            guard let window = try? window() else { return nil }
            let busy = !window.all {
                [kAXProgressIndicatorRole, kAXBusyIndicatorRole].contains($0.role) && ($0.frame?.width ?? 0) > 0
            }.isEmpty
            if busy { quietSince = nil; return nil }
            if quietSince == nil { quietSince = Date() }
            return Date().timeIntervalSince(quietSince!) > 0.5 ? true : nil
        }
        pause(extra)
    }

    // MARK: Acting

    func click(_ element: AXUIElement) throws {
        guard let frame = element.frame else { throw DriverError("Element has no frame") }
        Input.click(at: CGPoint(x: frame.midX, y: frame.midY))
        pause(0.25)
    }

    func click(_ name: String, role: String? = nil, in scope: AXUIElement? = nil) throws {
        try click(find(name, role: role, in: scope))
    }

    /// SwiftUI exposes both the sidebar and tables as outlines; the sidebar is the leftmost one.
    func sidebarOutline() throws -> AXUIElement {
        try waitFor("the sidebar") {
            (try? window())?.all { $0.role == kAXOutlineRole && $0.frame != nil }
                .min { $0.frame!.minX < $1.frame!.minX }
        }
    }

    func sidebar(_ title: String) throws {
        try click(find(title, role: kAXStaticTextRole, in: sidebarOutline()))
        try settle()
    }

    func row(_ title: String) throws {
        let edge = try sidebarOutline().frame?.maxX ?? 0
        let cell = try find(title, role: kAXStaticTextRole) { $0.hasAncestor(role: [kAXRowRole]) && ($0.frame?.minX ?? 0) > edge }
        try click(cell)
    }

    func replaceText(of field: AXUIElement, with text: String) throws {
        try click(field)
        Input.selectAll()
        Input.type(text)
        pause(0.3)
    }

    // MARK: Screenshots

    func shot(_ name: String, of element: AXUIElement? = nil) throws {
        guard let output else { return }
        let target = try element ?? window()
        guard let frame = target.frame else { throw DriverError("Cannot locate \(name) for a screenshot") }
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let candidates = info.compactMap { entry -> (Int, CGRect)? in
            guard (entry[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (number, rect)
        }
        func distance(_ rect: CGRect) -> CGFloat {
            abs(rect.minX - frame.minX) + abs(rect.minY - frame.minY) + abs(rect.width - frame.width) + abs(rect.height - frame.height)
        }
        guard let number = candidates.min(by: { distance($0.1) < distance($1.1) })?.0 else {
            throw DriverError("No on-screen window for \(name)")
        }
        let path = output.appendingPathComponent("\(name).png").path
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-o", "-x", "-l", String(number), path]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw DriverError("screencapture failed for \(name)") }
        print("captured \(name)")
    }

    // MARK: Tour

    func connect(address: String, key: String, capture: Bool) throws {
        activate()
        let addressField = try find("https://192.168.1.1", role: kAXTextFieldRole)
        if capture { try shot("connect") }
        try replaceText(of: addressField, with: address)
        let keyField = try find("Leave blank to use the key saved in Keychain")
        try replaceText(of: keyField, with: key)
        pause(0.5)
        try click("Connect", role: kAXButtonRole)

        let review = try sheet(containing: "Trust and Connect")
        pause(1.2)
        if capture { try shot("certificate", of: review) }
        try click("Trust and Connect", role: kAXButtonRole, in: review)
        try waitForSheetToClose()
        _ = try find("UniFi Devices", role: kAXStaticTextRole, in: sidebarOutline(), timeout: 20)
        try settle(1.5)
    }

    func tour(address: String, key: String) throws {
        try connect(address: address, key: key, capture: true)
        try shot("dashboard")

        try sidebar("UniFi Devices")
        pause(0.8)
        try row("Harbor Gateway")
        _ = try find("Close", role: kAXButtonRole)
        try settle(1.5)
        try shot("devices")

        try sidebar("Client Devices")
        pause(0.8)
        try row("Visitor Laptop")
        _ = try find("Close", role: kAXButtonRole)
        try settle(1.5)
        try shot("clients")

        try sidebar("Networks")
        pause(1.0)
        try shot("networks")
        try row("IoT")
        let name = try find("IoT", role: kAXTextFieldRole)
        try settle(1.0)
        try shot("network-editor")
        try replaceText(of: name, with: "Smart Home")
        pause(0.6)
        try click("Apply Changes", role: kAXButtonRole)
        _ = try find("Smart Home", role: kAXStaticTextRole) { $0.hasAncestor(role: [kAXRowRole]) }
        try settle(1.2)

        try sidebar("WiFi")
        pause(0.8)
        try click("Enable Harbor Lab")
        try settle(1.2)
        try shot("wifi")
        try row("Harbor")
        _ = try find("Harbor", role: kAXTextFieldRole)
        try settle(1.0)
        try shot("wifi-editor")
        try click("Cancel", role: kAXButtonRole)
        pause(0.6)
        try waitForConfirmationToClear("Enabled WiFi network Harbor Lab.")

        try sidebar("Firewall")
        pause(1.0)
        try shot("firewall")
        try row("Block IoT to Internal")
        _ = try find("Block IoT to Internal", role: kAXTextFieldRole)
        try settle(1.0)
        try shot("firewall-policy")
        try click("Cancel", role: kAXButtonRole)
        pause(0.6)
        try click("Zones")
        try settle(1.2)
        try shot("firewall-zones")
        try click("Policies")
        pause(0.4)

        try sidebar("DNS")
        pause(1.0)
        try shot("dns")

        try sidebar("Hotspot")
        pause(0.8)
        let form = try presentSheet(with: "Create Vouchers", containing: "Quantity")
        pause(0.6)
        try replaceText(of: find("Guest", role: kAXTextFieldRole, in: form), with: "Saturday BBQ")
        try replaceText(of: find("Quantity", role: kAXTextFieldRole, in: form), with: "6")
        pause(0.6)
        try shot("voucher-form", of: form)
        try click("Create", role: kAXButtonRole, in: form)
        let created = try sheet(containing: "Copy All")
        pause(1.5)
        try shot("vouchers-created", of: created)
        try click("Done", role: kAXButtonRole, in: created)
        try waitForSheetToClose()
        try settle(1.2)
        try shot("hotspot")

        try sidebar("Dashboard")
        pause(2.0)
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments.dropFirst()
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Grant Accessibility access to this terminal in System Settings > Privacy & Security.\n".utf8))
    exit(2)
}

do {
    switch (arguments.first, arguments.count) {
    case ("place", 2):
        let frame = try Driver(bundleID: arguments[arguments.startIndex + 1]).place()
        print("\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
    case ("tour", 5):
        let values = Array(arguments)
        try Driver(bundleID: values[1], output: URL(fileURLWithPath: values[4], isDirectory: true)).tour(address: values[2], key: values[3])
    case ("connect", 4):
        let values = Array(arguments)
        try Driver(bundleID: values[1]).connect(address: values[2], key: values[3], capture: false)
    case ("sidebar", 3), ("click", 3), ("press", 3):
        let values = Array(arguments)
        let driver = try Driver(bundleID: values[1])
        driver.activate()
        switch values[0] {
        case "sidebar": try driver.sidebar(values[2])
        case "click": try driver.click(values[2])
        default:
            let error = AXUIElementPerformAction(try driver.find(values[2], role: kAXButtonRole), kAXPressAction as CFString)
            print("AXPress:", error.rawValue)
        }
    case ("dump", 2):
        try Driver(bundleID: arguments[arguments.startIndex + 1]).window().dump()
    case ("quit", 2):
        NSRunningApplication.runningApplications(withBundleIdentifier: arguments[arguments.startIndex + 1]).forEach { $0.terminate() }
    default:
        FileHandle.standardError.write(Data("usage: docs-driver place|tour|dump|quit <bundle-id> [address key output-dir]\n".utf8))
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("docs-driver: \(error)\n".utf8))
    exit(1)
}
