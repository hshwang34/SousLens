import Foundation
import XCTest
@testable import Umma

/// Brief 015 DTOs and request shapes through the `URLProtocol` stub.
final class SocialDTOTests: XCTestCase {
    func testUserDecodesOnboardingFields() throws {
        let fresh = SocialFixtures.user()
        XCTAssertNil(fresh.onboardedAt)
        XCTAssertTrue(fresh.needsOnboarding)
        XCTAssertNil(fresh.role)

        let done = SocialFixtures.user(onboarded: true, role: "creator")
        XCTAssertFalse(done.needsOnboarding)
        XCTAssertEqual(done.role, .creator)
    }

    func testUnknownRoleAndOlderServerDecode() throws {
        let newer = try SocialFixtures.decode(User.self, SocialFixtures.userJSON(role: "chef"))
        XCTAssertNil(newer.role, "an unknown role is 'not chosen', not a decode failure")
        let older = try SocialFixtures.decode(User.self, """
        {"id":"\(SocialFixtures.userId)","display_name":"a","preference_units":"metric","created_at":"2026-11-13T00:00:00Z"}
        """)
        XCTAssertNil(older.onboardedAt)
        XCTAssertNil(older.role)
    }

    func testCachedUserRoundTrips() throws {
        let user = SocialFixtures.user(onboarded: true, role: "cook")
        let data = try JSONCoding.makeEncoder().encode(user)
        XCTAssertEqual(try JSONCoding.makeDecoder().decode(User.self, from: data), user)
    }

    func testPreferencesDecodeTasteAndOldPayload() throws {
        let prefs = try SocialFixtures.decode(FoodPreferences.self, """
        {"allergies":["peanut"],"avoid":[],"diets":["vegetarian"],"cuisines":["korean","thai"],
         "skill_level":"beginner","updated_at":null,"unrecognized":[]}
        """)
        XCTAssertEqual(prefs.diets, ["vegetarian"])
        XCTAssertEqual(prefs.cuisines, ["korean", "thai"])
        XCTAssertEqual(prefs.skillLevel, "beginner")

        let old = try SocialFixtures.decode(FoodPreferences.self, #"{"allergies":[],"avoid":[]}"#)
        XCTAssertEqual(old.diets, [])
        XCTAssertNil(old.skillLevel)
    }

    func testTasteUpdateSendsNullSkillButPlainUpdateOmitsTaste() throws {
        let prefs = FoodPreferences(allergies: ["egg"], diets: ["vegan"], cuisines: [])
        let taste = try JSONSerialization.jsonObject(with: JSONCoding.makeEncoder().encode(prefs.tasteUpdate)) as? [String: Any]
        XCTAssertEqual(taste?["diets"] as? [String], ["vegan"])
        XCTAssertEqual(taste?["cuisines"] as? [String], [])
        XCTAssertTrue(taste?["skill_level"] is NSNull, "null clears; omitted would keep the stored value")

        let plain = try JSONSerialization.jsonObject(with: JSONCoding.makeEncoder().encode(prefs.update)) as? [String: Any]
        XCTAssertEqual(Set(plain?.keys ?? [:].keys), ["allergies", "avoid"], "allergy editor never touches taste")
    }

    func testCreatorAndFeedCardDecode() throws {
        let mina = SocialFixtures.creator(following: true)
        XCTAssertEqual(mina.initials, "MC")
        XCTAssertTrue(mina.isFollowing)
        XCTAssertEqual(mina.sampleRecipeTitles.count, 2)

        let card = SocialFixtures.card(feed: SocialFixtures.allergyFeed)
        XCTAssertEqual(card.feed?.allergyConflict, "egg")
        XCTAssertNil(card.feed?.coverage)
        XCTAssertNil(SocialFixtures.card().feed, "plain lists carry no feed info")
    }

    func testTasteOptionLabels() {
        XCTAssertEqual(TasteOptions.label(for: "korean", in: TasteOptions.cuisines), "Korean")
        XCTAssertEqual(TasteOptions.label(for: "nordic", in: TasteOptions.cuisines), "Nordic")
    }
}

final class SocialAPIClientTests: XCTestCase {
    private func makeClient() -> APIClient {
        APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
            tokenProvider: InMemoryTokenStore(token: "tok")
        )
    }

    private func route(_ table: [String: (Int, String)]) {
        StubURLProtocol.install { request in
            let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            guard let (status, body) = table[key] else {
                return (.stub(request, status: 404), Data(#"{"error":{"code":"NOT_FOUND","message":"no route \#(key)","retryable":false}}"#.utf8))
            }
            return (.stub(request, status: status), Data(body.utf8))
        }
    }

    private func json(_ request: URLRequest?) throws -> [String: Any] {
        let request = try XCTUnwrap(request)
        let data = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(readAll))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRoleAndOnboardingComplete() async throws {
        route([
            "PATCH /v1/me": (200, SocialFixtures.userJSON(role: "creator")),
            "POST /v1/me/onboarding/complete": (200, SocialFixtures.userJSON(onboardedAt: "2026-11-13T01:00:00Z", role: "creator")),
        ])
        let client = makeClient()
        let user = try await client.setRole(.creator)
        XCTAssertEqual(user.role, .creator)
        XCTAssertEqual(try json(StubURLProtocol.requests.last)["role"] as? String, "creator")
        let done = try await client.completeOnboarding()
        XCTAssertFalse(done.needsOnboarding)
    }

    func testSuggestedSendsCuisinesAndLimit() async throws {
        route(["GET /v1/creators/suggested": (200, #"{"items":[\#(SocialFixtures.creatorJSON())]}"#)])
        let items = try await makeClient().suggestedCreators(cuisines: ["korean", "thai"], limit: 8)
        XCTAssertEqual(items.map(\.displayName), ["Mina Cho"])
        let query = StubURLProtocol.requests.last?.url?.query ?? ""
        XCTAssertTrue(query.contains("cuisines=korean,thai") || query.contains("cuisines=korean%2Cthai"), query)
        XCTAssertTrue(query.contains("limit=8"))
    }

    func testFollowUnfollowPaths() async throws {
        let id = SocialFixtures.minaId
        route([
            "PUT /v1/creators/\(id)/follow": (200, SocialFixtures.creatorJSON(following: true)),
            "DELETE /v1/creators/\(id)/follow": (200, SocialFixtures.creatorJSON(following: false)),
            "GET /v1/me/following": (200, #"{"items":[]}"#),
        ])
        let client = makeClient()
        let followed = try await client.follow(creatorId: try XCTUnwrap(UUID(uuidString: id)))
        XCTAssertTrue(followed.isFollowing)
        let unfollowed = try await client.unfollow(creatorId: try XCTUnwrap(UUID(uuidString: id)))
        XCTAssertFalse(unfollowed.isFollowing)
        let list = try await client.following()
        XCTAssertTrue(list.isEmpty)
    }

    func testCreatorProfileAndFeeds() async throws {
        let id = SocialFixtures.minaId
        route([
            "GET /v1/creators/\(id)": (200, #"{"creator":\#(SocialFixtures.creatorJSON()),"recipes":[\#(SocialFixtures.cardJSON())]}"#),
            "GET /v1/feed/for-you": (200, #"{"items":[\#(SocialFixtures.cardJSON(feed: SocialFixtures.forYouFeed))],"next_cursor":"o20"}"#),
            "GET /v1/feed/following": (200, #"{"items":[],"next_cursor":null}"#),
        ])
        let client = makeClient()
        let profile = try await client.creator(id: try XCTUnwrap(UUID(uuidString: id)))
        XCTAssertEqual(profile.recipes.count, 1)

        let page = try await client.forYou(cursor: "o20", limit: 20)
        XCTAssertEqual(page.items.first?.feed?.reason, "You have 6 of 8")
        XCTAssertEqual(page.nextCursor, "o20")
        XCTAssertTrue(StubURLProtocol.requests.last?.url?.query?.contains("cursor=o20") ?? false)

        let following = try await client.followingFeed(cursor: nil, limit: 20)
        XCTAssertTrue(following.items.isEmpty)
    }

    func testTastePutBody() async throws {
        route(["PUT /v1/me/preferences": (200, #"{"allergies":[],"avoid":[],"diets":["vegan"],"cuisines":["korean"],"skill_level":null}"#)])
        let saved = try await makeClient().updateTaste(FoodPreferences(diets: ["vegan"], cuisines: ["korean"]))
        XCTAssertEqual(saved.diets, ["vegan"])
        let body = try json(StubURLProtocol.requests.last)
        XCTAssertEqual(body["cuisines"] as? [String], ["korean"])
        XCTAssertTrue(body["skill_level"] is NSNull)
    }
}
