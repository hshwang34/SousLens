import Foundation

/// Brief 005 food preferences (`/me/preferences`).
protocol PreferencesService: Sendable {
    func preferences() async throws -> FoodPreferences
    func updatePreferences(_ preferences: FoodPreferences) async throws -> FoodPreferences
}

/// Brief 005 substitutions, sessions, commands, ask, notes and private variations.
/// `APIClient` is the real implementation; view-model tests inject `FakeCookingService`.
protocol CookingService: Sendable {
    func suggestSubstitutions(recipeVersionId: UUID, ingredientRef: String) async throws -> SubstitutionResult

    /// `POST /sessions` → 201 (`status: created`, `revision: 0`).
    func createSession(recipeVersionId: UUID, adaptations: [AdaptationInput]) async throws -> CookingSession
    /// `GET /sessions?status=active`, newest first.
    func activeSessions() async throws -> [SessionSummary]
    func session(id: UUID) async throws -> CookingSession
    func deleteSession(id: UUID) async throws
    /// `POST /sessions/{id}/commands` with the `Idempotency-Key` header. Use `SessionCommandSender`
    /// rather than calling this directly, so a retry reuses the key.
    func sendCommand(sessionId: UUID, _ command: SessionCommand, idempotencyKey: String) async throws -> CookingSession
    func ask(sessionId: UUID, query: String, groundedRevision: Int) async throws -> AskResponse
    func addNote(sessionId: UUID, text: String) async throws -> SessionNote

    /// `GET /recipe-versions/{id}/my-variation`; a 404 (none saved) is `nil`, not an error.
    func myVariation(recipeVersionId: UUID) async throws -> PrivateVariation?
    func deleteMyVariation(recipeVersionId: UUID) async throws
}

extension APIClient: PreferencesService, CookingService {
    static let idempotencyHeader = "Idempotency-Key"

    func preferences() async throws -> FoodPreferences {
        try await send(.get("/v1/me/preferences"))
    }

    func updatePreferences(_ preferences: FoodPreferences) async throws -> FoodPreferences {
        try await send(.put("/v1/me/preferences", body: try encoder.encode(preferences.update)))
    }

    func suggestSubstitutions(recipeVersionId: UUID, ingredientRef: String) async throws -> SubstitutionResult {
        let body = try encoder.encode(SubstitutionRequest(recipeVersionId: recipeVersionId, ingredientRef: ingredientRef))
        // Rules + advisor can take a moment; same budget as other AI-backed calls.
        var endpoint = Endpoint.post("/v1/substitutions/suggest", body: body)
        endpoint.timeout = 20
        return try await send(endpoint)
    }

    func createSession(recipeVersionId: UUID, adaptations: [AdaptationInput]) async throws -> CookingSession {
        let body = try encoder.encode(CreateSessionRequest(recipeVersionId: recipeVersionId, adaptations: adaptations))
        return try await send(.post("/v1/sessions", body: body))
    }

    func activeSessions() async throws -> [SessionSummary] {
        let response: ItemsResponse<SessionSummary> = try await send(.get("/v1/sessions", query: [URLQueryItem(name: "status", value: "active")]))
        return response.items
    }

    func session(id: UUID) async throws -> CookingSession {
        try await send(.get("/v1/sessions/\(Self.pathId(id))"))
    }

    func deleteSession(id: UUID) async throws {
        _ = try await raw(.delete("/v1/sessions/\(Self.pathId(id))"))
    }

    func sendCommand(sessionId: UUID, _ command: SessionCommand, idempotencyKey: String) async throws -> CookingSession {
        var endpoint = Endpoint.post("/v1/sessions/\(Self.pathId(sessionId))/commands", body: try encoder.encode(command))
        endpoint.headers[Self.idempotencyHeader] = idempotencyKey
        return try await send(endpoint)
    }

    func ask(sessionId: UUID, query: String, groundedRevision: Int) async throws -> AskResponse {
        let body = try encoder.encode(AskRequest(query: query, groundedRevision: groundedRevision))
        var endpoint = Endpoint.post("/v1/sessions/\(Self.pathId(sessionId))/ask", body: body)
        endpoint.timeout = 20
        return try await send(endpoint)
    }

    func addNote(sessionId: UUID, text: String) async throws -> SessionNote {
        try await send(.post("/v1/sessions/\(Self.pathId(sessionId))/notes", body: try encoder.encode(NoteRequest(text: text))))
    }

    func myVariation(recipeVersionId: UUID) async throws -> PrivateVariation? {
        do {
            return try await send(.get("/v1/recipe-versions/\(Self.pathId(recipeVersionId))/my-variation")) as PrivateVariation
        } catch let error as APIError where error.isNotFound {
            return nil
        }
    }

    func deleteMyVariation(recipeVersionId: UUID) async throws {
        _ = try await raw(.delete("/v1/recipe-versions/\(Self.pathId(recipeVersionId))/my-variation"))
    }
}
