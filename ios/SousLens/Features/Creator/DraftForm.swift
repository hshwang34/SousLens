import Foundation

/// Backend PATCH limits (brief 003, item 12). Text fields cap at these lengths as you type, and the
/// PATCH body is normalised to them, so a creator sees the limit instead of a failed save.
enum DraftLimits {
    static let title = 120
    static let summary = 1000
    static let tag = 40
    static let line = 500            // creator notes, dietary warnings, success cues, step warnings
    static let ingredientName = 200
    static let unit = 32
    static let preparation = 200
    static let ingredientNotes = 500
    static let instruction = 2000
    static let creatorNote = 500
}

/// Client-side copy of the backend's text rules: no control or bidi-override characters, no
/// newlines in single-line fields, trimmed, within the length limit. Untrusted-content hygiene too.
enum DraftText {
    /// Bidi embedding/override/isolate marks and the directional marks.
    private static let bidi: Set<Unicode.Scalar> = Set(
        [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
            .compactMap(Unicode.Scalar.init)
    )

    private static func clean(_ text: String, keepNewlines: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            if bidi.contains(scalar) { continue }
            if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                scalars.append(keepNewlines ? "\n" : " ")
            } else if scalar == "\t" {
                scalars.append(" ")
            } else if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format && scalar.value != 0x200D {
                continue   // C0/C1 controls, zero-width/format chars (ZWJ kept for emoji)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Title, tags, ingredient name/unit/preparation.
    static func singleLine(_ text: String, max: Int) -> String {
        String(clean(text, keepNewlines: false).trimmingCharacters(in: .whitespaces).prefix(max))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Summary, instruction, notes, cues, warnings.
    static func multiLine(_ text: String, max: Int) -> String {
        String(clean(text, keepNewlines: true).trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// Trimmed, lowercased, ≤40, unique, in order.
    static func tags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let tag = singleLine(raw, max: DraftLimits.tag).lowercased()
            guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }
}

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

    /// The title as committed: newlines (a vertical text field accepts Return) become spaces,
    /// control/bidi characters are dropped, trimmed, ≤120.
    var committedTitle: String? {
        DraftText.nonEmpty(DraftText.singleLine(title, max: DraftLimits.title))
    }

    var committedSummary: String? {
        DraftText.nonEmpty(DraftText.multiLine(summary, max: DraftLimits.summary))
    }

    /// Full-form PATCH body. Steps are sent in display order (the server rewrites `order` from array
    /// position; we send 0..n-1 too). Blank list lines are dropped.
    func patch() -> DraftPatch {
        DraftPatch(
            title: committedTitle,
            summary: committedSummary,
            tags: DraftText.tags(tags),
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
            summary: committedSummary,
            tags: DraftText.tags(tags),
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
            name: DraftText.singleLine(name, max: DraftLimits.ingredientName),
            quantity: quantity,
            unit: DraftText.nonEmpty(DraftText.singleLine(unit, max: DraftLimits.unit)),
            optional: optional,
            preparation: DraftText.nonEmpty(DraftText.singleLine(preparation, max: DraftLimits.preparation)),
            notes: DraftText.nonEmpty(DraftText.multiLine(notes, max: DraftLimits.ingredientNotes))
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
            instruction: DraftText.multiLine(instruction, max: DraftLimits.instruction),
            ingredientRefs: ingredientRefs,
            estimatedMinutes: estimatedMinutes,
            successCues: EditableLine.texts(successCues),
            warnings: EditableLine.texts(warnings),
            creatorNote: DraftText.nonEmpty(DraftText.multiLine(creatorNote, max: DraftLimits.creatorNote)),
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
        lines.compactMap { DraftText.nonEmpty(DraftText.multiLine($0.text, max: DraftLimits.line)) }
    }
}
