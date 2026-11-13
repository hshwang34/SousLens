import Foundation

/// Brief 003 authoring DTOs. Shapes follow `docs/product/briefs/003-api-contract.md` exactly.

enum DraftStatus: String, Codable, Sendable {
    case draft
    case published
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DraftStatus(rawValue: raw) ?? .unknown
    }
}

/// One reason the draft cannot be published yet, tied to a field so the editor can show it inline.
/// `field` is the backend's name ("title", "servings", "ingredients", "steps", or an indexed form
/// such as "steps[1].instruction"); `DraftValidation.problems(for:)` matches by prefix.
struct DraftProblem: Codable, Sendable, Hashable {
    let field: String
    let message: String
}

struct DraftValidation: Codable, Sendable, Hashable {
    let publishable: Bool
    let problems: [DraftProblem]

    static let empty = DraftValidation(publishable: false, problems: [])

    /// Problems for a field or anything nested under it (`ingredients` matches `ingredients[2].name`).
    func problems(for field: String) -> [DraftProblem] {
        problems.filter { Self.field($0.field, isWithin: field) }
    }

    /// True when `candidate` is `prefix` itself or nested under it (`prefix.x`, `prefix[0]`, `prefix.0.x`).
    /// A bare prefix match is not enough: `ingredients.1` must not claim `ingredients.10`.
    static func field(_ candidate: String, isWithin prefix: String) -> Bool {
        guard candidate.hasPrefix(prefix) else { return false }
        let rest = candidate.dropFirst(prefix.count)
        guard let next = rest.first else { return true }
        return next == "." || next == "["
    }

    /// Problems whose `field` is exactly `field` (section-level, not row-level).
    func problems(exactly field: String) -> [DraftProblem] {
        problems.filter { $0.field == field }
    }
}

/// `POST/GET/PATCH /v1/recipes/drafts/{id}`.
struct Draft: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    /// Set once the draft belongs to a published recipe (an edit, or after publishing).
    let recipeId: UUID?
    let status: DraftStatus
    let title: String?
    let summary: String?
    let tags: [String]
    let coverImageUrl: String?
    let servings: Int?
    let prepMinutes: Int?
    let cookMinutes: Int?
    let ingredients: [Ingredient]
    let steps: [RecipeStep]
    let creatorNotes: [String]
    let dietaryWarnings: [String]
    let validation: DraftValidation
    let createdAt: Date
    let updatedAt: Date

    var orderedSteps: [RecipeStep] { steps.sorted { $0.order < $1.order } }
}

/// `GET /v1/recipes/drafts` item: `Draft` minus the arrays, plus counts.
struct DraftSummary: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let recipeId: UUID?
    let status: DraftStatus
    let title: String?
    let summary: String?
    let tags: [String]
    let coverImageUrl: String?
    let servings: Int?
    let prepMinutes: Int?
    let cookMinutes: Int?
    let ingredientCount: Int
    let stepCount: Int
    let validation: DraftValidation
    let createdAt: Date
    let updatedAt: Date

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled draft" : trimmed
    }
}

/// Partial update body for `PATCH /v1/recipes/drafts/{id}` (and the optional body of `POST`).
///
/// The backend reads an omitted key as "unchanged" and an explicit `null` as "clear". By default a
/// `nil` field is omitted; a field listed in `clearsWhenNil` is sent as `null` instead. The editor's
/// full-form patch (`DraftForm.patch()`) lists every scalar it can empty, so clearing prep time
/// actually clears it on the server. Arrays replace the server's whole array.
struct DraftPatch: Encodable, Sendable, Hashable {
    enum Field: String, CodingKey, CaseIterable, Sendable {
        case title, summary, tags
        case coverImageUrl = "cover_image_url"
        case servings
        case prepMinutes = "prep_minutes"
        case cookMinutes = "cook_minutes"
        case ingredients, steps
        case creatorNotes = "creator_notes"
        case dietaryWarnings = "dietary_warnings"
    }

    var title: String?
    var summary: String?
    var tags: [String]?
    var coverImageUrl: String?
    var servings: Int?
    var prepMinutes: Int?
    var cookMinutes: Int?
    var ingredients: [Ingredient]?
    var steps: [RecipeStep]?
    var creatorNotes: [String]?
    var dietaryWarnings: [String]?
    /// Fields encoded as JSON `null` when their value is nil (instead of being omitted).
    var clearsWhenNil: Set<Field> = []

    static let empty = DraftPatch()

    // Keys are explicit snake_case raw values; `JSONEncoder.keyEncodingStrategy` leaves them as is.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Field.self)
        func put<T: Encodable>(_ value: T?, _ field: Field) throws {
            if let value {
                try container.encode(value, forKey: field)
            } else if clearsWhenNil.contains(field) {
                try container.encodeNil(forKey: field)
            }
        }
        try put(title, .title)
        try put(summary, .summary)
        try put(tags, .tags)
        try put(coverImageUrl, .coverImageUrl)
        try put(servings, .servings)
        try put(prepMinutes, .prepMinutes)
        try put(cookMinutes, .cookMinutes)
        try put(ingredients, .ingredients)
        try put(steps, .steps)
        try put(creatorNotes, .creatorNotes)
        try put(dietaryWarnings, .dietaryWarnings)
    }
}

/// `POST /v1/recipes/drafts/{id}/publish` → 201.
struct PublishResult: Codable, Sendable, Hashable {
    let recipeId: UUID
    let recipeVersionId: UUID
    let versionNumber: Int
    /// Decoded for completeness but never displayed or shared: the link is always built from
    /// `recipeId` (`ShareLinks`), so a server can't make the app hand out a foreign URL.
    let shareUrl: String?

    var shareURL: URL { ShareLinks.universal(recipeId: recipeId) }
}

/// `POST`/`DELETE /v1/recipes/{id}/save`.
struct SaveResult: Codable, Sendable, Hashable {
    let recipeId: UUID
    let saved: Bool
}

/// `POST /v1/recipes/{id}/unpublish`.
struct UnpublishResult: Codable, Sendable, Hashable {
    let recipeId: UUID
    let visibility: RecipeVisibility
}

enum RecipeVisibility: String, Codable, Sendable {
    case `public`
    case `private`
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RecipeVisibility(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .public: return "Public"
        case .private: return "Private"
        case .unknown: return "Unknown"
        }
    }
}

/// `GET /v1/me/recipes` item: a `RecipeCard` plus `visibility` and `has_open_draft`.
struct MyRecipe: Decodable, Sendable, Identifiable, Hashable {
    let card: RecipeCard
    let visibility: RecipeVisibility
    let hasOpenDraft: Bool

    var id: UUID { card.recipeId }

    private enum CodingKeys: String, CodingKey {
        case visibility
        case hasOpenDraft
    }

    init(card: RecipeCard, visibility: RecipeVisibility, hasOpenDraft: Bool) {
        self.card = card
        self.visibility = visibility
        self.hasOpenDraft = hasOpenDraft
    }

    init(from decoder: Decoder) throws {
        card = try RecipeCard(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibility = try container.decode(RecipeVisibility.self, forKey: .visibility)
        hasOpenDraft = try container.decodeIfPresent(Bool.self, forKey: .hasOpenDraft) ?? false
    }
}

/// `{"items": [...]}` wrapper used by drafts, saved and my-recipes lists.
struct ItemsResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
}

extension ItemsResponse: Equatable where Item: Equatable {}
