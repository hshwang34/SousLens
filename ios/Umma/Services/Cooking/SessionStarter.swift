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
/// its own key, after a confirmation) and the start is retried after each stop. Another 409
/// refreshes the list and marks the rows that changed.
///
/// - One operation at a time: a start or one abandon (`isBusy`); the sheet can't be dismissed
///   while busy.
/// - Every attempt carries the `generation` it began under. Cancel / Resume / dismiss bump it, so a
///   late result from an abandoned attempt is dropped and never becomes `outcome`.
/// - Presentation happens after the sheet has gone: the view reads `takeOutcome()` in `onDismiss`,
///   with the cooking-store epoch captured when Start cooking was tapped.
@MainActor
@Observable
final class SessionStarter {
    enum Outcome: Equatable {
        case started(CookingSession)
        case resume(UUID)
    }

    private(set) var isStarting = false
    /// The one session being stopped right now (abandons are serialized).
    private(set) var abandoningId: UUID?
    private(set) var errorMessage: String?
    /// Open sessions blocking a new one. Non-empty → the sheet is shown.
    private(set) var unfinished: [SessionSummary] = []
    /// Rows that changed since the user last saw them; each needs a fresh confirmation.
    private(set) var changedSessionIds: Set<UUID> = []
    /// `CookingSessionStore.epoch` when Start cooking was tapped.
    private(set) var initiatedEpoch: Int?
    /// Bumped by Cancel / Resume / dismiss: results from older attempts are dropped.
    private(set) var generation = 0
    /// Retries of the start in flight from inside the sheet (keeps it open until answered).
    private var retriesInFlight = 0
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

    var showsUnfinished: Bool { !unfinished.isEmpty || retriesInFlight > 0 }
    /// A start or an abandon is in flight: no Cancel, no swipe-down, no second abandon.
    var isBusy: Bool { isStarting || abandoningId != nil || retriesInFlight > 0 }

    /// Returns the created Session (status `created`), or nil with `errorMessage` / `unfinished` set.
    func start(recipeVersionId: UUID, adaptations: [AdaptationInput], epoch: Int? = nil) async -> CookingSession? {
        guard !isStarting else { return nil }
        if let epoch { initiatedEpoch = epoch }
        let token = generation
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            let session = try await service.createSession(recipeVersionId: recipeVersionId, adaptations: adaptations)
            guard token == generation else { return nil }
            pendingStart = nil
            if retriesInFlight > 0 || !unfinished.isEmpty {
                // Started from inside the sheet: present once it has gone.
                outcome = .started(session)
                unfinished = []
                changedSessionIds = []
            }
            return session
        } catch let error as APIError where error == .cancelled {
            return nil
        } catch let error as APIError {
            guard token == generation else { return nil }
            if let ids = error.openSessionIds {
                pendingStart = (recipeVersionId, adaptations)
                await loadUnfinished(ids: ids, token: token)
                if token == generation, unfinished.isEmpty {
                    errorMessage = "You have too many unfinished cooks. Finish or stop one, then try again."
                }
            } else if error.isRateLimited {
                errorMessage = Self.rateLimitedMessage
            } else {
                errorMessage = "Couldn’t start cooking: \(error.userMessage)"
            }
            return nil
        } catch {
            guard token == generation else { return nil }
            errorMessage = "Couldn’t start cooking: \(error.localizedDescription)"
            return nil
        }
    }

    /// Reads the open sessions and marks rows that differ from what was on screen.
    private func loadUnfinished(ids: [UUID], token: Int) async {
        let wanted = Set(ids)
        let active = (try? await service.activeSessions()) ?? []
        guard token == generation else { return }
        let matched = active.filter { wanted.contains($0.id) }
        let fresh = matched.isEmpty ? active.filter(\.status.isOpen) : matched
        let previous = Dictionary(unfinished.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in fresh {
            if let old = previous[row.id], Self.differs(old, row) { changedSessionIds.insert(row.id) }
        }
        changedSessionIds.formIntersection(Set(fresh.map(\.id)))
        unfinished = fresh
    }

    static func differs(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
        a.stepIndex != b.stepIndex || a.status != b.status || a.updatedAt != b.updatedAt
    }

    /// "Stop this cook" on one row (after the view's confirmation). If the cook changed since it
    /// was shown — on the first read or on a stale-revision answer — the row is refreshed and the
    /// user must confirm again; nothing is stopped silently.
    func abandon(_ summary: SessionSummary) async {
        guard !isBusy else { return }
        let token = generation
        abandoningId = summary.id
        errorMessage = nil
        defer { abandoningId = nil }
        do {
            // The summary has no revision: read the canonical Session first.
            let latest = try await service.session(id: summary.id)
            guard token == generation else { return }
            if latest.status.isOpen {
                if Self.differs(summary, latest.summary()) {
                    markChanged(latest)
                    return
                }
                switch try await sendAbandon(sessionId: summary.id, revision: latest.revision) {
                case .stopped, .alreadyEnded:
                    break
                case .changed(let newer):
                    guard token == generation else { return }
                    markChanged(newer)
                    return
                }
            }
            guard token == generation else { return }
            changedSessionIds.remove(summary.id)
            unfinished.removeAll { $0.id == summary.id }
        } catch let error as APIError {
            guard token == generation else { return }
            errorMessage = "Couldn’t stop that cook: \(error.userMessage)"
            return
        } catch {
            guard token == generation else { return }
            errorMessage = error.localizedDescription
            return
        }
        guard let pending = pendingStart else { return }
        retriesInFlight += 1
        defer { retriesInFlight -= 1 }
        _ = await start(recipeVersionId: pending.recipeVersionId, adaptations: pending.adaptations)
    }

    private func markChanged(_ latest: CookingSession) {
        if let index = unfinished.firstIndex(where: { $0.id == latest.id }) { unfinished[index] = latest.summary() }
        changedSessionIds.insert(latest.id)
        errorMessage = Self.changedMessage
    }

    private enum AbandonResult {
        case stopped
        case alreadyEnded
        /// 409 with a newer open Session: show it and ask again.
        case changed(CookingSession)
    }

    /// One confirmed `abandon`. A stale revision is not retried behind the user's back.
    private func sendAbandon(sessionId: UUID, revision: Int) async throws -> AbandonResult {
        let sender = SessionCommandSender(sessionId: sessionId, service: service, makeKey: makeKey)
        do {
            _ = try await sender.send(.confirmed(.abandon, revision: revision))
            return .stopped
        } catch let error as APIError where error.isStateConflict || error.isInvalidTransition {
            guard let latest = error.latestSession else { throw error }
            return latest.status.isOpen ? .changed(latest) : .alreadyEnded
        }
    }

    /// "Resume" on a row: close the sheet, then open that cook (from `onDismiss`).
    func chooseResume(_ sessionId: UUID) {
        guard !isBusy else { return }
        generation += 1
        outcome = .resume(sessionId)
        pendingStart = nil
        unfinished = []
        changedSessionIds = []
    }

    /// Cancel / swipe-down (only when not busy): the new start is dropped.
    func dismissUnfinished() {
        generation += 1
        unfinished = []
        pendingStart = nil
        changedSessionIds = []
    }

    /// Read once by the sheet's `onDismiss`.
    func takeOutcome() -> Outcome? {
        defer { outcome = nil }
        return outcome
    }
}
