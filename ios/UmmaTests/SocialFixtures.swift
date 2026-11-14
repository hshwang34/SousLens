import Foundation
@testable import Umma

/// Brief 015 payloads and a scriptable onboarding / social / feed service.
enum SocialFixtures {
    static let userId = "11111111-1111-4111-8111-111111111111"
    static let minaId = "22222222-2222-4222-8222-222222222222"
    static let samId = "33333333-3333-4333-8333-333333333333"

    static func userJSON(onboardedAt: String? = nil, role: String? = nil) -> String {
        let onboarded = onboardedAt.map { "\"\($0)\"" } ?? "null"
        let roleValue = role.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(userId)","display_name":"alice","preference_units":"us",
         "created_at":"2026-11-13T00:00:00Z","entitlement":"paid",
         "onboarded_at":\(onboarded),"role":\(roleValue)}
        """
    }

    static func creatorJSON(id: String = minaId, name: String = "Mina Cho", following: Bool = false) -> String {
        """
        {"id":"\(id)","display_name":"\(name)","bio":"Sample creator. Weeknight Korean.",
         "avatar_url":null,"recipe_count":3,"follower_count":\(following ? 1 : 0),
         "is_following":\(following),"cuisines":["korean"],
         "sample_recipe_titles":["Weeknight Doenjang Tofu Stew","Garlicky Spinach Namul"]}
        """
    }

    static func cardJSON(slug: String = "doenjang-tofu-stew", creatorId: String = minaId, feed: String? = nil) -> String {
        let feedPart = feed.map { #","feed":\#($0)"# } ?? ""
        return """
        {"recipe_id":"\(UUID().uuidString.lowercased())","slug":"\(slug)","title":"\(slug)",
         "summary":null,"tags":["korean"],"creator":{"id":"\(creatorId)","display_name":"Mina Cho"},
         "servings":2,"prep_minutes":10,"cook_minutes":20,"cover_image_url":null,
         "published_at":"2026-11-01T00:00:00Z","recipe_version_id":"\(UUID().uuidString.lowercased())",
         "version_number":1,"saved":false\(feedPart)}
        """
    }

    static let forYouFeed = #"{"reason":"You have 6 of 8","coverage":0.75,"can_make":false,"allergy_conflict":null}"#
    static let allergyFeed = #"{"reason":"Korean","coverage":null,"can_make":false,"allergy_conflict":"egg"}"#

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: Data(json.utf8))
    }

    static func creator(id: String = minaId, name: String = "Mina Cho", following: Bool = false) -> CreatorSummary {
        try! decode(CreatorSummary.self, creatorJSON(id: id, name: name, following: following))
    }

    static func card(slug: String = "doenjang-tofu-stew", feed: String? = nil) -> RecipeCard {
        try! decode(RecipeCard.self, cardJSON(slug: slug, feed: feed))
    }

    static func user(onboarded: Bool = false, role: String? = nil) -> User {
        try! decode(User.self, userJSON(onboardedAt: onboarded ? "2026-11-13T01:00:00Z" : nil, role: role))
    }
}

/// Scriptable `OnboardingService` + `SocialService` + `FeedService`.
final class FakeSocialService: OnboardingService, SocialService, FeedService, @unchecked Sendable {
    enum Call: Equatable {
        case setRole(User.Role)
        case completeOnboarding
        case updateTaste(FoodPreferences.TasteUpdate)
        case suggested([String])
        case creator(UUID)
        case follow(UUID)
        case unfollow(UUID)
        case following
        case forYou(String?)
        case followingFeed(String?)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    var user = SocialFixtures.user()
    var suggestedHandler: @Sendable ([String]) throws -> [CreatorSummary] = { _ in [SocialFixtures.creator()] }
    var creatorHandler: @Sendable (UUID) throws -> CreatorProfile = { _ in
        CreatorProfile(creator: SocialFixtures.creator(), recipes: [SocialFixtures.card()])
    }
    var followHandler: @Sendable (UUID, Bool) throws -> CreatorSummary = { id, following in
        let base = SocialFixtures.creator(id: id.uuidString.lowercased(), following: following)
        return base
    }
    var followingHandler: @Sendable () throws -> [CreatorSummary] = { [] }
    var forYouHandler: @Sendable (String?) throws -> FeedPage = { _ in FeedPage(items: [], nextCursor: nil) }
    var followingFeedHandler: @Sendable (String?) throws -> FeedPage = { _ in FeedPage(items: [], nextCursor: nil) }
    var tasteHandler: @Sendable (FoodPreferences) throws -> FoodPreferences = { $0 }
    var completeError: Error?

    func setRole(_ role: User.Role) async throws -> User {
        record(.setRole(role))
        return User(id: user.id, displayName: user.displayName, preferenceUnits: user.preferenceUnits,
                    createdAt: user.createdAt, entitlement: user.entitlement, onboardedAt: user.onboardedAt, role: role)
    }

    func completeOnboarding() async throws -> User {
        record(.completeOnboarding)
        if let completeError { throw completeError }
        return User(id: user.id, displayName: user.displayName, preferenceUnits: user.preferenceUnits,
                    createdAt: user.createdAt, entitlement: user.entitlement, onboardedAt: Date(), role: user.role)
    }

    func updateTaste(_ preferences: FoodPreferences) async throws -> FoodPreferences {
        record(.updateTaste(preferences.tasteUpdate))
        return try tasteHandler(preferences)
    }

    func suggestedCreators(cuisines: [String], limit: Int) async throws -> [CreatorSummary] {
        record(.suggested(cuisines))
        return try suggestedHandler(cuisines)
    }

    func creator(id: UUID) async throws -> CreatorProfile {
        record(.creator(id))
        return try creatorHandler(id)
    }

    func follow(creatorId: UUID) async throws -> CreatorSummary {
        record(.follow(creatorId))
        return try followHandler(creatorId, true)
    }

    func unfollow(creatorId: UUID) async throws -> CreatorSummary {
        record(.unfollow(creatorId))
        return try followHandler(creatorId, false)
    }

    func following() async throws -> [CreatorSummary] {
        record(.following)
        return try followingHandler()
    }

    func forYou(cursor: String?, limit: Int) async throws -> FeedPage {
        record(.forYou(cursor))
        return try forYouHandler(cursor)
    }

    func followingFeed(cursor: String?, limit: Int) async throws -> FeedPage {
        record(.followingFeed(cursor))
        return try followingFeedHandler(cursor)
    }
}
