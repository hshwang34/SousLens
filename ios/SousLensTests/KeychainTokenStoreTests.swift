import Foundation
import XCTest
import Security
@testable import SousLens

final class KeychainTokenStoreTests: XCTestCase {
    private var store = KeychainTokenStore(service: "com.souslens.ios.tests.\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try store.clear()
    }

    /// `errSecMissingEntitlement` means the host app was built unsigned (e.g. `CODE_SIGNING_ALLOWED=NO`);
    /// the simulator Keychain needs the ad-hoc-signed host that `make ios-check` produces.
    private func check<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch KeychainError.unexpectedStatus(let status) where status == errSecMissingEntitlement {
            XCTFail("Keychain returned errSecMissingEntitlement: the test host must be signed (run `make ios-check`, which uses CODE_SIGN_IDENTITY=-).")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func testRoundTrip() throws {
        XCTAssertNil(store.currentToken())
        try check { try store.save(token: "first.jwt") }
        XCTAssertEqual(store.currentToken(), "first.jwt")
        try store.save(token: "second.jwt")
        XCTAssertEqual(store.currentToken(), "second.jwt", "save must overwrite an existing item")
        try store.clear()
        XCTAssertNil(store.currentToken())
        try store.clear() // idempotent
    }

    func testQueryDisablesICloudSync() {
        XCTAssertEqual(store.baseQuery[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(store.baseQuery[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    func testSavedItemIsNotSynchronizableAndUsesThisDeviceOnlyAccessibility() throws {
        try check { try store.save(token: "jwt") }
        let attributes = try storedAttributes()
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let synchronizable = attributes[kSecAttrSynchronizable as String]
        XCTAssertTrue(synchronizable == nil || (synchronizable as? Bool) == false || (synchronizable as? Int) == 0,
                      "sync attribute must be absent or false, got \(String(describing: synchronizable))")
    }

    func testUpdateReappliesAccessibility() throws {
        // Simulate an item written by an older build with a weaker accessibility class.
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: store.account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecValueData as String: Data("old".utf8),
        ]
        let added = SecItemAdd(legacy as CFDictionary, nil)
        if added == errSecMissingEntitlement {
            XCTFail("test host must be signed (run `make ios-check`)")
            return
        }
        XCTAssertEqual(added, errSecSuccess)
        XCTAssertEqual(try storedAttributes()[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlocked as String)

        try store.save(token: "new")   // hits the errSecDuplicateItem → SecItemUpdate path

        XCTAssertEqual(store.currentToken(), "new")
        XCTAssertEqual(try storedAttributes()[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    private func storedAttributes() throws -> [String: Any] {
        var query = store.baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(result as? [String: Any])
    }

    func testServicesAreIsolated() throws {
        let other = KeychainTokenStore(service: "com.souslens.ios.tests.\(UUID().uuidString)")
        defer { try? other.clear() }
        try check { try store.save(token: "mine") }
        XCTAssertNil(other.currentToken())
    }
}
