import Foundation
import XCTest
@testable import Umma

/// Brief 012 PR 1: the voice core state machine, driven by a fake clock and transport.
@MainActor
final class VoiceSessionTests: XCTestCase {
    private var transport: FakeVoiceTransport!
    private var clock: FakeVoiceClock!
    private var events: [VoiceSessionEvent] = []

    override func setUp() async throws {
        transport = FakeVoiceTransport()
        clock = FakeVoiceClock()
        events = []
    }

    private func makeSession(_ config: VoiceSessionConfig = .init()) -> VoiceSession {
        let session = VoiceSession(transport: transport, clock: clock, config: config)
        session.onEvent = { [weak self] in self?.events.append($0) }
        return session
    }

    private func started(_ config: VoiceSessionConfig = .init()) async throws -> VoiceSession {
        let session = makeSession(config)
        try await session.start()
        return session
    }

    /// Lets a detached task reach its next suspension point.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    private var pauses: [Int64] {
        events.compactMap { if case .pause(let ms) = $0 { ms } else { nil } }
    }

    private var userSegments: [VoiceSegment] {
        events.compactMap { if case .userSegment(let s) = $0 { s } else { nil } }
    }

    // MARK: - Transitions

    func testStartListensAndTicks() async throws {
        let session = makeSession()
        XCTAssertEqual(session.state, .idle)
        try await session.start()
        XCTAssertEqual(session.state, .listening)
        XCTAssertTrue(transport.isRunning)
        XCTAssertTrue(clock.isTicking)
        XCTAssertEqual(session.inputLabel, "iPhone mic")
    }

    func testPartialThenFinalEmitsTimestampedSegment() async throws {
        let session = try await started()
        clock.advance(byMs: 2000)
        transport.emit(.transcript(text: "first the pork", isFinal: false))
        XCTAssertEqual(session.state, .userSpeaking)
        XCTAssertEqual(session.partial?.text, "first the pork")
        clock.advance(byMs: 1000)
        transport.emit(.transcript(text: "first the pork belly", isFinal: true))
        XCTAssertEqual(session.state, .listening)
        XCTAssertNil(session.partial)
        XCTAssertEqual(userSegments.count, 1)
        XCTAssertEqual(userSegments.first?.text, "first the pork belly")
        XCTAssertEqual(userSegments.first?.startMs, 2000, "starts when the first partial arrived")
        XCTAssertEqual(userSegments.first?.endMs, 3000)
        XCTAssertEqual(session.userCaptions.map(\.text), ["first the pork belly"])
    }

    func testTransportOffsetsAreRebasedOntoTheSessionClock() async throws {
        let session = makeSession()
        transport.beforeStart = { [clock] in clock?.advance(byMs: 500) }
        try await session.start()
        clock.advance(byMs: 3000)
        transport.emit(.transcript(text: "kimchi now", isFinal: true, startMs: 1200, endMs: 2100))
        XCTAssertEqual(userSegments.first?.startMs, 1700)
        XCTAssertEqual(userSegments.first?.endMs, 2600)
    }

    func testVoiceActivityMovesBetweenListeningAndUserSpeaking() async throws {
        let session = try await started()
        transport.emit(.voiceActivity(true))
        XCTAssertEqual(session.state, .userSpeaking)
        transport.emit(.voiceActivity(false))
        XCTAssertEqual(session.state, .listening)
    }

    func testThinkingThenSayReturnsToListening() async throws {
        let session = try await started()
        session.beginThinking()
        XCTAssertEqual(session.state, .thinking)
        transport.holdsSpeech = true
        let speaking = Task { await session.say("Got it. How long does it simmer?") }
        await settle { transport.isSpeaking }
        XCTAssertEqual(session.state, .speaking)
        XCTAssertEqual(session.assistantCaptions.last?.isFinal, false)
        clock.advance(byMs: 1500)
        transport.finishSpeaking()
        await speaking.value
        XCTAssertEqual(session.state, .listening)
        XCTAssertEqual(transport.spoken, ["Got it. How long does it simmer?"])
        XCTAssertEqual(session.assistantCaptions.last?.endMs, 1500)
        XCTAssertEqual(session.assistantCaptions.last?.isFinal, true)
    }

    func testEndThinkingWithoutSpeaking() async throws {
        let session = try await started()
        session.beginThinking()
        session.endThinking()
        XCTAssertEqual(session.state, .listening)
    }

    func testCaptionsKeepTheLastFewLinesPerSide() async throws {
        let session = try await started(VoiceSessionConfig(captionLimit: 2))
        for line in ["one", "two", "three"] {
            transport.emit(.transcript(text: line, isFinal: true))
        }
        XCTAssertEqual(session.userCaptions.map(\.text), ["two", "three"])
        XCTAssertEqual(userSegments.count, 3, "consumers still get every segment")
    }

    // MARK: - Silence

    func testPauseIsReportedOnceAfterThresholdFollowingSpeech() async throws {
        let session = try await started()
        clock.advance(byMs: 5000)
        XCTAssertTrue(pauses.isEmpty, "no pause before the user has spoken")
        transport.emit(.transcript(text: "now the kimchi", isFinal: true))
        clock.advance(byMs: 1250)
        XCTAssertTrue(pauses.isEmpty)
        XCTAssertEqual(session.silenceMs, 1250)
        clock.advance(byMs: 250)
        XCTAssertEqual(pauses, [1500])
        clock.advance(byMs: 5000)
        XCTAssertEqual(pauses.count, 1, "one pause per silence span")
        XCTAssertEqual(session.lastSpeechAt, 5000)
    }

    func testPauseThresholdIsConfigurable() async throws {
        let session = try await started(VoiceSessionConfig(pauseThresholdMs: 3000))
        transport.emit(.voiceActivity(true))
        transport.emit(.voiceActivity(false))
        clock.advance(byMs: 2750)
        XCTAssertTrue(pauses.isEmpty)
        clock.advance(byMs: 250)
        XCTAssertEqual(pauses, [3000])
        XCTAssertEqual(session.state, .listening)
    }

    func testEndsAfterTenMinutesOfSilence() async throws {
        let session = try await started()
        clock.advance(byMs: 9 * 60 * 1000)
        transport.emit(.transcript(text: "still here", isFinal: true))
        clock.advance(byMs: 10 * 60 * 1000 - 250)
        XCTAssertEqual(session.state, .listening, "speech restarts the silence clock")
        clock.advance(byMs: 250)
        XCTAssertEqual(session.state, .ended(.silenceTimeout))
        XCTAssertEqual(events.last, .ended(.silenceTimeout))
        XCTAssertFalse(transport.isRunning)
        XCTAssertFalse(clock.isTicking)
        XCTAssertEqual(session.elapsedMs, 19 * 60 * 1000)
    }

    func testNoSilenceTimeoutWhenDisabled() async throws {
        let session = try await started(VoiceSessionConfig(silenceTimeoutMs: nil))
        clock.advance(byMs: 45 * 60 * 1000)
        XCTAssertEqual(session.state, .listening)
    }

    func testSilenceDoesNotCountWhilePausedOrSpeaking() async throws {
        let session = try await started(VoiceSessionConfig(silenceTimeoutMs: 60_000))
        clock.advance(byMs: 50_000)
        session.pause()
        clock.advance(byMs: 120_000)
        XCTAssertEqual(session.state, .paused)
        session.resume()
        clock.advance(byMs: 50_000)
        XCTAssertEqual(session.state, .listening, "resume restarts the silence clock")
        transport.holdsSpeech = true
        let speaking = Task { await session.say("Take your time.") }
        await settle { transport.isSpeaking }
        clock.advance(byMs: 120_000)
        XCTAssertEqual(session.state, .speaking)
        transport.finishSpeaking()
        await speaking.value
        clock.advance(byMs: 59_750)
        XCTAssertEqual(session.state, .listening)
        clock.advance(byMs: 250)
        XCTAssertEqual(session.state, .ended(.silenceTimeout))
    }

    // MARK: - Self-hearing gate

    func testTranscriptIsGatedWhileSpeakingAndDuringEchoTail() async throws {
        let session = try await started(VoiceSessionConfig(echoTailMs: 400))
        transport.emit(.transcript(text: "half a sent", isFinal: false))
        transport.holdsSpeech = true
        let speaking = Task { await session.say("How long does it simmer?") }
        await settle { transport.isSpeaking }
        XCTAssertNil(session.partial, "the in-flight hypothesis is closed before Umma speaks")
        XCTAssertEqual(userSegments.map(\.text), ["half a sent"], "the user's words are kept, not dropped")
        XCTAssertEqual(transport.flushCount, 1)
        transport.emit(.transcript(text: "how long does it simmer", isFinal: false))
        transport.emit(.voiceActivity(true))
        transport.emit(.transcript(text: "how long does it simmer", isFinal: true))
        XCTAssertEqual(session.state, .speaking)
        XCTAssertNil(session.partial)
        transport.finishSpeaking()
        await speaking.value
        XCTAssertEqual(transport.flushCount, 2, "flushed again when speech ends")
        // The recognizer's late echo final and partial, inside the tail.
        transport.emit(.transcript(text: "does it simmer", isFinal: false))
        clock.advance(byMs: 250)
        transport.emit(.transcript(text: "simmer", isFinal: true))
        XCTAssertNil(session.partial)
        XCTAssertEqual(transport.flushCount, 2)
        clock.advance(byMs: 250)
        XCTAssertEqual(transport.flushCount, 3, "and once more after the echo tail")
        transport.emit(.transcript(text: "about fifteen minutes", isFinal: true))
        XCTAssertEqual(userSegments.map(\.text), ["half a sent", "about fifteen minutes"])
    }

    func testEchoWordsNeverBecomeUserSegments() async throws {
        let session = try await started()
        let line = "Got it, how long does it simmer"
        transport.holdsSpeech = true
        let speaking = Task { await session.say(line) }
        await settle { transport.isSpeaking }
        for words in ["got it", "got it how long", "got it how long does it simmer"] {
            transport.emit(.voiceActivity(true))
            transport.emit(.transcript(text: words, isFinal: false))
            clock.advance(byMs: 300)
        }
        transport.emit(.transcript(text: "got it how long does it simmer", isFinal: true))
        transport.finishSpeaking()
        await speaking.value
        transport.emit(.transcript(text: "does it simmer", isFinal: true))
        clock.advance(byMs: 1000)
        transport.emit(.transcript(text: "fifteen minutes", isFinal: true))
        XCTAssertEqual(userSegments.map(\.text), ["fifteen minutes"])
        XCTAssertFalse(session.userCaptions.contains { $0.text.contains("simmer") })
    }

    func testStopCommandBargesInWhileSpeaking() async throws {
        let session = try await started()
        transport.holdsSpeech = true
        let speaking = Task { await session.say("Next, add the tofu and") }
        await settle { transport.isSpeaking }
        transport.emit(.transcript(text: "Stop.", isFinal: true))
        await speaking.value
        XCTAssertEqual(session.state, .ended(.stopCommand))
        XCTAssertFalse(transport.isRunning)
    }

    func testNewerSayInterruptsOlderOne() async throws {
        let session = try await started()
        transport.holdsSpeech = true
        let first = Task { await session.say("first line") }
        await settle { transport.spoken.count == 1 }
        let second = Task { await session.say("second line") }
        await settle { transport.spoken.count == 2 }
        await first.value
        XCTAssertEqual(session.state, .speaking, "the older say must not flip the state")
        transport.finishSpeaking()
        await second.value
        XCTAssertEqual(session.state, .listening)
        XCTAssertEqual(session.assistantCaptions.map(\.text), ["first line", "second line"])
    }

    // MARK: - Commands

    func testSpokenStopEndsTheSession() async throws {
        let session = try await started()
        transport.emit(.transcript(text: "stop", isFinal: false))
        XCTAssertEqual(session.state, .userSpeaking, "a partial never ends the session")
        transport.emit(.transcript(text: "Stop!", isFinal: true))
        XCTAssertEqual(session.state, .ended(.stopCommand))
        XCTAssertTrue(userSegments.isEmpty)
    }

    func testStopAskingIsNotAStop() {
        XCTAssertNil(VoiceCommand.parse("stop asking"))
        XCTAssertNil(VoiceCommand.parse("don't stop"))
        XCTAssertEqual(VoiceCommand.parse("  Stop listening. "), .stop)
        XCTAssertEqual(VoiceCommand.parse("end voice mode"), .stop)
    }

    // MARK: - Pause / resume

    func testPauseStopsInputAndSpeechAndResumeListens() async throws {
        let session = try await started()
        transport.holdsSpeech = true
        let speaking = Task { await session.say("Here's the next step") }
        await settle { transport.isSpeaking }
        session.pause()
        await speaking.value
        XCTAssertEqual(session.state, .paused)
        XCTAssertTrue(transport.isInputPaused)
        XCTAssertEqual(session.assistantCaptions.last?.isFinal, true)
        XCTAssertEqual(transport.flushCount, 2, "paused mid-speech: the echo hypothesis is dropped")
        clock.advance(byMs: 2000)
        transport.emit(.transcript(text: "ignored", isFinal: true))
        XCTAssertTrue(userSegments.isEmpty)
        session.resume()
        XCTAssertEqual(session.state, .listening)
        XCTAssertFalse(transport.isInputPaused)
    }

    func testPauseKeepsWordsAlreadyHeard() async throws {
        let session = try await started()
        transport.emit(.transcript(text: "two cloves of", isFinal: false))
        session.pause()
        XCTAssertEqual(transport.flushCount, 0, "pausing must not discard the user's words")
        clock.advance(byMs: 500)
        transport.emit(.transcript(text: "two cloves of garlic", isFinal: true))
        XCTAssertEqual(userSegments.map(\.text), ["two cloves of garlic"])
        XCTAssertEqual(session.state, .paused)
        clock.advance(byMs: 1500)
        transport.emit(.transcript(text: "too late", isFinal: true))
        transport.emit(.transcript(text: "partials never count", isFinal: false))
        XCTAssertEqual(userSegments.map(\.text), ["two cloves of garlic"])
    }

    func testInterruptionPausesAndNeverResumesOnItsOwn() async throws {
        let session = try await started()
        transport.emit(.interruption(began: true))
        XCTAssertEqual(session.state, .paused)
        XCTAssertTrue(transport.isInputPaused)
        transport.emit(.interruption(began: false))
        XCTAssertEqual(session.state, .paused, "the user resumes by hand")
        XCTAssertTrue(transport.isInputPaused)
        session.resume()
        XCTAssertEqual(session.state, .listening)
    }

    func testSegmentsAreOnTheSessionClockAcrossALongPause() async throws {
        let session = makeSession()
        transport.beforeStart = { [clock] in clock?.advance(byMs: 700) }
        try await session.start()
        clock.advance(byMs: 2000)
        session.pause()
        clock.advance(byMs: 5 * 60 * 1000)
        session.resume()
        clock.advance(byMs: 1000)
        let sessionNow = session.elapsedMs
        XCTAssertEqual(sessionNow, 700 + 2000 + 300_000 + 1000)
        // Untimed final: stamped now.
        transport.emit(.transcript(text: "back again", isFinal: true))
        XCTAssertEqual(userSegments.last?.endMs, sessionNow)
        // Timed final: transport offsets are wall time since its start (pause included).
        transport.emit(.transcript(text: "simmer it", isFinal: true, startMs: 302_500, endMs: 302_900))
        XCTAssertEqual(userSegments.last?.startMs, 700 + 302_500)
        XCTAssertEqual(userSegments.last?.endMs, 700 + 302_900)
        // A transport claiming the future is clamped to now; times never run backwards.
        clock.advance(byMs: 500)
        transport.emit(.transcript(text: "future", isFinal: true, startMs: 400_000, endMs: 401_000))
        XCTAssertEqual(userSegments.last?.endMs, session.elapsedMs)
        XCTAssertLessThanOrEqual(userSegments.last!.startMs, userSegments.last!.endMs)
    }

    func testInterruptionEndDoesNotResumeAUserPause() async throws {
        let session = try await started()
        session.pause()
        transport.emit(.interruption(began: true))
        transport.emit(.interruption(began: false))
        XCTAssertEqual(session.state, .paused)
    }

    func testInputChangeUpdatesTheLabel() async throws {
        let session = try await started()
        transport.emit(.inputChanged(label: "AirPods mic"))
        XCTAssertEqual(session.inputLabel, "AirPods mic")
    }

    // MARK: - Start / stop races

    func testStopDuringStartWins() async throws {
        let session = makeSession()
        let gate = StartGate()
        transport.beforeStart = { await gate.hold() }
        let starting = Task { try await session.start() }
        await settle { gate.requested }
        XCTAssertEqual(session.state, .starting)
        session.stop()
        XCTAssertEqual(session.state, .ended(.stopped))
        gate.release()
        do {
            try await starting.value
            XCTFail("a superseded start must throw")
        } catch let error as CaptureError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(session.state, .ended(.stopped))
        XCTAssertFalse(clock.isTicking)
        transport.emit(.transcript(text: "late", isFinal: true))
        XCTAssertTrue(userSegments.isEmpty)
    }

    func testRestartAfterStopIgnoresTheOldRun() async throws {
        let session = try await started()
        session.stop()
        XCTAssertEqual(events.last, .ended(.stopped))
        try await session.start()
        XCTAssertEqual(session.state, .listening)
        XCTAssertEqual(transport.startCount, 2)
        transport.emit(.transcript(text: "new run", isFinal: true))
        XCTAssertEqual(userSegments.map(\.text), ["new run"])
        XCTAssertEqual(session.userCaptions.map(\.text), ["new run"])
    }

    func testStaleEventsFromAnEndedRunAreDropped() async throws {
        let session = try await started()
        session.stop()
        transport.emit(.transcript(text: "after stop", isFinal: true))
        transport.emit(.failed("late failure"))
        XCTAssertEqual(session.state, .ended(.stopped))
        XCTAssertTrue(userSegments.isEmpty)
    }

    func testStartFailureEndsWithReason() async {
        transport.startError = CaptureError.failed("mic busy")
        let session = makeSession()
        do {
            try await session.start()
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(session.state, .ended(.failed("mic busy")))
    }

    func testTransportFailureEndsTheSession() async throws {
        let session = try await started()
        transport.emit(.failed("recognizer died"))
        XCTAssertEqual(session.state, .ended(.failed("recognizer died")))
    }

    func testSecondStartWhileActiveIsANoOp() async throws {
        let session = try await started()
        try await session.start()
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(session.state, .listening)
    }

    // MARK: - Tier

    func testTierChoice() {
        XCTAssertEqual(VoiceTierChoice.tier(entitlement: .paid, runOnDevice: false), .paid)
        XCTAssertEqual(VoiceTierChoice.tier(entitlement: .paid, runOnDevice: true), .free)
        XCTAssertEqual(VoiceTierChoice.tier(entitlement: .free, runOnDevice: false), .free)
        XCTAssertEqual(VoiceTierChoice.tier(entitlement: nil, runOnDevice: false), .free)
    }

    func testPaidFallsBackToFreeWithAVisibleReason() async throws {
        let free = FakeVoiceTransport()
        let transport = VoiceTierChoice.transport(entitlement: .paid, runOnDevice: false) { free }
        XCTAssertTrue(transport is PaidVoiceTransport)
        XCTAssertEqual(transport.notice, PaidVoiceTransport.fallbackNotice)
        let session = VoiceSession(transport: transport, clock: clock)
        try await session.start()
        XCTAssertTrue(free.isRunning)
        XCTAssertEqual(session.notice, PaidVoiceTransport.fallbackNotice)
        free.emit(.transcript(text: "eggs and rice", isFinal: true))
        XCTAssertEqual(session.userCaptions.map(\.text), ["eggs and rice"])
        await session.say("Got two.")
        XCTAssertEqual(free.spoken, ["Got two."])
    }

    func testFreeEntitlementGetsTheFreeTransportDirectly() {
        let transport = VoiceTierChoice.transport(entitlement: .free, runOnDevice: false) { FakeVoiceTransport() }
        XCTAssertTrue(transport is FakeVoiceTransport)
        XCTAssertNil(transport.notice)
    }

    func testVoiceSettingPersists() {
        let defaults = UserDefaults(suiteName: "voice.\(UUID().uuidString)")!
        XCTAssertFalse(VoiceSettings(defaults: defaults).runOnDevice)
        VoiceSettings(defaults: defaults).runOnDevice = true
        XCTAssertTrue(VoiceSettings(defaults: defaults).runOnDevice)
    }

    // MARK: - Entitlement decoding

    func testUserDecodesEntitlementAndToleratesMissingOrUnknown() throws {
        func decode(_ extra: String) throws -> User {
            let json = """
            {"id":"7f8a1c2e-0000-4000-8000-000000000001","display_name":"t","preference_units":"us",
             "created_at":"2026-11-13T00:00:00Z"\(extra)}
            """
            return try JSONCoding.makeDecoder().decode(User.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#","entitlement":"paid""#).entitlement, .paid)
        XCTAssertEqual(try decode(#","entitlement":"free""#).entitlement, .free)
        XCTAssertEqual(try decode(#","entitlement":"platinum""#).entitlement, .free)
        XCTAssertNil(try decode("").entitlement)
    }
}

/// Holds the fake transport's start open (stands in for the permission prompt).
@MainActor
private final class StartGate {
    private(set) var requested = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        requested = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
