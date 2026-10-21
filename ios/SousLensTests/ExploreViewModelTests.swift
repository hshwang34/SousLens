import Foundation
import XCTest
@testable import SousLens

@MainActor
final class ExploreViewModelTests: XCTestCase {
    private func fixturePage() throws -> RecipePage {
        try Fixtures.decode(RecipePage.self, from: "recipes_list")
    }

    func testLoadGoesLoadingThenLoaded() async throws {
        let page = try fixturePage()
        let service = FakeRecipeService(listHandler: { _ in page })
        let model = ExploreViewModel(service: service, cache: InMemoryRecipeCache(), debounce: .zero)
        XCTAssertEqual(model.phase, .idle)

        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.cards.map(\.title), ["Gochujang Chicken Thighs"])
        XCTAssertFalse(model.isShowingCached)
        XCTAssertEqual(service.calls, [.init(query: nil, tag: nil, cursor: nil, limit: 20)])
    }

    func testLoadShowsLoadingWhileFetchIsInFlight() async throws {
        let page = try fixturePage()
        let gate = AsyncGate()
        let service = FakeRecipeService(listHandler: { _ in page })
        service.beforeList = { await gate.wait() }
        let model = ExploreViewModel(service: service, cache: InMemoryRecipeCache(), debounce: .zero)

        let load = Task { await model.load() }
        await gate.waitUntilWaiting()
        XCTAssertEqual(model.phase, .loading)
        await gate.open()
        await load.value
        XCTAssertEqual(model.phase, .loaded)
    }

    func testSearchDebouncesIntoQueryParameter() async throws {
        let page = try fixturePage()
        let service = FakeRecipeService(listHandler: { call in
            guard let query = call.query else { return page }
            return RecipePage(items: page.items.filter { $0.title.localizedCaseInsensitiveContains(query) }, nextCursor: nil)
        })
        let model = ExploreViewModel(service: service, cache: InMemoryRecipeCache(), debounce: .zero)
        await model.load()

        model.searchText = "goch"
        model.searchText = "gochu"
        model.searchText = "gochujang"
        await model.awaitPendingSearch()

        XCTAssertEqual(model.query, "gochujang")
        XCTAssertEqual(model.cards.map(\.title), ["Gochujang Chicken Thighs"])
        XCTAssertEqual(service.calls.map(\.query), [nil, "gochujang"], "intermediate keystrokes must be debounced away")
    }

    func testRapidKeystrokesIssueExactlyOneSearchRequestWithFinalQuery() async throws {
        let page = try fixturePage()
        let service = FakeRecipeService(listHandler: { _ in page })
        let model = ExploreViewModel(service: service, cache: InMemoryRecipeCache(), debounce: .milliseconds(60))
        await model.load()
        for text in ["g", "go", "goc", "goch", "gochu", "gochuj", "gochujang"] {
            model.searchText = text
        }
        await model.awaitPendingSearch()
        XCTAssertEqual(service.calls.map(\.query), [nil, "gochujang"])
    }

    func testSearchWithNoMatchesShowsEmpty() async throws {
        let page = try fixturePage()
        let service = FakeRecipeService(listHandler: { call in
            call.query == nil ? page : RecipePage(items: [], nextCursor: nil)
        })
        let model = ExploreViewModel(service: service, cache: InMemoryRecipeCache(), debounce: .zero)
        await model.load()
        model.searchText = "zzz"
        await model.awaitPendingSearch()
        XCTAssertEqual(model.phase, .empty)
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertEqual(model.query, "zzz")
    }

    func testClearingSearchReloadsFullList() async throws {
        let page = try fixturePage()
        let service = FakeRecipeService(listHandler: { call in
            call.query == nil ? page : RecipePage(items: [], nextCursor: nil)
        })
        let model = ExploreViewModel(service: service, cache: InMemoryRecipeCache(), debounce: .zero)
        await model.load()
        model.searchText = "zzz"
        await model.awaitPendingSearch()
        XCTAssertEqual(model.phase, .empty)
        model.searchText = ""
        await model.awaitPendingSearch()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.cards.count, 1)
    }

    func testErrorWithoutCacheShowsErrorState() async {
        let service = FakeRecipeService(listHandler: { _ in
            throw APIError.unreachable(baseURL: "http://localhost:8000", underlying: "refused")
        })
        let model = ExploreViewModel(service: service, cache: InMemoryRecipeCache(), debounce: .zero)
        await model.load()
        guard case .error(let message, let retryable) = model.phase else {
            return XCTFail("expected error, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("localhost:8000"))
        XCTAssertTrue(retryable)
        XCTAssertTrue(model.cards.isEmpty)
    }

    func testErrorWithCacheShowsCachedCardsAndNotice() async throws {
        let page = try fixturePage()
        let cache = InMemoryRecipeCache(stored: CachedRecipeList(items: page.items, savedAt: Date()))
        let service = FakeRecipeService(listHandler: { _ in
            throw APIError.unreachable(baseURL: "http://localhost:8000", underlying: "refused")
        })
        let model = ExploreViewModel(service: service, cache: cache, debounce: .zero)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.cards.count, 1)
        XCTAssertTrue(model.isShowingCached)
        XCTAssertNotNil(model.cachedAt)
        XCTAssertTrue(try XCTUnwrap(model.offlineNotice).contains("Can’t reach the server"))
    }

    func testSuccessfulLoadWritesCache() async throws {
        let page = try fixturePage()
        let cache = InMemoryRecipeCache()
        let model = ExploreViewModel(service: FakeRecipeService(listHandler: { _ in page }), cache: cache, debounce: .zero)
        await model.load()
        XCTAssertEqual(cache.load()?.items, page.items)
    }
}

/// One-shot gate so a test can hold a fake request open without sleeping.
actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrival: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            arrival?.resume()
            arrival = nil
        }
    }

    /// Resolves once something is blocked in `wait()`.
    func waitUntilWaiting() async {
        if !waiters.isEmpty || opened { return }
        await withCheckedContinuation { continuation in arrival = continuation }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
