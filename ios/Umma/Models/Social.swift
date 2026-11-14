import Foundation

// Brief 015 DTOs (`docs/product/briefs/015-api-contract.md`): creators, follows and feeds.

/// A creator as shown in onboarding suggestions, on profiles and in the Following list.
struct CreatorSummary: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let bio: String?
    let avatarUrl: String?
    let recipeCount: Int
    let followerCount: Int
    var isFollowing: Bool
    let cuisines: [String]
    let sampleRecipeTitles: [String]

    var avatarURL: URL? { avatarUrl.flatMap(URL.init(string:)) }

    /// Up to two initials for the monogram avatar (seeded personas have no image).
    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// `GET /creators/{id}`.
struct CreatorProfile: Codable, Sendable, Equatable {
    var creator: CreatorSummary
    let recipes: [RecipeCard]
}

/// Why a recipe is in For You. Absent on every other list.
struct FeedInfo: Codable, Sendable, Hashable {
    /// Display as is ("You have 8 of 9", "Korean", "From Mina", "New").
    let reason: String
    /// Share of required ingredients present in the pantry; `nil` with an empty pantry.
    let coverage: Double?
    let canMake: Bool
    /// An allergen from the user's list that this recipe touches ("peanut"), else `nil`.
    let allergyConflict: String?
}

/// `GET /feed/for-you`, `GET /feed/following`: a `RecipePage` whose cards may carry `feed`.
typealias FeedPage = RecipePage

struct CreatorListResponse: Decodable, Sendable {
    let items: [CreatorSummary]
}

struct RoleUpdate: Encodable, Sendable, Equatable {
    let role: User.Role
}
