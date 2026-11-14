import Foundation
import XCTest
@testable import Umma

/// Brief 015: Explore's For You / Following feeds. Search still uses `/recipes`.
@MainActor
final class ExploreFeedTests: XCTestCase {
    func testForYouLoadsByDefaultAndCaches() async {
        let social = FakeSocialService()
        social.forYouHandler = { _ in FeedPage(items: [SocialFixtures.card(feed: SocialFixtures.forYouFeed)], nextCursor: nil) }
        let recipes = FakeRecipeService()
        let cache = InMemoryRecipeCache()
        let model = ExploreViewModel(service: recipes, feeds: social, cache: cache, debounce: .zero)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.cards.first?.feed?.reason, "You have 6 of 8")
        XCTAssertEqual(social.calls, [.forYou(nil)])
        XCTAssertTrue(recipes.calls.isEmpty, "the feed replaces the plain list")
        XCTAssertEqual(cache.load()?.items.count, 1)
        XCTAssertFalse(model.showsPantryNudge, "pantry has items: coverage present")
    }

    func testSwitchingToFollowingFetchesItAndShowsEmpty() async throws {
        let social = FakeSocialService()
        social.forYouHandler = { _ in FeedPage(items: [SocialFixtures.card()], nextCursor: nil) }
        let cache = InMemoryRecipeCache()
        let model = ExploreViewModel(service: FakeRecipeService(), feeds: social, cache: cache, debounce: .zero)
        await model.load()
        model.feed = .following
        try await waitUntil { model.phase == .empty }
        XCTAssertEqual(social.calls.last, .followingFeed(nil))
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertEqual(cache.load()?.items.count, 1, "Following never overwrites the For You cache")
    }

    func testSearchUsesRecipesEndpoint() async {
        let social = FakeSocialService()
        let recipes = FakeRecipeService(listHandler: { _ in RecipePage(items: [SocialFixtures.card()], nextCursor: nil) })
        let model = ExploreViewModel(service: recipes, feeds: social, cache: InMemoryRecipeCache(), debounce: .zero)
        model.searchText = "tofu"
        await model.submitSearchNow()
        XCTAssertEqual(recipes.calls.last?.query, "tofu")
        XCTAssertFalse(social.calls.contains(.forYou(nil)))
    }

    func testPantryNudgeWhenNoCoverageAnywhere() async {
        let social = FakeSocialService()
        social.forYouHandler = { _ in FeedPage(items: [SocialFixtures.card(feed: SocialFixtures.allergyFeed)], nextCursor: nil) }
        let model = ExploreViewModel(service: FakeRecipeService(), feeds: social, cache: InMemoryRecipeCache(), debounce: .zero)
        await model.load()
        XCTAssertTrue(model.showsPantryNudge)
        XCTAssertEqual(model.cards.first?.feed?.allergyConflict, "egg", "conflicts stay visible")
    }

    func testWithoutFeedsKeepsThePlainList() async {
        let recipes = FakeRecipeService(listHandler: { _ in RecipePage(items: [SocialFixtures.card()], nextCursor: nil) })
        let model = ExploreViewModel(service: recipes, cache: InMemoryRecipeCache(), debounce: .zero)
        await model.load()
        XCTAssertEqual(recipes.calls.count, 1)
        XCTAssertFalse(model.showsPantryNudge)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
