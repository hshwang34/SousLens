import Foundation
import XCTest
@testable import SousLens

@MainActor
final class SessionCommandSenderTests: XCTestCase {
    func testOneKeyPerActionReusedOnRetryNewKeyForNextAction() async throws {
        let service = FakeCookingService()
        let oracle = FakeOracle()
        let failNext = TestBox(true)
        service.commandHandler = { command, key in
            if failNext.value { failNext.value = false; throw APIError.unreachable(baseURL: "x", underlying: "offline") }
            return try oracle.apply(command, key: key)
        }
        let minter = KeyMinter()
        let sender = SessionCommandSender(sessionId: CookingFixtures.sessionUUID, service: service, makeKey: { minter.next() })

        do {
            _ = try await sender.send(.confirmed(.next, revision: 1))
            XCTFail("first attempt is offline")
        } catch {}
        XCTAssertEqual(sender.pending?.key, "key-1", "outcome unknown → keep the key")

        let retried = try await sender.retryPending()
        XCTAssertEqual(retried?.stepIndex, 1)
        XCTAssertNil(sender.pending)
        XCTAssertEqual(service.commands.map(\.1), ["key-1", "key-1"], "retry reuses the same key")
        XCTAssertEqual(service.commands[0].0, service.commands[1].0, "…and the identical body")

        _ = try await sender.send(.confirmed(.next, revision: 2))
        XCTAssertEqual(service.commands.map(\.1), ["key-1", "key-1", "key-2"], "a new action gets a new key")
        XCTAssertEqual(minter.minted.count, 2)
    }

    func testRetryOfAnActionThatAlreadyLandedAdvancesOnce() async throws {
        // The server applied the command but the response was lost.
        let service = FakeCookingService()
        let oracle = FakeOracle()
        let dropResponse = TestBox(true)
        service.commandHandler = { command, key in
            let result = try oracle.apply(command, key: key)
            if dropResponse.value { dropResponse.value = false; throw APIError.http(status: 502, correlationId: nil) }
            return result
        }
        let sender = SessionCommandSender(sessionId: CookingFixtures.sessionUUID, service: service)
        _ = try? await sender.send(.confirmed(.next, revision: 1))
        let session = try await sender.retryPending()
        XCTAssertEqual(session?.stepIndex, 1, "same key → no second event")
        XCTAssertEqual(oracle.appliedCount, 1)
    }

    func testDefinitiveErrorsClearThePendingKey() async throws {
        let service = FakeCookingService()
        service.commandHandler = { _, _ in throw try CookingFixtures.apiError(status: 409, code: "INVALID_TRANSITION") }
        let sender = SessionCommandSender(sessionId: CookingFixtures.sessionUUID, service: service)
        _ = try? await sender.send(.confirmed(.next, revision: 1))
        XCTAssertNil(sender.pending)
        let nothing = try await sender.retryPending()
        XCTAssertNil(nothing)
    }
}

@MainActor
final class CookingViewModelTests: XCTestCase {
    private var service: FakeCookingService!
    private var oracle: FakeOracle!
    private var audio: FakeAudioOutput!
    private var minter: KeyMinter!
    private var clock = ISO8601Flexible.parse("2026-10-23T10:00:00Z")!

    override func setUp() async throws {
        service = FakeCookingService()
        audio = FakeAudioOutput()
        minter = KeyMinter()
        let fixedNow = clock
        oracle = FakeOracle(now: { fixedNow })
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
    }

    private func makeModel(initial: CookingSession? = nil, startOnOpen: Bool = false,
                           loadCached: @escaping @MainActor () -> CookingSession? = { nil }) -> CookingViewModel {
        let minter = minter!
        return CookingViewModel(sessionId: CookingFixtures.sessionUUID, initial: initial, startOnOpen: startOnOpen,
                                service: service, audio: audio, loadCached: loadCached,
                                makeKey: { minter.next() }, now: { [unowned self] in self.clock })
    }

    func testRendersServerStateOnly() async throws {
        let model = makeModel()
        XCTAssertNil(model.session)
        await model.load()
        XCTAssertEqual(model.stepCounterText, "Step 1 of 7")
        XCTAssertEqual(model.instructionText, try oracle.current().steps[0].instruction)
        XCTAssertTrue(audio.spoken.isEmpty, "opening a session never speaks")
    }

    func testNextSendsConfirmedCommandWithExpectedRevisionAndRendersServerReply() async throws {
        let model = makeModel()
        await model.load()
        await model.next()
        let (command, key) = try XCTUnwrap(service.commands.last)
        XCTAssertEqual(command.command, .next)
        XCTAssertEqual(command.expectedRevision, 1)
        XCTAssertTrue(command.userConfirmed, "button presses are always user_confirmed → never a 422")
        XCTAssertEqual(command.clientSource, .iosButton)
        XCTAssertEqual(key, "key-1")
        XCTAssertEqual(model.session?.stepIndex, 1)
        XCTAssertEqual(model.session?.revision, 2)
        XCTAssertEqual(model.stepCounterText, "Step 2 of 7")
    }

    func testNeverAdvancesLocallyWhenTheServerFails() async throws {
        let model = makeModel()
        await model.load()
        service.commandHandler = { _, _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        await model.next()
        XCTAssertEqual(model.session?.stepIndex, 0, "no local advancing")
        XCTAssertTrue(model.isOffline)
        XCTAssertEqual(model.errorMessage, CookingViewModel.offlineMessage)
        XCTAssertFalse(model.canGoNext, "read-only until reconnected")

        // Reconnect re-sends the SAME tap with the same key.
        let oracle = oracle!
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        await model.reconnect()
        XCTAssertEqual(service.commands.map(\.1), ["key-1", "key-1"])
        XCTAssertEqual(model.session?.stepIndex, 1)
        XCTAssertFalse(model.isOffline)
    }

    func testStateConflictAdoptsServerSessionAndShowsToast() async throws {
        let model = makeModel()
        await model.load()
        oracle.externalNext()   // another device moved on: revision 2, step 1
        oracle.externalNext()   // revision 3, step 2
        await model.next()      // sent with expected_revision 1 → 409
        XCTAssertEqual(model.session?.stepIndex, 2, "adopts details.session")
        XCTAssertEqual(model.session?.revision, 3)
        XCTAssertEqual(model.toast, "Updated from your other device")
        XCTAssertEqual(oracle.appliedCount, 0, "nothing re-sent automatically")
    }

    func testInvalidTransitionAdoptsLatest() async throws {
        let model = makeModel()
        await model.load()
        // Coach proposes "next" on what it thinks is not the last step, but the server disagrees.
        service.commandHandler = { _, _ in
            throw try CookingFixtures.conflict(latest: CookingFixtures.sessionJSON(stepIndex: 4, revision: 6), code: "INVALID_TRANSITION")
        }
        await model.next()
        XCTAssertEqual(model.session?.stepIndex, 4)
        XCTAssertEqual(model.toast, CookingViewModel.invalidTransitionToast)
    }

    func testStartOnOpenStartsACreatedSessionAndSpeaksStepOne() async throws {
        oracle = FakeOracle(status: "created", revision: 0)
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        let model = makeModel(initial: try oracle.current(), startOnOpen: true)
        await model.load()
        XCTAssertEqual(service.commands.first?.0.command, .start)
        XCTAssertEqual(service.commands.first?.0.expectedRevision, 0)
        XCTAssertEqual(model.status, .active)
        XCTAssertEqual(audio.spoken.count, 1)
        XCTAssertTrue(audio.spoken[0].hasPrefix("Step 1."))
    }

    func testResumedCreatedSessionWaitsForATap() async throws {
        oracle = FakeOracle(status: "created", revision: 0)
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        let model = makeModel(startOnOpen: false)
        await model.load()
        XCTAssertTrue(service.commands.isEmpty)
        XCTAssertTrue(model.isNotStarted)
    }

    func testReadsAloudOnlyOnExplicitActions() async throws {
        let model = makeModel()
        await model.load()
        XCTAssertTrue(audio.spoken.isEmpty)
        await model.next()
        XCTAssertEqual(audio.spoken.count, 1)
        await model.repeatStep()
        await model.slower()
        XCTAssertEqual(audio.spoken.count, 3)
        XCTAssertEqual(audio.paces, [.normal, .normal, .slow])
        await model.pause()
        await model.resume()
        await model.refresh()
        _ = model.timerRows()
        XCTAssertEqual(audio.spoken.count, 3, "pause / resume / refresh never chatter")
        model.readAloudEnabled = false
        await model.next()
        XCTAssertEqual(audio.spoken.count, 3, "auto read-aloud off")
        await model.repeatStep()
        XCTAssertEqual(audio.spoken.count, 4, "Repeat still speaks: it was asked for")
    }

    func testAdaptedBadgeAndShowOriginal() async throws {
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.adaptedBadgeText, "Adapted · Common swap")
        let adapted = try XCTUnwrap(model.instructionText)
        model.showOriginal = true
        XCTAssertEqual(model.instructionText, try oracle.current().steps[0].originalInstruction)
        XCTAssertNotEqual(model.instructionText, adapted)
        await model.next()
        XCTAssertFalse(model.showOriginal, "resets on step change")
        XCTAssertNil(model.adaptedBadgeText, "step 2 is not adapted")
    }

    func testAiAdaptationBadge() async throws {
        let session = try CookingFixtures.session(source: "ai")
        service.sessionHandler = { _ in session }
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.adaptedBadgeText, "Adapted · AI suggested adaptation")
    }

    func testRevertAdaptationIsACommand() async throws {
        let model = makeModel()
        await model.load()
        await model.revertAdaptation(id: try XCTUnwrap(UUID(uuidString: CookingFixtures.adaptationId)))
        XCTAssertEqual(service.commands.last?.0.command, .revertAdaptation)
        XCTAssertEqual(service.commands.last?.0.adaptationId, UUID(uuidString: CookingFixtures.adaptationId))
        XCTAssertNil(model.adaptedBadgeText, "the server restored the original text")
    }

    func testLastStepNextBecomesFinishAndCompleteSendsOutcome() async throws {
        oracle = FakeOracle(stepIndex: 6, revision: 7)
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        let model = makeModel()
        await model.load()
        XCTAssertTrue(model.isLastStep)
        XCTAssertEqual(model.nextTitle, "Finish")
        await model.next()
        XCTAssertTrue(service.commands.isEmpty, "Finish opens Session end; it never sends next")

        let end = SessionEndViewModel(cooking: model)
        XCTAssertTrue(end.showsSaveChanges)
        XCTAssertFalse(end.canFinish, "pick an outcome first")
        end.result = .cooked
        end.saveChanges = true
        end.note = "  More garlic next time  "
        let done = await end.finish()
        XCTAssertTrue(done)
        XCTAssertEqual(service.calls.first { if case .note = $0 { return true } else { return false } }, .note("More garlic next time"))
        let complete = try XCTUnwrap(service.commands.last?.0)
        XCTAssertEqual(complete.command, .complete)
        XCTAssertEqual(complete.outcome, OutcomeInput(result: .cooked, saveChanges: true))
        XCTAssertTrue(model.isEnded)
    }

    func testSaveChangesIsNeverSentWithoutAdaptations() async throws {
        oracle = FakeOracle(stepIndex: 6, revision: 7)
        let plain = try CookingFixtures.session(stepIndex: 6, revision: 7, adapted: false)
        service.sessionHandler = { _ in plain }
        service.commandHandler = { _, _ in try CookingFixtures.session(status: "completed", stepIndex: 6, revision: 8, adapted: false) }
        let model = makeModel()
        await model.load()
        let end = SessionEndViewModel(cooking: model)
        XCTAssertFalse(end.showsSaveChanges)
        end.result = .partly
        end.saveChanges = true
        _ = await end.finish()
        XCTAssertEqual(service.commands.last?.0.outcome, OutcomeInput(result: .partly, saveChanges: false))
        XCTAssertFalse(service.calls.contains { if case .note = $0 { return true } else { return false } }, "empty note not sent")
    }

    func testAbandonIsAConfirmedCommand() async throws {
        let model = makeModel()
        await model.load()
        let ok = await model.abandon()
        XCTAssertTrue(ok)
        XCTAssertEqual(service.commands.last?.0.command, .abandon)
        XCTAssertTrue(service.commands.last?.0.userConfirmed ?? false)
        XCTAssertTrue(model.isEnded)
    }

    func testBackAtStepZeroIsDisabledAndPausedBlocksNavigation() async throws {
        let model = makeModel()
        await model.load()
        XCTAssertFalse(model.canGoBack)
        await model.back()
        XCTAssertTrue(service.commands.isEmpty)
        await model.pause()
        XCTAssertTrue(model.isPaused)
        XCTAssertFalse(model.canGoNext)
        XCTAssertEqual(audio.stopCount, 1, "pausing stops speech")
    }

    // MARK: Timers

    func testTimerSuggestionNeedsATapThenCountsDownFromTargetAt() async throws {
        oracle = FakeOracle(stepIndex: 2, revision: 3, now: { [clock] in clock })
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        let model = makeModel()
        await model.load()
        let suggestion = try XCTUnwrap(model.timerSuggestion)
        XCTAssertEqual(CookingFormatting.timerPrompt(suggestion), "Start a 10-min simmer timer?")
        XCTAssertTrue(model.timerRows().isEmpty, "a suggestion is not a timer")
        XCTAssertTrue(service.commands.isEmpty)

        await model.startSuggestedTimer()
        let command = try XCTUnwrap(service.commands.last?.0)
        XCTAssertEqual(command.command, .startTimer)
        XCTAssertEqual(command.timer, TimerRequest(label: "Simmer", durationSeconds: 600))
        XCTAssertNil(model.timerSuggestion, "already started")

        clock = clock.addingTimeInterval(61)
        let row = try XCTUnwrap(model.timerRows().first)
        XCTAssertEqual(row.remainingSeconds, 539)
        XCTAssertEqual(row.countdownText, "8:59")
        clock = clock.addingTimeInterval(600)
        XCTAssertTrue(try XCTUnwrap(model.timerRows().first).isDone)
    }

    func testSkipHidesTheSuggestionWithoutACommand() async throws {
        let session = try CookingFixtures.session(stepIndex: 2, revision: 3)
        service.sessionHandler = { _ in session }
        let model = makeModel()
        await model.load()
        XCTAssertNotNil(model.timerSuggestion)
        model.skipSuggestedTimer()
        XCTAssertNil(model.timerSuggestion)
        XCTAssertTrue(service.commands.isEmpty)
    }

    func testTimersSurviveRelaunchBecauseTheyAreAbsolute() async throws {
        let target = "2026-10-23T10:10:00Z"
        let session = try CookingFixtures.session(stepIndex: 2, revision: 4, timers: [.init(targetAt: target)])
        service.sessionHandler = { _ in session }
        let first = makeModel()
        await first.load()
        XCTAssertEqual(first.timerRows().first?.remainingSeconds, 600)

        // "Kill" the app: a brand-new model 4 minutes later, server unreachable → cached copy.
        clock = clock.addingTimeInterval(240)
        service.sessionHandler = { _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        let relaunched = makeModel(loadCached: { session })
        await relaunched.load()
        XCTAssertTrue(relaunched.isOffline)
        XCTAssertEqual(relaunched.session?.stepIndex, 2)
        XCTAssertEqual(relaunched.timerRows().first?.remainingSeconds, 360, "same target_at → same countdown")
        XCTAssertFalse(relaunched.canGoNext, "cached copy is read-only")
    }

    func testCancelTimerIsACommand() async throws {
        let session = try CookingFixtures.session(stepIndex: 2, revision: 4, timers: [.init(targetAt: "2026-10-23T10:10:00Z")])
        service.sessionHandler = { _ in session }
        service.commandHandler = { _, _ in try CookingFixtures.session(stepIndex: 2, revision: 5, timers: [.init(targetAt: "2026-10-23T10:10:00Z", status: "cancelled")]) }
        let model = makeModel()
        await model.load()
        await model.cancelTimer(id: try XCTUnwrap(UUID(uuidString: CookingFixtures.timerId)))
        XCTAssertEqual(service.commands.last?.0.timerId, UUID(uuidString: CookingFixtures.timerId))
        XCTAssertTrue(model.timerRows().isEmpty)
    }

    // MARK: Coach proposals

    func testProposalIsSentOnlyAsAnAssistantCommand() async throws {
        let model = makeModel()
        await model.load()
        let ok = await model.perform(ProposedAction(command: .next, stepIndex: nil, timer: nil))
        XCTAssertTrue(ok)
        XCTAssertEqual(service.commands.last?.0.clientSource, .iosAssistant)
        XCTAssertTrue(service.commands.last?.0.userConfirmed ?? false)
        let unsupported = await model.perform(ProposedAction(command: .complete, stepIndex: nil, timer: nil))
        XCTAssertFalse(unsupported, "the coach can't finish a session")
    }

    // MARK: Account isolation

    func testInvalidatedModelDropsLateResults() async throws {
        let reported = TestBox(0)
        let latch = TestLatch()
        let gated = GatedCookingService(inner: service, latch: latch)
        let minter = minter!
        let model = CookingViewModel(sessionId: CookingFixtures.sessionUUID, initial: try oracle.current(),
                                     service: gated, audio: audio, makeKey: { minter.next() })
        await model.load()
        model.onSessionChanged = { _ in reported.value += 1 }
        let pending = Task { await model.next() }
        while gated.entered == 0 { await Task.yield() }
        model.invalidate()   // sign-out while the command is in flight
        await latch.open()
        await pending.value
        XCTAssertEqual(model.session?.stepIndex, 0, "the late reply is never adopted")
        XCTAssertEqual(reported.value, 0, "…nor reported to the store / cache")
        XCTAssertFalse(model.canGoNext || model.sender.pending != nil, "nothing left to retry")
    }
}

/// Wraps a service and parks `sendCommand` until the latch opens.
final class GatedCookingService: CookingService, @unchecked Sendable {
    let inner: FakeCookingService
    let latch: TestLatch
    private let counter = TestBox(0)
    var entered: Int { counter.value }

    init(inner: FakeCookingService, latch: TestLatch) {
        self.inner = inner
        self.latch = latch
    }

    func suggestSubstitutions(recipeVersionId: UUID, ingredientRef: String) async throws -> SubstitutionResult {
        try await inner.suggestSubstitutions(recipeVersionId: recipeVersionId, ingredientRef: ingredientRef)
    }
    func createSession(recipeVersionId: UUID, adaptations: [AdaptationInput]) async throws -> CookingSession {
        try await inner.createSession(recipeVersionId: recipeVersionId, adaptations: adaptations)
    }
    func activeSessions() async throws -> [SessionSummary] {
        counter.value += 1
        await latch.wait()
        return try await inner.activeSessions()
    }
    func session(id: UUID) async throws -> CookingSession { try await inner.session(id: id) }
    func deleteSession(id: UUID) async throws { try await inner.deleteSession(id: id) }
    func sendCommand(sessionId: UUID, _ command: SessionCommand, idempotencyKey: String) async throws -> CookingSession {
        counter.value += 1
        await latch.wait()
        return try await inner.sendCommand(sessionId: sessionId, command, idempotencyKey: idempotencyKey)
    }
    func ask(sessionId: UUID, query: String, groundedRevision: Int) async throws -> AskResponse {
        try await inner.ask(sessionId: sessionId, query: query, groundedRevision: groundedRevision)
    }
    func addNote(sessionId: UUID, text: String) async throws -> SessionNote { try await inner.addNote(sessionId: sessionId, text: text) }
    func myVariation(recipeVersionId: UUID) async throws -> PrivateVariation? { try await inner.myVariation(recipeVersionId: recipeVersionId) }
    func deleteMyVariation(recipeVersionId: UUID) async throws { try await inner.deleteMyVariation(recipeVersionId: recipeVersionId) }
}
