import Foundation
import Observation

/// Cooking screen state (PRD §6, J4, COOK-01..08).
///
/// Invariants (CLAUDE.md "Step Oracle owns session state"):
/// - `session` is only ever replaced by a Session the server returned (200, or `details.session`
///   on a 409). Nothing here computes a new `step_index`, status or timer list.
/// - Every change is a command with `user_confirmed: true`, the session's current `revision` as
///   `expected_revision`, and one `Idempotency-Key` per tap (`SessionCommandSender`).
/// - Offline, the cached copy is shown read-only; commands are disabled until the server answers.
/// - The step is read aloud only after an explicit start / next / back / repeat / slower.
@MainActor
@Observable
final class CookingViewModel: CookingSessionClient {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
        /// 404 on the first read: the cook was deleted / ended elsewhere and isn't ours to show.
        case gone(String)
    }

    let sessionId: UUID
    private(set) var phase: Phase = .loading
    /// The canonical Session (server's, or the cached copy while `isOffline`).
    private(set) var session: CookingSession?
    /// Showing a cached copy, or the last command could not reach the server. Read-only.
    private(set) var isOffline = false
    private(set) var isSending = false
    /// Transient notice ("Updated from your other device").
    private(set) var toast: String?
    /// Inline error under the controls.
    private(set) var errorMessage: String?
    /// "Show original" for the current step's adapted text. Resets when the step changes.
    var showOriginal = false
    /// Steps whose suggested timer the user skipped (UI only; a skipped suggestion is not state).
    private(set) var skippedTimerSteps: Set<Int> = []
    var readAloudEnabled = true
    /// Session-end draft lives here so a failed (offline) Done never loses it.
    var endDraft = SessionEndDraft()
    /// The note text the server already has, so a retried Done never posts it twice.
    private(set) var savedNoteText: String?
    /// One `Idempotency-Key` per note text, reused when the same text is retried.
    private var noteKey: (text: String, key: String)?
    private let makeKey: @MainActor () -> String
    /// Swap cautions (allergy warning, risks, safety notice) by `ingredient_ref`, carried from the
    /// swap sheet; the Session itself doesn't repeat them.
    let swapCautions: [String: SwapCaution]
    /// A cached / resumed copy not yet confirmed by a server read: shown, never acted on.
    private(set) var isProvisional = false
    /// The pending tap is older than `staleTapInterval`: ask before re-sending it.
    private(set) var asksToResendStaleTap = false
    /// False once the cooking screen is gone: nothing more is spoken.
    private(set) var isScreenVisible = true

    /// Every canonical Session (for the resume store and the on-device cache).
    var onSessionChanged: (@MainActor (CookingSession) -> Void)?
    /// 404: the store drops it from `active` and the cache.
    var onSessionGone: (@MainActor (UUID) -> Void)?

    static let goneMessage = "This cook is no longer available."
    static let timerAlreadyDoneToast = "That timer has already finished."

    private let initial: CookingSession?
    private let initialIsFresh: Bool
    private let startOnOpen: Bool
    private let service: CookingService
    private let audio: any AudioOutput
    /// The signed-in owner's cached copy (offline, read-only). Never another account's.
    private let loadCached: @MainActor () -> CookingSession?
    /// Set on sign-out / server change: every later result is dropped.
    private(set) var isInvalidated = false
    let sender: SessionCommandSender
    private let now: @MainActor () -> Date
    /// Timer ids already reported as done (nil until the first look, so timers that were already
    /// done when the screen opened are not announced).
    private var announcedDoneTimers: Set<UUID>?

    static let conflictToast = "Updated from your other device"
    static let invalidTransitionToast = "That step change wasn’t possible. Showing where you are."
    static let offlineMessage = "Reconnect to continue. Your step hasn’t changed."
    static let staleTapInterval: TimeInterval = 120

    init(sessionId: UUID,
         initial: CookingSession? = nil,
         initialIsFresh: Bool? = nil,
         startOnOpen: Bool = false,
         service: CookingService,
         audio: any AudioOutput,
         loadCached: @escaping @MainActor () -> CookingSession? = { nil },
         swapCautions: [String: SwapCaution] = [:],
         makeKey: @escaping @MainActor () -> String = { UUID().uuidString.lowercased() },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.sessionId = sessionId
        self.initial = initial
        // A Session handed over right after POST /sessions is the server's answer; a resumed one
        // comes from the cache.
        self.initialIsFresh = initialIsFresh ?? startOnOpen
        self.startOnOpen = startOnOpen
        self.service = service
        self.audio = audio
        self.loadCached = loadCached
        self.swapCautions = swapCautions
        self.makeKey = makeKey
        self.now = now
        sender = SessionCommandSender(sessionId: sessionId, service: service, makeKey: makeKey, now: now)
    }

    // MARK: - Derived

    var currentStep: SessionStep? { session?.currentStep }
    var currentRecipeStep: RecipeStep? { session?.currentRecipeStep }

    /// "Step 3 of 7" (1-based, from the server's index).
    var stepCounterText: String? {
        guard let session, session.stepsCount > 0 else { return nil }
        return "Step \(min(session.stepIndex, session.stepsCount - 1) + 1) of \(session.stepsCount)"
    }

    var instructionText: String? {
        guard let step = currentStep else { return nil }
        return showOriginal ? step.originalInstruction : step.instruction
    }

    /// The approved swaps that changed the current step (badge "Adapted · Common swap").
    var currentAdaptations: [SessionAdaptation] {
        guard let session, let step = currentStep, step.adapted else { return [] }
        let ids = Set(step.adaptationIds)
        let matched = session.adaptations.filter { ids.contains($0.id) }
        return matched.isEmpty ? [] : matched
    }

    /// "Adapted · Common swap" / "Adapted · AI suggested adaptation" (AI wins when mixed), plus
    /// "· Check the label: …" when a swap on this step carried an allergy warning.
    var adaptedBadgeText: String? {
        guard let step = currentStep, step.adapted else { return nil }
        let sources = Set(currentAdaptations.map(\.source))
        let label = sources.isEmpty || sources.contains(.ai) ? SwapSource.ai.label : SwapSource.rule.label
        if let warning = currentCautions.compactMap(\.allergyWarning).first {
            return "Adapted · \(label) · Check the label: \(warning)"
        }
        return "Adapted · \(label)"
    }

    /// The Session's own cautions (survive relaunch, other devices), plus the sheet's notice
    /// from this run as an addition.
    private var currentCautions: [SwapCaution] {
        currentAdaptations.map { adaptation in
            let sheet = swapCautions[adaptation.ingredientRef]
            var risks = adaptation.risks
            for risk in sheet?.risks ?? [] where !risks.contains(risk) { risks.append(risk) }
            return SwapCaution(allergyWarning: adaptation.allergyWarning ?? sheet?.allergyWarning,
                               risks: risks, safetyNotice: sheet?.safetyNotice)
        }.filter { !$0.isEmpty }
    }

    /// Swaps on this step that now overlap the user's allergies (an allergy added mid-cook).
    var conflictingAdaptations: [SessionAdaptation] {
        currentAdaptations.filter(\.conflictsWithAllergies)
    }

    /// Risks and safety notices of the swaps on this step, shown under the badge.
    var adaptedCautionLines: [String] {
        var seen = Set<String>()
        return currentCautions.flatMap { $0.risks + [$0.safetyNotice].compactMap { $0 } }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var status: SessionStatus? { session?.status }
    var isPaused: Bool { session?.status == .paused }
    var isNotStarted: Bool { session?.status == .created }
    var isEnded: Bool { session.map { !$0.status.isOpen } ?? false }

    /// Commands need a live server copy, an open session and nothing in flight.
    var canSendCommands: Bool {
        guard let session, !isOffline, !isSending, !isInvalidated, !isProvisional else { return false }
        return session.status.isOpen
    }

    var canGoBack: Bool { canSendCommands && session?.status == .active && (session?.stepIndex ?? 0) > 0 }
    var canGoNext: Bool { canSendCommands && session?.status == .active }
    /// Next on the last step becomes **Finish** (opens Session end; `complete` is sent from there).
    var isLastStep: Bool { session?.isLastStep ?? false }
    var nextTitle: String { isLastStep ? "Finish" : "Next" }

    /// "Start a 10-min simmer timer?" — offered, never started on its own (DECISIONS #14).
    var timerSuggestion: SuggestedTimer? {
        guard let session, session.status == .active, let step = currentStep, let suggested = step.suggestedTimer,
              !skippedTimerSteps.contains(session.stepIndex)
        else { return nil }
        let alreadyStarted = session.timers.contains {
            $0.status != .cancelled && $0.stepIndex == session.stepIndex && $0.label.caseInsensitiveCompare(suggested.label) == .orderedSame
        }
        return alreadyStarted ? nil : suggested
    }

    func timerRows(at date: Date? = nil) -> [TimerRow] {
        TimerRow.rows(for: session?.timers ?? [], now: date ?? now())
    }

    /// Timers that turned done since the last look (haptic + VoiceOver announcement). Timers that
    /// were already done when the first Session arrived are the baseline and never announced.
    func newlyFinishedTimers(at date: Date? = nil) -> [TimerRow] {
        let done = timerRows(at: date).filter(\.isDone)
        let announced = announcedDoneTimers ?? []
        let fresh = done.filter { !announced.contains($0.id) }
        announcedDoneTimers = announced.union(fresh.map(\.id))
        return fresh
    }

    /// "Your last tap (Next) wasn’t confirmed" on the offline banner.
    var pendingTapText: String? {
        guard let pending = sender.pending else { return nil }
        return "Your last tap (\(pending.command.command.displayName)) wasn’t confirmed"
    }

    /// A Done (`complete`) whose outcome is unknown. Its body is fixed, so Session end is locked
    /// until it is confirmed (Reconnect / Send it again) or discarded.
    var isCompletePending: Bool { sender.pending?.command.command == .complete }

    var pendingTapIsStale: Bool {
        guard let pending = sender.pending else { return false }
        return now().timeIntervalSince(pending.createdAt) > Self.staleTapInterval
    }

    // MARK: - Loading

    func load() async {
        if let initial, session == nil {
            adopt(initial, persist: initialIsFresh)
            isProvisional = !initialIsFresh
        }
        await refresh()
        if startOnOpen, session?.status == .created, !isOffline, !isInvalidated {
            await start()
        }
    }

    /// Re-read the canonical Session (also the "Reconnect" button when nothing is pending).
    func refresh() async {
        // A command in flight will answer with a newer Session anyway.
        guard !isInvalidated, !isSending else { return }
        do {
            let latest = try await service.session(id: sessionId)
            guard !isInvalidated else { return }
            isOffline = false
            isProvisional = false
            errorMessage = nil
            adopt(latest)
            // The server moved past the unconfirmed tap: its body is stale either way.
            if let pending = sender.pending, (session?.revision ?? 0) > pending.command.expectedRevision {
                sender.discardPending()
                asksToResendStaleTap = false
            }
            phase = .ready
        } catch let error as APIError where error == .cancelled {
            return
        } catch let error as APIError where error.isTransportFailure {
            guard !isInvalidated else { return }
            if session == nil, let cached = loadCached(), cached.id == sessionId {
                adopt(cached, persist: false)
                isProvisional = true
            }
            isOffline = true
            if session != nil {
                phase = .ready
                errorMessage = Self.offlineMessage
            } else {
                phase = .failed(error.userMessage)
            }
        } catch {
            guard !isInvalidated else { return }
            let apiError = error as? APIError
            if apiError?.isNotFound == true {
                // Deleted or not ours: never keep showing a cached copy of it.
                session = nil
                isProvisional = false
                phase = .gone(Self.goneMessage)
                onSessionGone?(sessionId)
                return
            }
            let message = apiError?.userMessage ?? error.localizedDescription
            if session == nil || isProvisional {
                // A cached copy that the server wouldn't confirm: don't sit read-only forever.
                phase = .failed(message)
            } else {
                errorMessage = message
            }
        }
    }

    /// Sign-out / server change while this screen is alive: stop speaking, drop all later results.
    func invalidate() {
        isInvalidated = true
        audio.stop()
        sender.discardPending()
    }

    func screenDidAppear() { isScreenVisible = true }

    /// The cooking screen closed: stop speaking and never start again from this model.
    func screenDidDisappear() {
        isScreenVisible = false
        audio.stop()
    }

    /// "Reconnect": re-send the pending tap with its original key, or re-read the Session.
    /// A tap older than two minutes is not re-sent without asking (`resendStaleTap`).
    func reconnect() async {
        guard !isSending, !isInvalidated else { return }
        if sender.pending != nil, pendingTapIsStale {
            asksToResendStaleTap = true
            return
        }
        await resendPendingOrRefresh()
    }

    /// "Send it again" on the stale-tap question.
    func resendStaleTap() async {
        asksToResendStaleTap = false
        await resendPendingOrRefresh()
    }

    /// "Discard" on the stale-tap question: forget the tap, re-read the Session.
    func discardStaleTap() async {
        asksToResendStaleTap = false
        sender.discardPending()
        await refresh()
    }

    private func resendPendingOrRefresh() async {
        guard !isSending, !isInvalidated else { return }
        if sender.pending != nil {
            isSending = true
            defer { isSending = false }
            do {
                if let latest = try await sender.retryPending() {
                    guard !isInvalidated else { return }
                    isOffline = false
                    isProvisional = false
                    errorMessage = nil
                    adopt(latest)
                    return
                }
            } catch let error as APIError {
                if !isInvalidated { handle(error) }
                return
            } catch {
                if !isInvalidated { errorMessage = error.localizedDescription }
                return
            }
        }
        await refresh()
    }

    // MARK: - Commands (each is one user tap)

    func start() async {
        guard session?.status == .created else { return }
        if await run(.confirmed(.start, revision: revisionOrZero)) { await speakCurrentStep() }
    }

    func next() async {
        guard canGoNext, !isLastStep else { return }
        if await run(.confirmed(.next, revision: revisionOrZero)) { await speakCurrentStep() }
    }

    func back() async {
        guard canGoBack else { return }
        if await run(.confirmed(.back, revision: revisionOrZero)) { await speakCurrentStep() }
    }

    func pause() async {
        guard session?.status == .active else { return }
        audio.stop()
        _ = await run(.confirmed(.pause, revision: revisionOrZero))
    }

    func resume() async {
        guard session?.status == .paused else { return }
        _ = await run(.confirmed(.resume, revision: revisionOrZero))
    }

    func startSuggestedTimer() async {
        guard let suggestion = timerSuggestion else { return }
        var command = SessionCommand.confirmed(.startTimer, revision: revisionOrZero)
        command.timer = TimerRequest(label: suggestion.label, durationSeconds: suggestion.durationSeconds)
        _ = await run(command)
    }

    func skipSuggestedTimer() {
        guard let index = session?.stepIndex else { return }
        skippedTimerSteps.insert(index)
    }

    func cancelTimer(id: UUID) async {
        if timerRows().first(where: { $0.id == id })?.isDone == true {
            toast = Self.timerAlreadyDoneToast
            return
        }
        var command = SessionCommand.confirmed(.cancelTimer, revision: revisionOrZero)
        command.timerId = id
        _ = await run(command)
    }

    /// Undo a swap mid-cook (SUB-03): the server restores the original step text.
    func revertAdaptation(id: UUID) async {
        var command = SessionCommand.confirmed(.revertAdaptation, revision: revisionOrZero)
        command.adaptationId = id
        _ = await run(command)
    }

    /// Session end **Done**: private note (if any, and not already saved), then `complete`.
    /// The whole thing counts as one in-flight command, so a second tap can't double-post.
    @discardableResult
    func complete(result: OutcomeResult, saveChanges: Bool, note: String) async -> Bool {
        guard canSendCommands else { return false }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SessionEndViewModel.maxNoteLength))
        if !text.isEmpty, text != savedNoteText {
            if noteKey?.text != text { noteKey = (text, makeKey()) }
            do {
                _ = try await service.addNote(sessionId: sessionId, text: text, idempotencyKey: noteKey?.key ?? makeKey())
                guard !isInvalidated else { return false }
                savedNoteText = text
            } catch let error as APIError {
                guard !isInvalidated else { return false }
                if error.isTransportFailure {
                    isOffline = true
                    errorMessage = "Couldn’t save your note — reconnect and tap Done again. Nothing is lost."
                } else {
                    errorMessage = "Couldn’t save your note: \(error.userMessage)"
                }
                return false
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        var command = SessionCommand.confirmed(.complete, revision: revisionOrZero)
        let adaptations = session?.adaptations ?? []
        let saveable = !adaptations.isEmpty && !adaptations.contains(where: \.conflictsWithAllergies)
        command.outcome = OutcomeInput(result: result, saveChanges: saveChanges && saveable)
        audio.stop()
        return await execute(command)
    }

    /// Cooking menu → Stop cooking (after a confirmation dialog in the view).
    @discardableResult
    func abandon() async -> Bool {
        audio.stop()
        return await run(.confirmed(.abandon, revision: revisionOrZero))
    }

    /// A coach proposal the user just tapped ("Go to next step?"). The tap is the confirmation.
    /// Sent with `expected_revision` = the revision the answer was grounded on, so a proposal made
    /// for an older state is refused by the server instead of applied to a newer one.
    @discardableResult
    func perform(_ proposal: ProposedAction) async -> Bool {
        guard proposal.isSupported, canSendCommands, let session, session.status == .active else { return false }
        let grounded = proposal.groundedRevision ?? session.revision
        guard grounded == session.revision else { return false }
        var command = SessionCommand.confirmed(proposal.command, revision: grounded, source: .iosAssistant)
        switch proposal.command {
        case .jumpToStep: command.stepIndex = proposal.stepIndex
        case .startTimer: command.timer = proposal.timer
        case .next where isLastStep: return false
        default: break
        }
        let moved = proposal.command == .next || proposal.command == .back || proposal.command == .jumpToStep
        let ok = await run(command)
        if ok, moved { await speakCurrentStep() }
        return ok
    }

    // MARK: - Read aloud (explicit only)

    func repeatStep() async {
        await speakCurrentStep(pace: .normal, force: true)
    }

    func slower() async {
        await speakCurrentStep(pace: .slow, force: true)
    }

    func stopSpeaking() {
        audio.stop()
    }

    var spokenText: String? {
        guard let session, let step = currentStep else { return nil }
        return "Step \(session.stepIndex + 1). \(step.instruction)"
    }

    private func speakCurrentStep(pace: SpeechPace = .normal, force: Bool = false) async {
        guard !isInvalidated, isScreenVisible, force || readAloudEnabled, let text = spokenText, session?.status == .active else { return }
        await audio.speak(text, pace: pace)
    }

    func dismissToast() { toast = nil }

    // MARK: - Plumbing

    private var revisionOrZero: Int { session?.revision ?? 0 }

    /// Sends one command; adopts whatever Session the server answers with. Returns true on 200.
    private func run(_ command: SessionCommand) async -> Bool {
        guard session != nil, !isSending, !isOffline, !isInvalidated, !isProvisional else { return false }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        return await execute(command)
    }

    /// The request itself; the caller has already set `isSending`.
    private func execute(_ command: SessionCommand) async -> Bool {
        do {
            let latest = try await sender.send(command)
            guard !isInvalidated else { return false }
            adopt(latest)
            return true
        } catch let error as APIError {
            if !isInvalidated { handle(error) }
            return false
        } catch {
            if !isInvalidated { errorMessage = error.localizedDescription }
            return false
        }
    }

    private func handle(_ error: APIError) {
        if error.isStateConflict || error.isInvalidTransition {
            if let latest = error.latestSession, latest.id == sessionId {
                adopt(latest)
                toast = error.isStateConflict ? Self.conflictToast : Self.invalidTransitionToast
            } else {
                toast = error.isStateConflict ? Self.conflictToast : Self.invalidTransitionToast
                Task { await refresh() }
            }
            return
        }
        if SessionCommandSender.outcomeUnknown(error) {
            if error == .cancelled { return }
            isOffline = true
            errorMessage = Self.offlineMessage
            return
        }
        if error.isNotFound {
            errorMessage = "This cooking session is no longer available."
            return
        }
        errorMessage = error.userMessage
    }

    /// Adopts a server Session — unless it is an older revision of the one on screen (a slow read
    /// overtaken by a command). Equal revisions may re-adopt.
    private func adopt(_ latest: CookingSession, persist: Bool = true) {
        guard !isInvalidated, latest.id == sessionId else { return }
        if let current = session, current.id == latest.id, latest.revision < current.revision { return }
        let stepChanged = session?.stepIndex != latest.stepIndex
        session = latest
        if announcedDoneTimers == nil {
            // Baseline when the screen opens: timers already done then are never announced.
            announcedDoneTimers = Set(TimerRow.rows(for: latest.timers, now: now()).filter(\.isDone).map(\.id))
        }
        if stepChanged { showOriginal = false }
        if phase != .ready { phase = .ready }
        if persist { onSessionChanged?(latest) }
    }
}
