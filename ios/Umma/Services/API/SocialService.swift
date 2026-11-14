import Foundation

/// Brief 015 onboarding writes on `/me` and the taste fields on `/me/preferences`.
protocol OnboardingService: Sendable {
    /// `PATCH /me {role}`.
    func setRole(_ role: User.Role) async throws -> User
    /// `POST /me/onboarding/complete`. Idempotent: the first timestamp is kept.
    func completeOnboarding() async throws -> User
    /// `PUT /me/preferences` with allergies, avoid and the taste fields.
    func updateTaste(_ preferences: FoodPreferences) async throws -> FoodPreferences
}

/// Brief 015 creators and follows.
protocol SocialService: Sendable {
    func suggestedCreators(cuisines: [String], limit: Int) async throws -> [CreatorSummary]
    func creator(id: UUID) async throws -> CreatorProfile
    func follow(creatorId: UUID) async throws -> CreatorSummary
    func unfollow(creatorId: UUID) async throws -> CreatorSummary
    func following() async throws -> [CreatorSummary]
}

/// Brief 015 feeds. Search stays on `RecipeService.listRecipes`.
protocol FeedService: Sendable {
    func forYou(cursor: String?, limit: Int) async throws -> FeedPage
    func followingFeed(cursor: String?, limit: Int) async throws -> FeedPage
}

extension APIClient: OnboardingService, SocialService, FeedService {
    func setRole(_ role: User.Role) async throws -> User {
        try await send(.patch("/v1/me", body: try encoder.encode(RoleUpdate(role: role))))
    }

    func completeOnboarding() async throws -> User {
        try await send(.post("/v1/me/onboarding/complete", body: nil))
    }

    func updateTaste(_ preferences: FoodPreferences) async throws -> FoodPreferences {
        try await send(.put("/v1/me/preferences", body: try encoder.encode(preferences.tasteUpdate)))
    }

    func suggestedCreators(cuisines: [String], limit: Int = 8) async throws -> [CreatorSummary] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if !cuisines.isEmpty {
            query.append(URLQueryItem(name: "cuisines", value: cuisines.joined(separator: ",")))
        }
        let response: CreatorListResponse = try await send(.get("/v1/creators/suggested", query: query))
        return response.items
    }

    func creator(id: UUID) async throws -> CreatorProfile {
        try await send(.get("/v1/creators/\(Self.pathId(id))"))
    }

    func follow(creatorId: UUID) async throws -> CreatorSummary {
        try await send(.put("/v1/creators/\(Self.pathId(creatorId))/follow", body: nil))
    }

    func unfollow(creatorId: UUID) async throws -> CreatorSummary {
        try await send(.delete("/v1/creators/\(Self.pathId(creatorId))/follow"))
    }

    func following() async throws -> [CreatorSummary] {
        let response: CreatorListResponse = try await send(.get("/v1/me/following"))
        return response.items
    }

    func forYou(cursor: String? = nil, limit: Int = 20) async throws -> FeedPage {
        try await send(.get("/v1/feed/for-you", query: Self.pageQuery(cursor: cursor, limit: limit)))
    }

    func followingFeed(cursor: String? = nil, limit: Int = 20) async throws -> FeedPage {
        try await send(.get("/v1/feed/following", query: Self.pageQuery(cursor: cursor, limit: limit)))
    }

    private static func pageQuery(cursor: String?, limit: Int) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }
}
