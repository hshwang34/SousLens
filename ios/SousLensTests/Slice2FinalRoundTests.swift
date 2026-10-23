import Foundation
import XCTest
@testable import SousLens

/// Fix round 2: press/release ordering and 404 disambiguation.
@MainActor
final class Slice2PushToTalkOrderingTests: XCTestCase {
    func testReleaseBeforeQueuedStartRunsNeverStartsMic() async {
        let speech = FakeSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        let latch = TestLatch()
        // Exactly what the gesture does: token now, start in a Task that hasn't run yet.
        let token = model.pressBegan()
        XCTAssertNotNil(token)
        XCTAssertTrue(model.isStarting)
        let queued = Task {
            await latch.wait()
            await model.beginListening(token: token)
        }
        model.endListening()                 // finger lifted before the Task body ran
        await latch.open()
        await queued.value
        XCTAssertEqual(speech.startCount, 0, "startListening is never called")
        XCTAssertFalse(speech.isListening)
        XCTAssertFalse(model.isListening)
        XCTAssertFalse(model.isStarting)
        XCTAssertNil(model.listenTask)
    }

    func testVoiceOverToggleTapThenStopBeforeStartRuns() async {
        let speech = FakeSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        let token = model.toggleTapped()
        XCTAssertNotNil(token)
        XCTAssertNil(model.toggleTapped(), "second tap stops")
        await model.beginListening(token: token)
        XCTAssertEqual(speech.startCount, 0)
        XCTAssertFalse(speech.isListening)
    }

    func testStaleStartDoesNotStopNewerSession() async {
        let speech = FakeSpeechInput()
        let latch = TestLatch()
        let calls = TestCounter()
        var firstReached = false
        speech.beforeStart = {
            if calls.next() == 1 {
                firstReached = true
                await latch.wait()
            }
        }
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        let first = model.pressBegan()
        let firstTask = Task { await model.beginListening(token: first) }
        while !firstReached { await Task.yield() }
        model.endListening()                 // release #1 while its start is suspended
        await model.beginListening()         // press #2 starts and goes live
        XCTAssertTrue(model.isListening)
        XCTAssertTrue(speech.isListening)
        await latch.open()                   // stale start #1 resumes
        await firstTask.value
        XCTAssertTrue(model.isListening, "the newer session is untouched")
        XCTAssertTrue(speech.isListening, "the stale start must not stop the newer session")
        XCTAssertEqual(speech.startCount, 2)
    }

    func testStaleStartWithNewerPressStillStartingDoesNotStop() async {
        let speech = FakeSpeechInput()
        let latch = TestLatch()
        var reached = false
        speech.beforeStart = { reached = true; await latch.wait() }
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        let first = model.pressBegan()
        let firstTask = Task { await model.beginListening(token: first) }
        while !reached { await Task.yield() }
        model.endListening()
        let second = model.pressBegan()      // newer press, its start not run yet
        XCTAssertNotNil(second)
        await latch.open()
        await firstTask.value
        XCTAssertTrue(model.isStarting, "newer press is still in flight")
        speech.beforeStart = nil
        await model.beginListening(token: second)
        XCTAssertTrue(model.isListening)
        XCTAssertTrue(speech.isListening)
        model.endListening()
    }
}

@MainActor
final class Slice2NotFoundMappingTests: XCTestCase {
    private let existingOnion = PantryFixtures.item(id: PantryFixtures.onionId, raw: "Onions", normalized: "onion", source: "voice")

    private func model(_ service: FakePantryService, choice: DuplicateChoice) throws -> ScanReviewViewModel {
        let observation = try PantryFixtures.decode(PantryObservation.self, PantryFixtures.observationTranscriptJSON)
        let model = ScanReviewViewModel(observation: observation, existingItems: [existingOnion], service: service)
        model.choose(1, choice)
        return model
    }

    private func notFound(message: String, details: JSONValue? = nil) -> APIError {
        .server(status: 404, code: "NOT_FOUND", message: message, retryable: false, correlationId: nil, details: details)
    }

    func test404ForMissingMergeTargetReopensThatRowsChoice() async throws {
        let service = FakePantryService()
        let error = notFound(message: "Pantry item not found.", details: .object(["merge_into": .string(PantryFixtures.onionId)]))
        service.addHandler = { _, _ in throw error }
        let model = try model(service, choice: .merge)
        await model.confirm()
        XCTAssertEqual(model.error, "That item no longer exists — pick Merge again or Keep both.")
        XCTAssertNil(model.rows[1].duplicateChoice, "choice reopened")
        XCTAssertTrue(model.rows[1].needsDuplicateChoice)
        XCTAssertFalse(model.canConfirm)
        model.choose(1, .keepBoth)
        XCTAssertTrue(model.canConfirm)
    }

    func test404WithoutDetailsButMergeInRequestIsMergeTarget() async throws {
        let service = FakePantryService()
        let error = notFound(message: "Not found.")
        service.addHandler = { _, _ in throw error }
        let model = try model(service, choice: .merge)
        await model.confirm()
        XCTAssertEqual(model.error, ScanReviewViewModel.mergeTargetGoneMessage)
    }

    func test404NamingObservationIsExpiredEvenWithMerge() async throws {
        for error in [notFound(message: "Observation not found."),
                      notFound(message: "Not found.", details: .object(["observation_id": .string(PantryFixtures.observationId)])),
                      notFound(message: "Not found.", details: .object(["field": .string("observation_id")]))] {
            let service = FakePantryService()
            service.addHandler = { _, _ in throw error }
            let model = try model(service, choice: .merge)
            await model.confirm()
            XCTAssertEqual(model.error, "This scan expired — scan again.")
            XCTAssertEqual(model.rows[1].duplicateChoice, .merge, "choice untouched")
        }
    }

    func test404WithKeepBothOnlyIsExpired() async throws {
        let service = FakePantryService()
        let error = notFound(message: "Not found.")
        service.addHandler = { _, _ in throw error }
        let model = try model(service, choice: .keepBoth)
        await model.confirm()
        XCTAssertEqual(model.error, ScanReviewViewModel.expiredMessage)
    }
}
