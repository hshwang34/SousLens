import Foundation
import XCTest
import os
@testable import SousLens

struct MissingFixture: Error, CustomStringConvertible {
    let name: String
    var description: String { "Missing fixture \(name).json in the test bundle — check project.yml resources" }
}

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: FixtureAnchor.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw MissingFixture(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: data(name))
    }
}

private final class FixtureAnchor {}

/// `URLProtocol` stub: tests register a handler, `URLSession` routes every request through it.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let state = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let recorded = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static func install(_ handler: @escaping Handler) {
        state.withLock { $0 = handler }
        recorded.withLock { $0 = [] }
    }

    static var requests: [URLRequest] { recorded.withLock { $0 } }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.state.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let request = self.request
        Self.recorded.withLock { $0.append(request) }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension HTTPURLResponse {
    static func stub(_ request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            preconditionFailure("stub response could not be built")
        }
        return response
    }
}

/// Scriptable `RecipeService` for view-model tests.
final class FakeRecipeService: RecipeService, @unchecked Sendable {
    struct Call: Equatable {
        let query: String?
        let tag: String?
        let cursor: String?
        let limit: Int
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    /// Called for each list request; may throw.
    var listHandler: @Sendable (Call) throws -> RecipePage
    var detailHandler: @Sendable (UUID) throws -> RecipeDetail
    /// Optional suspension point before a list request resolves (lets tests observe `.loading`).
    var beforeList: (@Sendable () async -> Void)?

    init(listHandler: @escaping @Sendable (Call) throws -> RecipePage = { _ in RecipePage(items: [], nextCursor: nil) },
         detailHandler: @escaping @Sendable (UUID) throws -> RecipeDetail = { _ in throw APIError.http(status: 404, correlationId: nil) }) {
        self.listHandler = listHandler
        self.detailHandler = detailHandler
    }

    func listRecipes(query: String?, tag: String?, cursor: String?, limit: Int) async throws -> RecipePage {
        let call = Call(query: query, tag: tag, cursor: cursor, limit: limit)
        lock.withLock { _calls.append(call) }
        await beforeList?()
        return try listHandler(call)
    }

    func recipe(id: UUID) async throws -> RecipeDetail {
        try detailHandler(id)
    }
}

final class InMemoryRecipeCache: RecipeCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CachedRecipeList?
    private var _clearCount = 0
    var clearCount: Int { lock.withLock { _clearCount } }

    init(stored: CachedRecipeList? = nil) {
        self.stored = stored
    }

    func load() -> CachedRecipeList? { lock.withLock { stored } }
    func save(_ items: [RecipeCard]) throws { lock.withLock { stored = CachedRecipeList(items: items, savedAt: Date()) } }
    func clear() throws { lock.withLock { stored = nil; _clearCount += 1 } }
}

/// Shared JSON bodies and helpers for auth-flow tests.
enum AuthFixtures {
    static let userJSON = #"{"id":"c1a2b3c4-d5e6-4f70-8a9b-0c1d2e3f4a5b","display_name":"Tester","preference_units":"us","created_at":"2026-10-20T00:00:00Z"}"#
    static let loginJSON = #"{"access_token":"jwt-1","token_type":"bearer","user":"# + userJSON + "}"
    static let challengeJSON = #"{"challenge_id":"chal-1","expires_in_seconds":600,"hint":"Check the server log for your sign-in code."}"#
    static let badCodeJSON = #"{"error":{"code":"UNAUTHORIZED","message":"Invalid or expired sign-in code","retryable":false,"correlation_id":"c-bad"}}"#
    static let expiredTokenJSON = #"{"error":{"code":"UNAUTHORIZED","message":"Token expired.","retryable":false,"correlation_id":"c401"}}"#

    /// Routes dev-login, verify and `/v1/me`; everything else gets `fallback`.
    static func installHappyPath(fallback: @escaping StubURLProtocol.Handler = { request in
        (.stub(request, status: 200), Data(userJSON.utf8))
    }) {
        StubURLProtocol.install { request in
            switch request.url?.path {
            case "/v1/auth/dev-login": return (.stub(request, status: 202), Data(challengeJSON.utf8))
            case "/v1/auth/dev-login/verify": return (.stub(request, status: 200), Data(loginJSON.utf8))
            default: return try fallback(request)
            }
        }
    }
}

/// `UserDefaults` suite that is unique per test and already past first launch (so `restore()`
/// does not wipe a token the test planted).
func freshDefaults(launched: Bool = true) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "SousLensTests.\(UUID().uuidString)") ?? .standard
    if launched { defaults.set(true, forKey: AuthStore.hasLaunchedKey) }
    return defaults
}

func readAll(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

extension URLRequest {
    /// Body as JSON object regardless of whether URLSession moved it into a stream.
    func jsonBody() throws -> [String: Any] {
        let data = try XCTUnwrap(httpBody ?? httpBodyStream.map(readAll))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
