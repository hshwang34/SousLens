import Foundation
import XCTest
@testable import SousLens

/// Wraps a service; `session(id:)` answers with the snapshot taken on entry but delivers it only
/// after the latch opens (a slow GET that is overtaken by a command).
final class SlowReadService: CookingService, @unchecked Sendable {
    let inner: FakeCookingService
    let latch: TestLatch
    let armed = TestBox(false)
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
    func activeSessions() async throws -> [SessionSummary] { try await inner.activeSessions() }
    func session(id: UUID) async throws -> CookingSession {
        let snapshot = try await inner.session(id: id)
        if armed.value {
            counter.value += 1
            await latch.wait()
        }
        return snapshot
    }
    func deleteSession(id: UUID) async throws { try await inner.deleteSession(id: id) }
    func sendCommand(sessionId: UUID, _ command: SessionCommand, idempotencyKey: String) async throws -> CookingSession {
        try await inner.sendCommand(sessionId: sessionId, command, idempotencyKey: idempotencyKey)
    }
    func ask(sessionId: UUID, query: String, groundedRevision: Int) async throws -> AskResponse {
        try await inner.ask(sessionId: sessionId, query: query, groundedRevision: groundedRevision)
    }
    func addNote(sessionId: UUID, text: String, idempotencyKey: String) async throws -> SessionNote {
        try await inner.addNote(sessionId: sessionId, text: text, idempotencyKey: idempotencyKey)
    }
    func myVariation(recipeVersionId: UUID) async throws -> PrivateVariation? { try await inner.myVariation(recipeVersionId: recipeVersionId) }
    func deleteMyVariation(recipeVersionId: UUID) async throws { try await inner.deleteMyVariation(recipeVersionId: recipeVersionId) }
}

/// Brief 005 iOS gate (Slice 3): Step Oracle discipline, idempotency, conflicts, timers,
/// read-aloud, assistant, swap wording, session end.
@MainActor
final class Slice3GateTests: XCTestCase {
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
        wire(oracle)
    }

    private func wire(_ oracle: FakeOracle) {
        self.oracle = oracle
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
    }

    private func makeModel(service override: (any CookingService)? = nil, initial: CookingSession? = nil,
                           loadCached: @escaping @MainActor () -> CookingSession? = { nil }) -> CookingViewModel {
        let minter = minter!
        return CookingViewModel(sessionId: CookingFixtures.sessionUUID, initial: initial, startOnOpen: false,
                                service: override ?? service, audio: audio, loadCached: loadCached,
                                makeKey: { minter.next() }, now: { [unowned self] in self.clock })
    }

    // MARK: Probe 1 — no local state writes (guard against someone adding a mutator)

    func testModelStateIsOnlyChangedByServerSessions() async throws {
        let failures: [APIError] = [
            .unreachable(baseURL: "x", underlying: "offline"), .http(status: 503, correlationId: nil),
            try CookingFixtures.apiError(status: 422, code: "CONFIRMATION_REQUIRED"),
            try CookingFixtures.apiError(status: 404, code: "NOT_FOUND"),
        ]
        for failure in failures {
            let model = makeModel()
            await model.load()
            service.commandHandler = { _, _ in throw failure }
            await model.next()
            XCTAssertEqual(model.session?.stepIndex, 0, "\(failure)")
            XCTAssertEqual(model.session?.status, .active, "\(failure)")
            XCTAssertEqual(model.session?.revision, 1, "\(failure)")
        }
    }

    // MARK: Probe 2 — idempotency

    func testDuplicateTapsWhileInFlightSendAtMostOneRequest() async throws {
        let latch = TestLatch()
        let gated = GatedCookingService(inner: service, latch: latch)
        let model = makeModel(service: gated, initial: try oracle.current())
        await model.load()
        // `GatedCookingService` gates sendCommand and activeSessions; count only commands.
        let first = Task { await model.next() }
        while gated.entered == 0 { await Task.yield() }
        await model.next()
        await model.next()
        await model.back()
        await model.pause()
        await model.startSuggestedTimer()
        await model.revertAdaptation(id: UUID())
        XCTAssertEqual(gated.entered, 1, "second tap, other buttons and a revert are ignored while a command is in flight")
        XCTAssertFalse(model.canGoNext)
        await latch.open()
        await first.value
        XCTAssertEqual(service.commands.count, 1)
        XCTAssertEqual(oracle.appliedCount, 1)
        XCTAssertEqual(model.session?.stepIndex, 1)
    }

    func testNewTapAfterUnknownOutcomeGetsANewKeyAndTheCurrentRevision() async throws {
        let model = makeModel()
        await model.load()
        let oracle = oracle!
        let drop = TestBox(true)
        service.commandHandler = { command, key in
            let result = try oracle.apply(command, key: key)
            if drop.value { drop.value = false; throw APIError.http(status: 502, correlationId: nil) }
            return result
        }
        await model.next()                       // landed, response lost
        XCTAssertTrue(model.isOffline)
        XCTAssertEqual(model.session?.stepIndex, 0, "no optimistic advance")
        await model.refresh()                    // user pulls fresh state: server is at rev 2
        XCTAssertEqual(model.session?.revision, 2)
        await model.next()                       // a NEW tap
        XCTAssertEqual(service.commands.map(\.1), ["key-1", "key-2"])
        XCTAssertEqual(service.commands.map(\.0.expectedRevision), [1, 2], "body changed → new key and new revision")
        XCTAssertNil(model.sender.pending)
    }

    func testReconnectResendsTheIdenticalBodyAndKeyOnce() async throws {
        let model = makeModel()
        await model.load()
        let oracle = oracle!
        let drop = TestBox(true)
        service.commandHandler = { command, key in
            let result = try oracle.apply(command, key: key)
            if drop.value { drop.value = false; throw APIError.unreachable(baseURL: "x", underlying: "offline") }
            return result
        }
        await model.next()
        await model.reconnect()
        await model.reconnect()   // nothing pending any more: a read, not a command
        XCTAssertEqual(service.commands.map(\.1), ["key-1", "key-1"])
        XCTAssertEqual(service.commands[0].0, service.commands[1].0)
        XCTAssertEqual(oracle.appliedCount, 1, "advanced once")
        XCTAssertEqual(model.session?.stepIndex, 1)
    }

    // MARK: Probe 3 — conflicts and late responses

    func testStateConflictAdoptsStepAdaptationsAndTimers() async throws {
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.currentAdaptations.count, 1)
        let latest = try CookingFixtures.sessionJSON(stepIndex: 2, revision: 5, adapted: false,
                                                     timers: [.init(targetAt: "2026-10-23T10:10:00Z")])
        service.commandHandler = { _, _ in throw try CookingFixtures.conflict(latest: latest) }
        var changed: [CookingSession] = []
        model.onSessionChanged = { changed.append($0) }
        await model.next()
        XCTAssertEqual(model.session?.stepIndex, 2)
        XCTAssertEqual(model.session?.revision, 5)
        XCTAssertTrue(model.session?.adaptations.isEmpty ?? false, "adopted the server's adaptations")
        XCTAssertEqual(model.timerRows().count, 1, "adopted the server's timers")
        XCTAssertEqual(model.toast, "Updated from your other device")
        XCTAssertEqual(changed.map(\.revision), [5], "the store/cache hear about it")
        XCTAssertNil(model.sender.pending, "a 409 is definitive; nothing is retried")
        XCTAssertEqual(service.commands.count, 1)
    }

    func testInvalidTransitionAdoptsTimersAndAdaptationsToo() async throws {
        let model = makeModel()
        await model.load()
        let latest = try CookingFixtures.sessionJSON(stepIndex: 6, revision: 9, adapted: false,
                                                     timers: [.init(stepIndex: 6, targetAt: "2026-10-23T10:20:00Z")])
        service.commandHandler = { _, _ in throw try CookingFixtures.conflict(latest: latest, code: "INVALID_TRANSITION") }
        await model.next()
        XCTAssertEqual(model.session?.stepIndex, 6)
        XCTAssertEqual(model.session?.revision, 9)
        XCTAssertTrue(model.session?.adaptations.isEmpty ?? false)
        XCTAssertEqual(model.timerRows().count, 1)
        XCTAssertEqual(model.toast, CookingViewModel.invalidTransitionToast)
    }

    func testConflictWithoutDetailsRereadsTheSession() async throws {
        let model = makeModel()
        await model.load()
        service.commandHandler = { _, _ in throw try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT") }
        oracle.externalNext()
        await model.next()
        for _ in 0..<100 where model.session?.revision != 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.session?.revision, 2)
        XCTAssertEqual(model.toast, "Updated from your other device")
    }

    /// REGRESSION GUARD: a GET that was answered before a command but delivered after it must not
    /// roll the screen back to an older revision (CLAUDE.md: render only the server's newest Session).
    func testLateReadOfAnOlderRevisionNeverOverwritesANewerAdoptedState() async throws {
        let latch = TestLatch()
        let slow = SlowReadService(inner: service, latch: latch)
        let model = makeModel(service: slow)
        await model.load()                       // revision 1
        let reported = TestBox<[Int]>([])
        model.onSessionChanged = { reported.value.append($0.revision) }
        slow.armed.value = true
        let refresh = Task { await model.refresh() }
        while slow.entered == 0 { await Task.yield() }   // GET captured revision 1
        await model.next()                       // command lands: revision 2, step index 1
        XCTAssertEqual(model.session?.revision, 2)
        await latch.open()
        await refresh.value                      // the old GET arrives late
        XCTAssertEqual(model.session?.revision, 2, "older revision must be ignored")
        XCTAssertEqual(model.session?.stepIndex, 1)
        XCTAssertEqual(reported.value, [2], "…and must not reach the cache / resume store either")
    }

    // MARK: Probe 4 — timers

    func testTimerClockJumpsAndRelaunch() async throws {
        let session = try CookingFixtures.session(stepIndex: 2, revision: 4, timers: [.init(targetAt: "2026-10-23T10:10:00Z")])
        service.sessionHandler = { _ in session }
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.timerRows().first?.remainingSeconds, 600)
        clock = clock.addingTimeInterval(3 * 3600)               // clock jumps far forward
        var row = try XCTUnwrap(model.timerRows().first)
        XCTAssertTrue(row.isDone); XCTAssertEqual(row.countdownText, "Done"); XCTAssertEqual(row.remainingSeconds, 0)
        clock = clock.addingTimeInterval(-3 * 3600 - 300)         // jumps back 5 min before start
        row = try XCTUnwrap(model.timerRows().first)
        XCTAssertEqual(row.remainingSeconds, 900, "derived from target_at and now, not a local tick count")
        XCTAssertFalse(row.isDone)
        // Server says done early (target already passed on its read) → Done regardless of local clock.
        let done = try CookingFixtures.session(stepIndex: 2, revision: 5, timers: [.init(targetAt: "2026-10-23T10:10:00Z", status: "done")])
        let rows = TimerRow.rows(for: done.timers, now: clock)
        XCTAssertTrue(rows[0].isDone)
        XCTAssertEqual(rows[0].countdownText, "Done")
    }

    func testSuggestedTimerIsOnlyAPromptAcrossAdoptionAndRefresh() async throws {
        let session = try CookingFixtures.session(stepIndex: 2, revision: 3)
        service.sessionHandler = { _ in session }
        let model = makeModel()
        await model.load()
        await model.refresh()
        await model.reconnect()
        XCTAssertNotNil(model.timerSuggestion)
        XCTAssertTrue(model.timerRows().isEmpty)
        XCTAssertTrue(service.commands.isEmpty, "no start_timer without a tap")
        // Paused sessions don't prompt.
        let paused = try CookingFixtures.session(status: "paused", stepIndex: 2, revision: 4)
        service.sessionHandler = { _ in paused }
        await model.refresh()
        XCTAssertNil(model.timerSuggestion)
        XCTAssertTrue(service.commands.isEmpty)
    }

    // MARK: Probe 5 — read aloud

    func testNothingIsSpokenOnAdoptionConflictResumeOrFailure() async throws {
        // Resume from a cached/initial active copy, then adopt a conflict and an invalid transition.
        let cached = try CookingFixtures.session(stepIndex: 3, revision: 6)
        let model = makeModel(initial: cached)
        await model.load()
        service.commandHandler = { _, _ in
            throw try CookingFixtures.conflict(latest: CookingFixtures.sessionJSON(stepIndex: 4, revision: 7))
        }
        await model.next()
        service.commandHandler = { _, _ in
            throw try CookingFixtures.conflict(latest: CookingFixtures.sessionJSON(stepIndex: 5, revision: 8), code: "INVALID_TRANSITION")
        }
        await model.next()
        service.commandHandler = { _, _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        await model.back()
        XCTAssertEqual(model.session?.stepIndex, 5)
        XCTAssertTrue(audio.spoken.isEmpty, "server-pushed state is never read out; failed taps don't speak")
    }

    func testCoachTimerProposalDoesNotSpeakButStepMovesDo() async throws {
        let model = makeModel()
        await model.load()
        _ = await model.perform(ProposedAction(command: .startTimer, stepIndex: nil, timer: TimerRequest(label: "Rest", durationSeconds: 300)))
        XCTAssertTrue(audio.spoken.isEmpty)
        XCTAssertEqual(service.commands.last?.0.clientSource, .iosAssistant)
        _ = await model.perform(ProposedAction(command: .jumpToStep, stepIndex: 3, timer: nil))
        XCTAssertEqual(service.commands.last?.0.stepIndex, 3)
        XCTAssertTrue(service.commands.last?.0.userConfirmed ?? false)
        XCTAssertEqual(audio.spoken.count, 1, "jump is a tapped step change")
    }

    func testResumedCacheForADifferentSessionIsIgnored() async throws {
        let foreign = try CookingFixtures.session(id: CookingFixtures.otherSessionId, stepIndex: 4, revision: 9)
        service.sessionHandler = { _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        let model = makeModel(loadCached: { foreign })
        await model.load()
        XCTAssertNil(model.session)
        if case .failed = model.phase {} else { XCTFail("expected failed phase, got \(model.phase)") }
    }

    // MARK: Probe 6 — assistant

    func testServerStaleAnswerOffersNoActionAndKeepsSafetyNotice() async throws {
        let ask = FakeCookingService()
        ask.askHandler = { _, revision in
            try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(
                revision: revision, stale: true, proposed: #"{"command":"next"}"#, safety: #""Use a thermometer.""#))
        }
        let session = TestBox<CookingSession?>(try CookingFixtures.session())
        let model = AssistantViewModel(sessionId: CookingFixtures.sessionUUID, service: ask, audio: audio, currentSession: { session.value })
        let sent = TestBox(0)
        model.onProposal = { _ in sent.value += 1; return true }
        model.query = "is this done?"
        await model.ask()
        let turn = try XCTUnwrap(model.turns.first)
        XCTAssertTrue(model.isStale(turn))
        XCTAssertNil(model.proposalTitle(for: turn))
        await model.acceptProposal(turnId: turn.id)
        XCTAssertEqual(sent.value, 0, "no action for a stale answer, even if the button were somehow tapped")
        XCTAssertEqual(turn.response.safetyNotice, "Use a thermometer.")
    }

    func testFailedProposalCommandKeepsTheButtonAndSendsOnlyOnTap() async throws {
        let model = makeModel()
        await model.load()
        let ask = FakeCookingService()
        ask.askHandler = { _, revision in
            try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision, proposed: #"{"command":"next"}"#))
        }
        let drawer = AssistantViewModel(sessionId: CookingFixtures.sessionUUID, service: ask, audio: audio, currentSession: { model.session })
        drawer.onProposal = { await model.perform($0) }
        drawer.query = "what next?"
        await drawer.ask()
        XCTAssertTrue(service.commands.isEmpty, "asking never sends a command")
        service.commandHandler = { _, _ in throw APIError.http(status: 500, correlationId: nil) }
        await drawer.acceptProposal(turnId: drawer.turns[0].id)
        XCTAssertNotNil(drawer.proposalTitle(for: drawer.turns[0]), "not consumed by a failure")
        XCTAssertEqual(model.session?.stepIndex, 0)
    }

    // MARK: Probe 7 — honest wording

    func testNoSafeForYouWordingInUserFacingSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SousLens")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        let banned = ["safe for you", "safe to eat", "safe to use", "is safe", "perfectly safe", "allergy-safe", "allergen-free", "100% safe", "guaranteed"]
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            scanned += 1
            for phrase in banned {
                XCTAssertFalse(text.contains(phrase), "\(url.lastPathComponent) contains “\(phrase)”")
            }
        }
        XCTAssertGreaterThan(scanned, 50)
        XCTAssertEqual(SwapSource.rule.label, "Common swap")
        XCTAssertEqual(SwapSource.ai.label, "AI suggested adaptation")
    }

    // MARK: Probe 9 — session end

    func testNoteIsCappedAt2000AndCompleteSendsEveryOutcome() async throws {
        let model = makeModel()
        await model.load()
        let end = SessionEndViewModel(cooking: model)
        end.note = String(repeating: "n", count: 2500)
        XCTAssertEqual(end.note.count, SessionEndViewModel.maxNoteLength)
        XCTAssertEqual(SessionEndViewModel.maxNoteLength, 2000)
        XCTAssertFalse(end.saveChanges, "Save my changes defaults off")
        end.result = .didntWork
        let ok = await end.finish()
        XCTAssertTrue(ok)
        let noted = service.calls.compactMap { call -> String? in if case .note(let text) = call { return text } else { return nil } }
        XCTAssertEqual(noted.first?.count, 2000)
        XCTAssertEqual(service.commands.last?.0.outcome, OutcomeInput(result: .didntWork, saveChanges: false))
    }

    func testViewModelCapsAnOverlongNoteEvenIfCalledDirectly() async throws {
        let model = makeModel()
        await model.load()
        _ = await model.complete(result: .cooked, saveChanges: false, note: String(repeating: "x", count: 5000))
        let noted = service.calls.compactMap { call -> String? in if case .note(let text) = call { return text } else { return nil } }
        XCTAssertEqual(noted.first?.count, 2000)
    }

    func testSaveChangesDisappearsAfterTheOnlySwapIsReverted() async throws {
        let model = makeModel()
        await model.load()
        let end = SessionEndViewModel(cooking: model)
        XCTAssertTrue(end.showsSaveChanges)
        end.saveChanges = true
        await model.revertAdaptation(id: try XCTUnwrap(UUID(uuidString: CookingFixtures.adaptationId)))
        XCTAssertFalse(end.showsSaveChanges)
        end.result = .cooked
        _ = await end.finish()
        XCTAssertEqual(service.commands.last?.0.outcome, OutcomeInput(result: .cooked, saveChanges: false),
                       "a stale toggle can't save a variation that no longer exists")
    }

    func testFailedNoteDoesNotCompleteTheSession() async throws {
        let model = makeModel()
        await model.load()
        service.noteHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        let ok = await model.complete(result: .cooked, saveChanges: false, note: "hi")
        XCTAssertFalse(ok)
        XCTAssertTrue(service.commands.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: Probe 8 — cache ownership

    func testResumeNeverHandsAnotherAccountsCachedCopyToTheScreen() async throws {
        let a = SessionOwner(userId: UUID(), server: "http://localhost:8000")
        let b = SessionOwner(userId: UUID(), server: "http://localhost:8000")
        let cache = InMemorySessionCache()
        try cache.save(try CookingFixtures.session(stepIndex: 3, revision: 4), owner: a)
        let owner = TestBox<SessionOwner?>(b)
        let store = CookingSessionStore(service: service, cache: cache, owner: { owner.value })
        service.activeHandler = { [try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON())] }
        await store.refresh()
        store.resume(sessionId: CookingFixtures.sessionUUID)
        XCTAssertNil(store.presented?.initial, "B never paints A's copy")
        owner.value = nil
        store.reset()
        store.resume()
        XCTAssertNil(store.presented, "signed out → nothing to resume")
    }
}
