import Foundation
import SwiftUI
import XCTest
@testable import SousLens

/// Brief 005 iOS fix round 1 (coordinator items 1–15).
@MainActor
final class Slice3FixRoundTests: XCTestCase {
    private var service: FakeCookingService!
    private var oracle: FakeOracle!
    private var audio: FakeAudioOutput!
    private var clock = ISO8601Flexible.parse("2026-10-23T10:00:00Z")!

    override func setUp() async throws {
        service = FakeCookingService()
        audio = FakeAudioOutput()
        let fixed = clock
        oracle = FakeOracle(now: { fixed })
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
    }

    private func makeModel(initial: CookingSession? = nil, startOnOpen: Bool = false,
                           cautions: [String: SwapCaution] = [:]) -> CookingViewModel {
        CookingViewModel(sessionId: CookingFixtures.sessionUUID, initial: initial, startOnOpen: startOnOpen,
                         service: service, audio: audio, swapCautions: cautions, now: { [unowned self] in self.clock })
    }

    // MARK: 1 — stale state

    func testCachedInitialIsReadOnlyUntilTheFirstReadSettles() async throws {
        let latch = TestLatch()
        let slow = SlowReadService(inner: service, latch: latch)
        slow.armed.value = true
        let model = CookingViewModel(sessionId: CookingFixtures.sessionUUID, initial: try CookingFixtures.session(stepIndex: 0, revision: 1),
                                     service: slow, audio: audio)
        let loading = Task { await model.load() }
        while slow.entered == 0 { await Task.yield() }
        XCTAssertNotNil(model.session, "the cached copy paints immediately")
        XCTAssertTrue(model.isProvisional)
        XCTAssertFalse(model.canGoNext, "…but can't be acted on")
        await model.next()
        XCTAssertTrue(service.commands.isEmpty)
        await latch.open()
        await loading.value
        XCTAssertFalse(model.isProvisional)
        XCTAssertTrue(model.canGoNext)
    }

    func testFreshInitialFromStartCookingIsUsableAndPersisted() async throws {
        let reported = TestBox(0)
        oracle = FakeOracle(status: "created", revision: 0)
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        let model = makeModel(initial: try oracle.current(), startOnOpen: true)
        model.onSessionChanged = { _ in reported.value += 1 }
        await model.load()
        XCTAssertFalse(model.isProvisional)
        XCTAssertEqual(model.status, .active)
        XCTAssertGreaterThan(reported.value, 0)
    }

    func testRefreshIsSkippedWhileACommandIsInFlight() async throws {
        let latch = TestLatch()
        let gated = GatedCookingService(inner: service, latch: latch)
        let model = CookingViewModel(sessionId: CookingFixtures.sessionUUID, service: gated, audio: audio)
        await model.load()
        let reads = service.calls.filter { if case .session = $0 { return true } else { return false } }.count
        let next = Task { await model.next() }
        while gated.entered == 0 { await Task.yield() }
        await model.refresh()
        XCTAssertEqual(service.calls.filter { if case .session = $0 { return true } else { return false } }.count, reads)
        await latch.open()
        await next.value
    }

    // MARK: 4 — swap warnings stay visible

    func testCautionsShowOnTheAdaptedStepBadge() async throws {
        let caution = SwapCaution(allergyWarning: "contains sulfites", risks: ["A little sharper."], safetyNotice: "Recipe contains sesame.")
        let model = makeModel(cautions: ["ing-8": caution])
        await model.load()
        XCTAssertEqual(model.adaptedBadgeText, "Adapted · Common swap · Check the label: contains sulfites")
        XCTAssertEqual(model.adaptedCautionLines, ["A little sharper.", "Recipe contains sesame."])
        await model.next()
        XCTAssertTrue(model.adaptedCautionLines.isEmpty, "only on the adapted step")
    }

    func testApprovedSwapCarriesWarningsFromTheSheet() async throws {
        let cooking = FakeCookingService()
        cooking.suggestHandler = { _, _ in
            let json = CookingFixtures.substitutionsJSON.replacingOccurrences(of: #""safety_notice":null"#, with: #""safety_notice":"You listed sesame.""#)
            return try CookingFixtures.decode(SubstitutionResult.self, json)
        }
        let sheet = SubstitutionSheetViewModel(recipeVersionId: CookingFixtures.versionUUID, ingredientRef: "ing-8",
                                               ingredientName: "rice vinegar", service: cooking)
        await sheet.load()
        let swap = try XCTUnwrap(sheet.approve(suggestionId: try XCTUnwrap(UUID(uuidString: CookingFixtures.suggestionAiId))))
        XCTAssertNotNil(swap.caution.allergyWarning)
        XCTAssertEqual(swap.caution.safetyNotice, "You listed sesame.")

        let pantry = FakePantryService()
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        pantry.fitHandler = { _ in fit }
        let fitModel = PantryFitViewModel(recipeVersionId: fit.recipeVersionId, recipeTitle: "T", service: pantry, cooking: cooking)
        fitModel.approve(swap)
        XCTAssertEqual(fitModel.swapCautions["ing-8"], swap.caution, "handed to the cooking screen")

        let store = CookingSessionStore(service: cooking, cache: InMemorySessionCache(), owner: { SessionOwner(userId: UUID(), server: "s") })
        store.present(newSession: try CookingFixtures.session(status: "created", revision: 0), epoch: store.epoch, cautions: fitModel.swapCautions)
        XCTAssertEqual(store.presented?.swapCautions["ing-8"], swap.caution)
        store.closeCookingScreen()
        store.resume()
        XCTAssertEqual(store.presented?.swapCautions["ing-8"], swap.caution, "kept for a resume in the same run")
    }

    // MARK: 5 — Dynamic Type layout

    func testLayoutStacksAtAccessibilitySizes() {
        XCTAssertEqual(CookingLayout.forSize(.large), CookingLayout(stacksNavigation: false, toolColumns: 2, controlsScrollWithContent: false))
        XCTAssertEqual(CookingLayout.forSize(.xxxLarge), CookingLayout(stacksNavigation: false, toolColumns: 2, controlsScrollWithContent: false))
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            XCTAssertEqual(CookingLayout.forSize(size), CookingLayout(stacksNavigation: true, toolColumns: 2, controlsScrollWithContent: true), "\(size)")
        }
    }

    // MARK: 6 — no speech after close

    func testNoSpeechAfterTheCookingScreenCloses() async throws {
        let model = makeModel()
        await model.load()
        model.screenDidDisappear()
        XCTAssertEqual(audio.stopCount, 1)
        await model.next()
        await model.repeatStep()
        XCTAssertTrue(audio.spoken.isEmpty)
        model.screenDidAppear()
        await model.repeatStep()
        XCTAssertEqual(audio.spoken.count, 1)
    }

    func testNoSpeechAfterTheDrawerCloses() async throws {
        let ask = FakeCookingService()
        ask.askHandler = { _, revision in try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision)) }
        let drawer = AssistantViewModel(sessionId: CookingFixtures.sessionUUID, service: ask, audio: audio,
                                        currentSession: { try? CookingFixtures.session() })
        drawer.query = "q"
        await drawer.ask()
        drawer.drawerDidDisappear()
        await drawer.readAloud(turnId: drawer.turns[0].id)
        XCTAssertTrue(audio.spoken.isEmpty)
        XCTAssertEqual(audio.stopCount, 1)
    }

    // MARK: 7 — notes

    func testNoteIsNotPostedTwiceWhenDoneIsRetriedAndDraftSurvives() async throws {
        let model = makeModel()
        await model.load()
        let end = SessionEndViewModel(cooking: model)
        end.result = .cooked
        end.note = "Less salt"
        service.commandHandler = { _, _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        let first = await end.finish()
        XCTAssertFalse(first)
        XCTAssertTrue(end.showsReconnect)
        // The sheet closes and reopens: a new view model sees the same draft.
        let reopened = SessionEndViewModel(cooking: model)
        XCTAssertEqual(reopened.result, .cooked)
        XCTAssertEqual(reopened.note, "Less salt")
        let oracle = oracle!
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        await reopened.reconnect()   // re-sends the pending complete with its key
        let notes = service.calls.filter { if case .note = $0 { return true } else { return false } }
        XCTAssertEqual(notes.count, 1, "the note is posted once")
        XCTAssertTrue(model.isEnded)
    }

    func testDoneIsGuardedAgainstADoubleTap() async throws {
        let model = makeModel()
        await model.load()
        let latch = TestLatch()
        service.noteHandler = { text in SessionNote(id: UUID(), text: text, createdAt: Date()) }
        let gated = GatedCookingService(inner: service, latch: latch)
        let gatedModel = CookingViewModel(sessionId: CookingFixtures.sessionUUID, service: gated, audio: audio)
        await gatedModel.load()
        let first = Task { await gatedModel.complete(result: .cooked, saveChanges: false, note: "n") }
        while gated.entered == 0 { await Task.yield() }
        let second = await gatedModel.complete(result: .cooked, saveChanges: false, note: "n")
        XCTAssertFalse(second, "a second Done while the first is in flight does nothing")
        await latch.open()
        _ = await first.value
        XCTAssertEqual(service.calls.filter { if case .note = $0 { return true } else { return false } }.count, 1)
        _ = model
    }

    // MARK: 8 — proposals

    func testProposalSuppressedWhenRevisionMovedOrPausedAndSentAtGroundedRevision() async throws {
        let model = makeModel()
        await model.load()
        let ask = FakeCookingService()
        ask.askHandler = { _, revision in
            try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision, proposed: #"{"command":"start_timer","timer":{"label":"Rest","duration_seconds":300}}"#))
        }
        let drawer = AssistantViewModel(sessionId: CookingFixtures.sessionUUID, service: ask, audio: audio, currentSession: { model.session })
        drawer.onProposal = { await model.perform($0) }
        drawer.query = "q"
        await drawer.ask()
        XCTAssertNotNil(drawer.proposalTitle(for: drawer.turns[0]))
        await drawer.acceptProposal(turnId: drawer.turns[0].id)
        XCTAssertEqual(service.commands.last?.0.expectedRevision, 1, "expected_revision = grounded revision")

        // Revision moved (the timer started) without a step change → no button.
        drawer.query = "q2"
        await drawer.ask()   // grounded on revision 2
        oracle.externalNext()
        await model.refresh()
        XCTAssertNil(drawer.proposalTitle(for: drawer.turns[1]))
        let stale = try XCTUnwrap(drawer.turns[1].response.proposedAction)
        let sent = await model.perform(stale)
        XCTAssertFalse(sent, "a proposal for an older revision is never sent")

        await model.pause()
        drawer.query = "q3"
        await drawer.ask()
        XCTAssertNil(drawer.proposalTitle(for: drawer.turns[2]), "no proposals while paused")
    }

    // MARK: 9 — safety first when read

    func testReadAloudSpeaksTheSafetyNoticeFirst() async throws {
        let ask = FakeCookingService()
        ask.askHandler = { _, revision in
            try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision, safety: #""Use a thermometer.""#))
        }
        let drawer = AssistantViewModel(sessionId: CookingFixtures.sessionUUID, service: ask, audio: audio,
                                        currentSession: { try? CookingFixtures.session() })
        drawer.query = "is it done?"
        await drawer.ask()
        await drawer.readAloud(turnId: drawer.turns[0].id)
        XCTAssertTrue(audio.spoken.first?.hasPrefix("Use a thermometer. The recipe says") ?? false, audio.spoken.first ?? "")
    }

    // MARK: 10 — timer done

    func testTimerDoneIsAnnouncedOnceAndNotForAlreadyDoneTimers() async throws {
        let session = try CookingFixtures.session(stepIndex: 2, revision: 4, timers: [
            .init(id: CookingFixtures.timerId, targetAt: "2026-10-23T10:01:00Z"),
            .init(id: "70000000-0000-4000-8000-000000000002", label: "Rest", targetAt: "2026-10-23T09:59:00Z"),
        ])
        service.sessionHandler = { _ in session }
        let model = makeModel()
        await model.load()
        XCTAssertTrue(model.newlyFinishedTimers().isEmpty, "first look: Rest was already done when the screen opened")
        clock = clock.addingTimeInterval(30)
        XCTAssertTrue(model.newlyFinishedTimers().isEmpty)
        clock = clock.addingTimeInterval(31)
        XCTAssertEqual(model.newlyFinishedTimers().map(\.label), ["Simmer"])
        XCTAssertTrue(model.newlyFinishedTimers().isEmpty, "announced once")
    }

    // MARK: 11 — pending tap

    func testPendingTapIsNamedAndAStaleOneIsNotResentWithoutAsking() async throws {
        let model = makeModel()
        await model.load()
        service.commandHandler = { _, _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        await model.next()
        XCTAssertEqual(model.pendingTapText, "Your last tap (Next) wasn’t confirmed")
        clock = clock.addingTimeInterval(121)
        XCTAssertTrue(model.pendingTapIsStale)
        let oracle = oracle!
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        await model.reconnect()
        XCTAssertTrue(model.asksToResendStaleTap)
        XCTAssertEqual(service.commands.count, 1, "not re-sent without asking")
        await model.discardStaleTap()
        XCTAssertNil(model.sender.pending)
        XCTAssertEqual(service.commands.count, 1)
        XCTAssertFalse(model.isOffline)
        XCTAssertEqual(model.session?.stepIndex, 0)
    }

    func testStaleTapCanBeResentOnRequest() async throws {
        let model = makeModel()
        await model.load()
        service.commandHandler = { _, _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        await model.next()
        clock = clock.addingTimeInterval(300)
        let oracle = oracle!
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
        await model.reconnect()
        await model.resendStaleTap()
        XCTAssertEqual(service.commands.map(\.1).count, 2)
        XCTAssertEqual(service.commands[0].1, service.commands[1].1, "same key")
        XCTAssertEqual(model.session?.stepIndex, 1)
    }

    // MARK: 12 — backups

    func testSessionCacheIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "session-cache-\(UUID().uuidString)")
        let cache = SessionCache(directory: directory)
        let owner = SessionOwner(userId: UUID(), server: "s")
        try cache.save(try CookingFixtures.session(), owner: owner)
        let values = try cache.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertNotNil(cache.load(for: owner))
        try cache.clear()
    }

    // MARK: 15 — server safety additions

    func testUnrecognizedPreferencesAreFlaggedUntilRemoved() async throws {
        let service = FakeCookingService()
        service.updatePreferencesHandler = { prefs in
            FoodPreferences(allergies: prefs.allergies.flatMap { $0 == "tree nuts, peanuts" ? ["tree nut", "peanut"] : [$0] },
                            avoid: prefs.avoid, unrecognized: prefs.allergies.filter { $0 == "zorbleberry" })
        }
        let model = PreferencesViewModel(service: service)
        await model.load()
        model.allergyDraft = "tree nuts, peanuts"
        await model.add(.allergies)
        XCTAssertEqual(model.entries(.allergies), ["tree nut", "peanut"], "renders whatever split the server returns")
        model.allergyDraft = "zorbleberry"
        await model.add(.allergies)
        XCTAssertEqual(model.unrecognizedEntries(.allergies), ["zorbleberry"])
        XCTAssertTrue(PreferencesViewModel.unrecognizedMessage("zorbleberry").hasPrefix("We don’t recognise “zorbleberry”, so swaps can’t check for it"))
        await model.remove(.allergies, at: 2)
        XCTAssertTrue(model.unrecognizedEntries(.allergies).isEmpty)
        let decoded = try CookingFixtures.decode(FoodPreferences.self, #"{"allergies":["x"],"avoid":[],"updated_at":null,"unrecognized":["x"]}"#)
        XCTAssertEqual(decoded.unrecognized, ["x"])
    }

    func testAllergyConflictOnAnAdaptationFlagsTheStepAndBlocksSaving() async throws {
        let json = try CookingFixtures.sessionJSON().replacingOccurrences(of: #""reason":"rice vinegar unavailable","#,
                                                                          with: #""reason":"rice vinegar unavailable","conflicts_with_allergies":true,"#)
        let session = try CookingFixtures.decode(CookingSession.self, json)
        XCTAssertTrue(session.adaptations[0].conflictsWithAllergies)
        XCTAssertFalse(try CookingFixtures.session().adaptations[0].conflictsWithAllergies, "absent → false")
        service.sessionHandler = { _ in session }
        service.commandHandler = { command, _ in
            try CookingFixtures.decode(CookingSession.self, json.replacingOccurrences(of: #""status":"active""#, with: #""status":"completed""#)
                .replacingOccurrences(of: #""revision":1"#, with: #""revision":2"#))
        }
        let model = makeModel()
        await model.load()
        XCTAssertEqual(model.conflictingAdaptations.map(\.id), [session.adaptations[0].id])
        let end = SessionEndViewModel(cooking: model)
        XCTAssertTrue(end.hasAllergyConflict)
        XCTAssertFalse(end.canSaveChanges)
        end.result = .cooked
        end.saveChanges = true
        _ = await end.finish()
        XCTAssertEqual(service.commands.last?.0.outcome, OutcomeInput(result: .cooked, saveChanges: false))
    }
}
