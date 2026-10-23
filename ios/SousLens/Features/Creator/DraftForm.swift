import Foundation

/// Editable, value-typed mirror of a `Draft`. The editor binds to this; `patch()` turns it back
/// into the wire shape (full arrays — the contract replaces arrays whole).
struct DraftForm: Equatable, Sendable {
    var title = ""
    var summary = ""
    var tags: [String] = []
    var servings = 4
    var prepMinutes: Int?
    var cookMinutes: Int?
    var ingredients: [EditableIngredient] = []
    var steps: [EditableStep] = []
    var creatorNotes: [String] = []
    var dietaryWarnings: [String] = []

    init() {}

    init(draft: Draft) {
        title = draft.title ?? ""
        summary = draft.summary ?? ""
        tags = draft.tags
        servings = draft.servings ?? 4
        prepMinutes = draft.prepMinutes
        cookMinutes = draft.cookMinutes
        ingredients = draft.ingredients.map(EditableIngredient.init(ingredient:))
        steps = draft.orderedSteps.map(EditableStep.init(step:))
        creatorNotes = draft.creatorNotes
        dietaryWarnings = draft.dietaryWarnings
    }

    /// Full-form PATCH body. Steps are renumbered 0..n-1 from their array position (REC-04).
    func patch() -> DraftPatch {
        DraftPatch(
            title: title,
            summary: summary,
            tags: tags,
            coverImageUrl: nil,
            servings: servings,
            prepMinutes: prepMinutes,
            cookMinutes: cookMinutes,
            ingredients: ingredients.map { $0.ingredient },
            steps: steps.enumerated().map { index, step in step.recipeStep(order: index) },
            creatorNotes: creatorNotes,
            dietaryWarnings: dietaryWarnings
        )
    }

    // MARK: - Ingredients

    @discardableResult
    mutating func addIngredient() -> EditableIngredient {
        let ingredient = EditableIngredient(id: Self.nextId(prefix: "ing", existing: ingredients.map(\.id)))
        ingredients.append(ingredient)
        return ingredient
    }

    /// Removing an ingredient also drops any step reference to it (publish rule: every ref must resolve).
    mutating func removeIngredients(at offsets: IndexSet) {
        let removed = Set(offsets.map { ingredients[$0].id })
        ingredients.remove(atOffsets: offsets)
        for index in steps.indices {
            steps[index].ingredientRefs.removeAll { removed.contains($0) }
        }
    }

    mutating func moveIngredients(from source: IndexSet, to destination: Int) {
        ingredients.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Steps

    @discardableResult
    mutating func addStep() -> EditableStep {
        let step = EditableStep(id: Self.nextId(prefix: "step", existing: steps.map(\.id)))
        steps.append(step)
        return step
    }

    mutating func removeSteps(at offsets: IndexSet) {
        steps.remove(atOffsets: offsets)
    }

    mutating func moveSteps(from source: IndexSet, to destination: Int) {
        steps.move(fromOffsets: source, toOffset: destination)
    }

    /// "ing-1", "ing-2", … — one past the highest numeric suffix already in use.
    static func nextId(prefix: String, existing: [String]) -> String {
        let highest = existing.compactMap { id -> Int? in
            guard id.hasPrefix(prefix + "-") else { return nil }
            return Int(id.dropFirst(prefix.count + 1))
        }.max() ?? 0
        return "\(prefix)-\(highest + 1)"
    }

    // MARK: - Preview

    /// What the learner will see, rendered through the same screen as a published recipe.
    func previewDetail(draft: Draft, creator: Creator, versionNumber: Int) -> RecipeDetail {
        RecipeDetail(
            schemaVersion: "1.0",
            recipeId: draft.recipeId ?? draft.id,
            recipeVersionId: draft.id,
            versionNumber: versionNumber,
            slug: "draft",
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled draft" : title,
            summary: summary.isEmpty ? nil : summary,
            tags: tags,
            creator: creator,
            servings: servings,
            prepMinutes: prepMinutes,
            cookMinutes: cookMinutes,
            coverImageUrl: draft.coverImageUrl,
            ingredients: ingredients.map { $0.ingredient },
            steps: steps.enumerated().map { index, step in step.recipeStep(order: index) },
            creatorNotes: creatorNotes,
            dietaryWarnings: dietaryWarnings,
            publishedAt: draft.updatedAt,
            saved: nil,
            shareUrl: nil
        )
    }
}

struct EditableIngredient: Identifiable, Equatable, Sendable {
    let id: String
    var name = ""
    var quantity: Double?
    var unit = ""
    var optional = false
    var preparation = ""
    var notes = ""

    init(id: String) {
        self.id = id
    }

    init(ingredient: Ingredient) {
        id = ingredient.id
        name = ingredient.name
        quantity = ingredient.quantity
        unit = ingredient.unit ?? ""
        optional = ingredient.optional
        preparation = ingredient.preparation ?? ""
        notes = ingredient.notes ?? ""
    }

    var ingredient: Ingredient {
        Ingredient(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            quantity: quantity,
            unit: Self.nilIfBlank(unit),
            optional: optional,
            preparation: Self.nilIfBlank(preparation),
            notes: Self.nilIfBlank(notes)
        )
    }

    /// Row label in the editor list.
    var displayLine: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let qty = RecipeFormatting.quantity(quantity, unit: Self.nilIfBlank(unit))
        let base = trimmed.isEmpty ? "New ingredient" : trimmed
        return [qty, base].compactMap { $0 }.joined(separator: " ")
    }

    static func nilIfBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct EditableStep: Identifiable, Equatable, Sendable {
    let id: String
    var instruction = ""
    var estimatedMinutes: Int?
    var successCues: [String] = []
    var warnings: [String] = []
    var creatorNote = ""
    var ingredientRefs: [String] = []

    init(id: String) {
        self.id = id
    }

    init(step: RecipeStep) {
        id = step.id
        instruction = step.instruction
        estimatedMinutes = step.estimatedMinutes
        successCues = step.successCues
        warnings = step.warnings
        creatorNote = step.creatorNote ?? ""
        ingredientRefs = step.ingredientRefs
    }

    /// Hand-written in this editor, so the provenance is always `creator_authored` (PRD §13.4).
    func recipeStep(order: Int) -> RecipeStep {
        RecipeStep(
            id: id,
            order: order,
            instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredientRefs: ingredientRefs,
            estimatedMinutes: estimatedMinutes,
            successCues: successCues,
            warnings: warnings,
            creatorNote: EditableIngredient.nilIfBlank(creatorNote),
            sourceClipId: nil,
            sourceStartMs: nil,
            sourceEndMs: nil,
            evidenceOrigin: .creatorAuthored
        )
    }

    var displayLine: String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New step" : trimmed
    }
}
