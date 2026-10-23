import Foundation
import XCTest
@testable import SousLens

/// Brief 003 iOS gate probes: backend field names, autosave/publish ordering, save races, link edge
/// cases, decoding tolerance. Complements the per-feature suites.
@MainActor
final class Slice1GateTests: XCTestCase {
    private let recipeId = UUID(uuidString: AuthoringFixtures.recipeId)!

    private func makeService(initial: Draft) -> FakeRecipeService {
        let service = FakeRecipeService()
        service.updateDraftHandler = { _, patch in
            AuthoringFixtures.applying(patch, to: initial, validation: AuthoringFixtures.validate(patch))
        }
        return service
    }

    private func patches(_ service: FakeRecipeService) -> [DraftPatch] {
        service.authoringCalls.compactMap { if case .updateDraft(_, let patch) = $0 { return patch } else { return nil } }
    }

    // MARK: - 1. Publish gating and 422 field mapping

    func testPublish422ShowsEachBackendProblemNextToItsField() async throws {
        let draft = try AuthoringFixtures.draft()
        let service = makeService(initial: draft)
        let json = """
        {"error":{"code":"VALIDATION_ERROR","message":"Draft is not publishable.","retryable":false,"correlation_id":"c",
         "details":{"problems":[
          {"field":"title","message":"T"},{"field":"servings","message":"S"},
          {"field":"ingredients","message":"I-section"},{"field":"steps","message":"St-section"},
          {"field":"ingredients[0].name","message":"I0-name"},
          {"field":"steps[1].instruction","message":"S1-instr"},
          {"field":"steps[0].ingredient_refs","message":"S0-refs"}]}}}
        """
        let envelope = try JSONCoding.makeDecoder().decode(APIErrorEnvelope.self, from: Data(json.utf8))
        service.publishDraftHandler = { _ in
            throw APIError.server(status: 422, code: "VALIDATION_ERROR", message: envelope.error.message, retryable: false, correlationId: "c", details: envelope.error.details)
        }
        let model = DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, nextVersionNumber: 2, debounce: .zero)
        model.requestPublish()
        await model.confirmPublish()

        XCTAssertEqual(model.problems.count, 7)
        XCTAssertEqual(model.problems(for: "title").map(\.message), ["T"])
        XCTAssertEqual(model.problems(for: "servings").map(\.message), ["S"])
        XCTAssertEqual(model.sectionProblems("ingredients").map(\.message), ["I-section"])
        XCTAssertEqual(model.sectionProblems("steps").map(\.message), ["St-section"])
        XCTAssertEqual(model.problems(in: "ingredients", row: 0).map(\.message), ["I0-name"])
        XCTAssertTrue(model.problems(in: "ingredients", row: 1).isEmpty)
        XCTAssertEqual(model.problems(in: "steps", row: 0).map(\.message), ["S0-refs"])
        XCTAssertEqual(model.problems(in: "steps", row: 1).map(\.message), ["S1-instr"])
        XCTAssertTrue(model.problems(in: "steps", row: 10).isEmpty)
        XCTAssertFalse(model.canPublish)
    }

    func testRowMatchingDoesNotBleedBetweenRow1AndRow10() throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let validation = DraftValidation(publishable: false, problems: [
            DraftProblem(field: "steps[10].instruction", message: "ten"),
            DraftProblem(field: "steps[1].instruction", message: "one"),
        ])
        let withProblems = Draft(id: draft.id, recipeId: nil, status: .draft, title: nil, summary: nil, tags: [], coverImageUrl: nil, servings: nil,
                                 prepMinutes: nil, cookMinutes: nil, ingredients: [], steps: [], creatorNotes: [], dietaryWarnings: [],
                                 validation: validation, createdAt: draft.createdAt, updatedAt: draft.updatedAt)
        let model = DraftEditorViewModel(draft: withProblems, service: FakeRecipeService(), creator: AuthoringFixtures.creator)
        XCTAssertEqual(model.problems(in: "steps", row: 1).map(\.message), ["one"])
        XCTAssertEqual(model.problems(in: "steps", row: 10).map(\.message), ["ten"])
    }

    func testPublishWithoutConfirmationNeverCallsServer() async throws {
        let draft = try AuthoringFixtures.draft()
        let service = makeService(initial: draft)
        service.publishDraftHandler = { _ in XCTFail("publish without confirmation"); throw APIError.cancelled }
        let model = DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, nextVersionNumber: 2, debounce: .zero)
        await model.confirmPublish()                 // never requested
        model.requestPublish(); model.cancelPublish()
        await model.confirmPublish()                 // requested then cancelled
        XCTAssertTrue(service.authoringCalls.isEmpty)
        XCTAssertEqual(model.publishPhase, .idle)
    }

    func testPublishRevalidatesAfterFlushWhenPendingEditMakesDraftUnpublishable() async throws {
        let draft = try AuthoringFixtures.draft()   // publishable
        let service = FakeRecipeService()
        service.updateDraftHandler = { _, patch in
            AuthoringFixtures.applying(patch, to: draft, validation: AuthoringFixtures.validate(patch))
        }
        service.publishDraftHandler = { _ in XCTFail("stale 'publishable' must not publish"); throw APIError.cancelled }
        let model = DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, nextVersionNumber: 2, debounce: .seconds(30))
        XCTAssertTrue(model.canPublish)
        model.form.title = ""        // pending, server has not seen it yet
        model.requestPublish()
        await model.confirmPublish()
        guard case .failed = model.publishPhase else { return XCTFail("\(model.publishPhase)") }
        XCTAssertFalse(service.authoringCalls.contains(.publishDraft(draft.id)))
        XCTAssertEqual(model.problems(for: "title").count, 1)
    }

    // MARK: - 2. Autosave

    func testRapidEditsAcrossFieldsCoalesceToOnePatchWithFinalState() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = makeService(initial: draft)
        let model = DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, debounce: .milliseconds(80))
        model.form.title = "A"
        model.form.addIngredient()
        model.form.ingredients[0].name = "garlic"
        model.form.title = "Garlic Pasta"
        model.form.summary = "Quick"
        try await Task.sleep(for: .milliseconds(400))
        let sent = patches(service)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].title, "Garlic Pasta")
        XCTAssertEqual(sent[0].summary, "Quick")
        XCTAssertEqual(sent[0].ingredients?.map(\.name), ["garlic"])
        XCTAssertEqual(model.saveStatus, .saved)
    }

    func testFailedPatchNeverReportsSavedAndRetryResendsFinalState() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = makeService(initial: draft)
        let good = service.updateDraftHandler
        let failing = OSAllocatedUnfairLockBox(true)
        service.updateDraftHandler = { id, patch in
            if failing.value { throw APIError.http(status: 503, correlationId: nil) }
            return try good(id, patch)
        }
        let model = DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, debounce: .zero)
        model.form.title = "Soup"
        await model.flush()
        XCTAssertNotEqual(model.saveStatus, .saved)
        XCTAssertNotEqual(model.saveStatus.label, "Saved")
        model.form.title = "Soup 2"
        XCTAssertNotEqual(model.saveStatus.label, "Saved")
        failing.value = false
        await model.retrySave()
        XCTAssertEqual(model.saveStatus, .saved)
        XCTAssertEqual(patches(service).last?.title, "Soup 2", "retry sends the latest state, not the stale failed body")
        XCTAssertGreaterThanOrEqual(patches(service).count, 2)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testLeavingEditorFlushesPendingEdit() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = makeService(initial: draft)
        let model = DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, debounce: .seconds(30))
        model.form.title = "Pending"
        XCTAssertTrue(model.hasUnsavedChanges)
        await model.flush()               // what DraftEditorView.close() awaits before dismiss
        XCTAssertEqual(patches(service).map(\.title), ["Pending"])
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.saveStatus, .saved)
    }

    func testLeavingEditorWithFailingSaveStaysFlaggedUnsaved() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = FakeRecipeService()
        service.updateDraftHandler = { _, _ in throw APIError.http(status: 500, correlationId: nil) }
        let model = DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, debounce: .seconds(30))
        model.form.title = "Pending"
        await model.flush()
        guard case .failed = model.saveStatus else { return XCTFail("\(model.saveStatus)") }
        XCTAssertTrue(model.hasUnsavedChanges, "view shows the 'haven’t been saved' dialog instead of dismissing")
        XCTAssertEqual(patches(service).count, 1, "flush does not spin on a failing PATCH")
    }

    // MARK: - 3. Save / unsave

    private func detailModel(saved: String) throws -> (RecipeDetailViewModel, FakeRecipeService) {
        let service = FakeRecipeService()
        let detail = try AuthoringFixtures.detail(AuthoringFixtures.detailJSON(saved: saved))
        service.detailHandler = { _ in detail }
        return (RecipeDetailViewModel(recipeId: recipeId, service: service), service)
    }

    func testFailedSaveWithDoubleTapRollsBackAfterSingleRequest() async throws {
        let (model, service) = try detailModel(saved: "false")
        await model.load()
        let gate = AsyncGate()
        service.beforeAuthoring = { _ in await gate.wait() }
        service.saveRecipeHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        let first = Task { await model.toggleSave() }
        await gate.waitUntilWaiting()
        XCTAssertTrue(model.isSaved)
        await model.toggleSave()            // double tap while in flight
        XCTAssertTrue(model.isSaved)
        await gate.open()
        await first.value
        XCTAssertFalse(model.isSaved, "rolled back")
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(service.authoringCalls, [.saveRecipe(recipeId)])
    }

    func testRapidSequentialTogglesEndConsistentWithServer() async throws {
        let (model, service) = try detailModel(saved: "false")
        await model.load()
        await model.toggleSave(); await model.toggleSave(); await model.toggleSave()
        XCTAssertTrue(model.isSaved)
        XCTAssertEqual(service.authoringCalls, [.saveRecipe(recipeId), .unsaveRecipe(recipeId), .saveRecipe(recipeId)])
    }

    // MARK: - 4. Deep links

    func testDeepLinkEdgeCases() {
        let id = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
        for raw in [
            "https://souslens.app.evil.com/r/\(id)",
            "https://evilsouslens.app/r/\(id)",
            "https://sub.souslens.app/r/\(id)",
            "https://souslens.app/R/\(id)",
            "https://souslens.app/r/\(id)/",       // accepted below, kept out of this list
            "https://souslens.app/r/\(id)x",
            "https://souslens.app/r/{\(id)}",
            "souslens:///recipe/\(id)",
            "souslens://recipe/\(id)/",             // accepted below
            "souslens://recipe/\(id)x",
            "souslens://recipe/12345",
            "souslens://recipes/\(id)",
            "ftp://souslens.app/r/\(id)",
            "souslens.app/r/\(id)",
        ] where !raw.hasSuffix("/\(id)/") {
            XCTAssertNil(DeepLink.parse(URL(string: raw)!), raw)
        }
        XCTAssertNotNil(DeepLink.parse(URL(string: "souslens://recipe/\(id)/")!))
        XCTAssertNotNil(DeepLink.parse(URL(string: "HTTPS://SOUSLENS.APP/r/\(id)")!))
        XCTAssertNotNil(DeepLink.parse(URL(string: "souslens://RECIPE/\(id)")!))
        XCTAssertNotNil(DeepLink.parse(URL(string: "https://souslens.app/r/\(id)#frag")!))
    }

    func testLatestSignedOutLinkWinsAndNothingNavigatesBeforeSignIn() async {
        let env = AppEnvironment.preview(signedIn: false)
        await env.auth.restore()
        let a = UUID(), b = UUID()
        env.open(url: ShareLinks.custom(recipeId: a))
        env.open(url: ShareLinks.universal(recipeId: b))
        env.open(url: URL(string: "https://evil.example/r/\(a.uuidString)")!)   // ignored, does not clobber
        XCTAssertEqual(env.pendingDeepLink, .recipe(b))
        XCTAssertTrue(env.exploreRoutes.isEmpty)
        env.forceSignedInForTests()
        env.applyPendingDeepLink()
        XCTAssertEqual(env.exploreRoutes, [.recipe(id: b, card: nil)])
        env.applyPendingDeepLink()            // idempotent: onAppear can fire twice
        XCTAssertEqual(env.exploreRoutes, [.recipe(id: b, card: nil)])
    }

    // MARK: - 7. Decoding tolerance

    func testMyRecipeWithUnknownVisibilityAndNullSavedDecodes() throws {
        let json = AuthoringFixtures.myRecipesJSON
            .replacingOccurrences(of: #""visibility":"public""#, with: #""visibility":"followers_only""#)
            .replacingOccurrences(of: #""saved":false"#, with: #""saved":null"#)
        let items = try JSONCoding.makeDecoder().decode(ItemsResponse<MyRecipe>.self, from: Data(json.utf8)).items
        XCTAssertEqual(items[0].visibility, .unknown)
        XCTAssertNil(items[0].card.saved)
    }

    func testCardWithSavedKeyAbsentDecodes() throws {
        let json = AuthoringFixtures.cardJSON().replacingOccurrences(of: #","saved":true"#, with: "")
        XCTAssertFalse(json.contains("saved"))
        XCTAssertNil(try AuthoringFixtures.card(json).saved)
    }

    func testDetailWithShareUrlKeyAbsentDecodesAndFallsBack() throws {
        let json = AuthoringFixtures.detailJSON().replacingOccurrences(of: #","share_url":"https://souslens.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d""#, with: "")
        XCTAssertFalse(json.contains("share_url"))
        let detail = try AuthoringFixtures.detail(json)
        XCTAssertNil(detail.shareUrl)
        XCTAssertEqual(detail.shareURL, ShareLinks.universal(recipeId: recipeId))
    }
}
