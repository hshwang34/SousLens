import Foundation
import XCTest
@testable import SousLens

@MainActor
final class AuthStoreTests: XCTestCase {
    private struct Harness {
        let client: APIClient
        let tokenStore: InMemoryTokenStore
        let defaults: UserDefaults
        let cache: InMemoryRecipeCache
        let auth: AuthStore
    }

    private func makeHarness(token: String? = nil, defaults: UserDefaults? = nil, bind: Bool = true) -> Harness {
        let tokenStore = InMemoryTokenStore(token: token)
        let generation = SessionGeneration()
        let defaults = defaults ?? freshDefaults()
        let cache = InMemoryRecipeCache()
        let client = APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
            tokenProvider: tokenStore,
            sessionGeneration: generation
        )
        let auth = AuthStore(api: client, tokenStore: tokenStore, defaults: defaults, recipeCache: cache, generation: generation)
        if bind {
            AppEnvironment.bind(api: client, auth: auth, settings: ServerSettings(defaults: defaults), recipeCache: cache)
        }
        return Harness(client: client, tokenStore: tokenStore, defaults: defaults, cache: cache, auth: auth)
    }

    // MARK: - Two-step dev sign-in

    func testTwoStepSignInHappyPath() async throws {
        AuthFixtures.installHappyPath()
        let h = makeHarness()
        await h.auth.restore()   // launch: no token → signed out
        XCTAssertEqual(h.auth.state, .signedOut)

        let challenge = try await h.auth.requestCode(email: " Tester@Example.com ")
        XCTAssertEqual(challenge.challengeId, "chal-1")
        XCTAssertEqual(h.auth.pendingChallenge, challenge)
        XCTAssertEqual(h.auth.pendingEmail, "tester@example.com")
        XCTAssertEqual(h.auth.state, .signedOut, "no session until the code is verified")
        XCTAssertNil(h.tokenStore.currentToken())

        try await h.auth.verify(challengeId: challenge.challengeId, code: " 123456 ")
        XCTAssertTrue(h.auth.isSignedIn)
        XCTAssertEqual(h.auth.user?.displayName, "Tester")
        XCTAssertEqual(h.tokenStore.currentToken(), "jwt-1")
        XCTAssertNotNil(h.defaults.data(forKey: AuthStore.cachedUserKey))
        XCTAssertNil(h.auth.pendingChallenge)
        XCTAssertNil(h.auth.banner)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/auth/dev-login", "/v1/auth/dev-login/verify"])
        XCTAssertEqual(try requests[0].jsonBody()["email"] as? String, "tester@example.com", "email trimmed + lowercased")
        let verifyBody = try requests[1].jsonBody()
        XCTAssertEqual(verifyBody["challenge_id"] as? String, "chal-1")
        XCTAssertEqual(verifyBody["code"] as? String, "123456", "code trimmed")
    }

    func testWrongCodeShowsServerMessageAndStaysOnCodeStep() async throws {
        StubURLProtocol.install { request in
            switch request.url?.path {
            case "/v1/auth/dev-login": return (.stub(request, status: 202), Data(AuthFixtures.challengeJSON.utf8))
            default: return (.stub(request, status: 401), Data(AuthFixtures.badCodeJSON.utf8))
            }
        }
        let h = makeHarness()
        await h.auth.restore()
        h.client.events.onUnauthorized { _ in
            XCTFail("401 on verify must not fire the global unauthorized path")
        }
        let challenge = try await h.auth.requestCode(email: "a@b.co")

        do {
            try await h.auth.verify(challengeId: challenge.challengeId, code: "000000")
            XCTFail("expected 401")
        } catch let error as APIError {
            XCTAssertEqual(error.userMessage, "Invalid or expired sign-in code")
        }
        XCTAssertEqual(h.auth.pendingChallenge, challenge, "challenge kept so the user can retry the code")
        XCTAssertEqual(h.auth.pendingEmail, "a@b.co")
        XCTAssertEqual(h.auth.state, .signedOut)
        XCTAssertNil(h.tokenStore.currentToken())
        XCTAssertNil(h.auth.banner, "the inline error belongs to the code field, not the banner")

        // Even if the global path were invoked while signed out, it is a no-op.
        h.auth.handleUnauthorized(UnauthorizedEvent(error: .unauthorized(message: nil, correlationId: nil), generation: h.auth.generation.current()))
        XCTAssertEqual(h.auth.pendingChallenge, challenge)
        XCTAssertEqual(h.auth.state, .signedOut)
    }

    func testCancelPendingChallengeReturnsToEmailStep() async throws {
        AuthFixtures.installHappyPath()
        let h = makeHarness()
        try await h.auth.requestCode(email: "a@b.co")
        XCTAssertNotNil(h.auth.pendingChallenge)
        h.auth.cancelPendingChallenge()
        XCTAssertNil(h.auth.pendingChallenge)
        XCTAssertNil(h.auth.pendingEmail)
    }

    // MARK: - 401 teardown

    /// 401 -> event -> AuthStore.handleUnauthorized -> token + cached user + recipe cache cleared, signedOut.
    func test401ClearsTokenAndSignsOutThroughAuthStore() async throws {
        let h = makeHarness(bind: false)
        let auth = h.auth
        let signedOut = expectation(description: "handleUnauthorized ran")
        // Same wiring as AppEnvironment.bind, plus a hook so the test can await the main-actor hop.
        h.client.events.onUnauthorized { event in
            Task { @MainActor in
                auth.handleUnauthorized(event)
                signedOut.fulfill()
            }
        }
        AuthFixtures.installHappyPath { request in
            (.stub(request, status: 401), Data(AuthFixtures.expiredTokenJSON.utf8))
        }
        try await h.auth.requestCode(email: "tester@example.com")
        try await h.auth.verify(challengeId: "chal-1", code: "123456")
        XCTAssertTrue(h.auth.isSignedIn)
        XCTAssertEqual(h.tokenStore.currentToken(), "jwt-1")
        try h.cache.save([])

        do {
            _ = try await h.client.listRecipes()
            XCTFail("expected 401")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(message: "Token expired.", correlationId: "c401"))
        }
        await fulfillment(of: [signedOut], timeout: 2)

        XCTAssertEqual(h.auth.state, .signedOut)
        XCTAssertNil(h.tokenStore.currentToken(), "401 must clear the stored token")
        XCTAssertNil(h.defaults.data(forKey: AuthStore.cachedUserKey))
        XCTAssertNil(h.cache.load(), "recipe cache is dropped with the session")
        XCTAssertEqual(h.auth.banner, "Your session ended. Please sign in again.")
    }

    func testStaleGeneration401IsIgnored() async throws {
        AuthFixtures.installHappyPath()
        let h = makeHarness()
        try await h.auth.requestCode(email: "a@b.co")
        try await h.auth.verify(challengeId: "chal-1", code: "123456")
        let before = h.auth.generation.current()

        // Sign out and back in: the generation moves on.
        h.auth.signOut()
        try await h.auth.requestCode(email: "a@b.co")
        try await h.auth.verify(challengeId: "chal-1", code: "123456")
        XCTAssertTrue(h.auth.isSignedIn)
        XCTAssertGreaterThan(h.auth.generation.current(), before)

        // A 401 from a request issued under the old session lands late.
        h.auth.handleUnauthorized(UnauthorizedEvent(error: .unauthorized(message: nil, correlationId: "late"), generation: before))
        XCTAssertTrue(h.auth.isSignedIn, "late 401 from a previous session must not end the new one")
        XCTAssertEqual(h.tokenStore.currentToken(), "jwt-1")

        // The same 401 under the current generation does.
        h.auth.handleUnauthorized(UnauthorizedEvent(error: .unauthorized(message: nil, correlationId: "now"), generation: h.auth.generation.current()))
        XCTAssertEqual(h.auth.state, .signedOut)
    }

    // MARK: - Sign-out and restore

    func testSignOutClearsKeychainTokenCachedUserAndRecipeCache() async throws {
        let keychain = KeychainTokenStore(service: "com.souslens.ios.tests.\(UUID().uuidString)")
        defer { try? keychain.clear() }
        let defaults = freshDefaults()
        let cache = InMemoryRecipeCache()
        let client = APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
            tokenProvider: keychain
        )
        let auth = AuthStore(api: client, tokenStore: keychain, defaults: defaults, recipeCache: cache)
        AuthFixtures.installHappyPath()

        try await auth.requestCode(email: "a@b.co")
        try await auth.verify(challengeId: "chal-1", code: "123456")
        XCTAssertEqual(keychain.currentToken(), "jwt-1")
        XCTAssertNotNil(defaults.data(forKey: AuthStore.cachedUserKey))
        try cache.save([])
        XCTAssertNotNil(cache.load())

        auth.signOut()
        XCTAssertNil(keychain.currentToken())
        XCTAssertNil(defaults.data(forKey: AuthStore.cachedUserKey))
        XCTAssertNil(cache.load())
        XCTAssertEqual(cache.clearCount, 1)
        XCTAssertEqual(auth.state, .signedOut)
    }

    func testRestoreWithoutTokenIsSignedOutAndWithTokenUsesMe() async throws {
        let signedOut = makeHarness()
        await signedOut.auth.restore()
        XCTAssertEqual(signedOut.auth.state, .signedOut)

        StubURLProtocol.install { request in (.stub(request, status: 200), Data(AuthFixtures.userJSON.utf8)) }
        let restored = makeHarness(token: "saved")
        await restored.auth.restore()
        XCTAssertEqual(restored.auth.user?.displayName, "Tester")
        XCTAssertEqual(restored.tokenStore.currentToken(), "saved")
    }

    func testRestoreUsesCachedUserWhenOfflineAndSignsOutOn401() async throws {
        // Offline with a cached user → stays signed in on the cached profile.
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        let defaults = freshDefaults()
        let cached = try JSONCoding.makeDecoder().decode(User.self, from: Data(AuthFixtures.userJSON.utf8))
        defaults.set(try JSONCoding.makeEncoder().encode(cached), forKey: AuthStore.cachedUserKey)
        let offline = makeHarness(token: "saved", defaults: defaults)
        await offline.auth.restore()
        XCTAssertEqual(offline.auth.user?.displayName, "Tester")
        XCTAssertEqual(offline.tokenStore.currentToken(), "saved")

        // 401 on refresh → everything cleared.
        StubURLProtocol.install { request in (.stub(request, status: 401), Data(AuthFixtures.expiredTokenJSON.utf8)) }
        let expired = makeHarness(token: "saved", defaults: defaults)
        await expired.auth.restore()
        XCTAssertEqual(expired.auth.state, .signedOut)
        XCTAssertNil(expired.tokenStore.currentToken())
        XCTAssertNil(defaults.data(forKey: AuthStore.cachedUserKey))
    }

    func testFirstLaunchAfterReinstallDiscardsLeftoverKeychainToken() async throws {
        StubURLProtocol.install { request in (.stub(request, status: 200), Data(AuthFixtures.userJSON.utf8)) }
        let defaults = freshDefaults(launched: false)
        let h = makeHarness(token: "left-over-from-previous-install", defaults: defaults)
        await h.auth.restore()
        XCTAssertEqual(h.auth.state, .signedOut)
        XCTAssertNil(h.tokenStore.currentToken(), "a token that outlived the install is never trusted")
        XCTAssertTrue(defaults.bool(forKey: AuthStore.hasLaunchedKey))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no /v1/me call with a discarded token")

        // Second launch: the flag is set, a real token is honoured.
        try h.tokenStore.save(token: "fresh")
        let again = makeHarness(token: "fresh", defaults: defaults)
        await again.auth.restore()
        XCTAssertEqual(again.auth.user?.displayName, "Tester")
    }
}
