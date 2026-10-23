import Foundation
import Observation

/// Something the store can invalidate on sign-out (the open cooking screen's view model).
@MainActor
protocol CookingSessionClient: AnyObject {
    /// Drop every in-flight result; nothing more may be adopted, cached or reported.
    func invalidate()
}

/// App-wide cooking state: which session is open (resume banner + floating pill, COOK-07) and
/// whether the full-screen cooking view is presented. It never holds step state of its own; the
/// summary is whatever the server (or, offline, the last cached Session) said.
///
/// Account isolation: the cache is stamped with the owner (user id + server) and only read back
/// for that owner. `reset()` (every sign-out path, server change, a different user signing in)
/// bumps `epoch`; any result that was awaited under an older epoch is dropped, so a late response
/// can never write the previous account's session into `active` or the cache.
@MainActor
@Observable
final class CookingSessionStore {
    /// What the cooking screen opens with.
    struct Presentation: Identifiable, Equatable {
        let sessionId: UUID
        /// A Session already in hand (just created, or cached) so the screen paints immediately.
        let initial: CookingSession?
        /// True only right after the user tapped **Start cooking**: a `created` session is then
        /// started (that tap is the confirmation). A resumed `created` session waits for a tap.
        let startOnOpen: Bool
        /// Swap cautions (allergy warning, risks, safety notice) by ingredient ref, from the sheet.
        var swapCautions: [String: SwapCaution] = [:]

        var id: UUID { sessionId }
    }

    /// The newest open session (created / active / paused), if any.
    private(set) var active: SessionSummary?
    /// `active` came from the on-device cache because the server was unreachable.
    private(set) var activeIsFromCache = false
    private(set) var bannerDismissedFor: UUID?
    var presented: Presentation?
    /// Bumped by `reset()`. Results captured under an older value are discarded.
    private(set) var epoch = 0

    private let service: CookingService
    private let cache: SessionCaching
    /// The signed-in user on the current server; nil when signed out.
    private let owner: @MainActor () -> SessionOwner?
    private weak var client: CookingSessionClient?
    /// Cautions per session for this app run (the Session doesn't repeat them).
    private var cautionsBySession: [UUID: [String: SwapCaution]] = [:]

    init(service: CookingService, cache: SessionCaching, owner: @escaping @MainActor () -> SessionOwner?) {
        self.service = service
        self.cache = cache
        self.owner = owner
    }

    /// "Continue cooking <title> — step N" after launch / foreground, until dismissed or opened.
    var showsBanner: Bool {
        guard let active, presented == nil else { return false }
        return bannerDismissedFor != active.id
    }

    /// Floating current-session entry while browsing (PRD §6: only when cooking).
    var showsPill: Bool { active != nil && presented == nil && !showsBanner }

    var resumeTitle: String? {
        guard let active else { return nil }
        return "Continue cooking \(active.title)"
    }

    /// 1-based, from the server's `step_index`.
    var resumeStepText: String? {
        guard let active else { return nil }
        if active.status == .created { return "Not started" }
        let step = min(max(active.stepIndex, 0), max(active.stepsCount - 1, 0)) + 1
        return active.status == .paused ? "Paused · step \(step)" : "Step \(step)"
    }

    /// The cached Session for the signed-in owner only (someone else's is deleted on read).
    func cachedSession() -> CookingSession? {
        guard let owner = owner() else { return nil }
        return cache.load(for: owner)
    }

    /// On launch and on every return to the foreground.
    func refresh() async {
        guard owner() != nil else { return }
        let started = epoch
        do {
            let items = try await service.activeSessions()
            guard started == epoch else { return }
            active = items.first { $0.status.isOpen }
            activeIsFromCache = false
            // The cached copy belongs to a session that is no longer the open one.
            if let cached = cachedSession(), cached.id != active?.id { try? cache.clear() }
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            guard started == epoch else { return }
            // Offline: show this account's cached session so the user sees where they were (read-only).
            if let cached = cachedSession(), cached.status.isOpen {
                active = cached.summary()
                activeIsFromCache = true
            }
        }
    }

    func dismissBanner() {
        bannerDismissedFor = active?.id
    }

    /// Banner / pill tap: reopen at whatever step the server reports.
    func resume() {
        guard let active, owner() != nil else { return }
        let cached = cachedSession()
        presented = Presentation(sessionId: active.id, initial: cached?.id == active.id ? cached : nil, startOnOpen: false,
                                 swapCautions: cautionsBySession[active.id] ?? [:])
    }

    /// "You have unfinished cooks" → Resume: open that session at the server's step.
    func resume(sessionId: UUID) {
        guard owner() != nil else { return }
        let cached = cachedSession()
        presented = Presentation(sessionId: sessionId, initial: cached?.id == sessionId ? cached : nil, startOnOpen: false,
                                 swapCautions: cautionsBySession[sessionId] ?? [:])
    }

    /// Right after `POST /sessions` from an explicit **Start cooking** tap. `epoch` is the value
    /// captured before that request was sent.
    func present(newSession session: CookingSession, epoch started: Int, cautions: [String: SwapCaution] = [:]) {
        guard started == epoch, owner() != nil else { return }
        sessionChanged(session, epoch: started)
        let kept = cautions.filter { !$0.value.isEmpty }
        if !kept.isEmpty { cautionsBySession[session.id] = kept }
        presented = Presentation(sessionId: session.id, initial: session, startOnOpen: true, swapCautions: kept)
    }

    /// Every canonical Session the cooking screen receives lands here, stamped with the epoch the
    /// screen was opened under. After a reset this is a no-op.
    func sessionChanged(_ session: CookingSession, epoch started: Int) {
        guard started == epoch, let owner = owner() else { return }
        if session.status.isOpen {
            active = session.summary()
            activeIsFromCache = false
            try? cache.save(session, owner: owner)
        } else {
            if active?.id == session.id { active = nil }
            try? cache.clear()
        }
    }

    /// The cooking screen registers its view model so a reset can invalidate it.
    func attach(_ client: CookingSessionClient) {
        self.client = client
    }

    func closeCookingScreen() {
        presented = nil
    }

    /// Sign-out (any path) / server change / a different user signing in.
    func reset() {
        epoch += 1
        client?.invalidate()
        client = nil
        active = nil
        activeIsFromCache = false
        presented = nil
        bannerDismissedFor = nil
        cautionsBySession = [:]
        try? cache.clear()
    }
}
