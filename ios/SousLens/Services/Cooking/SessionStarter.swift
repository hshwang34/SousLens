import Foundation
import Observation

extension APIError {
    /// `409 STATE_CONFLICT` on `POST /sessions`: the user already has the maximum number of open
    /// sessions; `details.open_session_ids` lists them.
    var openSessionIds: [UUID]? {
        guard case .server(let status, _, _, _, _, let details) = self, status == 409,
              let ids = details?["open_session_ids"]?.arrayValue
        else { return nil }
        return ids.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
    }
}

/// `POST /sessions` from a **Start cooking** tap, including the "You have unfinished cooks" path
/// (409 with `open_session_ids`): the user resumes one, or abandons some (each a confirmed
/// `abandon` command with its own key) and the start is retried with the same version and swaps.
@MainActor
@Observable
final class SessionStarter {
    private(set) var isStarting = false
    private(set) var errorMessage: String?
    /// Open sessions blocking a new one. Non-empty → the sheet is shown.
    private(set) var unfinished: [SessionSummary] = []
    private(set) var busySessionIds: Set<UUID> = []

    private var pendingStart: (recipeVersionId: UUID, adaptations: [AdaptationInput])?
    private let service: CookingService
    private let makeKey: @MainActor () -> String

    static let rateLimitedMessage = "You’ve started a lot of cooks this hour. Try again in a little while."

    init(service: CookingService, makeKey: @escaping @MainActor () -> String = { UUID().uuidString.lowercased() }) {
        self.service = service
        self.makeKey = makeKey
    }

    var showsUnfinished: Bool { !unfinished.isEmpty }

    /// Returns the created Session (status `created`), or nil with `errorMessage` / `unfinished` set.
    func start(recipeVersionId: UUID, adaptations: [AdaptationInput]) async -> CookingSession? {
        guard !isStarting else { return nil }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            let session = try await service.createSession(recipeVersionId: recipeVersionId, adaptations: adaptations)
            pendingStart = nil
            unfinished = []
            return session
        } catch let error as APIError where error == .cancelled {
            return nil
        } catch let error as APIError {
            if let ids = error.openSessionIds {
                pendingStart = (recipeVersionId, adaptations)
                await loadUnfinished(ids: ids)
                if unfinished.isEmpty {
                    errorMessage = "You have unfinished cooks. Finish or stop one, then try again."
                }
            } else if error.isRateLimited {
                errorMessage = Self.rateLimitedMessage
            } else {
                errorMessage = "Couldn’t start cooking: \(error.userMessage)"
            }
            return nil
        } catch {
            errorMessage = "Couldn’t start cooking: \(error.localizedDescription)"
            return nil
        }
    }

    private func loadUnfinished(ids: [UUID]) async {
        let wanted = Set(ids)
        let active = (try? await service.activeSessions()) ?? []
        let matched = active.filter { wanted.contains($0.id) }
        unfinished = matched.isEmpty ? active.filter(\.status.isOpen) : matched
    }

    /// "Abandon" on one unfinished cook (after the view's confirmation). When the last blocker is
    /// gone the original start is retried; its Session is returned.
    func abandon(_ summary: SessionSummary) async -> CookingSession? {
        guard !busySessionIds.contains(summary.id) else { return nil }
        busySessionIds.insert(summary.id)
        errorMessage = nil
        defer { busySessionIds.remove(summary.id) }
        do {
            // The summary has no revision: read the canonical Session first.
            let latest = try await service.session(id: summary.id)
            if latest.status.isOpen {
                try await sendAbandon(sessionId: summary.id, revision: latest.revision)
            }
            unfinished.removeAll { $0.id == summary.id }
        } catch let error as APIError {
            errorMessage = "Couldn’t stop that cook: \(error.userMessage)"
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        guard unfinished.isEmpty, let pending = pendingStart else { return nil }
        return await start(recipeVersionId: pending.recipeVersionId, adaptations: pending.adaptations)
    }

    /// One confirmed `abandon`; a stale revision is retried once against the server's latest.
    private func sendAbandon(sessionId: UUID, revision: Int) async throws {
        let sender = SessionCommandSender(sessionId: sessionId, service: service, makeKey: makeKey)
        do {
            _ = try await sender.send(.confirmed(.abandon, revision: revision))
        } catch let error as APIError where error.isStateConflict || error.isInvalidTransition {
            guard let latest = error.latestSession else { throw error }
            guard latest.status.isOpen else { return }   // already ended elsewhere
            _ = try await sender.send(.confirmed(.abandon, revision: latest.revision))
        }
    }

    /// "Resume" chosen, or the sheet dismissed: the new start is dropped.
    func dismissUnfinished() {
        unfinished = []
        pendingStart = nil
    }
}
