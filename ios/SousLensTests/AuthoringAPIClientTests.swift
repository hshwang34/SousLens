import Foundation
import XCTest
@testable import SousLens

/// Request shapes for every brief-003 endpoint, through the `URLProtocol` stub.
final class AuthoringAPIClientTests: XCTestCase {
    private func makeClient() -> APIClient {
        APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
            tokenProvider: InMemoryTokenStore(token: "tok")
        )
    }

    private let draftId = UUID(uuidString: AuthoringFixtures.draftId)!
    private let recipeId = UUID(uuidString: AuthoringFixtures.recipeId)!

    private func route(_ table: [String: (Int, String)]) {
        StubURLProtocol.install { request in
            let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            guard let (status, body) = table[key] else {
                return (.stub(request, status: 404), Data(#"{"error":{"code":"NOT_FOUND","message":"no route \#(key)","retryable":false}}"#.utf8))
            }
            return (.stub(request, status: status), Data(body.utf8))
        }
    }

    func testCreateDraftPostsEmptyObjectAndDecodes201() async throws {
        route(["POST /v1/recipes/drafts": (201, AuthoringFixtures.emptyDraftJSON)])
        let draft = try await makeClient().createDraft(.empty)
        XCTAssertEqual(draft.id, draftId)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try request.jsonBody().count, 0)
    }

    func testListAndGetDraft() async throws {
        route([
            "GET /v1/recipes/drafts": (200, AuthoringFixtures.draftSummaryListJSON),
            "GET /v1/recipes/drafts/\(AuthoringFixtures.draftId)": (200, AuthoringFixtures.fullDraftJSON),
        ])
        let client = makeClient()
        let v1 = try await client.listDrafts().count
        XCTAssertEqual(v1, 2)
        let v2 = try await client.draft(id: draftId).title
        XCTAssertEqual(v2, "Garlic Pasta")
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/v1/recipes/drafts", "/v1/recipes/drafts/\(AuthoringFixtures.draftId)"])
    }

    func testPatchSendsOnlyProvidedFieldsInSnakeCase() async throws {
        route(["PATCH /v1/recipes/drafts/\(AuthoringFixtures.draftId)": (200, AuthoringFixtures.fullDraftJSON)])
        var patch = DraftPatch()
        patch.title = "Garlic Pasta"
        patch.cookMinutes = 12
        patch.dietaryWarnings = ["Contains wheat."]
        _ = try await makeClient().updateDraft(id: draftId, patch)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        let json = try request.jsonBody()
        XCTAssertEqual(Set(json.keys), ["title", "cook_minutes", "dietary_warnings"])
        XCTAssertEqual(json["dietary_warnings"] as? [String], ["Contains wheat."])
    }

    func testDeleteDraftAccepts204WithEmptyBody() async throws {
        StubURLProtocol.install { request in (.stub(request, status: 204), Data()) }
        try await makeClient().deleteDraft(id: draftId)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/recipes/drafts/\(AuthoringFixtures.draftId)")
        XCTAssertNil(request.httpBody)
    }

    func testPublishReturns201ResultAnd422SurfacesProblems() async throws {
        route(["POST /v1/recipes/drafts/\(AuthoringFixtures.draftId)/publish": (201, AuthoringFixtures.publishResultJSON)])
        let result = try await makeClient().publishDraft(id: draftId)
        XCTAssertEqual(result.versionNumber, 2)
        XCTAssertEqual(try XCTUnwrap(StubURLProtocol.requests.first).jsonBody().count, 0, "publish posts {}")

        route(["POST /v1/recipes/drafts/\(AuthoringFixtures.draftId)/publish": (422, AuthoringFixtures.validationErrorJSON)])
        do {
            _ = try await makeClient().publishDraft(id: draftId)
            XCTFail("expected 422")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 422)
            XCTAssertEqual(error.userMessage, "Draft is not publishable.")
            XCTAssertEqual(error.correlationId, "c-422")
            XCTAssertEqual(error.validationProblems?.map(\.field), ["title", "steps[0].instruction"])
        }
    }

    func testEditReturnsDraftOr409WithExistingDraftId() async throws {
        route(["POST /v1/recipes/\(AuthoringFixtures.recipeId)/edit": (201, AuthoringFixtures.fullDraftJSON)])
        let draft = try await makeClient().editRecipe(id: recipeId)
        XCTAssertEqual(draft.recipeId, recipeId)

        route(["POST /v1/recipes/\(AuthoringFixtures.recipeId)/edit": (409, AuthoringFixtures.stateConflictJSON)])
        do {
            _ = try await makeClient().editRecipe(id: recipeId)
            XCTFail("expected 409")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.conflictingDraftId, draftId)
        }
    }

    func testUnpublishPostsAndDecodesVisibility() async throws {
        route(["POST /v1/recipes/\(AuthoringFixtures.recipeId)/unpublish": (200, #"{"recipe_id":"\#(AuthoringFixtures.recipeId)","visibility":"private"}"#)])
        let result = try await makeClient().unpublishRecipe(id: recipeId)
        XCTAssertEqual(result.visibility, .private)
        XCTAssertEqual(result.recipeId, recipeId)
    }

    func testSaveIsPostAndUnsaveIsDelete() async throws {
        route([
            "POST /v1/recipes/\(AuthoringFixtures.recipeId)/save": (200, #"{"recipe_id":"\#(AuthoringFixtures.recipeId)","saved":true}"#),
            "DELETE /v1/recipes/\(AuthoringFixtures.recipeId)/save": (200, #"{"recipe_id":"\#(AuthoringFixtures.recipeId)","saved":false}"#),
        ])
        let client = makeClient()
        let v3 = try await client.saveRecipe(id: recipeId).saved
        XCTAssertTrue(v3)
        let v4 = try await client.unsaveRecipe(id: recipeId).saved
        XCTAssertFalse(v4)
        XCTAssertEqual(StubURLProtocol.requests.map(\.httpMethod), ["POST", "DELETE"])
    }

    func testMySavedMyRecipesAndRecipeVersionPaths() async throws {
        route([
            "GET /v1/me/saved": (200, AuthoringFixtures.savedListJSON),
            "GET /v1/me/recipes": (200, AuthoringFixtures.myRecipesJSON),
            "GET /v1/recipe-versions/\(AuthoringFixtures.versionId)": (200, AuthoringFixtures.detailJSON()),
        ])
        let client = makeClient()
        let v5 = try await client.mySaved().map(\.title)
        XCTAssertEqual(v5, ["Garlic Pasta"])
        let v6 = try await client.myRecipes().map(\.visibility)
        XCTAssertEqual(v6, [.public])
        let version = try await client.recipeVersion(id: UUID(uuidString: AuthoringFixtures.versionId)!)
        XCTAssertEqual(version.versionNumber, 2)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/v1/me/saved", "/v1/me/recipes", "/v1/recipe-versions/\(AuthoringFixtures.versionId)"])
    }
}
