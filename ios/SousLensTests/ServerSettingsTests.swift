import Foundation
import XCTest
@testable import SousLens

@MainActor
final class ServerSettingsTests: XCTestCase {
    func testValidation() {
        for bad in ["", "   ", "localhost:8000", "ftp://host", "not a url", "http://", "://x", "192.168.1.5:8000"] {
            XCTAssertNil(ServerSettings.validate(bad), "should reject \(bad.debugDescription)")
        }
        XCTAssertEqual(ServerSettings.validate("http://192.168.1.5:8000/")?.absoluteString, "http://192.168.1.5:8000")
        XCTAssertEqual(ServerSettings.validate(" https://api.example.com ")?.absoluteString, "https://api.example.com")
    }

    func testInvalidTextIsFlaggedAndDefaultIsLocalhostOnSimulator() {
        let defaults = freshDefaults()
        let settings = ServerSettings(defaults: defaults)
        #if targetEnvironment(simulator)
        XCTAssertEqual(ServerSettings.platformDefault, "http://localhost:8000")
        XCTAssertEqual(settings.effectiveBaseURLString, "http://localhost:8000")
        XCTAssertEqual(UserDefaultsBaseURLProvider(defaults: defaults).baseURL?.absoluteString, "http://localhost:8000")
        #endif
        XCTAssertTrue(settings.isValid)
        settings.baseURLText = "nonsense"
        XCTAssertFalse(settings.isValid)
        settings.baseURLText = "http://10.0.0.2:8000"
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(UserDefaultsBaseURLProvider(defaults: defaults).baseURL?.absoluteString, "http://10.0.0.2:8000")
        settings.resetToDefault()
        XCTAssertEqual(settings.effectiveBaseURLString, ServerSettings.platformDefault)
        // Empty text falls back to the platform default.
        settings.baseURLText = "   "
        XCTAssertEqual(settings.effectiveBaseURLString, ServerSettings.platformDefault)
    }

    func testChangeHookFiresOnlyWhenEffectiveURLChanges() {
        let settings = ServerSettings(defaults: freshDefaults())
        var changes: [(String, String)] = []
        settings.onEffectiveBaseURLChanged = { old, new in changes.append((old, new)) }

        settings.baseURLText = "http://10.0.0.2:8000"
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.last?.1, "http://10.0.0.2:8000")

        settings.baseURLText = "http://10.0.0.2:8000"   // same value: no change
        XCTAssertEqual(changes.count, 1)

        settings.baseURLText = "  http://10.0.0.2:8000  "   // whitespace only: effective URL unchanged
        XCTAssertEqual(changes.count, 1)

        settings.baseURLText = ""   // back to platform default
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.last?.1, ServerSettings.platformDefault)
    }

    func testChangingServerWhileSignedInSignsOutAndClearsCaches() async throws {
        let defaults = freshDefaults()
        let tokenStore = InMemoryTokenStore()
        let cache = InMemoryRecipeCache()
        let client = APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: UserDefaultsBaseURLProvider(defaults: defaults),
            tokenProvider: tokenStore
        )
        let auth = AuthStore(api: client, tokenStore: tokenStore, defaults: defaults, recipeCache: cache)
        let settings = ServerSettings(defaults: defaults)
        AppEnvironment.bind(api: client, auth: auth, settings: settings, recipeCache: cache)

        AuthFixtures.installHappyPath()
        try await auth.requestCode(email: "a@b.co")
        try await auth.verify(challengeId: "chal-1", code: "123456")
        try cache.save([])
        XCTAssertTrue(auth.isSignedIn)

        settings.baseURLText = "http://10.0.0.9:8000"

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(tokenStore.currentToken())
        XCTAssertNil(defaults.data(forKey: AuthStore.cachedUserKey))
        XCTAssertNil(cache.load())
        XCTAssertEqual(try XCTUnwrap(auth.banner), "Server changed to http://10.0.0.9:8000. Sign in again.")
    }

    func testChangingServerOnCodeStepCancelsPendingChallenge() async throws {
        let defaults = freshDefaults()
        let tokenStore = InMemoryTokenStore()
        let cache = InMemoryRecipeCache()
        let client = APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: UserDefaultsBaseURLProvider(defaults: defaults),
            tokenProvider: tokenStore
        )
        let auth = AuthStore(api: client, tokenStore: tokenStore, defaults: defaults, recipeCache: cache)
        let settings = ServerSettings(defaults: defaults)
        AppEnvironment.bind(api: client, auth: auth, settings: settings, recipeCache: cache)
        await auth.restore()

        AuthFixtures.installHappyPath()
        try await auth.requestCode(email: "a@b.co")
        XCTAssertNotNil(auth.pendingChallenge, "on the code step")

        settings.baseURLText = "http://10.0.0.9:8000"

        XCTAssertNil(auth.pendingChallenge, "a challenge issued by the old server is dropped")
        XCTAssertNil(auth.pendingEmail, "back on the email step")
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(auth.banner, "never signed in, so no sign-out banner")
    }

    func testChangingServerWhileSignedOutOnlyClearsRecipeCache() throws {
        let defaults = freshDefaults()
        let tokenStore = InMemoryTokenStore()
        let cache = InMemoryRecipeCache()
        let client = APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: UserDefaultsBaseURLProvider(defaults: defaults),
            tokenProvider: tokenStore
        )
        let auth = AuthStore(api: client, tokenStore: tokenStore, defaults: defaults, recipeCache: cache)
        let settings = ServerSettings(defaults: defaults)
        AppEnvironment.bind(api: client, auth: auth, settings: settings, recipeCache: cache)
        try cache.save([])
        // A token can linger while signed out (e.g. restore() failed on a network error).
        try tokenStore.save(token: "stale-token-for-old-server")

        settings.baseURLText = "http://10.0.0.9:8000"
        XCTAssertNil(cache.load())
        XCTAssertEqual(cache.clearCount, 1)
        XCTAssertNil(tokenStore.currentToken(), "a stale token must never reach the new server")
        XCTAssertNil(auth.banner, "nothing to sign out of")
    }
}
