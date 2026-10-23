import Foundation
@testable import SousLens

/// Inline JSON matching `docs/product/briefs/003-api-contract.md` exactly.
enum AuthoringFixtures {
    static let draftId = "0b9c8d7e-6f5a-4b3c-9d2e-1f0a9b8c7d6e"
    static let recipeId = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
    static let versionId = "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e"
    static let creatorId = "c1a2b3c4-d5e6-4f70-8a9b-0c1d2e3f4a5b"

    static let ingredientJSON = #"{"id":"ing-1","name":"garlic","quantity":3,"unit":"clove","optional":false,"preparation":"minced","notes":null}"#
    static let stepJSON = #"{"id":"step-1","order":0,"instruction":"Sizzle the garlic in oil.","ingredient_refs":["ing-1"],"estimated_minutes":2,"success_cues":["Fragrant, not brown"],"warnings":["Garlic burns in seconds"],"creator_note":"Low heat.","source_clip_id":null,"source_start_ms":null,"source_end_ms":null,"evidence_origin":"creator_authored"}"#

    /// Fresh `POST /recipes/drafts {}` response: everything empty/null, not publishable.
    static let emptyDraftJSON = """
    {"id":"\(draftId)","recipe_id":null,"status":"draft","title":null,"summary":null,"tags":[],"cover_image_url":null,
     "servings":null,"prep_minutes":null,"cook_minutes":null,"ingredients":[],"steps":[],"creator_notes":[],"dietary_warnings":[],
     "validation":{"publishable":false,"problems":[{"field":"title","message":"Add a title"},{"field":"ingredients","message":"Add at least one ingredient"},{"field":"steps","message":"Add at least one step"}]},
     "created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-20T10:00:00Z"}
    """

    /// A complete, publishable draft (an edit of a published recipe: `recipe_id` set).
    static let fullDraftJSON = """
    {"id":"\(draftId)","recipe_id":"\(recipeId)","status":"draft","title":"Garlic Pasta","summary":"Ten-minute garlic pasta.","tags":["pasta","weeknight"],
     "cover_image_url":null,"servings":2,"prep_minutes":5,"cook_minutes":12,
     "ingredients":[\(ingredientJSON)],"steps":[\(stepJSON)],"creator_notes":["Salt the water like the sea."],"dietary_warnings":["Contains wheat."],
     "validation":{"publishable":true,"problems":[]},
     "created_at":"2026-10-20T10:00:00.123456Z","updated_at":"2026-10-20T10:05:00+00:00","future":{"x":1}}
    """

    static let draftSummaryListJSON = """
    {"items":[{"id":"\(draftId)","recipe_id":null,"status":"draft","title":null,"summary":null,"tags":[],"cover_image_url":null,
      "servings":4,"prep_minutes":null,"cook_minutes":null,"ingredient_count":0,"step_count":0,
      "validation":{"publishable":false,"problems":[{"field":"title","message":"Add a title"}]},
      "created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-20T10:00:00Z"},
     {"id":"\(versionId)","recipe_id":"\(recipeId)","status":"draft","title":"Garlic Pasta","summary":"S","tags":["pasta"],"cover_image_url":null,
      "servings":2,"prep_minutes":5,"cook_minutes":12,"ingredient_count":4,"step_count":5,
      "validation":{"publishable":true,"problems":[]},
      "created_at":"2026-10-19T10:00:00Z","updated_at":"2026-10-19T11:00:00Z"}]}
    """

    static let publishResultJSON = """
    {"recipe_id":"\(recipeId)","recipe_version_id":"\(versionId)","version_number":2,"share_url":"https://souslens.app/r/\(recipeId)"}
    """

    static let validationErrorJSON = """
    {"error":{"code":"VALIDATION_ERROR","message":"Draft is not publishable.","retryable":false,"correlation_id":"c-422",
     "details":{"problems":[{"field":"title","message":"Add a title"},{"field":"steps[0].instruction","message":"Step 1 needs an instruction"}]}}}
    """

    static let stateConflictJSON = """
    {"error":{"code":"STATE_CONFLICT","message":"A draft for this recipe is already open.","retryable":false,"correlation_id":"c-409",
     "details":{"draft_id":"\(draftId)"}}}
    """

    static func cardJSON(saved: String = "true", extra: String = "") -> String {
        """
        {\(extra)"recipe_id":"\(recipeId)","slug":"garlic-pasta","title":"Garlic Pasta","summary":"Ten-minute garlic pasta.","tags":["pasta"],
         "creator":{"id":"\(creatorId)","display_name":"Mina Park"},"servings":2,"prep_minutes":5,"cook_minutes":12,"cover_image_url":null,
         "published_at":"2026-10-20T12:00:00Z","recipe_version_id":"\(versionId)","version_number":2,"saved":\(saved)}
        """
    }

    static let savedListJSON = #"{"items":["# + cardJSON() + "]}"

    static let myRecipesJSON = #"{"items":["# + cardJSON(saved: "false", extra: #""visibility":"public","has_open_draft":true,"#) + "]}"

    static func detailJSON(saved: String = "false", shareURL: String = #""https://souslens.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d""#, creatorId: String = creatorId) -> String {
        """
        {"schema_version":"1.0","recipe_id":"\(recipeId)","recipe_version_id":"\(versionId)","version_number":2,"slug":"garlic-pasta",
         "title":"Garlic Pasta","summary":"Ten-minute garlic pasta.","tags":["pasta"],"creator":{"id":"\(creatorId)","display_name":"Mina Park"},
         "servings":2,"prep_minutes":5,"cook_minutes":12,"cover_image_url":null,"ingredients":[\(ingredientJSON)],"steps":[\(stepJSON)],
         "creator_notes":[],"dietary_warnings":[],"published_at":"2026-10-20T12:00:00Z","saved":\(saved),"share_url":\(shareURL)}
        """
    }

    // MARK: - Decoded helpers

    static func draft(_ json: String = fullDraftJSON) throws -> Draft {
        try JSONCoding.makeDecoder().decode(Draft.self, from: Data(json.utf8))
    }

    static func emptyDraft() throws -> Draft { try draft(emptyDraftJSON) }

    static func detail(_ json: String = detailJSON()) throws -> RecipeDetail {
        try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: Data(json.utf8))
    }

    static func card(_ json: String = cardJSON()) throws -> RecipeCard {
        try JSONCoding.makeDecoder().decode(RecipeCard.self, from: Data(json.utf8))
    }

    static let creator = Creator(id: UUID(uuidString: creatorId)!, displayName: "Mina Park")

    /// A copy of `draft` with the server's view of the patch applied and the given validation.
    static func applying(_ patch: DraftPatch, to draft: Draft, validation: DraftValidation) -> Draft {
        Draft(
            id: draft.id, recipeId: draft.recipeId, status: draft.status,
            title: patch.title ?? draft.title, summary: patch.summary ?? draft.summary, tags: patch.tags ?? draft.tags,
            coverImageUrl: draft.coverImageUrl, servings: patch.servings ?? draft.servings,
            prepMinutes: patch.prepMinutes ?? draft.prepMinutes, cookMinutes: patch.cookMinutes ?? draft.cookMinutes,
            ingredients: patch.ingredients ?? draft.ingredients, steps: patch.steps ?? draft.steps,
            creatorNotes: patch.creatorNotes ?? draft.creatorNotes, dietaryWarnings: patch.dietaryWarnings ?? draft.dietaryWarnings,
            validation: validation, createdAt: draft.createdAt, updatedAt: Date()
        )
    }

    /// Server-side publish rules (REC-04), mirrored so fakes answer the way the backend will.
    static func validate(_ patch: DraftPatch) -> DraftValidation {
        var problems: [DraftProblem] = []
        let title = patch.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty || title.count > 120 { problems.append(DraftProblem(field: "title", message: "Add a title (1–120 characters)")) }
        if (patch.servings ?? 0) < 1 { problems.append(DraftProblem(field: "servings", message: "Servings must be at least 1")) }
        let ingredients = patch.ingredients ?? []
        if !ingredients.contains(where: { !$0.name.isEmpty }) { problems.append(DraftProblem(field: "ingredients", message: "Add at least one ingredient")) }
        let steps = patch.steps ?? []
        if !steps.contains(where: { !$0.instruction.isEmpty }) { problems.append(DraftProblem(field: "steps", message: "Add at least one step")) }
        for (index, step) in steps.enumerated() where step.instruction.isEmpty {
            problems.append(DraftProblem(field: "steps[\(index)].instruction", message: "Step \(index + 1) needs an instruction"))
        }
        return DraftValidation(publishable: problems.isEmpty, problems: problems)
    }
}
