import Foundation

struct Creator: Codable, Sendable, Hashable {
    let id: UUID
    let displayName: String
}

/// `GET /v1/recipes` list item.
struct RecipeCard: Codable, Sendable, Identifiable, Hashable {
    let recipeId: UUID
    let slug: String
    let title: String
    let summary: String?
    let tags: [String]
    let creator: Creator
    let servings: Int
    let prepMinutes: Int?
    let cookMinutes: Int?
    let coverImageUrl: String?
    let publishedAt: Date
    let recipeVersionId: UUID
    let versionNumber: Int

    var id: UUID { recipeId }
    var coverImageURL: URL? { coverImageUrl.flatMap(URL.init(string:)) }
}

struct RecipePage: Codable, Sendable, Equatable {
    let items: [RecipeCard]
    let nextCursor: String?
}

/// `GET /v1/recipes/{id}` — mirrors the backend's canonical recipe JSON (PRD §10.1).
struct RecipeDetail: Codable, Sendable, Identifiable, Hashable {
    let schemaVersion: String
    let recipeId: UUID
    let recipeVersionId: UUID
    let versionNumber: Int
    let slug: String
    let title: String
    let summary: String?
    let tags: [String]
    let creator: Creator
    let servings: Int
    let prepMinutes: Int?
    let cookMinutes: Int?
    let coverImageUrl: String?
    let ingredients: [Ingredient]
    let steps: [RecipeStep]
    let creatorNotes: [String]
    let dietaryWarnings: [String]
    let publishedAt: Date

    var id: UUID { recipeId }
    var coverImageURL: URL? { coverImageUrl.flatMap(URL.init(string:)) }
    var orderedSteps: [RecipeStep] { steps.sorted { $0.order < $1.order } }

    /// Header label (PRD §13.4): the least creator-authored origin present wins.
    var headerProvenanceLabel: String {
        let origins = Set(steps.map(\.evidenceOrigin))
        if origins.contains(.aiExtracted) || origins.contains(.unknown) { return EvidenceOrigin.aiExtracted.label }
        if origins.contains(.creatorReviewed) { return EvidenceOrigin.creatorReviewed.label }
        return EvidenceOrigin.creatorAuthored.label
    }
}

struct Ingredient: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let quantity: Double?
    let unit: String?
    let optional: Bool
    let preparation: String?
    let notes: String?
}

/// PRD §13.4 transparency label source. Unrecognised values (a future backend enum member) decode
/// as `.unknown`, which is labelled conservatively — never as creator-authored.
enum EvidenceOrigin: String, Codable, Sendable, CaseIterable {
    case creatorAuthored = "creator_authored"
    case creatorReviewed = "creator_reviewed"
    case aiExtracted = "ai_extracted"
    case unknown = "unknown"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EvidenceOrigin(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .creatorAuthored: return "Creator instructions"
        case .creatorReviewed: return "AI-extracted, creator-verified"
        case .aiExtracted, .unknown: return "AI-extracted"
        }
    }

    /// True when the step text is exactly what the creator wrote.
    var isCreatorAuthored: Bool { self == .creatorAuthored }
}

struct RecipeStep: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let order: Int
    let instruction: String
    let ingredientRefs: [String]
    let estimatedMinutes: Int?
    let successCues: [String]
    let warnings: [String]
    let creatorNote: String?
    let sourceClipId: String?
    let sourceStartMs: Int?
    let sourceEndMs: Int?
    let evidenceOrigin: EvidenceOrigin

    /// Per-step transparency label; nil for creator-authored steps (the header already says so).
    var provenanceLabel: String? {
        evidenceOrigin.isCreatorAuthored ? nil : evidenceOrigin.label
    }
}
