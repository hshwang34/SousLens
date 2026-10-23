import Foundation
import Security

/// Read side used by `APIClient`.
protocol TokenProviding: Sendable {
    func currentToken() -> String?
}

/// Full access used by `AuthStore`.
protocol TokenStore: TokenProviding {
    func save(token: String) throws
    func clear() throws
}

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case encoding
}

/// JWT storage in the iOS Keychain (Security framework, no third-party code).
/// `service` is unique per app build; tests pass a throwaway service name.
struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String

    init(service: String = "com.souslens.ios.auth", account: String = "access_token") {
        self.service = service
        self.account = account
    }

    /// Internal (not private) so tests can assert the attributes every query carries.
    var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // A session token must never ride iCloud Keychain to another device.
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    func currentToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(token: String) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.encoding }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = Self.accessibility
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Reapply accessibility so an item written by an older build is upgraded in place.
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: Self.accessibility,
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// Memory-only store for previews and tests that don't need the Keychain.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func currentToken() -> String? {
        lock.withLock { token }
    }

    func save(token: String) throws {
        lock.withLock { self.token = token }
    }

    func clear() throws {
        lock.withLock { token = nil }
    }
}
