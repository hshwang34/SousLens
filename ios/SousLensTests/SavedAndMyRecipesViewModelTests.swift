import Foundation
import XCTest
@testable import SousLens

@MainActor
final class SavedViewModelTests: XCTestCase {
    func testLoadGoesLoadingLoadedThenEmptyOnRefresh() async throws {
        let card = try AuthoringFixtures.card()
        let service = FakeRecipeService()
        let empty = OSAllocatedUnfairLockBox(false)
        service.mySavedHandler = { empty.value ? [] : [card] }
        let model = SavedViewModel(service: service)
        XCTAssertEqual(model.phase, .idle)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.cards.map(\.title), ["Garlic Pasta"])
        empty.value = true
        await model.refresh()
        XCTAssertEqual(model.phase, .empty)
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertEqual(service.authoringCalls, [.mySaved, .mySaved])
    }

    func testErrorState() async {
        let service = FakeRecipeService()
        service.mySavedHandler = { throw APIError.unreachable(baseURL: "http://localhost:8000", underlying: "refused") }
        let model = SavedViewModel(service: service)
        await model.load()
        guard case .error(let message, let retryable) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(message.contains("localhost:8000"))
        XCTAssertTrue(retryable)
    }
}

@MainActor
final class MyRecipesViewModelTests: XCTestCase {
    private func makeService() throws -> FakeRecipeService {
        let service = FakeRecipeService()
        let mine = try JSONCoding.makeDecoder().decode(ItemsResponse<MyRecipe>.self, from: Data(AuthoringFixtures.myRecipesJSON.utf8)).items
        let drafts = try JSONCoding.makeDecoder().decode(ItemsResponse<DraftSummary>.self, from: Data(AuthoringFixtures.draftSummaryListJSON.utf8)).items
        service.myRecipesHandler = { mine }
        service.listDraftsHandler = { drafts }
        return service
    }

    func testLoadFetchesRecipesAndDraftsTogether() async throws {
        let service = try makeService()
        let model = MyRecipesViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.recipes.map(\.card.title), ["Garlic Pasta"])
        XCTAssertEqual(model.recipes[0].visibility, .public)
        XCTAssertTrue(model.recipes[0].hasOpenDraft)
        XCTAssertEqual(model.drafts.map(\.displayTitle), ["Untitled draft", "Garlic Pasta"])
        XCTAssertEqual(Set(service.authoringCalls), [.myRecipes, .listDrafts])
    }

    func testPublishedDraftsAreHiddenFromDraftsList() async throws {
        let service = try makeService()
        let published = AuthoringFixtures.draftSummaryListJSON.replacingOccurrences(of: #""status":"draft","title":"Garlic Pasta""#, with: #""status":"published","title":"Garlic Pasta""#)
        let drafts = try JSONCoding.makeDecoder().decode(ItemsResponse<DraftSummary>.self, from: Data(published.utf8)).items
        service.listDraftsHandler = { drafts }
        let model = MyRecipesViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.drafts.map(\.displayTitle), ["Untitled draft"])
    }

    func testUnpublishUpdatesVisibilityInPlace() async throws {
        let service = try makeService()
        let model = MyRecipesViewModel(service: service)
        await model.load()
        let id = model.recipes[0].id
        let r1 = await model.unpublish(recipeId: id)
        XCTAssertTrue(r1)
        XCTAssertEqual(model.recipes[0].visibility, .private)
        XCTAssertEqual(model.recipes.count, 1, "stays listed under My recipes")
        XCTAssertTrue(service.authoringCalls.contains(.unpublishRecipe(id)))

        service.unpublishRecipeHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        let r2 = await model.unpublish(recipeId: id)
        XCTAssertFalse(r2)
        XCTAssertNotNil(model.actionError)
    }

    func testDeleteDraftRemovesItAndClearsOpenDraftFlag() async throws {
        let service = try makeService()
        let model = MyRecipesViewModel(service: service)
        await model.load()
        let edit = model.drafts[1]   // belongs to the published recipe
        XCTAssertNotNil(edit.recipeId)
        let r3 = await model.deleteDraft(id: edit.id)
        XCTAssertTrue(r3)
        XCTAssertEqual(model.drafts.map(\.displayTitle), ["Untitled draft"])
        XCTAssertFalse(model.recipes[0].hasOpenDraft)
        XCTAssertTrue(service.authoringCalls.contains(.deleteDraft(edit.id)))

        service.deleteDraftHandler = { _ in throw APIError.server(status: 404, code: "NOT_FOUND", message: "Gone.", retryable: false, correlationId: nil) }
        let r4 = await model.deleteDraft(id: model.drafts[0].id)
        XCTAssertFalse(r4)
        XCTAssertEqual(model.actionError, "Gone.")
        XCTAssertEqual(model.drafts.count, 1, "nothing removed on failure")
    }

    func testEitherRequestFailingYieldsErrorPhase() async throws {
        let service = try makeService()
        service.listDraftsHandler = { throw APIError.http(status: 503, correlationId: nil) }
        let model = MyRecipesViewModel(service: service)
        await model.load()
        guard case .error(_, let retryable) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(retryable)
    }
}
