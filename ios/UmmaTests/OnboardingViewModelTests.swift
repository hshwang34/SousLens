import Foundation
import XCTest
@testable import Umma

/// Brief 015: the onboarding step machine, driven without UI.
@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private var social: FakeSocialService!
    private var cooking: FakeCookingService!
    private var updatedUsers: [User] = []

    override func setUp() async throws {
        social = FakeSocialService()
        cooking = FakeCookingService()
        updatedUsers = []
    }

    private func makeModel(_ steps: [OnboardingViewModel.Step] = OnboardingViewModel.allSteps) async -> OnboardingViewModel {
        let model = OnboardingViewModel(service: social, social: social, preferencesService: cooking, steps: steps) { [weak self] user in
            self?.updatedUsers.append(user)
        }
        await model.start()
        return model
    }

    private let phaseOne: [OnboardingViewModel.Step] = [.welcome, .role, .allergies, .taste, .done]

    func testRoleIsRequiredAndSavedOnContinue() async {
        let model = await makeModel(phaseOne)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertFalse(model.canGoBack)
        await model.continueTapped()
        XCTAssertEqual(model.step, .role)
        XCTAssertFalse(model.canContinue, "a role must be chosen")
        XCTAssertFalse(model.canSkip)

        model.role = .creator
        await model.continueTapped()
        XCTAssertEqual(model.step, .allergies)
        XCTAssertEqual(social.calls, [.setRole(.creator)])
        XCTAssertEqual(updatedUsers.last?.role, .creator)
        XCTAssertTrue(updatedUsers.last?.needsOnboarding ?? false, "still onboarding after the role")
    }

    func testAllergiesNeedAnExplicitAnswer() async {
        let model = await makeModel(phaseOne)
        await model.continueTapped()
        model.role = .cook
        await model.continueTapped()
        XCTAssertEqual(model.step, .allergies)
        XCTAssertFalse(model.canContinue, "no answer yet")
        XCTAssertFalse(model.canSkip, "allergies can't be skipped")

        model.toggleNoAllergies()
        XCTAssertTrue(model.canContinue)
        model.toggleNoAllergies()
        XCTAssertFalse(model.canContinue)

        model.preferences.allergyDraft = "peanuts"
        await model.preferences.add(.allergies)
        XCTAssertTrue(model.hasAllergies)
        XCTAssertTrue(model.canContinue, "a listed allergy is an answer")
        model.toggleNoAllergies()
        XCTAssertFalse(model.saysNoAllergies, "can't claim none with one listed")
    }

    func testTasteSavesWithCurrentAllergiesAndSkipSavesNothing() async {
        let model = await makeModel(phaseOne)
        await model.continueTapped()
        model.role = .cook
        await model.continueTapped()
        model.preferences.allergyDraft = "egg"
        await model.preferences.add(.allergies)
        await model.continueTapped()
        XCTAssertEqual(model.step, .taste)
        XCTAssertTrue(model.canSkip)

        model.toggleDiet("vegetarian")
        model.toggleCuisine("korean")
        model.toggleCuisine("thai")
        model.toggleCuisine("thai")
        model.skillLevel = "beginner"
        await model.continueTapped()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(social.calls.last, .updateTaste(.init(allergies: ["egg"], avoid: [], diets: ["vegetarian"],
                                                             cuisines: ["korean"], skillLevel: "beginner")))

        XCTAssertFalse(model.canGoBack, "no going back from the last screen")
    }

    func testSkipSavesNothingAndBackWorks() async {
        let model = await makeModel([.welcome, .taste, .done])
        await model.continueTapped()
        XCTAssertEqual(model.step, .taste)
        model.toggleCuisine("korean")
        model.skip()
        XCTAssertEqual(model.step, .done)
        XCTAssertTrue(social.calls.isEmpty, "skip saves nothing")

        let again = await makeModel([.welcome, .taste, .done])
        await again.continueTapped()
        again.back()
        XCTAssertEqual(again.step, .welcome)
    }

    func testDoneCompletesAndReportsTheUser() async {
        let model = await makeModel([.welcome, .done])
        await model.continueTapped()
        XCTAssertEqual(model.step, .done)
        XCTAssertFalse(model.canGoBack, "no going back from the last screen")
        await model.continueTapped()
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(social.calls, [.completeOnboarding])
        XCTAssertEqual(updatedUsers.last?.needsOnboarding, false)
    }

    func testFailedCompletionStaysWithMessage() async {
        social.completeError = APIError.http(status: 503, correlationId: nil)
        let model = await makeModel([.welcome, .done])
        await model.continueTapped()
        await model.continueTapped()
        XCTAssertFalse(model.isFinished)
        XCTAssertEqual(model.step, .done)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(updatedUsers.isEmpty)
    }

    func testTastePrefillsFromSavedPreferences() async {
        cooking.preferencesHandler = { FoodPreferences(diets: ["vegan"], cuisines: ["japanese"], skillLevel: "confident") }
        let model = await makeModel(phaseOne)
        XCTAssertEqual(model.diets, ["vegan"])
        XCTAssertEqual(model.cuisines, ["japanese"])
        XCTAssertEqual(model.skillLevel, "confident")
    }

    func testFollowSuggestionsUseCuisinesAndToggleSavesEachTap() async throws {
        let mina = try XCTUnwrap(UUID(uuidString: SocialFixtures.minaId))
        social.suggestedHandler = { _ in
            [SocialFixtures.creator(), SocialFixtures.creator(id: SocialFixtures.samId, name: "Sam Okafor")]
        }
        let model = await makeModel([.welcome, .taste, .follow, .done])
        await model.continueTapped()
        model.toggleCuisine("korean")
        await model.continueTapped()
        XCTAssertEqual(model.step, .follow)
        XCTAssertTrue(model.canSkip)

        await model.loadSuggestions()
        XCTAssertEqual(model.suggestionsPhase, .loaded)
        XCTAssertEqual(model.suggestions.count, 2)
        XCTAssertEqual(model.followingCount, 0, "nothing preselected")
        XCTAssertTrue(social.calls.contains(.suggested(["korean"])))

        await model.loadSuggestions()
        XCTAssertEqual(social.calls.filter { if case .suggested = $0 { true } else { false } }.count, 1, "same cuisines: no reload")

        await model.toggleFollow(mina)
        XCTAssertEqual(model.followingCount, 1)
        XCTAssertEqual(social.calls.last, .follow(mina))
        await model.toggleFollow(mina)
        XCTAssertEqual(model.followingCount, 0)
        XCTAssertEqual(social.calls.last, .unfollow(mina))
    }

    func testFailedFollowRollsBack() async throws {
        let mina = try XCTUnwrap(UUID(uuidString: SocialFixtures.minaId))
        social.followHandler = { _, _ in throw APIError.http(status: 503, correlationId: nil) }
        let model = await makeModel([.welcome, .follow, .done])
        await model.continueTapped()
        await model.loadSuggestions()
        await model.toggleFollow(mina)
        XCTAssertEqual(model.followingCount, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testPantryCountsAddedItemsAndCanBeSkipped() async {
        let model = await makeModel([.welcome, .pantry, .done])
        await model.continueTapped()
        XCTAssertEqual(model.step, .pantry)
        XCTAssertTrue(model.canContinue)
        model.pantryAdded(3)
        model.pantryAdded(2)
        XCTAssertEqual(model.pantryItemsAdded, 5)
        model.skip()
        XCTAssertEqual(model.step, .done)
    }

    func testProgressCountsOnlyRealSteps() async {
        let model = await makeModel()
        XCTAssertNil(model.countedPosition)
        XCTAssertEqual(model.countedSteps, [.role, .allergies, .taste, .follow, .pantry])
        XCTAssertEqual(model.progress, 0)
        await model.continueTapped()
        XCTAssertEqual(model.countedPosition, 1)
    }

    func testGateFollowsUserAndFlag() {
        let env = AppEnvironment.preview(signedIn: true)
        env.forceSignedInForTests()
        env.onboardingEnabled = true
        env.auth.updateUser(SocialFixtures.user(onboarded: false).with(id: env.auth.user!.id))
        XCTAssertTrue(env.isOnboarding)
        env.onboardingEnabled = false
        XCTAssertFalse(env.isOnboarding, "flag off: never shown")
        env.onboardingEnabled = true
        env.auth.updateUser(SocialFixtures.user(onboarded: true).with(id: env.auth.user!.id))
        XCTAssertFalse(env.isOnboarding)
    }

    func testDeepLinkWaitsForOnboarding() throws {
        let env = AppEnvironment.preview(signedIn: true)
        env.forceSignedInForTests()
        env.onboardingEnabled = true
        env.auth.updateUser(SocialFixtures.user(onboarded: false).with(id: env.auth.user!.id))
        let id = UUID()
        env.open(.recipe(id))
        XCTAssertEqual(env.pendingDeepLink, .recipe(id))
        XCTAssertTrue(env.exploreRoutes.isEmpty)

        env.auth.updateUser(SocialFixtures.user(onboarded: true).with(id: env.auth.user!.id))
        env.applyPendingDeepLink()
        XCTAssertNil(env.pendingDeepLink)
        XCTAssertEqual(env.exploreRoutes.count, 1)
    }
}

private extension User {
    func with(id: UUID) -> User {
        User(id: id, displayName: displayName, preferenceUnits: preferenceUnits, createdAt: createdAt,
             entitlement: entitlement, onboardedAt: onboardedAt, role: role)
    }
}
