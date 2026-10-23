import Foundation
import os

/// What the recipe screens need. `APIClient` is the real implementation; tests inject a fake.
protocol RecipeService: Sendable {
    // Browse (Slice 0)
    func listRecipes(query: String?, tag: String?, cursor: String?, limit: Int) async throws -> RecipePage
    func recipe(id: UUID) async throws -> RecipeDetail

    // Brief 003 — drafts (owner only)
    func createDraft(_ patch: DraftPatch) async throws -> Draft
    func listDrafts() async throws -> [DraftSummary]
    func draft(id: UUID) async throws -> Draft
    func updateDraft(id: UUID, _ patch: DraftPatch) async throws -> Draft
    func deleteDraft(id: UUID) async throws
    func publishDraft(id: UUID) async throws -> PublishResult
    /// `POST /recipes/{id}/edit`; 409 `STATE_CONFLICT` → `APIError.conflictingDraftId`.
    func editRecipe(id: UUID) async throws -> Draft
    func unpublishRecipe(id: UUID) async throws -> UnpublishResult

    // Brief 003 — saves and "mine"
    func saveRecipe(id: UUID) async throws -> SaveResult
    func unsaveRecipe(id: UUID) async throws -> SaveResult
    func mySaved() async throws -> [RecipeCard]
    func myRecipes() async throws -> [MyRecipe]
    /// `GET /recipe-versions/{id}` — an exact version, whatever the recipe's current visibility.
    func recipeVersion(id: UUID) async throws -> RecipeDetail
}

protocol AuthService: Sendable {
    /// Step 1: the backend prints a 6-digit code to its log and returns a challenge.
    func requestDevCode(email: String) async throws -> DevLoginChallenge
    /// Step 2: exchange challenge + code for a token. Wrong/expired code → `APIError.unauthorized`.
    func verifyDevCode(challengeId: String, code: String) async throws -> AuthResponse
    func me() async throws -> User
}

/// Monotonic sign-in generation shared by `APIClient` and `AuthStore`. A request remembers the
/// generation it was issued under, so a 401 that lands after the user already signed out and back
/// in (a stale generation) cannot tear down the new session.
final class SessionGeneration: Sendable {
    private let value = OSAllocatedUnfairLock<Int>(initialState: 0)

    func current() -> Int { value.withLock { $0 } }

    @discardableResult
    func advance() -> Int { value.withLock { $0 += 1; return $0 } }
}

struct UnauthorizedEvent: Sendable, Equatable {
    let error: APIError
    /// `SessionGeneration` value when the request was issued.
    let generation: Int
}

/// Thread-safe hook so `AuthStore` can be told about a 401 without a reference cycle.
final class APIClientEvents: Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (UnauthorizedEvent) -> Void)?>(initialState: nil)

    func onUnauthorized(_ block: @escaping @Sendable (UnauthorizedEvent) -> Void) {
        handler.withLock { $0 = block }
    }

    fileprivate func fireUnauthorized(_ event: UnauthorizedEvent) {
        handler.withLock { $0 }?(event)
    }
}

/// Typed, async client for the SousLens backend.
///
/// - Base URL comes from `BaseURLProviding` on every request, so a settings change applies immediately.
/// - Bearer token comes from `TokenProviding`; a 401 anywhere clears it via `events` → `AuthStore`.
/// - Every response's `X-Correlation-Id` is logged; errors are decoded from the PRD envelope.
final class APIClient: Sendable, RecipeService, AuthService {
    let events = APIClientEvents()
    let sessionGeneration: SessionGeneration

    private let session: URLSessionProtocol
    private let baseURLProvider: BaseURLProviding
    private let tokenProvider: TokenProviding
    private let decoder = JSONCoding.makeDecoder()
    let encoder = JSONCoding.makeEncoder()
    private let logger = Logger(subsystem: "com.souslens.ios", category: "api")

    init(session: URLSessionProtocol = URLSession.shared,
         baseURLProvider: BaseURLProviding,
         tokenProvider: TokenProviding,
         sessionGeneration: SessionGeneration = SessionGeneration()) {
        self.session = session
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.sessionGeneration = sessionGeneration
    }

    // MARK: - Endpoints

    func health() async throws -> HealthResponse {
        try await send(.get("/v1/health"), authenticated: false)
    }

    func requestDevCode(email: String) async throws -> DevLoginChallenge {
        let body = try encoder.encode(DevLoginRequest(email: email))
        return try await send(.post("/v1/auth/dev-login", body: body), authenticated: false)
    }

    func verifyDevCode(challengeId: String, code: String) async throws -> AuthResponse {
        let body = try encoder.encode(DevLoginVerifyRequest(challengeId: challengeId, code: code))
        return try await send(.post("/v1/auth/dev-login/verify", body: body), authenticated: false)
    }

    func me() async throws -> User {
        try await send(.get("/v1/me"))
    }

    func listRecipes(query: String? = nil, tag: String? = nil, cursor: String? = nil, limit: Int = 20) async throws -> RecipePage {
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        if let tag, !tag.isEmpty { items.append(URLQueryItem(name: "tag", value: tag)) }
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(.get("/v1/recipes", query: items))
    }

    func recipe(id: UUID) async throws -> RecipeDetail {
        try await send(.get("/v1/recipes/\(id.uuidString.lowercased())"))
    }

    // MARK: Brief 003 — drafts

    func createDraft(_ patch: DraftPatch = .empty) async throws -> Draft {
        try await send(.post("/v1/recipes/drafts", body: try encoder.encode(patch)))
    }

    func listDrafts() async throws -> [DraftSummary] {
        let response: ItemsResponse<DraftSummary> = try await send(.get("/v1/recipes/drafts"))
        return response.items
    }

    func draft(id: UUID) async throws -> Draft {
        try await send(.get("/v1/recipes/drafts/\(Self.pathId(id))"))
    }

    func updateDraft(id: UUID, _ patch: DraftPatch) async throws -> Draft {
        try await send(.patch("/v1/recipes/drafts/\(Self.pathId(id))", body: try encoder.encode(patch)))
    }

    func deleteDraft(id: UUID) async throws {
        _ = try await raw(.delete("/v1/recipes/drafts/\(Self.pathId(id))"))
    }

    func publishDraft(id: UUID) async throws -> PublishResult {
        try await send(.post("/v1/recipes/drafts/\(Self.pathId(id))/publish", body: Self.emptyObject))
    }

    func editRecipe(id: UUID) async throws -> Draft {
        try await send(.post("/v1/recipes/\(Self.pathId(id))/edit", body: Self.emptyObject))
    }

    func unpublishRecipe(id: UUID) async throws -> UnpublishResult {
        try await send(.post("/v1/recipes/\(Self.pathId(id))/unpublish", body: Self.emptyObject))
    }

    // MARK: Brief 003 — saves and "mine"

    func saveRecipe(id: UUID) async throws -> SaveResult {
        try await send(.post("/v1/recipes/\(Self.pathId(id))/save", body: Self.emptyObject))
    }

    func unsaveRecipe(id: UUID) async throws -> SaveResult {
        try await send(.delete("/v1/recipes/\(Self.pathId(id))/save"))
    }

    func mySaved() async throws -> [RecipeCard] {
        let response: ItemsResponse<RecipeCard> = try await send(.get("/v1/me/saved"))
        return response.items
    }

    func myRecipes() async throws -> [MyRecipe] {
        let response: ItemsResponse<MyRecipe> = try await send(.get("/v1/me/recipes"))
        return response.items
    }

    func recipeVersion(id: UUID) async throws -> RecipeDetail {
        try await send(.get("/v1/recipe-versions/\(Self.pathId(id))"))
    }

    static let emptyObject = Data("{}".utf8)

    static func pathId(_ id: UUID) -> String { id.uuidString.lowercased() }

    // MARK: - Transport

    struct Endpoint: Sendable {
        let method: String
        let path: String
        var query: [URLQueryItem] = []
        var body: Data? = nil
        /// Sent with `body`. JSON unless a multipart upload says otherwise.
        var contentType = "application/json"
        var timeout: TimeInterval = 15

        static func get(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
            Endpoint(method: "GET", path: path, query: query)
        }

        static func post(_ path: String, body: Data?) -> Endpoint {
            Endpoint(method: "POST", path: path, body: body)
        }

        static func patch(_ path: String, body: Data?) -> Endpoint {
            Endpoint(method: "PATCH", path: path, body: body)
        }

        static func delete(_ path: String) -> Endpoint {
            Endpoint(method: "DELETE", path: path)
        }

        /// `multipart/form-data` POST (pantry photo). Uploads get a longer timeout (PRD §14: 15 s
        /// vision target plus transfer).
        static func multipart(_ path: String, form: MultipartFormData) -> Endpoint {
            Endpoint(method: "POST", path: path, body: form.encoded(), contentType: form.contentType, timeout: 30)
        }
    }

    func send<T: Decodable>(_ endpoint: Endpoint, authenticated: Bool = true) async throws -> T {
        let data = try await raw(endpoint, authenticated: authenticated)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Decoding errors can echo response fragments; keep them out of the public log.
            logger.error("decode \(endpoint.path, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            throw APIError.decoding(String(describing: error))
        }
    }

    func raw(_ endpoint: Endpoint, authenticated: Bool = true) async throws -> Data {
        let issuedGeneration = sessionGeneration.current()
        let request = try makeRequest(endpoint, authenticated: authenticated)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw APIError.cancelled
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            let base = baseURLProvider.baseURLString
            logger.error("\(endpoint.method, privacy: .public) \(endpoint.path, privacy: .public) unreachable: \(error.localizedDescription, privacy: .public)")
            throw APIError.unreachable(baseURL: base, underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, correlationId: nil)
        }
        let correlationId = http.value(forHTTPHeaderField: "X-Correlation-Id")
        logger.info("\(endpoint.method, privacy: .public) \(endpoint.path, privacy: .public) → \(http.statusCode) cid=\(correlationId ?? "-", privacy: .public)")

        if (200...299).contains(http.statusCode) {
            return data
        }

        let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
        let cid = envelope?.error.correlationId ?? correlationId
        if http.statusCode == 401 {
            let error = APIError.unauthorized(message: envelope?.error.message, correlationId: cid)
            // A 401 from an unauthenticated call (wrong sign-in code) says nothing about a session.
            if authenticated {
                events.fireUnauthorized(UnauthorizedEvent(error: error, generation: issuedGeneration))
            }
            throw error
        }
        if let envelope {
            throw APIError.server(
                status: http.statusCode,
                code: envelope.error.code,
                message: envelope.error.message,
                retryable: envelope.error.retryable,
                correlationId: cid,
                details: envelope.error.details
            )
        }
        throw APIError.http(status: http.statusCode, correlationId: cid)
    }

    private func makeRequest(_ endpoint: Endpoint, authenticated: Bool) throws -> URLRequest {
        let baseString = baseURLProvider.baseURLString
        guard !baseString.isEmpty else { throw APIError.noServerConfigured }
        guard let base = baseURLProvider.baseURL,
              var components = URLComponents(url: base.appending(path: endpoint.path), resolvingAgainstBaseURL: false)
        else { throw APIError.invalidURL(baseString) }
        if !endpoint.query.isEmpty {
            // `queryItems` leaves "+" unencoded, which servers read as a space; encode it ourselves.
            components.percentEncodedQuery = Self.percentEncodedQuery(endpoint.query)
        }
        guard let url = components.url else { throw APIError.invalidURL(baseString) }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = endpoint.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue(endpoint.contentType, forHTTPHeaderField: "Content-Type")
        }
        if authenticated, let token = tokenProvider.currentToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// RFC 3986 query encoding where "+", "&", "=" and "#" inside values are escaped too.
    static func percentEncodedQuery(_ items: [URLQueryItem]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        func encode(_ string: String) -> String {
            string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
        }
        return items.map { item in
            guard let value = item.value else { return encode(item.name) }
            return "\(encode(item.name))=\(encode(value))"
        }.joined(separator: "&")
    }
}
