import Foundation
import Observation

/// App-wide cooking state: which session is open (resume banner + floating pill, COOK-07) and
/// whether the full-screen cooking view is presented. It never holds step state of its own; the
/// summary is whatever the server (or, offline, the last cached Session) said.
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

        var id: UUID { sessionId }
    }

    /// The newest open session (created / active / paused), if any.
    private(set) var active: SessionSummary?
    /// `active` came from the on-device cache because the server was unreachable.
    private(set) var activeIsFromCache = false
    private(set) var bannerDismissedFor: UUID?
    var presented: Presentation?

    private let service: CookingService
    let cache: SessionCaching

    init(service: CookingService, cache: SessionCaching) {
        self.service = service
        self.cache = cache
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

    /// On launch and on every return to the foreground.
    func refresh() async {
        do {
            let items = try await service.activeSessions()
            active = items.first { $0.status.isOpen }
            activeIsFromCache = false
            // The cached copy belongs to a session that is no longer the open one.
            if let cached = cache.load(), cached.id != active?.id { try? cache.clear() }
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            // Offline: show the cached session so the user can see where they were (read-only).
            if let cached = cache.load(), cached.status.isOpen {
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
        guard let active else { return }
        let cached = cache.load()
        presented = Presentation(sessionId: active.id, initial: cached?.id == active.id ? cached : nil, startOnOpen: false)
    }

    /// Right after `POST /sessions` from an explicit **Start cooking** tap.
    func present(newSession session: CookingSession) {
        sessionChanged(session)
        presented = Presentation(sessionId: session.id, initial: session, startOnOpen: true)
    }

    /// Every canonical Session the cooking screen receives lands here.
    func sessionChanged(_ session: CookingSession) {
        if session.status.isOpen {
            active = session.summary()
            activeIsFromCache = false
            try? cache.save(session)
        } else {
            if active?.id == session.id { active = nil }
            try? cache.clear()
        }
    }

    func closeCookingScreen() {
        presented = nil
    }

    /// Sign-out / server change: session data is private to the account.
    func reset() {
        active = nil
        activeIsFromCache = false
        presented = nil
        bannerDismissedFor = nil
        try? cache.clear()
    }
}
