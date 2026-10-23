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
    var creatorNotes: [EditableLine] = []
    var dietaryWarnings: [EditableLine] = []

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
        creatorNotes = draft.creatorNotes.map { EditableLine($0) }
        dietaryWarnings = draft.dietaryWarnings.map { EditableLine($0) }
    }

    /// Fields the form can empty; a nil value for these is sent as JSON `null` ("clear").
    /// `cover_image_url` is deliberately absent: the editor has no cover control, so it must never
    /// clear one set elsewhere.
    static let clearableFields: Set<DraftPatch.Field> = [.title, .summary, .servings, .prepMinutes, .cookMinutes]

    /// The title as committed: newlines (a vertical text field accepts Return) become spaces, trimmed.
    var committedTitle: String? {
        let flattened = title.components(separatedBy: .newlines).joined(separator: " ")
        return EditableIngredient.nilIfBlank(flattened)
    }

    /// Full-form PATCH body. Steps are sent in display order (the server rewrites `order` from array
    /// position; we send 0..n-1 too). Blank list lines are dropped.
    func patch() -> DraftPatch {
        DraftPatch(
            title: committedTitle,
            summary: EditableIngredient.nilIfBlank(summary),
            tags: tags,
            coverImageUrl: nil,
            servings: servings,
            prepMinutes: prepMinutes,
            cookMinutes: cookMinutes,
            ingredients: ingredients.map { $0.ingredient },
            steps: steps.enumerated().map { index, step in step.recipeStep(order: index) },
            creatorNotes: EditableLine.texts(creatorNotes),
            dietaryWarnings: EditableLine.texts(dietaryWarnings),
            clearsWhenNil: Self.clearableFields
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
            title: committedTitle ?? "Untitled draft",
            summary: EditableIngredient.nilIfBlank(summary),
            tags: tags,
            creator: creator,
            servings: servings,
            prepMinutes: prepMinutes,
            cookMinutes: cookMinutes,
            coverImageUrl: draft.coverImageUrl,
            ingredients: ingredients.map { $0.ingredient },
            steps: steps.enumerated().map { index, step in step.recipeStep(order: index) },
            creatorNotes: EditableLine.texts(creatorNotes),
            dietaryWarnings: EditableLine.texts(dietaryWarnings),
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
    var successCues: [EditableLine] = []
    var warnings: [EditableLine] = []
    var creatorNote = ""
    var ingredientRefs: [String] = []
    /// Provenance is carried through unchanged (PRD §13.4): an AI-extracted or creator-reviewed step
    /// keeps its label and source clip after an edit here. Only steps added in this editor are
    /// `creator_authored`.
    let evidenceOrigin: EvidenceOrigin
    let sourceClipId: String?
    let sourceStartMs: Int?
    let sourceEndMs: Int?

    init(id: String) {
        self.id = id
        evidenceOrigin = .creatorAuthored
        sourceClipId = nil
        sourceStartMs = nil
        sourceEndMs = nil
    }

    init(step: RecipeStep) {
        id = step.id
        instruction = step.instruction
        estimatedMinutes = step.estimatedMinutes
        successCues = step.successCues.map { EditableLine($0) }
        warnings = step.warnings.map { EditableLine($0) }
        creatorNote = step.creatorNote ?? ""
        ingredientRefs = step.ingredientRefs
        evidenceOrigin = step.evidenceOrigin
        sourceClipId = step.sourceClipId
        sourceStartMs = step.sourceStartMs
        sourceEndMs = step.sourceEndMs
    }

    func recipeStep(order: Int) -> RecipeStep {
        RecipeStep(
            id: id,
            order: order,
            instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredientRefs: ingredientRefs,
            estimatedMinutes: estimatedMinutes,
            successCues: EditableLine.texts(successCues),
            warnings: EditableLine.texts(warnings),
            creatorNote: EditableIngredient.nilIfBlank(creatorNote),
            sourceClipId: sourceClipId,
            sourceStartMs: sourceStartMs,
            sourceEndMs: sourceEndMs,
            evidenceOrigin: evidenceOrigin
        )
    }

    var displayLine: String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New step" : trimmed
    }
}

/// One free-text line (cue, warning, note) with a stable identity, so list rows bind by id rather
/// than by index (deleting a row while its field is focused can't index past the end).
struct EditableLine: Identifiable, Equatable, Sendable, ExpressibleByStringLiteral {
    let id: UUID
    var text: String

    init(_ text: String) {
        id = UUID()
        self.text = text
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    /// Trimmed, non-blank texts in order: what goes on the wire.
    static func texts(_ lines: [EditableLine]) -> [String] {
        lines.compactMap { EditableIngredient.nilIfBlank($0.text) }
    }
}
