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

/// `POST /sessions` from a **Start cooking** tap, including the "too many unfinished cooks" path
/// (409 with `open_session_ids`): the user resumes one, or stops one (a confirmed `abandon` with
/// its own key) and the start is retried after each stop. Another 409 refreshes the list.
///
/// Presentation happens after the sheet has gone: the view reads `takeOutcome()` in the sheet's
/// `onDismiss`, together with the cooking-store epoch captured when Start cooking was tapped.
@MainActor
@Observable
final class SessionStarter {
    enum Outcome: Equatable {
        case started(CookingSession)
        case resume(UUID)
    }

    private(set) var isStarting = false
    private(set) var errorMessage: String?
    /// Open sessions blocking a new one. Non-empty → the sheet is shown.
    private(set) var unfinished: [SessionSummary] = []
    private(set) var busySessionIds: Set<UUID> = []
    /// A cook that changed since the user saw it; its row was refreshed and needs a new confirm.
    private(set) var changedSessionId: UUID?
    /// `CookingSessionStore.epoch` when Start cooking was tapped.
    private(set) var initiatedEpoch: Int?
    /// What to do once the sheet is dismissed.
    private var outcome: Outcome?

    private var pendingStart: (recipeVersionId: UUID, adaptations: [AdaptationInput])?
    private let service: CookingService
    private let makeKey: @MainActor () -> String

    static let rateLimitedMessage = "You’ve started a lot of cooks this hour. Try again in a little while."
    static let changedMessage = "That cook changed since you looked. Check it and confirm again."

    init(service: CookingService, makeKey: @escaping @MainActor () -> String = { UUID().uuidString.lowercased() }) {
        self.service = service
        self.makeKey = makeKey
    }

    /// Retrying the start from inside the sheet (keeps it open until the answer is in).
    private(set) var isRetrying = false

    var showsUnfinished: Bool { !unfinished.isEmpty || isRetrying }

    /// Returns the created Session (status `created`), or nil with `errorMessage` / `unfinished` set.
    func start(recipeVersionId: UUID, adaptations: [AdaptationInput], epoch: Int? = nil) async -> CookingSession? {
        guard !isStarting else { return nil }
        if let epoch { initiatedEpoch = epoch }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            let session = try await service.createSession(recipeVersionId: recipeVersionId, adaptations: adaptations)
            pendingStart = nil
            if isRetrying || !unfinished.isEmpty {
                // Started from inside the sheet: present once it has gone.
                outcome = .started(session)
                unfinished = []
            }
            return session
        } catch let error as APIError where error == .cancelled {
            return nil
        } catch let error as APIError {
            if let ids = error.openSessionIds {
                pendingStart = (recipeVersionId, adaptations)
                await loadUnfinished(ids: ids)
                if unfinished.isEmpty {
                    errorMessage = "You have too many unfinished cooks. Finish or stop one, then try again."
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

    /// "Stop this cook" on one row (after the view's confirmation). The start is retried after
    /// every successful stop; if the server still says no, the refreshed list stays on screen.
    func abandon(_ summary: SessionSummary) async {
        guard !busySessionIds.contains(summary.id) else { return }
        busySessionIds.insert(summary.id)
        errorMessage = nil
        defer { busySessionIds.remove(summary.id) }
        do {
            // The summary has no revision: read the canonical Session first.
            let latest = try await service.session(id: summary.id)
            if latest.status.isOpen {
                // Changed since the user saw it (another device cooked on): show it, ask again.
                if latest.stepIndex != summary.stepIndex || latest.updatedAt != summary.updatedAt || latest.status != summary.status {
                    replace(summary.id, with: latest.summary())
                    changedSessionId = summary.id
                    errorMessage = Self.changedMessage
                    return
                }
                try await sendAbandon(sessionId: summary.id, revision: latest.revision)
            }
            if changedSessionId == summary.id { changedSessionId = nil }
            unfinished.removeAll { $0.id == summary.id }
        } catch let error as APIError {
            errorMessage = "Couldn’t stop that cook: \(error.userMessage)"
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard let pending = pendingStart else { return }
        isRetrying = true
        defer { isRetrying = false }
        _ = await start(recipeVersionId: pending.recipeVersionId, adaptations: pending.adaptations)
    }

    private func replace(_ id: UUID, with summary: SessionSummary) {
        if let index = unfinished.firstIndex(where: { $0.id == id }) { unfinished[index] = summary }
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

    /// "Resume" on a row: close the sheet, then open that cook (from `onDismiss`).
    func chooseResume(_ sessionId: UUID) {
        outcome = .resume(sessionId)
        pendingStart = nil
        unfinished = []
    }

    /// Cancel / swipe-down: the new start is dropped.
    func dismissUnfinished() {
        unfinished = []
        pendingStart = nil
        changedSessionId = nil
    }

    /// Read once by the sheet's `onDismiss`.
    func takeOutcome() -> Outcome? {
        defer { outcome = nil }
        return outcome
    }
}
