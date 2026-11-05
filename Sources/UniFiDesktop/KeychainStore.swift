import Foundation
import Security

protocol CredentialStore {
    func read(account: String) throws -> String?
    func save(_ key: String, account: String) throws
    func delete(account: String) throws
}

struct KeychainStore: CredentialStore {
    static let apiKeyService = "com.thorrsson.osx-unifi.local-network-api"
    static let certificateService = "com.thorrsson.osx-unifi.trusted-certificate"

    private let service: String

    init(service: String = KeychainStore.apiKeyService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func read(account: String) throws -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return key
    }

    func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query(account)
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(newItem as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        switch status {
        case errSecAuthFailed:
            return "macOS could not authorize access to the saved Keychain item (\(status)). If prompted, use your Mac login/keychain password, not your UniFi API key. Unlock the login keychain in Keychain Access and try again. A rebuilt app may need its access approved again."
        case errSecInteractionNotAllowed:
            return "macOS cannot access the Keychain while it is locked or an authorization prompt is unavailable (\(status)). Unlock your Mac and the login keychain in Keychain Access, then try again."
        case errSecUserCanceled:
            return "Keychain access was canceled (\(status)). Connect again and approve the macOS Keychain prompt to use the saved credentials."
        default:
            break
        }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return "Keychain operation failed (\(status)): \(message)"
    }
}
