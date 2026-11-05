import Security
import XCTest
@testable import UniFiDesktop

final class KeychainStoreTests: XCTestCase {
    func testAuthorizationFailureExplainsMacCredentialsAndRebuildAccess() {
        let message = KeychainError(status: errSecAuthFailed).localizedDescription
        XCTAssertTrue(message.contains("-25293"))
        XCTAssertTrue(message.contains("Mac login/keychain password, not your UniFi API key"))
        XCTAssertTrue(message.contains("rebuilt app"))
    }

    func testLockedKeychainExplainsHowToRetry() {
        let message = KeychainError(status: errSecInteractionNotAllowed).localizedDescription
        XCTAssertTrue(message.contains("Unlock your Mac"))
        XCTAssertTrue(message.contains("Keychain Access"))
        XCTAssertTrue(message.contains("try again"))
    }

    func testCanceledAccessIsNotReportedAsInvalidCredentials() {
        let message = KeychainError(status: errSecUserCanceled).localizedDescription
        XCTAssertTrue(message.contains("canceled"))
        XCTAssertTrue(message.contains("approve the macOS Keychain prompt"))
    }

    func testOtherErrorsRetainTheSystemStatus() {
        let message = KeychainError(status: errSecDecode).localizedDescription
        XCTAssertTrue(message.contains("Keychain operation failed (\(errSecDecode))"))
    }
}
