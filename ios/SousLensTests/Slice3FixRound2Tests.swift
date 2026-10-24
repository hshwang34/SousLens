import Foundation
import XCTest
@testable import SousLens

/// Brief 005 iOS fix round 2 (H1, H2, M1–M6, L3).
@MainActor
final class Slice3FixRound2Tests: XCTestCase {
    private var service: FakeCookingService!
    private var oracle: FakeOracle!
    private var audio: FakeAudioOutput!
    private var minter: KeyMinter!
    private var clock = ISO8601Flexible.parse("2026-10-23T10:00:00Z")!

    override func setUp() async throws {
        service = FakeCookingService()
        audio = FakeAudioOutput()
        minter = KeyMinter()
        let fixed = clock
        oracle = FakeOracle(now: { fixed })
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
    }

    private func makeModel(initial: CookingSession? = nil) -> CookingViewModel {
        let minter = minter!
        return CookingViewModel(sessionId: CookingFixtures.sessionUUID, initial: initial, service: service, audio: audio,
                                makeKey: { minter.next() }, now: { [unowned self] in self.clock })
    }

    // MARK: H1 — pending Done

    func testPendingCompleteLocksEditsAndStalePromptIsInTheSheet() async throws {
        let model = makeModel()
        await model.load()
        let end = SessionEndViewModel(cooking: model)
        end.result = .cooked
        end.note = "first"
        service.commandHandler = { _, _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        _ = await end.finish()
        XCTAssertTrue(end.editsLocked, "the Done's body is fixed while unconfirmed")
        end.result = .didntWork
        end.note = "changed"
        end.saveChanges = true
        XCTAssertEqual(end.result, .cooked)
        XCTAssertEqual(end.note, "first")
        XCTAssertFalse(end.saveChanges)

        // Two minutes later the sheet's Reconnect asks first, like the banner.
        clock = clock.addingTimeInterval(180)
        let oracle = oracle!
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        await end.reconnect()
        XCTAssertTrue(end.asksToResendStaleTap)
        XCTAssertEqual(service.commands.count, 1, "nothing re-sent without asking")

        // Discard → editable again; Done sends the CURRENT draft under a NEW key.
        await end.discardStaleTap()
        XCTAssertFalse(end.editsLocked)
        end.result = .partly
        end.saveChanges = true
        let done = await end.finish()
        XCTAssertTrue(done)
        let complete = try XCTUnwrap(service.commands.last)
        XCTAssertEqual(complete.0.outcome, OutcomeInput(result: .partly, saveChanges: true))
        XCTAssertNotEqual(complete.1, service.commands[0].1, "new body → new key")
    }

    func testDoneWhileACompleteIsPendingResendsThatSameOne() async throws {
        let model = makeModel()
        await model.load()
        let end = SessionEndViewModel(cooking: model)
        end.result = .cooked
        service.commandHandler = { _, _ in throw APIError.http(status: 502, correlationId: nil) }
        _ = await end.finish()
        let oracle = oracle!
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        XCTAssertTrue(end.canFinish, "Done stays available to re-send the pending one")
        let done = await end.finish()
        XCTAssertTrue(done)
        XCTAssertEqual(service.commands.map(\.1), ["key-1", "key-1"], "same key, same body")
    }

    // MARK: H2 — unfinished-cooks attempts

    private func blockedStarter() async throws -> (SessionStarter, FakeCookingService) {
        let cooking = FakeCookingService()
        let conflict = try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT",
                                                    details: #"{"open_session_ids":["\#(CookingFixtures.sessionId)"]}"#)
        cooking.createHandler = { _, _ in throw conflict }
        cooking.activeHandler = { [try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(stepIndex: 2))] }
        cooking.sessionHandler = { _ in try CookingFixtures.session(stepIndex: 2, revision: 5) }
        cooking.commandHandler = { _, _ in try CookingFixtures.session(status: "abandoned", stepIndex: 2, revision: 6) }
        let starter = SessionStarter(service: cooking)
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [], epoch: 1)
        return (starter, cooking)
    }

    func testBusyWhileAbandonAndALateResultFromADismissedAttemptIsDropped() async throws {
        let (_, cooking) = try await blockedStarter()
        let latch = TestLatch()
        let gated = GatedCookingService(inner: cooking, latch: latch)
        // Swap in a starter on the gated service with the same blocked state.
        let gatedStarter = SessionStarter(service: gated)
        cooking.createHandler = { _, _ in throw try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT",
                                                                              details: #"{"open_session_ids":["\#(CookingFixtures.sessionId)"]}"#) }
        let loading = Task { await gatedStarter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: []) }
        while gated.entered == 0 { await Task.yield() }     // parked in activeSessions
        XCTAssertTrue(gatedStarter.isBusy, "Cancel and swipe-down are disabled")
        gatedStarter.dismissUnfinished()                     // (simulates a dismiss that slipped through)
        await latch.open()
        _ = await loading.value
        XCTAssertFalse(gatedStarter.showsUnfinished, "the dismissed attempt's list never appears")
        XCTAssertNil(gatedStarter.takeOutcome())
    }

    func testStartSucceedingAfterDismissNeverBecomesOutcome() async throws {
        let (_, cooking) = try await blockedStarter()
        let latch = TestLatch()
        let slowCreate = SlowCreateService(inner: cooking, latch: latch)
        let starter = SessionStarter(service: slowCreate)
        cooking.createHandler = { _, _ in try CookingFixtures.session(status: "created", revision: 0) }
        // Bring the sheet up first (409), then let the retry hang.
        slowCreate.firstFails = true
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        XCTAssertTrue(starter.showsUnfinished)
        let stopping = Task { await starter.abandon(starter.unfinished[0]) }
        while slowCreate.parked == 0 { await Task.yield() }
        XCTAssertTrue(starter.isBusy)
        starter.chooseResume(CookingFixtures.sessionUUID)    // refused while busy
        XCTAssertNil(starter.takeOutcome())
        starter.dismissUnfinished()                          // a forced dismissal bumps the generation
        await latch.open()
        await stopping.value
        XCTAssertNil(starter.takeOutcome(), "a start from a cancelled attempt is dropped")
    }

    // MARK: M4 — serialized abandons

    func testOnlyOneAbandonAtATime() async throws {
        let cooking = FakeCookingService()
        let ids = [CookingFixtures.sessionId, CookingFixtures.otherSessionId]
        cooking.createHandler = { _, _ in throw try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT",
                                                                               details: #"{"open_session_ids":["\#(ids[0])","\#(ids[1])"]}"#) }
        cooking.activeHandler = { try ids.map { try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: $0, stepIndex: 2)) } }
        cooking.sessionHandler = { id in try CookingFixtures.session(id: id.uuidString.lowercased(), stepIndex: 2, revision: 5) }
        cooking.commandHandler = { _, _ in try CookingFixtures.session(status: "abandoned", revision: 6) }
        let latch = TestLatch()
        let slow = SlowReadService(inner: cooking, latch: latch)
        let starter = SessionStarter(service: slow)
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        let rows = starter.unfinished
        XCTAssertEqual(rows.count, 2)
        slow.armed.value = true                              // the abandon's session read parks
        let first = Task { await starter.abandon(rows[0]) }
        while slow.entered == 0 { await Task.yield() }
        XCTAssertEqual(starter.abandoningId, rows[0].id)
        await starter.abandon(rows[1])                       // ignored while the first is in flight
        slow.armed.value = false
        await latch.open()
        await first.value
        XCTAssertEqual(cooking.commands.count, 1, "the second row's stop never started")
        XCTAssertEqual(cooking.calls.filter { if case .session = $0 { return true } else { return false } }.count, 1)
    }

    // MARK: M6 — 409 refresh marks changed rows

    func testAnother409MarksRowsThatChanged() async throws {
        let cooking = FakeCookingService()
        let a = CookingFixtures.sessionId, b = CookingFixtures.otherSessionId
        cooking.createHandler = { _, _ in throw try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT",
                                                                               details: #"{"open_session_ids":["\#(a)","\#(b)"]}"#) }
        let bStep = TestBox(2)
        cooking.activeHandler = {
            [try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: a, stepIndex: 2)),
             try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: b, stepIndex: bStep.value))]
        }
        let starter = SessionStarter(service: cooking)
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        XCTAssertTrue(starter.changedSessionIds.isEmpty)
        bStep.value = 5                                       // B moved on another device
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        XCTAssertEqual(starter.changedSessionIds, [try XCTUnwrap(UUID(uuidString: b))])
    }

    // MARK: M1 — first read of a cached copy fails

    func testNotFoundOnFirstReadSaysGoneAndClearsTheCache() async throws {
        let cache = InMemorySessionCache()
        let owner = SessionOwner(userId: UUID(), server: "s")
        let cached = try CookingFixtures.session(stepIndex: 2, revision: 3)
        try cache.save(cached, owner: owner)
        let store = CookingSessionStore(service: service, cache: cache, owner: { owner })
        store.sessionChanged(cached, epoch: store.epoch)
        service.sessionHandler = { _ in throw try CookingFixtures.apiError(status: 404, code: "NOT_FOUND") }
        let model = makeModel(initial: cached)
        let epoch = store.epoch
        model.onSessionGone = { store.sessionGone($0, epoch: epoch) }
        await model.load()
        XCTAssertEqual(model.phase, .gone(CookingViewModel.goneMessage))
        XCTAssertNil(model.session, "the cached copy is not left on screen")
        XCTAssertNil(cache.raw, "removed from the cache")
        XCTAssertNil(store.active)
    }

    func testOtherErrorOnFirstReadOffersRetry() async throws {
        let cached = try CookingFixtures.session(stepIndex: 2, revision: 3)
        service.sessionHandler = { _ in throw try CookingFixtures.apiError(status: 500, code: "INTERNAL", message: "Something broke") }
        let model = makeModel(initial: cached)
        await model.load()
        XCTAssertEqual(model.phase, .failed("Something broke"), "not stuck read-only: an error with Try again")
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.isProvisional)
    }

    // MARK: M2 — note idempotency key

    func testNoteKeyIsReusedForTheSameTextAndNewForNewText() async throws {
        let model = makeModel()
        await model.load()
        let fail = TestBox(true)
        service.noteHandler = { text in
            if fail.value { fail.value = false; throw APIError.unreachable(baseURL: "x", underlying: "lost") }
            return SessionNote(id: UUID(), text: text, createdAt: Date())
        }
        _ = await model.complete(result: .cooked, saveChanges: false, note: "Less salt")
        await model.refresh()   // back online
        _ = await model.complete(result: .cooked, saveChanges: false, note: "Less salt")
        XCTAssertEqual(service.noteKeys.count, 2)
        XCTAssertEqual(service.noteKeys[0], service.noteKeys[1], "same draft text → same key on retry")
    }

    func testEditedNoteGetsANewKey() async throws {
        let model = makeModel()
        await model.load()
        service.noteHandler = { _ in throw APIError.unreachable(baseURL: "x", underlying: "lost") }
        _ = await model.complete(result: .cooked, saveChanges: false, note: "one")
        await model.refresh()
        _ = await model.complete(result: .cooked, saveChanges: false, note: "two")
        XCTAssertEqual(service.noteKeys.count, 2)
        XCTAssertNotEqual(service.noteKeys[0], service.noteKeys[1])
    }

    // MARK: M3 — cautions from the Session

    func testAdaptationCautionsComeFromTheSessionAfterRelaunch() async throws {
        let json = try CookingFixtures.sessionJSON().replacingOccurrences(
            of: #""reason":"rice vinegar unavailable","#,
            with: #""reason":"rice vinegar unavailable","allergy_warning":"May contain sulfites.","risks":["Sharper."],"#)
        let session = try CookingFixtures.decode(CookingSession.self, json)
        XCTAssertEqual(session.adaptations[0].allergyWarning, "May contain sulfites.")
        XCTAssertEqual(session.adaptations[0].risks, ["Sharper."])
        let lenient = try CookingFixtures.decode(CookingSession.self, try CookingFixtures.sessionJSON().replacingOccurrences(
            of: #""reason":"rice vinegar unavailable","#, with: #""reason":"rice vinegar unavailable","allergy_warning":7,"risks":"oops","#))
        XCTAssertNil(lenient.adaptations[0].allergyWarning, "wrong types decode to no caution")
        XCTAssertEqual(lenient.adaptations[0].risks, [])

        service.sessionHandler = { _ in session }
        let model = makeModel()   // no in-memory sheet cautions (fresh launch)
        await model.load()
        XCTAssertEqual(model.adaptedBadgeText, "Adapted · Common swap · Check the label: May contain sulfites.")
        XCTAssertEqual(model.adaptedCautionLines, ["Sharper."])

        let withSheet = CookingViewModel(sessionId: CookingFixtures.sessionUUID, service: service, audio: audio,
                                         swapCautions: ["ing-8": SwapCaution(risks: ["Sharper.", "Add sugar."], safetyNotice: "Recipe has sesame.")])
        await withSheet.load()
        XCTAssertEqual(withSheet.adaptedCautionLines, ["Sharper.", "Add sugar.", "Recipe has sesame."], "sheet notice is an addition")
    }

    // MARK: M5 — unchecked allergies in the swap sheet

    func testSwapSheetSaysWhichAllergiesCantBeChecked() async throws {
        let cooking = FakeCookingService()
        cooking.suggestHandler = { _, _ in try CookingFixtures.decode(SubstitutionResult.self, CookingFixtures.substitutionsJSON) }
        cooking.preferencesHandler = { FoodPreferences(allergies: ["peanut", "zorbleberry"], avoid: ["glorp"], unrecognized: ["zorbleberry", "glorp"]) }
        let sheet = SubstitutionSheetViewModel(recipeVersionId: CookingFixtures.versionUUID, ingredientRef: "ing-8",
                                               ingredientName: "rice vinegar", service: cooking, preferences: cooking)
        await sheet.load()
        XCTAssertEqual(sheet.uncheckedAllergiesNotice, "Some of your allergies can’t be checked: zorbleberry. Check labels yourself.")
        XCTAssertNil(SubstitutionSheetViewModel.uncheckedNotice(FoodPreferences(allergies: ["peanut"])))
    }

    // MARK: L3 — timers

    func testAlreadyDoneBaselineIsSetFromTheFirstSessionAndCancelOnDoneIsANoOp() async throws {
        let session = try CookingFixtures.session(stepIndex: 2, revision: 4, timers: [.init(targetAt: "2026-10-23T09:59:00Z")])
        service.sessionHandler = { _ in session }
        let model = makeModel()
        await model.load()
        clock = clock.addingTimeInterval(5)
        XCTAssertTrue(model.newlyFinishedTimers().isEmpty, "done before the screen opened: never announced")
        await model.cancelTimer(id: try XCTUnwrap(UUID(uuidString: CookingFixtures.timerId)))
        XCTAssertTrue(service.commands.isEmpty, "no cancel_timer for a finished timer")
        XCTAssertEqual(model.toast, CookingViewModel.timerAlreadyDoneToast)
    }

    // MARK: L4

    func testCacheDirectoryIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-dir-\(UUID().uuidString)")
        let cache = SessionCache(directory: directory)
        try cache.save(try CookingFixtures.session(), owner: SessionOwner(userId: UUID(), server: "s"))
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// `createSession` fails once (409) when `firstFails`, then parks the next call until the latch opens.
final class SlowCreateService: CookingService, @unchecked Sendable {
    let inner: FakeCookingService
    let latch: TestLatch
    var firstFails = false
    private let counter = TestBox(0)
    private let parkedBox = TestBox(0)
    var parked: Int { parkedBox.value }

    init(inner: FakeCookingService, latch: TestLatch) {
        self.inner = inner
        self.latch = latch
    }

    func suggestSubstitutions(recipeVersionId: UUID, ingredientRef: String) async throws -> SubstitutionResult {
        try await inner.suggestSubstitutions(recipeVersionId: recipeVersionId, ingredientRef: ingredientRef)
    }
    func createSession(recipeVersionId: UUID, adaptations: [AdaptationInput]) async throws -> CookingSession {
        counter.value += 1
        if firstFails, counter.value == 1 {
            throw try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT", details: #"{"open_session_ids":["\#(CookingFixtures.sessionId)"]}"#)
        }
        parkedBox.value += 1
        await latch.wait()
        return try await inner.createSession(recipeVersionId: recipeVersionId, adaptations: adaptations)
    }
    func activeSessions() async throws -> [SessionSummary] { try await inner.activeSessions() }
    func session(id: UUID) async throws -> CookingSession { try await inner.session(id: id) }
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
