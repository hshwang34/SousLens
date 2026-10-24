import Foundation
import XCTest
@testable import SousLens

/// 409 `open_session_ids` → "too many unfinished cooks"; 429 on create.
@MainActor
final class SessionStarterTests: XCTestCase {
    private let blockerA = CookingFixtures.sessionId
    private let blockerB = CookingFixtures.otherSessionId
    private let newSessionId = "7e1f0c2a-4b3d-4e5f-8a9b-0c1d2e3f5099"

    private func tooManyOpen() throws -> APIError {
        try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT", message: "Too many open sessions.",
                                     details: #"{"open_session_ids":["\#(blockerA)","\#(blockerB)"]}"#)
    }

    /// Server: create fails while more than `allowedOpen` blockers are open; abandoned ids leave the list.
    private func makeService(blockingUntilOpenAtMost allowedOpen: Int) throws -> (FakeCookingService, TestBox<Set<String>>) {
        let service = FakeCookingService()
        let abandoned = TestBox<Set<String>>([])
        let a = blockerA, b = blockerB, newId = newSessionId
        let conflict = try tooManyOpen()
        service.createHandler = { _, _ in
            if 2 - abandoned.value.count > allowedOpen { throw conflict }
            return try CookingFixtures.session(id: newId, status: "created", revision: 0)
        }
        service.activeHandler = {
            let all = [
                try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: a, stepIndex: 2)),
                try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: b, stepIndex: 2)),
                try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: "7e1f0c2a-4b3d-4e5f-8a9b-0c1d2e3f5003")),
            ]
            return all.filter { !abandoned.value.contains($0.id.uuidString.lowercased()) }
        }
        service.sessionHandler = { id in try CookingFixtures.session(id: id.uuidString.lowercased(), stepIndex: 2, revision: 5) }
        service.commandHandler = { command, _ in
            XCTAssertEqual(command.command, .abandon)
            return try CookingFixtures.session(status: "abandoned", stepIndex: 2, revision: command.expectedRevision + 1)
        }
        // Tests mark which blocker the server should treat as stopped (the fake has no session id).
        return (service, abandoned)
    }

    func testOpenSessionIdsAreReadFromDetails() throws {
        XCTAssertEqual(try tooManyOpen().openSessionIds?.map { $0.uuidString.lowercased() }, [blockerA, blockerB])
        XCTAssertNil(try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT").openSessionIds)
    }

    func testConflictListsOnlyTheBlockingSessions() async throws {
        let (service, _) = try makeService(blockingUntilOpenAtMost: 0)
        let starter = SessionStarter(service: service)
        let session = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [], epoch: 3)
        XCTAssertNil(session)
        XCTAssertTrue(starter.showsUnfinished)
        XCTAssertEqual(starter.unfinished.map { $0.id.uuidString.lowercased() }, [blockerA, blockerB])
        XCTAssertNil(starter.errorMessage)
        XCTAssertEqual(starter.initiatedEpoch, 3, "epoch captured at the Start tap")
    }

    func testStartIsRetriedAfterEachAbandonAndAnother409KeepsTheSheet() async throws {
        let (service, abandoned) = try makeService(blockingUntilOpenAtMost: 0)
        let minter = KeyMinter()
        let starter = SessionStarter(service: service, makeKey: { minter.next() })
        let swaps = [AdaptationInput.suggestion(try XCTUnwrap(UUID(uuidString: CookingFixtures.suggestionRuleId)), ingredientRef: "ing-8")]
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: swaps, epoch: 1)

        abandoned.value.insert(blockerA)   // the server will see A as stopped after this abandon
        await starter.abandon(starter.unfinished[0])
        let creates = { service.calls.compactMap { if case .create(_, let a) = $0 { return a } else { return nil } } }
        XCTAssertEqual(creates().count, 2, "retried right after the first stop")
        XCTAssertTrue(starter.showsUnfinished, "another 409 keeps the sheet open")
        XCTAssertEqual(starter.unfinished.map { $0.id.uuidString.lowercased() }, [blockerB], "list refreshed from the server")
        XCTAssertNil(starter.takeOutcome())

        abandoned.value.insert(blockerB)
        await starter.abandon(starter.unfinished[0])
        XCTAssertEqual(creates(), [swaps, swaps, swaps], "same version and swaps every time")
        XCTAssertFalse(starter.showsUnfinished, "sheet dismisses…")
        guard case .started(let session) = starter.takeOutcome() else { return XCTFail("no started outcome") }
        XCTAssertEqual(session.id.uuidString.lowercased(), newSessionId, "…and the parent presents from onDismiss")
        XCTAssertNil(starter.takeOutcome(), "read once")

        XCTAssertEqual(service.commands.map(\.1), ["key-1", "key-2"], "a fresh key per stop")
        XCTAssertTrue(service.commands.allSatisfy { $0.0.userConfirmed && $0.0.expectedRevision == 5 })
    }

    func testFirstAbandonEnoughStartsImmediately() async throws {
        let (service, abandoned) = try makeService(blockingUntilOpenAtMost: 1)
        let starter = SessionStarter(service: service)
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [], epoch: 1)
        abandoned.value.insert(blockerA)
        await starter.abandon(starter.unfinished[0])
        XCTAssertFalse(starter.showsUnfinished)
        if case .started = starter.takeOutcome() {} else { XCTFail("expected a start after one stop") }
    }

    func testChangedSessionIsRefreshedAndReconfirmedInsteadOfAbandoned() async throws {
        let (service, _) = try makeService(blockingUntilOpenAtMost: 0)
        // Another device cooked on: the server is at step 4 now.
        service.sessionHandler = { id in try CookingFixtures.session(id: id.uuidString.lowercased(), stepIndex: 4, revision: 8) }
        let starter = SessionStarter(service: service)
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [], epoch: 1)
        let shown = starter.unfinished[0]
        await starter.abandon(shown)
        XCTAssertTrue(service.commands.isEmpty, "nothing stopped without a fresh confirmation")
        XCTAssertTrue(starter.changedSessionIds.contains(shown.id))
        XCTAssertEqual(starter.errorMessage, SessionStarter.changedMessage)
        XCTAssertEqual(starter.unfinished[0].stepIndex, 4, "row shows the server's latest")
        await starter.abandon(starter.unfinished[0])   // confirmed again on the refreshed row
        XCTAssertEqual(service.commands.count, 1)
        XCTAssertEqual(service.commands.first?.0.expectedRevision, 8)
    }

    /// M6: a stale revision on abandon is shown to the user and re-confirmed, never re-sent silently.
    func testStaleRevisionOnAbandonAsksAgainInsteadOfRetrying() async throws {
        let (service, _) = try makeService(blockingUntilOpenAtMost: 0)
        let attempts = TestCounter()
        service.commandHandler = { command, _ in
            if attempts.next() == 1 {
                throw try CookingFixtures.conflict(latest: CookingFixtures.sessionJSON(stepIndex: 3, revision: 9))
            }
            XCTAssertEqual(command.expectedRevision, 9)
            return try CookingFixtures.session(status: "abandoned", revision: 10)
        }
        let minter = KeyMinter()
        let starter = SessionStarter(service: service, makeKey: { minter.next() })
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        let row = starter.unfinished[0]
        await starter.abandon(row)
        XCTAssertEqual(minter.minted, ["key-1"], "no silent second abandon")
        XCTAssertTrue(starter.changedSessionIds.contains(row.id))
        XCTAssertEqual(starter.unfinished[0].stepIndex, 3, "row shows the newer state")
        XCTAssertEqual(starter.errorMessage, SessionStarter.changedMessage)
        // The user confirms again on the refreshed row → the server's step 3 / rev 9.
        service.sessionHandler = { id in try CookingFixtures.session(id: id.uuidString.lowercased(), stepIndex: 3, revision: 9) }
        await starter.abandon(starter.unfinished[0])
        XCTAssertEqual(minter.minted, ["key-1", "key-2"])
    }

    func testResumeChoiceDropsThePendingStartAndIsPresentedOnDismiss() async throws {
        let (service, _) = try makeService(blockingUntilOpenAtMost: 0)
        let starter = SessionStarter(service: service)
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        let id = starter.unfinished[1].id
        starter.chooseResume(id)
        XCTAssertFalse(starter.showsUnfinished)
        XCTAssertEqual(starter.takeOutcome(), .resume(id))
        XCTAssertTrue(service.commands.isEmpty, "nothing abandoned")
    }

    func testCancelDropsEverything() async throws {
        let (service, _) = try makeService(blockingUntilOpenAtMost: 0)
        let starter = SessionStarter(service: service)
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        starter.dismissUnfinished()
        XCTAssertFalse(starter.showsUnfinished)
        XCTAssertNil(starter.takeOutcome())
    }

    func testRateLimitedCreateExplains() async throws {
        let service = FakeCookingService()
        service.createHandler = { _, _ in throw try CookingFixtures.apiError(status: 429, code: "RATE_LIMITED") }
        let starter = SessionStarter(service: service)
        let session = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        XCTAssertNil(session)
        XCTAssertEqual(starter.errorMessage, SessionStarter.rateLimitedMessage)
        XCTAssertFalse(starter.showsUnfinished)
    }

    func testCopyHasNoHardCodedLimit() {
        let summary = try? CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON())
        XCTAssertEqual(summary.map(UnfinishedCooksSheet.stepText), "At step 3 of 7")
        let source = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SousLens/Features/Cooking/UnfinishedCooksSheet.swift"), encoding: .utf8)) ?? ""
        XCTAssertFalse(source.contains("up to 3"))
        XCTAssertTrue(source.contains("too many unfinished cooks"))
        XCTAssertTrue(source.contains("Stop this cook?"))
    }

    func testFitScreenStartUsesTheStarter() async throws {
        let (cooking, _) = try makeService(blockingUntilOpenAtMost: 0)
        let pantry = FakePantryService()
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        pantry.fitHandler = { _ in fit }
        let model = PantryFitViewModel(recipeVersionId: fit.recipeVersionId, recipeTitle: "T", service: pantry, cooking: cooking)
        await model.load()
        let session = await model.startCooking(epoch: 4)
        XCTAssertNil(session)
        XCTAssertEqual(model.starter?.unfinished.count, 2)
        XCTAssertEqual(model.starter?.initiatedEpoch, 4)
    }

    func testStoreResumeBySessionId() throws {
        let store = CookingSessionStore(service: FakeCookingService(), cache: InMemorySessionCache(),
                                        owner: { SessionOwner(userId: UUID(), server: "s") })
        store.resume(sessionId: CookingFixtures.sessionUUID)
        XCTAssertEqual(store.presented?.sessionId, CookingFixtures.sessionUUID)
        XCTAssertEqual(store.presented?.startOnOpen, false)
    }
}
