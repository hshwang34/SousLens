import Foundation
import XCTest
@testable import SousLens

@MainActor
final class RecipeDetailViewModelTests: XCTestCase {
    private let recipeId = UUID(uuidString: AuthoringFixtures.recipeId)!

    private func makeModel(saved: String = "false", card: RecipeCard? = nil) throws -> (RecipeDetailViewModel, FakeRecipeService) {
        let service = FakeRecipeService()
        let detail = try AuthoringFixtures.detail(AuthoringFixtures.detailJSON(saved: saved))
        service.detailHandler = { _ in detail }
        return (RecipeDetailViewModel(recipeId: recipeId, card: card, service: service), service)
    }

    func testLoadSeedsSavedFromDetail() async throws {
        let (model, _) = try makeModel(saved: "true")
        XCTAssertFalse(model.isSaved)
        await model.load()
        XCTAssertTrue(model.isSaved)
        XCTAssertEqual(model.title, "Garlic Pasta")
        XCTAssertEqual(model.versionNumber, 2)
        XCTAssertEqual(model.shareURL.absoluteString, "https://souslens.app/r/\(AuthoringFixtures.recipeId)")
    }

    func testCardSeedsHeaderAndSavedBeforeLoad() throws {
        let card = try AuthoringFixtures.card()
        let (model, _) = try makeModel(card: card)
        XCTAssertTrue(model.isSaved, "card.saved = true")
        XCTAssertEqual(model.title, "Garlic Pasta")
        XCTAssertEqual(model.creatorName, "Mina Park")
        XCTAssertEqual(model.servings, 2)
        XCTAssertNil(model.detail)
    }

    func testDeepLinkOpenWithoutCardHasPlaceholderUntilLoaded() async throws {
        let (model, _) = try makeModel()
        XCTAssertEqual(model.title, "Recipe")
        XCTAssertNil(model.creatorName)
        XCTAssertEqual(model.shareURL, ShareLinks.universal(recipeId: recipeId), "share works from the id alone")
        await model.load()
        XCTAssertEqual(model.creatorName, "Mina Park")
    }

    func testToggleSaveIsOptimisticAndConfirmedByServer() async throws {
        let (model, service) = try makeModel()
        await model.load()
        let gate = AsyncGate()
        service.beforeAuthoring = { call in if case .saveRecipe = call { await gate.wait() } }

        let toggle = Task { await model.toggleSave() }
        await gate.waitUntilWaiting()
        XCTAssertTrue(model.isSaved, "flips before the server answers")
        XCTAssertTrue(model.isTogglingSave)
        await gate.open()
        await toggle.value
        XCTAssertTrue(model.isSaved)
        XCTAssertFalse(model.isTogglingSave)
        XCTAssertNil(model.saveError)
        XCTAssertEqual(service.authoringCalls, [.saveRecipe(recipeId)])

        service.beforeAuthoring = nil
        await model.toggleSave()
        XCTAssertFalse(model.isSaved)
        XCTAssertEqual(service.authoringCalls, [.saveRecipe(recipeId), .unsaveRecipe(recipeId)], "unsave is the DELETE")
    }

    func testToggleSaveRollsBackOnError() async throws {
        let (model, service) = try makeModel(saved: "true")
        await model.load()
        service.unsaveRecipeHandler = { _ in throw APIError.unreachable(baseURL: "http://localhost:8000", underlying: "refused") }
        await model.toggleSave()
        XCTAssertTrue(model.isSaved, "rolled back")
        XCTAssertTrue(try XCTUnwrap(model.saveError).contains("Can’t reach the server"))

        // Next attempt clears the error and succeeds.
        service.unsaveRecipeHandler = { id in SaveResult(recipeId: id, saved: false) }
        await model.toggleSave()
        XCTAssertFalse(model.isSaved)
        XCTAssertNil(model.saveError)
    }

    func testServerAnswerWinsOverOptimisticFlag() async throws {
        // An idempotent POST on an already-saved recipe still says saved:true.
        let (model, service) = try makeModel()
        await model.load()
        service.saveRecipeHandler = { id in SaveResult(recipeId: id, saved: true) }
        await model.toggleSave()
        XCTAssertTrue(model.isSaved)
    }

    func testSecondTapWhileInFlightIsIgnored() async throws {
        let (model, service) = try makeModel()
        await model.load()
        let gate = AsyncGate()
        service.beforeAuthoring = { _ in await gate.wait() }
        let first = Task { await model.toggleSave() }
        await gate.waitUntilWaiting()
        await model.toggleSave()
        await gate.open()
        await first.value
        XCTAssertEqual(service.authoringCalls, [.saveRecipe(recipeId)])
        XCTAssertTrue(model.isSaved)
    }

    func testOwnerDetection() async throws {
        let (model, _) = try makeModel()
        XCTAssertFalse(model.isOwner(userId: AuthoringFixtures.creator.id), "unknown until loaded")
        await model.load()
        XCTAssertTrue(model.isOwner(userId: AuthoringFixtures.creator.id))
        XCTAssertFalse(model.isOwner(userId: UUID()))
        XCTAssertFalse(model.isOwner(userId: nil))
    }

    func testUnpublishRecordsVisibilityOrError() async throws {
        let (model, service) = try makeModel()
        await model.load()
        let ok = await model.unpublish()
        XCTAssertTrue(ok)
        XCTAssertEqual(model.unpublishedVisibility, .private)
        XCTAssertEqual(service.authoringCalls, [.unpublishRecipe(recipeId)])

        let (failing, failingService) = try makeModel()
        failingService.unpublishRecipeHandler = { _ in throw APIError.server(status: 403, code: "FORBIDDEN", message: "Not your recipe.", retryable: false, correlationId: nil) }
        let failed = await failing.unpublish()
        XCTAssertFalse(failed)
        XCTAssertNil(failing.unpublishedVisibility)
        XCTAssertEqual(failing.actionError, "Not your recipe.")
    }

    func testLoadErrorState() async {
        let service = FakeRecipeService()
        service.detailHandler = { _ in throw APIError.server(status: 404, code: "NOT_FOUND", message: "No such recipe.", retryable: false, correlationId: nil) }
        let model = RecipeDetailViewModel(recipeId: recipeId, service: service)
        await model.load()
        XCTAssertEqual(model.phase, .error("No such recipe.", retryable: false))
    }
}
