import Foundation
import XCTest
@testable import SousLens

@MainActor
final class DraftEditorViewModelTests: XCTestCase {
    /// A fake whose PATCH answers like the backend: applies the patch and re-validates (REC-04 rules).
    private func makeService(initial: Draft) -> FakeRecipeService {
        let service = FakeRecipeService()
        service.updateDraftHandler = { _, patch in
            AuthoringFixtures.applying(patch, to: initial, validation: AuthoringFixtures.validate(patch))
        }
        return service
    }

    private func makeModel(draft: Draft, service: FakeRecipeService, debounce: Duration = .zero) -> DraftEditorViewModel {
        DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, debounce: debounce)
    }

    private var patchCalls: (FakeRecipeService) -> [DraftPatch] {
        { service in
            service.authoringCalls.compactMap { if case .updateDraft(_, let patch) = $0 { return patch } else { return nil } }
        }
    }

    // MARK: - Autosave

    func testEditSchedulesDebouncedPatchAndStatusGoesSavingThenSaved() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = makeService(initial: draft)
        let model = makeModel(draft: draft, service: service, debounce: .milliseconds(40))
        XCTAssertEqual(model.saveStatus, .saved)
        XCTAssertFalse(model.hasUnsavedChanges)

        model.form.title = "G"
        model.form.title = "Ga"
        model.form.title = "Garlic Pasta"
        XCTAssertEqual(model.saveStatus, .pending)
        XCTAssertEqual(model.saveStatus.label, "Saving…")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(patchCalls(service).isEmpty, "nothing is sent before the debounce elapses")

        await model.flush()

        XCTAssertEqual(model.saveStatus, .saved)
        XCTAssertFalse(model.hasUnsavedChanges)
        let patches = patchCalls(service)
        XCTAssertEqual(patches.count, 1, "keystrokes coalesce into one PATCH")
        XCTAssertEqual(patches[0].title, "Garlic Pasta")
        XCTAssertEqual(patches[0].servings, 4)
        XCTAssertEqual(patches[0].ingredients, [])
        XCTAssertEqual(model.draft.title, "Garlic Pasta", "server response becomes the draft of record")
    }

    func testRapidEditsWithRealDebounceIssueOnePatch() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = makeService(initial: draft)
        let model = makeModel(draft: draft, service: service, debounce: .milliseconds(60))
        for text in ["g", "ga", "gar", "garl", "garli", "garlic"] {
            model.form.title = text
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(patchCalls(service).map(\.title), ["garlic"])
        XCTAssertEqual(model.saveStatus, .saved)
    }

    func testEditDuringInFlightSaveIsSavedAfterwards() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = makeService(initial: draft)
        let gate = AsyncGate()
        service.beforeAuthoring = { call in
            if case .updateDraft = call { await gate.wait() }
        }
        let model = makeModel(draft: draft, service: service)

        model.form.title = "First"
        let flush = Task { await model.flush() }
        await gate.waitUntilWaiting()
        XCTAssertEqual(model.saveStatus, .saving)
        model.form.title = "First then second"   // arrives while PATCH #1 is in flight
        XCTAssertEqual(model.saveStatus.label, "Saving…")
        XCTAssertTrue(model.hasUnsavedChanges)
        await gate.open()
        await flush.value
        // flush() waits for the in-flight save, then saves the dirty form again.
        XCTAssertEqual(patchCalls(service).map(\.title), ["First", "First then second"])
        XCTAssertEqual(model.saveStatus, .saved)
    }

    func testFailedSaveShowsRetryStateAndRetrySucceeds() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = makeService(initial: draft)
        let failing = OSAllocatedUnfairLockBox(true)
        let good = service.updateDraftHandler
        service.updateDraftHandler = { id, patch in
            if failing.value { throw APIError.unreachable(baseURL: "http://localhost:8000", underlying: "refused") }
            return try good(id, patch)
        }
        let model = makeModel(draft: draft, service: service)

        model.form.title = "Garlic Pasta"
        await model.flush()
        guard case .failed(let message) = model.saveStatus else { return XCTFail("expected failed, got \(model.saveStatus)") }
        XCTAssertTrue(message.contains("Can’t reach the server"))
        XCTAssertEqual(model.saveStatus.label, "Couldn’t save")
        XCTAssertTrue(model.hasUnsavedChanges, "the edit is still unsaved")
        XCTAssertEqual(model.draft.title, nil, "the draft of record is untouched by a failed save")

        // Further typing keeps the failure visible (no silent flip back to "Saving…").
        model.form.title = "Garlic Pasta!"
        if case .failed = model.saveStatus {} else { XCTFail("failure must stay visible until a save succeeds") }

        failing.value = false
        await model.retrySave()
        XCTAssertEqual(model.saveStatus, .saved)
        XCTAssertEqual(model.draft.title, "Garlic Pasta!")
    }

    func testPatchOnPublishedDraft409MarksEditorReadOnly() async throws {
        let draft = try AuthoringFixtures.draft()
        let service = makeService(initial: draft)
        service.updateDraftHandler = { _, _ in
            throw APIError.server(status: 409, code: "STATE_CONFLICT", message: "Draft is published.", retryable: false, correlationId: nil,
                                  details: .object(["recipe_id": .string(AuthoringFixtures.recipeId)]))
        }
        let model = makeModel(draft: draft, service: service)
        XCTAssertFalse(model.isPublishedReadOnly)
        model.form.title = "Too late"
        await model.flush()
        XCTAssertTrue(model.isPublishedReadOnly)
        guard case .failed(let message) = model.saveStatus else { return XCTFail("\(model.saveStatus)") }
        XCTAssertTrue(message.contains("already published"))
        XCTAssertFalse(model.canPublish, "a published draft is never published twice")

        let publishedJSON = AuthoringFixtures.fullDraftJSON.replacingOccurrences(of: #""status":"draft""#, with: #""status":"published""#)
        let opened = makeModel(draft: try AuthoringFixtures.draft(publishedJSON), service: service)
        XCTAssertTrue(opened.isPublishedReadOnly)
        XCTAssertFalse(opened.canPublish)
    }

    // MARK: - Validation surfaced inline

    func testProblemsSurfacePerFieldAndPerRowAndPublishStaysDisabled() async throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let service = makeService(initial: draft)
        let model = makeModel(draft: draft, service: service)

        XCTAssertEqual(model.problems(for: "title").map(\.message), ["Add a title"])
        XCTAssertEqual(model.sectionProblems("ingredients").map(\.message), ["Add at least one ingredient"])
        XCTAssertFalse(model.canPublish)

        model.form.title = "Garlic Pasta"
        model.form.addIngredient()
        model.form.ingredients[0].name = "garlic"
        model.form.addStep()           // instruction left empty → row-level problem
        await model.flush()

        XCTAssertFalse(model.validation.publishable)
        XCTAssertFalse(model.canPublish)
        XCTAssertTrue(model.problems(for: "title").isEmpty)
        XCTAssertTrue(model.sectionProblems("ingredients").isEmpty)
        XCTAssertEqual(model.sectionProblems("steps").map(\.message), ["Add at least one step"])
        XCTAssertEqual(model.problems(in: "steps", row: 0).map(\.message), ["Step 1 needs an instruction"])
        XCTAssertTrue(model.problems(in: "steps", row: 1).isEmpty)

        model.form.steps[0].instruction = "Sizzle the garlic."
        await model.flush()
        XCTAssertTrue(model.validation.publishable)
        XCTAssertTrue(model.problems.isEmpty)
        XCTAssertTrue(model.canPublish)
    }

    func testPydanticStyleRowFieldsAlsoMatch() throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let model = makeModel(draft: draft, service: FakeRecipeService())
        let validation = DraftValidation(publishable: false, problems: [DraftProblem(field: "ingredients.2.name", message: "Name it")])
        let patched = Draft(id: draft.id, recipeId: nil, status: .draft, title: nil, summary: nil, tags: [], coverImageUrl: nil, servings: nil,
                            prepMinutes: nil, cookMinutes: nil, ingredients: [], steps: [], creatorNotes: [], dietaryWarnings: [],
                            validation: validation, createdAt: draft.createdAt, updatedAt: draft.updatedAt)
        let model2 = makeModel(draft: patched, service: FakeRecipeService())
        XCTAssertEqual(model2.problems(in: "ingredients", row: 2).map(\.message), ["Name it"])
        XCTAssertTrue(model.problems(in: "ingredients", row: 2).isEmpty)
    }

    // MARK: - Publish

    func testPublishRequiresConfirmationThenSucceeds() async throws {
        let draft = try AuthoringFixtures.draft()   // publishable, recipe_id set (an edit)
        let service = makeService(initial: draft)
        let expected = try JSONCoding.makeDecoder().decode(PublishResult.self, from: Data(AuthoringFixtures.publishResultJSON.utf8))
        service.publishDraftHandler = { _ in expected }
        let model = DraftEditorViewModel(draft: draft, service: service, creator: AuthoringFixtures.creator, nextVersionNumber: 2, debounce: .zero)

        XCTAssertTrue(model.canPublish)
        XCTAssertEqual(model.publishPhase, .idle)
        XCTAssertEqual(model.publishConfirmationTitle, "Publish version 2?")
        XCTAssertEqual(DraftEditorViewModel.publishConfirmationMessage, "This snapshot can’t be edited; later edits create a new version.")

        await model.confirmPublish()
        XCTAssertEqual(model.publishPhase, .idle, "confirmPublish without requestPublish is a no-op")
        XCTAssertTrue(service.authoringCalls.isEmpty)

        model.requestPublish()
        XCTAssertEqual(model.publishPhase, .confirming)
        XCTAssertFalse(model.canPublish, "no double publish while confirming")
        model.cancelPublish()
        XCTAssertEqual(model.publishPhase, .idle)

        model.requestPublish()
        await model.confirmPublish()
        XCTAssertEqual(model.publishPhase, .published(expected))
        XCTAssertEqual(model.publishResult?.shareUrl, "https://souslens.app/r/\(AuthoringFixtures.recipeId)")
        XCTAssertEqual(service.authoringCalls, [.publishDraft(draft.id)])
        XCTAssertFalse(model.canPublish)
    }

    func testPublishFlushesPendingEditsFirst() async throws {
        let draft = try AuthoringFixtures.draft()
        let service = makeService(initial: draft)
        service.publishDraftHandler = { _ in
            try JSONCoding.makeDecoder().decode(PublishResult.self, from: Data(AuthoringFixtures.publishResultJSON.utf8))
        }
        let model = makeModel(draft: draft, service: service, debounce: .seconds(10))
        model.form.summary = "Edited just before publishing"
        model.requestPublish()
        await model.confirmPublish()
        guard case .published = model.publishPhase else { return XCTFail("\(model.publishPhase)") }
        XCTAssertEqual(service.authoringCalls.count, 2)
        guard case .updateDraft(_, let patch) = service.authoringCalls[0] else { return XCTFail("PATCH must precede publish") }
        XCTAssertEqual(patch.summary, "Edited just before publishing")
        XCTAssertEqual(service.authoringCalls[1], .publishDraft(draft.id))
    }

    func testPublishRefusedBy422SurfacesServerProblems() async throws {
        let draft = try AuthoringFixtures.draft()
        let service = makeService(initial: draft)
        let envelope = try JSONCoding.makeDecoder().decode(APIErrorEnvelope.self, from: Data(AuthoringFixtures.validationErrorJSON.utf8))
        service.publishDraftHandler = { _ in
            throw APIError.server(status: 422, code: "VALIDATION_ERROR", message: envelope.error.message, retryable: false, correlationId: "c-422", details: envelope.error.details)
        }
        let model = makeModel(draft: draft, service: service)
        model.requestPublish()
        await model.confirmPublish()
        XCTAssertEqual(model.publishPhase, .failed("Draft is not publishable."))
        XCTAssertFalse(model.validation.publishable)
        XCTAssertEqual(model.problems(for: "title").map(\.message), ["Add a title"])
        XCTAssertEqual(model.problems(in: "steps", row: 0).map(\.message), ["Step 1 needs an instruction"])
        XCTAssertFalse(model.canPublish)
        model.cancelPublish()
        XCTAssertEqual(model.publishPhase, .idle)
    }

    func testPublishBlockedWhenLatestSaveFailed() async throws {
        let draft = try AuthoringFixtures.draft()
        let service = makeService(initial: draft)
        service.updateDraftHandler = { _, _ in throw APIError.http(status: 503, correlationId: nil) }
        service.publishDraftHandler = { _ in XCTFail("must not publish stale content"); throw APIError.cancelled }
        let model = makeModel(draft: draft, service: service)
        model.form.title = "Changed"
        model.requestPublish()
        await model.confirmPublish()
        guard case .failed(let message) = model.publishPhase else { return XCTFail("\(model.publishPhase)") }
        XCTAssertTrue(message.contains("didn’t save"))
        XCTAssertFalse(service.authoringCalls.contains(.publishDraft(draft.id)))
    }

    func testNextVersionNumberIsOneForNewRecipeAndResolvedForEdits() async throws {
        let fresh = makeModel(draft: try AuthoringFixtures.emptyDraft(), service: FakeRecipeService())
        XCTAssertEqual(fresh.nextVersionNumber, 1)
        XCTAssertEqual(fresh.publishConfirmationTitle, "Publish version 1?")

        let service = FakeRecipeService()
        service.detailHandler = { _ in try AuthoringFixtures.detail() }   // version_number 2
        let edit = makeModel(draft: try AuthoringFixtures.draft(), service: service)
        XCTAssertNil(edit.nextVersionNumber)
        XCTAssertEqual(edit.publishConfirmationTitle, "Publish a new version?")
        await edit.resolveNextVersionNumber()
        XCTAssertEqual(edit.nextVersionNumber, 3)
        XCTAssertEqual(edit.previewDetail().versionNumber, 3)
    }

    // MARK: - Entry points

    func testCreateNewPostsEmptyDraft() async throws {
        let service = FakeRecipeService()
        service.createDraftHandler = { _ in try AuthoringFixtures.emptyDraft() }
        let model = try await DraftEditorViewModel.createNew(service: service, creator: AuthoringFixtures.creator, debounce: .zero)
        XCTAssertEqual(service.authoringCalls, [.createDraft(.empty)])
        XCTAssertEqual(model.form.title, "")
        XCTAssertFalse(model.canPublish)
    }

    func testEditOpensNewDraftOrTheExistingOneOn409() async throws {
        let recipeId = UUID(uuidString: AuthoringFixtures.recipeId)!
        let draftId = UUID(uuidString: AuthoringFixtures.draftId)!
        let service = FakeRecipeService()
        service.editRecipeHandler = { _ in try AuthoringFixtures.draft() }
        let fresh = try await DraftEditorViewModel.forEditing(recipeId: recipeId, latestVersionNumber: 2, service: service, creator: AuthoringFixtures.creator, debounce: .zero)
        XCTAssertEqual(fresh.draft.recipeId, recipeId)
        XCTAssertEqual(fresh.nextVersionNumber, 3)
        XCTAssertEqual(service.authoringCalls, [.editRecipe(recipeId)])

        let conflicting = FakeRecipeService()
        let envelope = try JSONCoding.makeDecoder().decode(APIErrorEnvelope.self, from: Data(AuthoringFixtures.stateConflictJSON.utf8))
        conflicting.editRecipeHandler = { _ in
            throw APIError.server(status: 409, code: "STATE_CONFLICT", message: envelope.error.message, retryable: false, correlationId: "c-409", details: envelope.error.details)
        }
        conflicting.draftHandler = { id in
            XCTAssertEqual(id, draftId)
            return try AuthoringFixtures.draft()
        }
        let reopened = try await DraftEditorViewModel.forEditing(recipeId: recipeId, latestVersionNumber: 2, service: conflicting, creator: AuthoringFixtures.creator, debounce: .zero)
        XCTAssertEqual(reopened.id, draftId)
        XCTAssertEqual(conflicting.authoringCalls, [.editRecipe(recipeId), .draft(draftId)])

        let broken = FakeRecipeService()
        broken.editRecipeHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        do {
            _ = try await DraftEditorViewModel.forEditing(recipeId: recipeId, latestVersionNumber: nil, service: broken, creator: AuthoringFixtures.creator, debounce: .zero)
            XCTFail("non-409 errors propagate")
        } catch let error as APIError {
            XCTAssertEqual(error, .http(status: 500, correlationId: nil))
        }
    }

    func testOpenLoadsDraftById() async throws {
        let draftId = UUID(uuidString: AuthoringFixtures.draftId)!
        let service = FakeRecipeService()
        service.draftHandler = { _ in try AuthoringFixtures.draft() }
        let model = try await DraftEditorViewModel.open(draftId: draftId, service: service, creator: AuthoringFixtures.creator, debounce: .zero)
        XCTAssertEqual(model.id, draftId)
        XCTAssertEqual(model.form.title, "Garlic Pasta")
        XCTAssertEqual(service.authoringCalls, [.draft(draftId)])
    }
}

/// Tiny lock box for flags flipped from inside `@Sendable` fake handlers.
final class OSAllocatedUnfairLockBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
