import Foundation
import XCTest
@testable import SousLens

/// Fix order round 1 (brief 003 iOS): one test group per item.
@MainActor
final class Slice1FixRoundTests: XCTestCase {
    private let recipeId = UUID(uuidString: AuthoringFixtures.recipeId)!

    private func json(_ patch: DraftPatch) throws -> [String: Any] {
        let data = try JSONCoding.makeEncoder().encode(patch)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 1. Clearing a field sends explicit null

    func testFormPatchSendsNullForClearedScalarsAndOmitsCover() throws {
        let draft = try AuthoringFixtures.draft()      // prep 5, cook 12, summary set
        var form = DraftForm(draft: draft)
        form.prepMinutes = nil
        form.cookMinutes = nil
        form.summary = "   "
        let body = try json(form.patch())
        XCTAssertTrue(body["prep_minutes"] is NSNull, "cleared prep time must be sent as null (null = clear)")
        XCTAssertTrue(body["cook_minutes"] is NSNull)
        XCTAssertTrue(body["summary"] is NSNull, "a blanked summary clears it")
        XCTAssertEqual(body["title"] as? String, "Garlic Pasta")
        XCTAssertEqual(body["servings"] as? Int, 2)
        XCTAssertNil(body["cover_image_url"], "the editor has no cover control, so it never clears one")
        XCTAssertEqual(Set(body.keys), ["title", "summary", "tags", "servings", "prep_minutes", "cook_minutes",
                                        "ingredients", "steps", "creator_notes", "dietary_warnings"])
    }

    func testBlankTitleIsNullAndNewlinesAreFlattened() throws {
        var form = DraftForm()
        form.title = "\n  "
        XCTAssertTrue(try json(form.patch())["title"] is NSNull)
        form.title = "Garlic\nPasta\n"
        XCTAssertEqual(try json(form.patch())["title"] as? String, "Garlic Pasta")
        XCTAssertEqual(form.patch().title, "Garlic Pasta")
    }

    func testEmptyPatchStillEncodesAsEmptyObject() throws {
        XCTAssertEqual(String(decoding: try JSONCoding.makeEncoder().encode(DraftPatch.empty), as: UTF8.self), "{}")
        var cleared = DraftPatch()
        cleared.clearsWhenNil = [.coverImageUrl]
        XCTAssertEqual(String(decoding: try JSONCoding.makeEncoder().encode(cleared), as: UTF8.self), #"{"cover_image_url":null}"#)
    }

    // MARK: 2. Share links are built from the id, never taken from the server

    func testForeignOrNonHTTPSShareUrlFromServerIsIgnored() async throws {
        for hostile in [#""https://evil.example/phish""#, #""javascript:alert(1)""#, #""http://souslens.app/r/x""#] {
            let detail = try AuthoringFixtures.detail(AuthoringFixtures.detailJSON(shareURL: hostile))
            XCTAssertEqual(detail.shareURL, ShareLinks.universal(recipeId: recipeId), hostile)

            let service = FakeRecipeService()
            service.detailHandler = { _ in detail }
            let model = RecipeDetailViewModel(recipeId: recipeId, service: service)
            await model.load()
            XCTAssertEqual(model.shareURL.absoluteString, "https://souslens.app/r/\(AuthoringFixtures.recipeId)", hostile)

            let publish = try JSONCoding.makeDecoder().decode(PublishResult.self, from: Data("""
            {"recipe_id":"\(AuthoringFixtures.recipeId)","recipe_version_id":"\(AuthoringFixtures.versionId)","version_number":1,"share_url":\(hostile)}
            """.utf8))
            XCTAssertEqual(publish.shareURL, ShareLinks.universal(recipeId: recipeId), hostile)
        }
        XCTAssertTrue(PublishedView.linkCaveat.contains("aren’t live yet"))
    }

    // MARK: 4. Read-only drafts never PATCH

    func testNoPatchIssuedForReadOnlyDraft() async throws {
        let published = AuthoringFixtures.fullDraftJSON.replacingOccurrences(of: #""status":"draft""#, with: #""status":"published""#)
        let service = FakeRecipeService()
        service.updateDraftHandler = { _, _ in XCTFail("PATCH on a read-only draft"); throw APIError.cancelled }
        let model = DraftEditorViewModel(draft: try AuthoringFixtures.draft(published), service: service,
                                         creator: AuthoringFixtures.creator, debounce: .zero)
        XCTAssertTrue(model.isPublishedReadOnly)
        model.form.title = "Edited anyway"
        model.form.prepMinutes = nil
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.saveStatus, .saved)
        await model.flush()
        await model.retrySave()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(service.authoringCalls.isEmpty)
    }

    func testAfter409ThereIsNothingUnsavedToAskAbout() async throws {
        let service = FakeRecipeService()
        service.updateDraftHandler = { _, _ in
            throw APIError.server(status: 409, code: "STATE_CONFLICT", message: "published", retryable: false, correlationId: nil)
        }
        let model = DraftEditorViewModel(draft: try AuthoringFixtures.draft(), service: service, creator: AuthoringFixtures.creator, debounce: .zero)
        model.form.title = "x"
        await model.flush()
        XCTAssertTrue(model.isPublishedReadOnly)
        XCTAssertFalse(model.hasUnsavedChanges, "close dismisses without the unsaved-changes dialog")
        model.form.title = "y"
        await model.flush()
        XCTAssertEqual(service.authoringCalls.count, 1, "no further PATCH after the 409")
    }

    // MARK: 5. Step provenance survives an edit

    func testStepProvenanceRoundTripsAndNewStepsAreCreatorAuthored() throws {
        let aiStep = #"{"id":"step-1","order":0,"instruction":"Sear.","ingredient_refs":[],"estimated_minutes":null,"success_cues":["Brown"],"warnings":[],"creator_note":null,"source_clip_id":"clip-7","source_start_ms":1000,"source_end_ms":9000,"evidence_origin":"ai_extracted"}"#
        let json = AuthoringFixtures.fullDraftJSON.replacingOccurrences(of: AuthoringFixtures.stepJSON, with: aiStep)
        XCTAssertNotEqual(json, AuthoringFixtures.fullDraftJSON)
        var form = DraftForm(draft: try AuthoringFixtures.draft(json))
        form.steps[0].instruction = "Sear hard."
        let added = form.addStep()
        form.steps[1].instruction = "Rest."
        let steps = try XCTUnwrap(form.patch().steps)
        XCTAssertEqual(steps[0].evidenceOrigin, .aiExtracted)
        XCTAssertEqual(steps[0].sourceClipId, "clip-7")
        XCTAssertEqual(steps[0].sourceStartMs, 1000)
        XCTAssertEqual(steps[0].sourceEndMs, 9000)
        XCTAssertEqual(steps[0].instruction, "Sear hard.")
        XCTAssertEqual(steps[1].id, added.id)
        XCTAssertEqual(steps[1].evidenceOrigin, .creatorAuthored)
        XCTAssertNil(steps[1].sourceClipId)
        XCTAssertEqual(form.previewDetail(draft: try AuthoringFixtures.draft(json), creator: AuthoringFixtures.creator, versionNumber: 2).headerProvenanceLabel,
                       "AI-extracted", "preview keeps the honest label")
    }

    // MARK: 6. Stable-id list lines

    func testEditableLinesHaveStableIdsAndBlankLinesAreDropped() {
        var lines: [EditableLine] = ["a", "", "  b  "]
        let ids = lines.map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
        lines.remove(at: 1)
        XCTAssertEqual(lines.map(\.id), [ids[0], ids[2]], "deleting keeps the other rows' identity")
        XCTAssertEqual(EditableLine.texts(lines), ["a", "b"])
    }

    // MARK: 8. Numeric fields commit on change

    func testNumericParsing() {
        XCTAssertEqual(NumericTextField.parse("12", allowsDecimal: false), 12)
        XCTAssertEqual(NumericTextField.parse("1.", allowsDecimal: true), 1)
        XCTAssertEqual(NumericTextField.parse("1,5", allowsDecimal: true), 1.5)
        XCTAssertEqual(NumericTextField.parse("2.7", allowsDecimal: false), 2)
        XCTAssertNil(NumericTextField.parse("", allowsDecimal: true), "empty clears")
        XCTAssertNil(NumericTextField.parse("abc", allowsDecimal: true))
        XCTAssertNil(NumericTextField.parse("-3", allowsDecimal: true))
        XCTAssertEqual(NumericTextField.format(2), "2")
        XCTAssertEqual(NumericTextField.format(1.5), "1.5")
        XCTAssertEqual(NumericTextField.format(nil), "")
    }

    // MARK: 9. Publish after a network failure

    func testPublishNetworkFailureButServerPublishedShowsSuccess() async throws {
        let service = FakeRecipeService()
        service.publishDraftHandler = { _ in throw APIError.unreachable(baseURL: "http://localhost:8000", underlying: "timed out") }
        let published = AuthoringFixtures.fullDraftJSON.replacingOccurrences(of: #""status":"draft""#, with: #""status":"published""#)
        service.draftHandler = { _ in try AuthoringFixtures.draft(published) }
        service.detailHandler = { _ in try AuthoringFixtures.detail() }   // version 2
        let model = DraftEditorViewModel(draft: try AuthoringFixtures.draft(), service: service, creator: AuthoringFixtures.creator,
                                         nextVersionNumber: 2, debounce: .zero)
        model.requestPublish()
        await model.confirmPublish()
        let result = try XCTUnwrap(model.publishResult, "\(model.publishPhase)")
        XCTAssertEqual(result.versionNumber, 2)
        XCTAssertEqual(result.recipeId, recipeId)
        XCTAssertTrue(model.isPublishedReadOnly)
        XCTAssertEqual(service.authoringCalls.filter { if case .publishDraft = $0 { true } else { false } }.count, 1, "never publishes twice")
    }

    func testPublishNetworkFailureAndDraftStillDraftReportsUncertainFailure() async throws {
        let service = FakeRecipeService()
        service.publishDraftHandler = { _ in throw APIError.unreachable(baseURL: "http://localhost:8000", underlying: "timed out") }
        service.draftHandler = { _ in try AuthoringFixtures.draft() }
        let model = DraftEditorViewModel(draft: try AuthoringFixtures.draft(), service: service, creator: AuthoringFixtures.creator,
                                         nextVersionNumber: 2, debounce: .zero)
        model.requestPublish()
        await model.confirmPublish()
        guard case .failed(let message) = model.publishPhase else { return XCTFail("\(model.publishPhase)") }
        XCTAssertTrue(message.contains("check My recipes"))
        XCTAssertFalse(model.isPublishedReadOnly)

        // A server that answered (422) is not re-checked.
        let answered = FakeRecipeService()
        answered.publishDraftHandler = { _ in throw APIError.server(status: 422, code: "VALIDATION_ERROR", message: "No.", retryable: false, correlationId: nil) }
        let other = DraftEditorViewModel(draft: try AuthoringFixtures.draft(), service: answered, creator: AuthoringFixtures.creator, debounce: .zero)
        other.requestPublish()
        await other.confirmPublish()
        XCTAssertEqual(other.publishPhase, .failed("No."))
        XCTAssertFalse(answered.authoringCalls.contains { if case .draft = $0 { true } else { false } })
    }

    // MARK: 10. Saved tab learns about save changes

    func testSavedChangeCallbackFiresOnConfirmedChangeOnly() async throws {
        let service = FakeRecipeService()
        service.detailHandler = { _ in try AuthoringFixtures.detail() }
        let model = RecipeDetailViewModel(recipeId: recipeId, service: service)
        await model.load()
        var events: [Bool] = []
        model.onSavedChanged = { _, saved in events.append(saved) }
        await model.toggleSave()
        XCTAssertEqual(events, [true])
        service.unsaveRecipeHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        await model.toggleSave()
        XCTAssertEqual(events, [true], "a rolled-back toggle changes nothing")

        let env = AppEnvironment.preview()
        let before = env.savedRevision
        env.noteSavedChanged()
        XCTAssertEqual(env.savedRevision, before + 1)
    }

    // MARK: 11. Smaller correctness fixes

    func testDottedRowFieldsDoNotBleed() throws {
        let draft = try AuthoringFixtures.emptyDraft()
        let validation = DraftValidation(publishable: false, problems: [
            DraftProblem(field: "ingredients.10.name", message: "ten"),
            DraftProblem(field: "ingredients.1", message: "one"),
        ])
        let withProblems = Draft(id: draft.id, recipeId: nil, status: .draft, title: nil, summary: nil, tags: [], coverImageUrl: nil, servings: nil,
                                 prepMinutes: nil, cookMinutes: nil, ingredients: [], steps: [], creatorNotes: [], dietaryWarnings: [],
                                 validation: validation, createdAt: draft.createdAt, updatedAt: draft.updatedAt)
        let model = DraftEditorViewModel(draft: withProblems, service: FakeRecipeService(), creator: AuthoringFixtures.creator)
        XCTAssertEqual(model.problems(in: "ingredients", row: 1).map(\.message), ["one"])
        XCTAssertEqual(model.problems(in: "ingredients", row: 10).map(\.message), ["ten"])
        XCTAssertTrue(DraftValidation.field("titles", isWithin: "title") == false)
    }

    func testServerChangeClearsPendingDeepLink() async {
        let env = AppEnvironment.preview(signedIn: false)
        await env.auth.restore()
        env.open(url: ShareLinks.custom(recipeId: recipeId))
        XCTAssertEqual(env.pendingDeepLink, .recipe(recipeId))
        env.serverSettings.baseURLText = "http://192.168.1.50:8000"
        XCTAssertNil(env.pendingDeepLink, "a recipe id from the old server must not open on the new one")
        XCTAssertTrue(env.exploreRoutes.isEmpty)
    }

    func testReloadDuringToggleDoesNotOverwriteOptimisticSaved() async throws {
        let service = FakeRecipeService()
        service.detailHandler = { _ in try AuthoringFixtures.detail(AuthoringFixtures.detailJSON(saved: "false")) }
        let model = RecipeDetailViewModel(recipeId: recipeId, service: service)
        await model.load()
        let gate = AsyncGate()
        service.beforeAuthoring = { _ in await gate.wait() }
        let toggle = Task { await model.toggleSave() }
        await gate.waitUntilWaiting()
        await model.load()                 // stale `saved: false` arrives mid-toggle
        XCTAssertTrue(model.isSaved)
        await gate.open()
        await toggle.value
        XCTAssertTrue(model.isSaved)
    }

    // MARK: 12. Client-side normalisation to the backend's PATCH rules

    func testPatchIsNormalisedToBackendTextRules() throws {
        var form = DraftForm()
        form.title = "  Garlic\nPasta\u{202E}\u{0007}  " + String(repeating: "x", count: 200)
        form.summary = "Line one\r\nLine two\u{200F}"
        form.tags = ["  Weeknight ", "WEEKNIGHT", "Korean\nFood", "   ", String(repeating: "t", count: 60)]
        form.addIngredient()
        form.ingredients[0].name = " Garlic\ncloves\u{0000} "
        form.ingredients[0].unit = String(repeating: "u", count: 50)
        form.ingredients[0].preparation = "minced\n"
        form.addStep()
        form.steps[0].instruction = "Stir.\n\nThen rest." + String(repeating: "y", count: 2500)
        form.steps[0].successCues = ["  Glossy\u{2066} ", "  "]
        form.creatorNotes = [EditableLine(String(repeating: "n", count: 600))]
        let patch = form.patch()

        let title = try XCTUnwrap(patch.title)
        XCTAssertTrue(title.hasPrefix("Garlic Pasta"), title)
        XCTAssertFalse(title.contains("\n"))
        XCTAssertFalse(title.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x0007 })
        XCTAssertLessThanOrEqual(title.count, DraftLimits.title)
        XCTAssertEqual(patch.summary, "Line one\nLine two", "multi-line fields keep newlines, lose bidi marks")
        XCTAssertEqual(patch.tags, ["weeknight", "korean food", String(repeating: "t", count: 40)], "trimmed, lowercased, unique, ≤40")
        let ingredient = try XCTUnwrap(patch.ingredients?.first)
        XCTAssertEqual(ingredient.name, "Garlic cloves")
        XCTAssertEqual(ingredient.unit?.count, DraftLimits.unit)
        XCTAssertEqual(ingredient.preparation, "minced")
        let step = try XCTUnwrap(patch.steps?.first)
        XCTAssertTrue(step.instruction.hasPrefix("Stir.\n\nThen rest."))
        XCTAssertEqual(step.instruction.count, DraftLimits.instruction)
        XCTAssertEqual(step.successCues, ["Glossy"])
        XCTAssertEqual(patch.creatorNotes?.first?.count, DraftLimits.line)
    }

    func testPatch422ShowsServerReasonInlineWithoutRetryLoop() async throws {
        let service = FakeRecipeService()
        service.updateDraftHandler = { _, _ in
            throw APIError.server(status: 422, code: "VALIDATION_ERROR", message: "Title must be 120 characters or fewer.",
                                  retryable: false, correlationId: nil, details: .object(["fields": .array([.string("body.title")])]))
        }
        let model = DraftEditorViewModel(draft: try AuthoringFixtures.draft(), service: service, creator: AuthoringFixtures.creator, debounce: .zero)
        model.form.title = "Too long"
        await model.flush()
        XCTAssertEqual(model.saveStatus, .rejected("Title must be 120 characters or fewer."))
        XCTAssertEqual(model.saveStatus.label, "Couldn’t save · Title must be 120 characters or fewer.")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(service.authoringCalls.count, 1, "flush does not spin on a 422")

        model.requestPublish()
        await model.confirmPublish()
        guard case .failed(let message) = model.publishPhase else { return XCTFail("\(model.publishPhase)") }
        XCTAssertTrue(message.contains("weren’t accepted"))
        XCTAssertFalse(service.authoringCalls.contains(.publishDraft(model.id)))
    }
}
