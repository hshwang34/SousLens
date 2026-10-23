import Foundation
import XCTest
@testable import SousLens

final class APIClientTests: XCTestCase {
    private func makeClient(token: String? = "tok", baseURL: String? = "http://stub.test:8000", generation: SessionGeneration = SessionGeneration()) -> APIClient {
        APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: baseURL.flatMap(URL.init(string:))),
            tokenProvider: InMemoryTokenStore(token: token),
            sessionGeneration: generation
        )
    }

    // MARK: - Error envelope

    func testDecodesErrorEnvelopeAndCorrelationId() async throws {
        StubURLProtocol.install { request in
            let body = #"{"error":{"code":"NOT_FOUND","message":"No such recipe.","retryable":false,"correlation_id":"cid-123"}}"#
            return (.stub(request, status: 404, headers: ["X-Correlation-Id": "cid-123"]), Data(body.utf8))
        }
        do {
            _ = try await makeClient().recipe(id: UUID())
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 404, code: "NOT_FOUND", message: "No such recipe.", retryable: false, correlationId: "cid-123"))
            XCTAssertEqual(error.userMessage, "No such recipe.")
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(error.correlationId, "cid-123")
        }
    }

    func testUnknownErrorCodeDecodesAsServerError() async {
        StubURLProtocol.install { request in
            let body = #"{"error":{"code":"SOMETHING_NEW_FROM_V2","message":"Teapot.","retryable":true,"correlation_id":"x9"},"extra":1}"#
            return (.stub(request, status: 418), Data(body.utf8))
        }
        do {
            _ = try await makeClient().me()
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 418, code: "SOMETHING_NEW_FROM_V2", message: "Teapot.", retryable: true, correlationId: "x9"))
            XCTAssertTrue(error.isRetryable)
        } catch { XCTFail("\(error)") }
    }

    func testEnvelopeMissingOptionalCorrelationIdStillDecodes() async {
        StubURLProtocol.install { request in
            let body = #"{"error":{"code":"VALIDATION","message":"Bad.","retryable":false}}"#
            return (.stub(request, status: 422, headers: ["X-Correlation-Id": "hdr-7"]), Data(body.utf8))
        }
        do {
            _ = try await makeClient().me()
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error.correlationId, "hdr-7")
            XCTAssertEqual(error.userMessage, "Bad.")
        } catch { XCTFail("\(error)") }
    }

    func testNonJSON500YieldsHTTPErrorNotDecodeCrash() async {
        StubURLProtocol.install { request in
            (.stub(request, status: 500, headers: ["X-Correlation-Id": "cid-500"]), Data("<html>Internal Server Error</html>".utf8))
        }
        do {
            _ = try await makeClient().listRecipes()
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error, .http(status: 500, correlationId: "cid-500"))
            XCTAssertEqual(error.userMessage, "The server returned an unexpected error (HTTP 500).")
            XCTAssertTrue(error.isRetryable)
        } catch { XCTFail("\(error)") }
    }

    func testEmptyBody500AndMalformed200() async {
        StubURLProtocol.install { request in (.stub(request, status: 500), Data()) }
        do {
            _ = try await makeClient().me()
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error, .http(status: 500, correlationId: nil))
        } catch { XCTFail("\(error)") }

        StubURLProtocol.install { request in (.stub(request, status: 200), Data("not json".utf8)) }
        do {
            _ = try await makeClient().me()
            XCTFail("expected error")
        } catch let error as APIError {
            guard case .decoding = error else { return XCTFail("got \(error)") }
            XCTAssertFalse(error.userMessage.isEmpty)
        } catch { XCTFail("\(error)") }
    }

    func testFallsBackToHeaderCorrelationIdWithoutEnvelope() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 503, headers: ["X-Correlation-Id": "hdr-1"]), Data("oops".utf8))
        }
        do {
            _ = try await makeClient().health()
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error, .http(status: 503, correlationId: "hdr-1"))
            XCTAssertTrue(error.isRetryable)
        }
    }

    // MARK: - 401 handling

    func testUnauthorizedOnAuthenticatedRequestFiresEventWithIssuedGeneration() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 401), Data(AuthFixtures.expiredTokenJSON.utf8))
        }
        let generation = SessionGeneration()
        generation.advance()
        generation.advance()
        let client = makeClient(generation: generation)
        let fired = expectation(description: "unauthorized event")
        client.events.onUnauthorized { event in
            XCTAssertEqual(event, UnauthorizedEvent(error: .unauthorized(message: "Token expired.", correlationId: "c401"), generation: 2))
            fired.fulfill()
        }
        do {
            _ = try await client.me()
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(message: "Token expired.", correlationId: "c401"))
            XCTAssertEqual(error.userMessage, "Token expired.")
        }
        await fulfillment(of: [fired], timeout: 1)
    }

    func testUnauthorizedWithoutEnvelopeUsesDefaultMessage() {
        XCTAssertEqual(APIError.unauthorized(message: nil, correlationId: nil).userMessage, "Your session ended. Please sign in again.")
    }

    func testUnauthorizedOnUnauthenticatedVerifyDoesNotFireGlobalEvent() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 401), Data(AuthFixtures.badCodeJSON.utf8))
        }
        let client = makeClient(token: nil)
        client.events.onUnauthorized { _ in
            XCTFail("a wrong sign-in code must not trigger the global unauthorized path")
        }
        do {
            _ = try await client.verifyDevCode(challengeId: "chal-1", code: "000000")
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(message: "Invalid or expired sign-in code", correlationId: "c-bad"))
            XCTAssertEqual(error.userMessage, "Invalid or expired sign-in code")
        }
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Request shape

    func testSendsBearerTokenAndQueryParameters() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 200), try Fixtures.data("recipes_list"))
        }
        let page = try await makeClient(token: "secret-jwt").listRecipes(query: "gochujang chicken", tag: "korean", cursor: "c2", limit: 5)
        XCTAssertEqual(page.items.count, 1)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-jwt")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/v1/recipes")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["query"], "gochujang chicken")
        XCTAssertEqual(items["tag"], "korean")
        XCTAssertEqual(items["cursor"], "c2")
        XCTAssertEqual(items["limit"], "5")
    }

    func testQueryValuesPercentEncodePlusAmpersandAndSpace() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 200), try Fixtures.data("recipes_list"))
        }
        _ = try await makeClient().listRecipes(query: "salt+pepper & eggs", tag: "a=b", cursor: nil, limit: 20)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let encoded = try XCTUnwrap(request.url?.query(percentEncoded: true))
        XCTAssertTrue(encoded.contains("query=salt%2Bpepper%20%26%20eggs"), encoded)
        XCTAssertTrue(encoded.contains("tag=a%3Db"), encoded)
        XCTAssertFalse(encoded.contains("+"), "a literal + would be read as a space by the server")
        // And it still decodes back to the original on the server side.
        let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "query" }?.value, "salt+pepper & eggs")
        XCTAssertEqual(items.first { $0.name == "tag" }?.value, "a=b")
    }

    func testDevLoginRequestPostsEmailOnlyWithoutToken() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 202), Data(AuthFixtures.challengeJSON.utf8))
        }
        let challenge = try await makeClient(token: nil).requestDevCode(email: "tester@example.com")
        XCTAssertEqual(challenge.challengeId, "chal-1")
        XCTAssertEqual(challenge.expiresInSeconds, 600)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.path, "/v1/auth/dev-login")
        let json = try request.jsonBody()
        XCTAssertEqual(json["email"] as? String, "tester@example.com")
        XCTAssertEqual(json.count, 1, "step 1 sends only the email")
    }

    func testVerifyPostsSnakeCaseBody() async throws {
        StubURLProtocol.install { request in
            (.stub(request, status: 200), Data(AuthFixtures.loginJSON.utf8))
        }
        let response = try await makeClient(token: nil).verifyDevCode(challengeId: "chal-1", code: "123456")
        XCTAssertEqual(response.accessToken, "jwt-1")
        XCTAssertEqual(response.user.displayName, "Tester")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/auth/dev-login/verify")
        let json = try request.jsonBody()
        XCTAssertEqual(json["challenge_id"] as? String, "chal-1")
        XCTAssertEqual(json["code"] as? String, "123456")
    }

    func testUnreachableServerMapsToUnreachable() async throws {
        StubURLProtocol.install { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await makeClient().health()
            XCTFail("expected error")
        } catch let error as APIError {
            guard case .unreachable(let base, _) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(base, "http://stub.test:8000")
            XCTAssertTrue(error.userMessage.contains("Can’t reach the server"))
        }
    }

    func testMissingServerConfiguration() async throws {
        do {
            _ = try await makeClient(baseURL: nil).health()
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error, .noServerConfigured)
        }
    }
}
