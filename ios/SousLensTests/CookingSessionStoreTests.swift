import Foundation
import XCTest
@testable import SousLens

/// Resume banner / pill (COOK-07) and account isolation of the cached session.
@MainActor
final class CookingSessionStoreTests: XCTestCase {
    private let userA = SessionOwner(userId: UUID(), server: "http://localhost:8000")
    private let userB = SessionOwner(userId: UUID(), server: "http://localhost:8000")

    private func makeStore(service: CookingService, cache: SessionCaching, owner: TestBox<SessionOwner?>) -> CookingSessionStore {
        CookingSessionStore(service: service, cache: cache, owner: { owner.value })
    }

    func testBannerShowsServerStepThenPillAfterDismiss() async throws {
        let service = FakeCookingService()
        service.activeHandler = { [try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(stepIndex: 2))] }
        let store = makeStore(service: service, cache: InMemorySessionCache(), owner: TestBox(userA))
        XCTAssertFalse(store.showsBanner)
        await store.refresh()
        XCTAssertTrue(store.showsBanner)
        XCTAssertEqual(store.resumeTitle, "Continue cooking Gochujang Chicken Thighs")
        XCTAssertEqual(store.resumeStepText, "Step 3", "1-based from the server's step_index")
        XCTAssertFalse(store.showsPill)
        store.dismissBanner()
        XCTAssertFalse(store.showsBanner)
        XCTAssertTrue(store.showsPill)
        store.resume()
        XCTAssertEqual(store.presented?.sessionId, CookingFixtures.sessionUUID)
        XCTAssertEqual(store.presented?.startOnOpen, false, "resuming never auto-starts")
        XCTAssertFalse(store.showsPill, "no pill while the cooking screen is open")
    }

    func testNoOpenSessionMeansNoBanner() async {
        let service = FakeCookingService()
        service.activeHandler = { [try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(status: "completed"))] }
        let store = makeStore(service: service, cache: InMemorySessionCache(), owner: TestBox(userA))
        await store.refresh()
        XCTAssertNil(store.active)
        XCTAssertFalse(store.showsBanner)
        XCTAssertFalse(store.showsPill)
    }

    func testOfflineFallsBackToThisAccountsCachedSession() async throws {
        let service = FakeCookingService()
        service.activeHandler = { throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        let cache = InMemorySessionCache()
        try cache.save(try CookingFixtures.session(stepIndex: 2, revision: 3), owner: userA)
        let store = makeStore(service: service, cache: cache, owner: TestBox(userA))
        await store.refresh()
        XCTAssertTrue(store.activeIsFromCache)
        XCTAssertEqual(store.resumeStepText, "Step 3")
        store.resume()
        XCTAssertEqual(store.presented?.initial?.stepIndex, 2)
    }

    func testSessionChangedUpdatesActiveAndClearsWhenEnded() async throws {
        let cache = InMemorySessionCache()
        let store = makeStore(service: FakeCookingService(), cache: cache, owner: TestBox(userA))
        store.present(newSession: try CookingFixtures.session(status: "created", revision: 0), epoch: store.epoch)
        XCTAssertEqual(store.presented?.startOnOpen, true)
        XCTAssertEqual(cache.raw?.owner, userA, "cache stamped with the owner")
        store.sessionChanged(try CookingFixtures.session(status: "completed", stepIndex: 6, revision: 9), epoch: store.epoch)
        XCTAssertNil(store.active)
        XCTAssertNil(cache.raw)
    }

    // MARK: Security review: cross-account and late results

    func testUserBNeverSeesUserAsCachedSessionOffline() async throws {
        let owner = TestBox<SessionOwner?>(userA)
        let cache = InMemorySessionCache()
        let service = FakeCookingService()
        let store = makeStore(service: service, cache: cache, owner: owner)
        store.sessionChanged(try CookingFixtures.session(stepIndex: 3, revision: 4), epoch: store.epoch)
        XCTAssertNotNil(cache.raw)

        // A signs out (any path → reset), B signs in while offline.
        store.reset()
        owner.value = userB
        service.activeHandler = { throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        await store.refresh()
        XCTAssertNil(store.active)
        XCTAssertFalse(store.showsBanner)
        XCTAssertNil(store.cachedSession())
    }

    func testForeignCacheIsDeletedOnReadEvenWithoutAReset() async throws {
        // e.g. a crash between A's last save and the sign-out.
        let cache = InMemorySessionCache()
        try cache.save(try CookingFixtures.session(), owner: userA)
        let service = FakeCookingService()
        service.activeHandler = { throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        let store = makeStore(service: service, cache: cache, owner: TestBox(userB))
        await store.refresh()
        XCTAssertNil(store.active)
        XCTAssertNil(cache.raw, "someone else's session is deleted, not kept")
        let otherServer = SessionOwner(userId: userA.userId, server: "http://other:8000")
        try cache.save(try CookingFixtures.session(), owner: userA)
        XCTAssertNil(cache.load(for: otherServer), "same user on another server doesn't match either")
    }

    func testRefreshInFlightDuringSignOutWritesNothing() async throws {
        let inner = FakeCookingService()
        inner.activeHandler = { [try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON())] }
        let latch = TestLatch()
        let gated = GatedCookingService(inner: inner, latch: latch)
        let owner = TestBox<SessionOwner?>(userA)
        let cache = InMemorySessionCache()
        let store = makeStore(service: gated, cache: cache, owner: owner)
        let refresh = Task { await store.refresh() }
        while gated.entered == 0 { await Task.yield() }
        store.reset()
        owner.value = nil
        await latch.open()
        await refresh.value
        XCTAssertNil(store.active, "late result after sign-out is dropped")
        XCTAssertNil(cache.raw)
    }

    func testSessionChangedAfterResetIsANoOp() async throws {
        let cache = InMemorySessionCache()
        let owner = TestBox<SessionOwner?>(userA)
        let store = makeStore(service: FakeCookingService(), cache: cache, owner: owner)
        let openedUnder = store.epoch
        store.reset()
        store.sessionChanged(try CookingFixtures.session(), epoch: openedUnder)
        XCTAssertNil(store.active)
        XCTAssertNil(cache.raw)
        store.present(newSession: try CookingFixtures.session(status: "created", revision: 0), epoch: openedUnder)
        XCTAssertNil(store.presented, "a Start cooking reply that lands after sign-out opens nothing")
    }

    func testResetInvalidatesTheOpenCookingScreen() async throws {
        let service = FakeCookingService()
        let store = makeStore(service: service, cache: InMemorySessionCache(), owner: TestBox(userA))
        let model = CookingViewModel(sessionId: CookingFixtures.sessionUUID, service: service, audio: FakeAudioOutput())
        store.attach(model)
        store.reset()
        XCTAssertTrue(model.isInvalidated)
        XCTAssertNil(store.presented)
    }

    func testAuthClearingCredentialsResetsCookingState() async throws {
        let env = AppEnvironment.preview(signedIn: true)
        env.forceSignedInForTests()
        let owner = try XCTUnwrap(env.auth.user.map { SessionOwner(userId: $0.id, server: env.serverSettings.effectiveBaseURLString) })
        XCTAssertFalse(owner.server.isEmpty)
        env.cooking.sessionChanged(try CookingFixtures.session(), epoch: env.cooking.epoch)
        XCTAssertNotNil(env.cooking.active)
        let before = env.cooking.epoch
        env.auth.signOut()
        XCTAssertNil(env.cooking.active)
        XCTAssertGreaterThan(env.cooking.epoch, before)
    }
}
