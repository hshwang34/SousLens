import Foundation
import XCTest
@testable import SousLens

/// Brief 003 DTOs decode from JSON shaped exactly like `003-api-contract.md`.
final class AuthoringDTOTests: XCTestCase {
    private let decoder = JSONCoding.makeDecoder()

    // MARK: - Draft

    func testEmptyDraftDecodesNullsAndProblems() throws {
        let draft = try AuthoringFixtures.emptyDraft()
        XCTAssertEqual(draft.id.uuidString.lowercased(), AuthoringFixtures.draftId)
        XCTAssertNil(draft.recipeId)
        XCTAssertEqual(draft.status, .draft)
        XCTAssertNil(draft.title)
        XCTAssertNil(draft.summary)
        XCTAssertNil(draft.servings)
        XCTAssertNil(draft.prepMinutes)
        XCTAssertNil(draft.coverImageUrl)
        XCTAssertTrue(draft.tags.isEmpty)
        XCTAssertTrue(draft.ingredients.isEmpty)
        XCTAssertTrue(draft.steps.isEmpty)
        XCTAssertFalse(draft.validation.publishable)
        XCTAssertEqual(draft.validation.problems.map(\.field), ["title", "ingredients", "steps"])
        XCTAssertEqual(draft.validation.problems[1].message, "Add at least one ingredient")
    }

    func testFullDraftDecodesEveryFieldAndIgnoresUnknownKeys() throws {
        let draft = try AuthoringFixtures.draft()
        XCTAssertEqual(draft.recipeId?.uuidString.lowercased(), AuthoringFixtures.recipeId)
        XCTAssertEqual(draft.title, "Garlic Pasta")
        XCTAssertEqual(draft.tags, ["pasta", "weeknight"])
        XCTAssertEqual(draft.servings, 2)
        XCTAssertEqual(draft.prepMinutes, 5)
        XCTAssertEqual(draft.cookMinutes, 12)
        XCTAssertEqual(draft.ingredients.count, 1)
        XCTAssertEqual(draft.ingredients[0].id, "ing-1")
        XCTAssertEqual(draft.ingredients[0].quantity, 3)
        XCTAssertEqual(draft.ingredients[0].preparation, "minced")
        XCTAssertNil(draft.ingredients[0].notes)
        XCTAssertEqual(draft.steps[0].ingredientRefs, ["ing-1"])
        XCTAssertEqual(draft.steps[0].evidenceOrigin, .creatorAuthored)
        XCTAssertEqual(draft.steps[0].successCues, ["Fragrant, not brown"])
        XCTAssertEqual(draft.creatorNotes, ["Salt the water like the sea."])
        XCTAssertEqual(draft.dietaryWarnings, ["Contains wheat."])
        XCTAssertTrue(draft.validation.publishable)
        XCTAssertTrue(draft.validation.problems.isEmpty)
        XCTAssertEqual(draft.createdAt, try XCTUnwrap(ISO8601Flexible.parse("2026-10-20T10:00:00.123456Z")))
        XCTAssertEqual(draft.updatedAt, try XCTUnwrap(ISO8601Flexible.parse("2026-10-20T10:05:00Z")))
    }

    func testDraftStatusUnknownValueDoesNotBreakDecode() throws {
        let json = AuthoringFixtures.fullDraftJSON.replacingOccurrences(of: #""status":"draft""#, with: #""status":"archived_v2""#)
        XCTAssertEqual(try AuthoringFixtures.draft(json).status, .unknown)
        let published = AuthoringFixtures.fullDraftJSON.replacingOccurrences(of: #""status":"draft""#, with: #""status":"published""#)
        XCTAssertEqual(try AuthoringFixtures.draft(published).status, .published)
    }

    func testDraftSummaryListDecodes() throws {
        let page = try decoder.decode(ItemsResponse<DraftSummary>.self, from: Data(AuthoringFixtures.draftSummaryListJSON.utf8))
        XCTAssertEqual(page.items.count, 2)
        let untitled = page.items[0]
        XCTAssertNil(untitled.title)
        XCTAssertEqual(untitled.displayTitle, "Untitled draft")
        XCTAssertEqual(untitled.ingredientCount, 0)
        XCTAssertEqual(untitled.stepCount, 0)
        XCTAssertNil(untitled.recipeId)
        XCTAssertEqual(untitled.validation.problems.first?.field, "title")
        let edit = page.items[1]
        XCTAssertEqual(edit.displayTitle, "Garlic Pasta")
        XCTAssertEqual(edit.recipeId?.uuidString.lowercased(), AuthoringFixtures.recipeId)
        XCTAssertEqual(edit.ingredientCount, 4)
        XCTAssertEqual(edit.stepCount, 5)
        XCTAssertTrue(edit.validation.publishable)
    }

    func testDraftValidationPrefixMatching() {
        let validation = DraftValidation(publishable: false, problems: [
            DraftProblem(field: "ingredients", message: "a"),
            DraftProblem(field: "ingredients[1].name", message: "b"),
            DraftProblem(field: "steps[0].ingredient_refs", message: "c"),
            DraftProblem(field: "title", message: "d"),
        ])
        XCTAssertEqual(validation.problems(for: "ingredients").map(\.message), ["a", "b"])
        XCTAssertEqual(validation.problems(exactly: "ingredients").map(\.message), ["a"])
        XCTAssertEqual(validation.problems(for: "steps").map(\.message), ["c"])
        XCTAssertEqual(validation.problems(for: "title").map(\.message), ["d"])
        XCTAssertTrue(validation.problems(for: "tit").isEmpty, "prefix must stop at a field boundary")
    }

    // MARK: - DraftPatch encoding

    func testDraftPatchOmitsNilAndEncodesSnakeCase() throws {
        var patch = DraftPatch()
        patch.title = "T"
        patch.prepMinutes = 5
        patch.tags = []
        let data = try JSONCoding.makeEncoder().encode(patch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "T")
        XCTAssertEqual(object["prep_minutes"] as? Int, 5)
        XCTAssertEqual((object["tags"] as? [Any])?.count, 0, "an empty array is sent (arrays replace whole)")
        XCTAssertNil(object["summary"], "nil fields are omitted, not sent as null")
        XCTAssertNil(object["ingredients"])
        XCTAssertEqual(Set(object.keys), ["title", "prep_minutes", "tags"])

        let empty = try JSONCoding.makeEncoder().encode(DraftPatch.empty)
        XCTAssertEqual(String(decoding: empty, as: UTF8.self), "{}")
    }

    func testDraftPatchEncodesIngredientsAndStepsInContractShape() throws {
        var form = DraftForm()
        form.title = "Garlic Pasta"
        form.addIngredient()
        form.ingredients[0].name = "garlic"
        form.ingredients[0].quantity = 3
        form.ingredients[0].unit = "clove"
        form.addStep()
        form.steps[0].instruction = "Sizzle."
        form.steps[0].ingredientRefs = ["ing-1"]
        form.steps[0].successCues = ["Fragrant"]
        let data = try JSONCoding.makeEncoder().encode(form.patch())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ingredient = try XCTUnwrap((object["ingredients"] as? [[String: Any]])?.first)
        XCTAssertEqual(ingredient["id"] as? String, "ing-1")
        XCTAssertEqual(ingredient["name"] as? String, "garlic")
        XCTAssertEqual(ingredient["quantity"] as? Double, 3)
        XCTAssertEqual(ingredient["unit"] as? String, "clove")
        XCTAssertEqual(ingredient["optional"] as? Bool, false)
        XCTAssertTrue(ingredient["preparation"] is NSNull, "absent optional strings go out as null, matching the detail shape")
        let step = try XCTUnwrap((object["steps"] as? [[String: Any]])?.first)
        XCTAssertEqual(step["id"] as? String, "step-1")
        XCTAssertEqual(step["order"] as? Int, 0)
        XCTAssertEqual(step["instruction"] as? String, "Sizzle.")
        XCTAssertEqual(step["ingredient_refs"] as? [String], ["ing-1"])
        XCTAssertEqual(step["success_cues"] as? [String], ["Fragrant"])
        XCTAssertEqual(step["evidence_origin"] as? String, "creator_authored")
        XCTAssertEqual(step["warnings"] as? [String], [])
    }

    // MARK: - Publish / save / unpublish / my recipes

    func testPublishResultDecodes() throws {
        let result = try decoder.decode(PublishResult.self, from: Data(AuthoringFixtures.publishResultJSON.utf8))
        XCTAssertEqual(result.recipeId.uuidString.lowercased(), AuthoringFixtures.recipeId)
        XCTAssertEqual(result.recipeVersionId.uuidString.lowercased(), AuthoringFixtures.versionId)
        XCTAssertEqual(result.versionNumber, 2)
        XCTAssertEqual(result.shareUrl, "https://souslens.app/r/\(AuthoringFixtures.recipeId)")
        XCTAssertEqual(result.shareURL, ShareLinks.universal(recipeId: result.recipeId))
    }

    func testSaveAndUnpublishResultsDecode() throws {
        let saved = try decoder.decode(SaveResult.self, from: Data(#"{"recipe_id":"\#(AuthoringFixtures.recipeId)","saved":true}"#.utf8))
        XCTAssertTrue(saved.saved)
        let unsaved = try decoder.decode(SaveResult.self, from: Data(#"{"recipe_id":"\#(AuthoringFixtures.recipeId)","saved":false}"#.utf8))
        XCTAssertFalse(unsaved.saved)
        let unpublished = try decoder.decode(UnpublishResult.self, from: Data(#"{"recipe_id":"\#(AuthoringFixtures.recipeId)","visibility":"private"}"#.utf8))
        XCTAssertEqual(unpublished.visibility, .private)
        XCTAssertEqual(unpublished.visibility.label, "Private")
        let odd = try decoder.decode(UnpublishResult.self, from: Data(#"{"recipe_id":"\#(AuthoringFixtures.recipeId)","visibility":"unlisted"}"#.utf8))
        XCTAssertEqual(odd.visibility, .unknown)
    }

    func testMyRecipeDecodesCardPlusVisibilityAndOpenDraft() throws {
        let page = try decoder.decode(ItemsResponse<MyRecipe>.self, from: Data(AuthoringFixtures.myRecipesJSON.utf8))
        let mine = try XCTUnwrap(page.items.first)
        XCTAssertEqual(mine.id, mine.card.recipeId)
        XCTAssertEqual(mine.card.title, "Garlic Pasta")
        XCTAssertEqual(mine.card.versionNumber, 2)
        XCTAssertEqual(mine.card.saved, false)
        XCTAssertEqual(mine.visibility, .public)
        XCTAssertTrue(mine.hasOpenDraft)

        let privateJSON = AuthoringFixtures.myRecipesJSON.replacingOccurrences(of: #""visibility":"public","has_open_draft":true,"#, with: #""visibility":"private","#)
        let item = try XCTUnwrap(decoder.decode(ItemsResponse<MyRecipe>.self, from: Data(privateJSON.utf8)).items.first)
        XCTAssertEqual(item.visibility, .private)
        XCTAssertFalse(item.hasOpenDraft, "has_open_draft defaults to false when absent")
    }

    // MARK: - saved / share_url on the Slice 0 types

    func testRecipeCardAndDetailDecodeSavedAndShareUrl() throws {
        let card = try AuthoringFixtures.card()
        XCTAssertEqual(card.saved, true)
        let detail = try AuthoringFixtures.detail()
        XCTAssertEqual(detail.saved, false)
        XCTAssertEqual(detail.shareUrl, "https://souslens.app/r/\(AuthoringFixtures.recipeId)")
        XCTAssertEqual(detail.shareURL, ShareLinks.universal(recipeId: detail.recipeId))

        let nulls = try AuthoringFixtures.detail(AuthoringFixtures.detailJSON(saved: "null", shareURL: "null"))
        XCTAssertNil(nulls.saved, "null when unauthenticated")
        XCTAssertNil(nulls.shareUrl)
        XCTAssertEqual(nulls.shareURL, ShareLinks.universal(recipeId: nulls.recipeId), "falls back to the contract's canonical link")
    }

    func testSliceZeroFixturesStillDecodeWithoutSavedOrShareUrl() throws {
        let page = try Fixtures.decode(RecipePage.self, from: "recipes_list")
        XCTAssertNil(page.items[0].saved)
        let detail = try Fixtures.decode(RecipeDetail.self, from: "recipe_detail")
        XCTAssertNil(detail.saved)
        XCTAssertNil(detail.shareUrl)
        XCTAssertEqual(detail.shareURL.absoluteString, "https://souslens.app/r/a185d1a4-2726-57b9-9b17-069262cbf492")
        // Cached cards (no `saved`) round-trip unchanged.
        let data = try JSONCoding.makeEncoder().encode(page)
        XCTAssertEqual(try JSONCoding.makeDecoder().decode(RecipePage.self, from: data), page)
    }

    func testSavedListDecodes() throws {
        let page = try decoder.decode(ItemsResponse<RecipeCard>.self, from: Data(AuthoringFixtures.savedListJSON.utf8))
        XCTAssertEqual(page.items.map(\.title), ["Garlic Pasta"])
    }

    // MARK: - Error envelope details

    func testValidationErrorEnvelopeDecodesDetailsAndProblems() throws {
        let envelope = try decoder.decode(APIErrorEnvelope.self, from: Data(AuthoringFixtures.validationErrorJSON.utf8))
        XCTAssertEqual(envelope.error.code, "VALIDATION_ERROR")
        XCTAssertEqual(envelope.error.details?["problems"]?.arrayValue?.count, 2)

        let error = APIError.server(status: 422, code: envelope.error.code, message: envelope.error.message, retryable: false,
                                    correlationId: envelope.error.correlationId, details: envelope.error.details)
        XCTAssertEqual(error.validationProblems, [
            DraftProblem(field: "title", message: "Add a title"),
            DraftProblem(field: "steps[0].instruction", message: "Step 1 needs an instruction"),
        ])
        XCTAssertEqual(error.status, 422)
        XCTAssertNil(error.conflictingDraftId)
    }

    func testValidationProblemsToleratesBareArrayAndMissingDetails() throws {
        let bare = try decoder.decode(JSONValue.self, from: Data(#"[{"field":"title","message":"m"}]"#.utf8))
        XCTAssertEqual(APIError.server(status: 422, code: "VALIDATION_ERROR", message: "x", retryable: false, correlationId: nil, details: bare).validationProblems,
                       [DraftProblem(field: "title", message: "m")])
        XCTAssertNil(APIError.server(status: 422, code: "VALIDATION_ERROR", message: "x", retryable: false, correlationId: nil).validationProblems)
        XCTAssertNil(APIError.server(status: 500, code: "INTERNAL", message: "x", retryable: true, correlationId: nil, details: bare).validationProblems)
    }

    func testStateConflictEnvelopeExposesDraftId() throws {
        let envelope = try decoder.decode(APIErrorEnvelope.self, from: Data(AuthoringFixtures.stateConflictJSON.utf8))
        let error = APIError.server(status: 409, code: envelope.error.code, message: envelope.error.message, retryable: false,
                                    correlationId: "c-409", details: envelope.error.details)
        XCTAssertEqual(error.conflictingDraftId?.uuidString.lowercased(), AuthoringFixtures.draftId)
        XCTAssertNil(error.validationProblems)
    }

    func testEnvelopeWithoutDetailsStillDecodes() throws {
        let envelope = try decoder.decode(APIErrorEnvelope.self, from: Data(AuthFixtures.badCodeJSON.utf8))
        XCTAssertNil(envelope.error.details)
    }

    func testJSONValueRoundTripsMixedDocument() throws {
        let raw = #"{"a":1.5,"b":"s","c":[true,null,{"d":"e"}],"f":null}"#
        let value = try decoder.decode(JSONValue.self, from: Data(raw.utf8))
        XCTAssertEqual(value["a"], .number(1.5))
        XCTAssertEqual(value["b"]?.stringValue, "s")
        XCTAssertEqual(value["c"]?.arrayValue?[2]["d"]?.stringValue, "e")
        XCTAssertEqual(value["f"], .null)
        let again = try decoder.decode(JSONValue.self, from: try JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
    }

    // MARK: - DraftForm helpers

    func testDraftFormRoundTripsDraftAndAssignsNextIds() throws {
        let draft = try AuthoringFixtures.draft()
        var form = DraftForm(draft: draft)
        XCTAssertEqual(form.title, "Garlic Pasta")
        XCTAssertEqual(form.servings, 2)
        XCTAssertEqual(form.ingredients.map(\.id), ["ing-1"])
        XCTAssertEqual(form.steps[0].creatorNote, "Low heat.")

        let added = form.addIngredient()
        XCTAssertEqual(added.id, "ing-2")
        XCTAssertEqual(form.addStep().id, "step-2")
        XCTAssertEqual(DraftForm.nextId(prefix: "ing", existing: ["ing-7", "x", "ing-3"]), "ing-8")
        XCTAssertEqual(DraftForm.nextId(prefix: "step", existing: []), "step-1")

        // Removing an ingredient drops step references to it (publish rule: every ref must resolve).
        form.steps[0].ingredientRefs = ["ing-1", "ing-2"]
        form.removeIngredients(at: IndexSet(integer: 0))
        XCTAssertEqual(form.ingredients.map(\.id), ["ing-2"])
        XCTAssertEqual(form.steps[0].ingredientRefs, ["ing-2"])

        // Reordering steps renumbers `order` from array position.
        form.steps[1].instruction = "Second"
        form.moveSteps(from: IndexSet(integer: 1), to: 0)
        let patch = form.patch()
        XCTAssertEqual(patch.steps?.map(\.order), [0, 1])
        XCTAssertEqual(patch.steps?.map(\.instruction), ["Second", "Sizzle the garlic in oil."])
    }

    func testDraftFormEmptyServingsDefaultsToFour() throws {
        let form = DraftForm(draft: try AuthoringFixtures.emptyDraft())
        XCTAssertEqual(form.servings, 4)
        XCTAssertEqual(form.title, "")
        XCTAssertNil(form.prepMinutes)
    }

    func testPreviewDetailMirrorsFormAndIsLabelledCreatorAuthored() throws {
        let draft = try AuthoringFixtures.draft()
        var form = DraftForm(draft: draft)
        form.title = "   "
        let detail = form.previewDetail(draft: draft, creator: AuthoringFixtures.creator, versionNumber: 3)
        XCTAssertEqual(detail.title, "Untitled draft")
        XCTAssertEqual(detail.versionNumber, 3)
        XCTAssertEqual(detail.recipeId, draft.recipeId)
        XCTAssertEqual(detail.creator, AuthoringFixtures.creator)
        XCTAssertEqual(detail.ingredients.map(\.name), ["garlic"])
        XCTAssertEqual(detail.headerProvenanceLabel, "Creator instructions")
        XCTAssertNil(detail.saved)
        XCTAssertNil(detail.shareUrl)
    }
}
