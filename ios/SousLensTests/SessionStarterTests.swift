import Foundation
import XCTest
@testable import SousLens

/// Addendum: 409 `open_session_ids` → "You have unfinished cooks"; 429 on create.
@MainActor
final class SessionStarterTests: XCTestCase {
    private let blockerA = CookingFixtures.sessionId
    private let blockerB = CookingFixtures.otherSessionId

    private func tooManyOpen() throws -> APIError {
        try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT", message: "Too many open sessions.",
                                     details: #"{"open_session_ids":["\#(blockerA)","\#(blockerB)"]}"#)
    }

    private func makeService(createFailures: Int) throws -> FakeCookingService {
        let service = FakeCookingService()
        let remaining = TestBox(createFailures)
        let conflict = try tooManyOpen()
        service.createHandler = { _, _ in
            if remaining.value > 0 { remaining.value -= 1; throw conflict }
            return try CookingFixtures.session(id: "7e1f0c2a-4b3d-4e5f-8a9b-0c1d2e3f5099", status: "created", revision: 0)
        }
        let a = blockerA, b = blockerB
        service.activeHandler = {
            [try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: a, stepIndex: 2)),
             try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: b, status: "paused", stepIndex: 0)),
             try CookingFixtures.decode(SessionSummary.self, CookingFixtures.summaryJSON(id: "7e1f0c2a-4b3d-4e5f-8a9b-0c1d2e3f5003"))]
        }
        service.sessionHandler = { id in try CookingFixtures.session(id: id.uuidString.lowercased(), stepIndex: 2, revision: 5) }
        service.commandHandler = { command, _ in
            XCTAssertEqual(command.command, .abandon)
            return try CookingFixtures.session(status: "abandoned", stepIndex: 2, revision: command.expectedRevision + 1)
        }
        return service
    }

    func testOpenSessionIdsAreReadFromDetails() throws {
        XCTAssertEqual(try tooManyOpen().openSessionIds?.map { $0.uuidString.lowercased() }, [blockerA, blockerB])
        XCTAssertNil(try CookingFixtures.apiError(status: 409, code: "STATE_CONFLICT").openSessionIds)
    }

    func testConflictListsOnlyTheBlockingSessions() async throws {
        let service = try makeService(createFailures: 1)
        let starter = SessionStarter(service: service)
        let session = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        XCTAssertNil(session)
        XCTAssertTrue(starter.showsUnfinished)
        XCTAssertEqual(starter.unfinished.map { $0.id.uuidString.lowercased() }, [blockerA, blockerB])
        XCTAssertNil(starter.errorMessage)
    }

    func testAbandonEachWithAFreshConfirmedKeyThenStartIsRetried() async throws {
        let service = try makeService(createFailures: 1)
        let minter = KeyMinter()
        let starter = SessionStarter(service: service, makeKey: { minter.next() })
        let swaps = [AdaptationInput.suggestion(try XCTUnwrap(UUID(uuidString: CookingFixtures.suggestionRuleId)), ingredientRef: "ing-8")]
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: swaps)

        let first = await starter.abandon(starter.unfinished[0])
        XCTAssertNil(first, "one blocker left: no retry yet")
        XCTAssertEqual(starter.unfinished.count, 1)
        let started = await starter.abandon(starter.unfinished[0])
        XCTAssertEqual(started?.status, .created, "start retried after the last blocker is gone")
        XCTAssertFalse(starter.showsUnfinished)

        let abandons = service.commands
        XCTAssertEqual(abandons.count, 2)
        XCTAssertEqual(abandons.map(\.1), ["key-1", "key-2"], "a fresh key per abandon")
        XCTAssertTrue(abandons.allSatisfy { $0.0.userConfirmed && $0.0.expectedRevision == 5 })
        let creates = service.calls.compactMap { if case .create(_, let a) = $0 { return a } else { return nil } }
        XCTAssertEqual(creates, [swaps, swaps], "the retry sends the same version and swaps")
    }

    func testAbandonRetriesOnceOnStaleRevision() async throws {
        let service = try makeService(createFailures: 1)
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
        _ = await starter.abandon(starter.unfinished[0])
        XCTAssertEqual(starter.unfinished.count, 1, "abandoned after the retry")
        XCTAssertEqual(minter.minted, ["key-1", "key-2"], "the corrected body gets its own key")
    }

    func testResumeChoiceDropsThePendingStart() async throws {
        let service = try makeService(createFailures: 1)
        let starter = SessionStarter(service: service)
        _ = await starter.start(recipeVersionId: CookingFixtures.versionUUID, adaptations: [])
        starter.dismissUnfinished()
        XCTAssertFalse(starter.showsUnfinished)
        XCTAssertTrue(service.commands.isEmpty, "nothing abandoned")
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

    func testFitScreenStartUsesTheStarter() async throws {
        let cooking = try makeService(createFailures: 1)
        let pantry = FakePantryService()
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        pantry.fitHandler = { _ in fit }
        let model = PantryFitViewModel(recipeVersionId: fit.recipeVersionId, recipeTitle: "T", service: pantry, cooking: cooking)
        await model.load()
        let session = await model.startCooking()
        XCTAssertNil(session)
        XCTAssertEqual(model.starter?.unfinished.count, 2)
    }

    func testStoreResumeBySessionId() throws {
        let store = CookingSessionStore(service: FakeCookingService(), cache: InMemorySessionCache(),
                                        owner: { SessionOwner(userId: UUID(), server: "s") })
        store.resume(sessionId: CookingFixtures.sessionUUID)
        XCTAssertEqual(store.presented?.sessionId, CookingFixtures.sessionUUID)
        XCTAssertEqual(store.presented?.startOnOpen, false)
    }
}
