import Foundation

/// Sends Step Oracle commands (§11.1) with one `Idempotency-Key` per user action.
///
/// - `send` is a NEW action: it mints a fresh key.
/// - `retryPending` re-sends the SAME key and the SAME body (same `expected_revision`), so a
///   request that reached the server before the connection dropped is applied once, never twice.
/// - The pending action is kept only while the outcome is unknown (transport failure, 5xx,
///   cancellation). A definitive answer (200, 409, 422, 404, …) clears it.
@MainActor
final class SessionCommandSender {
    struct Action: Equatable, Sendable {
        let key: String
        let command: SessionCommand
        /// When the user tapped (a tap older than two minutes is not re-sent without asking).
        let createdAt: Date
    }

    let sessionId: UUID
    private let service: CookingService
    private let makeKey: @MainActor () -> String
    private let now: @MainActor () -> Date
    /// The action whose outcome is unknown; `retryPending` re-sends it unchanged.
    private(set) var pending: Action?

    init(sessionId: UUID, service: CookingService,
         makeKey: @escaping @MainActor () -> String = { UUID().uuidString.lowercased() },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.sessionId = sessionId
        self.service = service
        self.makeKey = makeKey
        self.now = now
    }

    /// A new user action → a new key.
    func send(_ command: SessionCommand) async throws -> CookingSession {
        let action = Action(key: makeKey(), command: command, createdAt: now())
        pending = action
        return try await perform(action)
    }

    /// Re-send the action that may or may not have landed. Nil when nothing is pending.
    func retryPending() async throws -> CookingSession? {
        guard let pending else { return nil }
        return try await perform(pending)
    }

    func discardPending() {
        pending = nil
    }

    private func perform(_ action: Action) async throws -> CookingSession {
        do {
            let session = try await service.sendCommand(sessionId: sessionId, action.command, idempotencyKey: action.key)
            if pending == action { pending = nil }
            return session
        } catch let error as APIError where Self.outcomeUnknown(error) {
            throw error
        } catch {
            if pending == action { pending = nil }
            throw error
        }
    }

    /// The server may have applied the command: keep the key for a retry.
    static func outcomeUnknown(_ error: APIError) -> Bool {
        if error.isTransportFailure || error == .cancelled { return true }
        if let status = error.status, status >= 500 { return true }
        return false
    }
}
