import XCTest
@testable import UniFiDesktop

final class FormatTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T17:00:00Z")!

    func testShortDateLeavesOutTheCurrentYear() {
        let text = Format.shortDate("2026-06-15T12:00:00Z", now: now)
        XCTAssertFalse(text.contains("2026"), text)
        XCTAssertTrue(text.contains("15"), text)
    }

    func testShortDateKeepsOtherYears() {
        XCTAssertTrue(Format.shortDate("2025-06-15T12:00:00.250Z", now: now).contains("2025"))
    }

    func testShortDateShowsMissingAndUnreadableValuesAsGiven() {
        XCTAssertEqual(Format.shortDate(nil, now: now), "—")
        XCTAssertEqual(Format.shortDate("soon", now: now), "soon")
    }
}
