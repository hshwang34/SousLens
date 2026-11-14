import Foundation
import XCTest
@testable import Umma

/// Brief 015: creator profile, Following list and the taste editor.
@MainActor
final class CreatorViewModelTests: XCTestCase {
    private let mina = UUID(uuidString: SocialFixtures.minaId)!

    func testProfileLoadsAndFollowToggles() async {
        let social = FakeSocialService()
        var changes = 0
        let model = CreatorProfileViewModel(creatorId: mina, service: social)
        model.onFollowChanged = { changes += 1 }
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.profile?.recipes.count, 1)
        XCTAssertFalse(model.profile?.creator.isFollowing ?? true)

        await model.toggleFollow()
        XCTAssertTrue(model.profile?.creator.isFollowing ?? false)
        XCTAssertEqual(social.calls.last, .follow(mina))
        await model.toggleFollow()
        XCTAssertFalse(model.profile?.creator.isFollowing ?? true)
        XCTAssertEqual(social.calls.last, .unfollow(mina))
        XCTAssertEqual(changes, 2)
    }

    func testProfileFollowFailureRollsBack() async {
        let social = FakeSocialService()
        social.followHandler = { _, _ in throw APIError.http(status: 503, correlationId: nil) }
        let model = CreatorProfileViewModel(creatorId: mina, service: social)
        await model.load()
        await model.toggleFollow()
        XCTAssertFalse(model.profile?.creator.isFollowing ?? true)
        XCTAssertNotNil(model.followError)
    }

    func testProfileNotFound() async {
        let social = FakeSocialService()
        social.creatorHandler = { _ in
            throw APIError.server(status: 404, code: "NOT_FOUND", message: "Creator not found", retryable: false, correlationId: nil)
        }
        let model = CreatorProfileViewModel(creatorId: mina, service: social)
        await model.load()
        XCTAssertEqual(model.phase, .notFound)
    }

    func testFollowingListUnfollowRemovesAndRestoresOnFailure() async {
        let social = FakeSocialService()
        social.followingHandler = { [SocialFixtures.creator(following: true)] }
        let model = FollowingListViewModel(service: social)
        await model.load()
        XCTAssertEqual(model.creators.count, 1)

        social.followHandler = { _, _ in throw APIError.http(status: 503, correlationId: nil) }
        await model.unfollow(mina)
        XCTAssertEqual(model.creators.count, 1, "put back when the server refuses")
        XCTAssertNotNil(model.actionError)

        social.followHandler = { id, f in SocialFixtures.creator(id: id.uuidString.lowercased(), following: f) }
        await model.unfollow(mina)
        XCTAssertTrue(model.creators.isEmpty)
    }

    func testTasteEditorSavesOnlyOnExplicitSave() async {
        let social = FakeSocialService()
        let cooking = FakeCookingService()
        cooking.preferencesHandler = { FoodPreferences(allergies: ["peanut"], cuisines: ["korean"]) }
        let model = TastePreferencesViewModel(preferences: cooking, onboarding: social)
        await model.load()
        XCTAssertFalse(model.hasChanges)
        model.toggleCuisine("thai")
        model.skillLevel = "beginner"
        XCTAssertTrue(model.hasChanges)
        XCTAssertTrue(social.calls.isEmpty, "nothing saved before Save")

        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(social.calls, [.updateTaste(.init(allergies: ["peanut"], avoid: [], diets: [],
                                                         cuisines: ["korean", "thai"], skillLevel: "beginner"))])
        XCTAssertFalse(model.hasChanges)
    }
}
