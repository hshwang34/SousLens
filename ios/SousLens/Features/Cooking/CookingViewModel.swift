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
final class CookingViewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
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

    /// Every canonical Session (for the resume store and the on-device cache).
    var onSessionChanged: (@MainActor (CookingSession) -> Void)?

    private let initial: CookingSession?
    private let startOnOpen: Bool
    private let service: CookingService
    private let audio: any AudioOutput
    private let cache: SessionCaching
    let sender: SessionCommandSender
    private let now: @MainActor () -> Date

    static let conflictToast = "Updated from your other device"
    static let invalidTransitionToast = "That step change wasn’t possible. Showing where you are."
    static let offlineMessage = "Reconnect to continue. Your step hasn’t changed."

    init(sessionId: UUID,
         initial: CookingSession? = nil,
         startOnOpen: Bool = false,
         service: CookingService,
         audio: any AudioOutput,
         cache: SessionCaching,
         makeKey: @escaping @MainActor () -> String = { UUID().uuidString.lowercased() },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.sessionId = sessionId
        self.initial = initial
        self.startOnOpen = startOnOpen
        self.service = service
        self.audio = audio
        self.cache = cache
        self.now = now
        sender = SessionCommandSender(sessionId: sessionId, service: service, makeKey: makeKey)
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

    /// "Adapted · Common swap" / "Adapted · AI suggested adaptation" (AI wins when mixed).
    var adaptedBadgeText: String? {
        guard let step = currentStep, step.adapted else { return nil }
        let sources = Set(currentAdaptations.map(\.source))
        let label = sources.isEmpty || sources.contains(.ai) ? SwapSource.ai.label : SwapSource.rule.label
        return "Adapted · \(label)"
    }

    var status: SessionStatus? { session?.status }
    var isPaused: Bool { session?.status == .paused }
    var isNotStarted: Bool { session?.status == .created }
    var isEnded: Bool { session.map { !$0.status.isOpen } ?? false }

    /// Commands need a live server copy, an open session and nothing in flight.
    var canSendCommands: Bool {
        guard let session, !isOffline, !isSending else { return false }
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

    // MARK: - Loading

    func load() async {
        if let initial, session == nil {
            adopt(initial)
        }
        await refresh()
        if startOnOpen, session?.status == .created, !isOffline {
            await start()
        }
    }

    /// Re-read the canonical Session (also the "Reconnect" button when nothing is pending).
    func refresh() async {
        do {
            let latest = try await service.session(id: sessionId)
            isOffline = false
            errorMessage = nil
            adopt(latest)
            phase = .ready
        } catch let error as APIError where error == .cancelled {
            return
        } catch let error as APIError where error.isTransportFailure {
            if session == nil, let cached = cache.load(), cached.id == sessionId {
                adopt(cached, persist: false)
            }
            isOffline = true
            if session != nil {
                phase = .ready
                errorMessage = Self.offlineMessage
            } else {
                phase = .failed(error.userMessage)
            }
        } catch {
            let message = (error as? APIError)?.userMessage ?? error.localizedDescription
            if session == nil { phase = .failed(message) } else { errorMessage = message }
        }
    }

    /// "Reconnect": re-send the pending tap with its original key, or re-read the Session.
    func reconnect() async {
        guard !isSending else { return }
        if sender.pending != nil {
            isSending = true
            defer { isSending = false }
            do {
                if let latest = try await sender.retryPending() {
                    isOffline = false
                    errorMessage = nil
                    adopt(latest)
                    return
                }
            } catch let error as APIError {
                handle(error)
                return
            } catch {
                errorMessage = error.localizedDescription
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

    /// Session end **Done**: private note (if any), then `complete` with the outcome.
    @discardableResult
    func complete(result: OutcomeResult, saveChanges: Bool, note: String) async -> Bool {
        guard canSendCommands else { return false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            do {
                _ = try await service.addNote(sessionId: sessionId, text: String(trimmed.prefix(2000)))
            } catch let error as APIError {
                errorMessage = "Couldn’t save your note: \(error.userMessage)"
                return false
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        var command = SessionCommand.confirmed(.complete, revision: revisionOrZero)
        command.outcome = OutcomeInput(result: result, saveChanges: saveChanges && !(session?.adaptations.isEmpty ?? true))
        audio.stop()
        return await run(command)
    }

    /// Cooking menu → Stop cooking (after a confirmation dialog in the view).
    @discardableResult
    func abandon() async -> Bool {
        audio.stop()
        return await run(.confirmed(.abandon, revision: revisionOrZero))
    }

    /// A coach proposal the user just tapped ("Go to next step?"). The tap is the confirmation.
    @discardableResult
    func perform(_ proposal: ProposedAction) async -> Bool {
        guard proposal.isSupported, canSendCommands else { return false }
        var command = SessionCommand.confirmed(proposal.command, revision: revisionOrZero, source: .iosAssistant)
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
        guard force || readAloudEnabled, let text = spokenText, session?.status == .active else { return }
        await audio.speak(text, pace: pace)
    }

    func dismissToast() { toast = nil }

    // MARK: - Plumbing

    private var revisionOrZero: Int { session?.revision ?? 0 }

    /// Sends one command; adopts whatever Session the server answers with. Returns true on 200.
    private func run(_ command: SessionCommand) async -> Bool {
        guard session != nil, !isSending, !isOffline else { return false }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let latest = try await sender.send(command)
            adopt(latest)
            return true
        } catch let error as APIError {
            handle(error)
            return false
        } catch {
            errorMessage = error.localizedDescription
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

    private func adopt(_ latest: CookingSession, persist: Bool = true) {
        let stepChanged = session?.stepIndex != latest.stepIndex
        session = latest
        if stepChanged { showOriginal = false }
        if phase != .ready { phase = .ready }
        if persist { onSessionChanged?(latest) }
    }
}
