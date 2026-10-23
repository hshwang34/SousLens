import Foundation
import XCTest
@testable import SousLens

@MainActor
final class CaptureTests: XCTestCase {
    // MARK: - Fakes

    func testFakeCameraLifecycle() async throws {
        let frame = CapturedFrame(jpegData: Data([0xFF, 0xD8]), capturedAt: Date())
        let camera = FakeCameraSource(scriptedFrames: [frame])
        XCTAssertFalse(camera.activeIndicator)
        do {
            _ = try await camera.captureFrame()
            XCTFail("capture before start must fail")
        } catch let error as CaptureError {
            XCTAssertEqual(error, .notRunning)
        }
        try await camera.startPreview()
        XCTAssertTrue(camera.activeIndicator)
        let captured = try await camera.captureFrame()
        XCTAssertEqual(captured, frame)
        await camera.stopPreview()
        XCTAssertFalse(camera.activeIndicator)
    }

    func testUnavailableCameraThrowsExplainer() async {
        let camera = FakeCameraSource(isAvailable: false)
        do {
            try await camera.startPreview()
            XCTFail("expected unavailable")
        } catch let error as CaptureError {
            guard case .unavailable(let kind, _) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(kind, .phone)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFakeSpeechStreamsChunksUntilStopped() async throws {
        let speech = FakeSpeechInput(scriptedChunks: [TranscriptChunk(text: "next", isFinal: false, receivedAt: Date())])
        let stream = try await speech.startListening()
        XCTAssertTrue(speech.isListening)
        speech.emit("next step", isFinal: true)
        speech.stop()
        var texts: [String] = []
        for await chunk in stream { texts.append(chunk.text) }
        XCTAssertEqual(texts, ["next", "next step"])
        XCTAssertFalse(speech.isListening)
    }

    func testFakeAudioRecordsUtterances() async {
        let audio = FakeAudioOutput()
        await audio.speak("Sear for four minutes.")
        XCTAssertEqual(audio.spoken, ["Sear for four minutes."])
        XCTAssertFalse(audio.isSpeaking)
    }

    // MARK: - Phone adapters on the simulator

    func testPhoneAdaptersReportUnavailableOnSimulator() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(PhoneCameraSource().isAvailable)
        XCTAssertFalse(PhoneSpeechInput().isAvailable)
        #endif
        XCTAssertTrue(SystemAudioOutput().isAvailable)
    }

    func testUnavailablePhoneCameraAndSpeechThrowUnavailableOnSimulator() async {
        #if targetEnvironment(simulator)
        do {
            try await PhoneCameraSource().startPreview()
            XCTFail("simulator camera must be unavailable")
        } catch let error as CaptureError {
            guard case .unavailable = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("\(error)") }
        do {
            _ = try await PhoneSpeechInput().startListening()
            XCTFail("simulator speech must be unavailable")
        } catch let error as CaptureError {
            guard case .unavailable = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("\(error)") }
        #endif
    }

    func testPhoneSpeechStopWithoutStartIsNoOp() {
        let speech = PhoneSpeechInput()
        speech.stop()
        XCTAssertFalse(speech.isListening)
    }

    // MARK: - Feature flags and wiring

    func testFeatureFlagsDefaultOn() {
        let defaults = freshDefaults()
        XCTAssertEqual(CaptureFeatureFlags.load(from: defaults), .allOn)
        defaults.set(false, forKey: CaptureFeatureFlags.Key.phoneCamera)
        XCTAssertFalse(CaptureFeatureFlags.load(from: defaults).phoneCamera)
    }

    func testLiveEnvironmentInjectsFakesWhenFlagsOff() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: CaptureFeatureFlags.Key.phoneCamera)
        defaults.set(false, forKey: CaptureFeatureFlags.Key.phoneSpeech)
        defaults.set(false, forKey: CaptureFeatureFlags.Key.systemAudio)
        let off = AppEnvironment.live(defaults: defaults)
        XCTAssertTrue(off.camera is FakeCameraSource)
        XCTAssertTrue(off.speech is FakeSpeechInput)
        XCTAssertTrue(off.audio is FakeAudioOutput)
        XCTAssertFalse(off.camera.isAvailable)
        XCTAssertFalse(off.speech.isAvailable)
        XCTAssertFalse(off.audio.isAvailable)

        let on = AppEnvironment.live(defaults: freshDefaults())
        XCTAssertTrue(on.camera is PhoneCameraSource)
        XCTAssertTrue(on.speech is PhoneSpeechInput)
        XCTAssertTrue(on.audio is SystemAudioOutput)
    }

    // MARK: - Camera run state (notification-driven indicator)

    func testCameraRunStateFollowsSessionEvents() {
        XCTAssertTrue(CameraRunState.activeIndicator(after: .started))
        XCTAssertFalse(CameraRunState.activeIndicator(after: .stopped))
        XCTAssertFalse(CameraRunState.activeIndicator(after: .interrupted))
        XCTAssertTrue(CameraRunState.activeIndicator(after: .interruptionEnded))
        XCTAssertFalse(CameraRunState.activeIndicator(after: .runtimeError("boom")))
    }

    // MARK: - Start gate (stop() during an awaited permission prompt must win)

    func testStartGateStopDuringAwaitSupersedesTheStart() {
        var gate = CaptureStartGate()
        let token = gate.begin()
        XCTAssertTrue(gate.isCurrent(token))
        gate.supersede()          // stop() arrived while the start was suspended
        XCTAssertFalse(gate.isCurrent(token), "the resumed start must give up")

        let retry = gate.begin()  // a later start is current again
        XCTAssertTrue(gate.isCurrent(retry))
        XCTAssertFalse(gate.isCurrent(token))
    }

    func testStartGateNewerStartSupersedesOlderStart() {
        var gate = CaptureStartGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testPhoneSpeechStopAlwaysBumpsGateEvenWhenIdle() {
        // stop() before any start must not throw or change listening state; the gate bump is
        // what makes a start suspended in the permission prompt give up afterwards.
        let speech = PhoneSpeechInput()
        speech.stop()
        speech.stop()
        XCTAssertFalse(speech.isListening)
    }

    // MARK: - TranscriptRelay (generation + bounded finish, the logic behind PhoneSpeechInput)

    func testRelayDeliversChunksAndFinishesOnFinal() async {
        let relay = TranscriptRelay()
        var finished: [Int] = []
        relay.onFinished = { finished.append($0) }
        let (generation, stream) = relay.begin()
        XCTAssertTrue(relay.isActive)

        relay.handle(.init(generation: generation, text: "sear", isFinal: false, failed: false))
        relay.handle(.init(generation: generation, text: "sear for four", isFinal: true, failed: false))

        var chunks: [TranscriptChunk] = []
        for await chunk in stream { chunks.append(chunk) }
        XCTAssertEqual(chunks.map(\.text), ["sear", "sear for four"])
        XCTAssertEqual(chunks.map(\.isFinal), [false, true])
        XCTAssertFalse(relay.isActive)
        XCTAssertEqual(finished, [generation])
    }

    func testRelayIgnoresStaleGenerationCallbacks() async {
        let relay = TranscriptRelay()
        let (old, oldStream) = relay.begin()
        let (new, newStream) = relay.begin()   // closes the old stream
        XCTAssertNotEqual(old, new)

        relay.handle(.init(generation: old, text: "stale words", isFinal: true, failed: false))
        XCTAssertTrue(relay.isActive, "a stale final must not close the newer session")

        relay.handle(.init(generation: new, text: "fresh", isFinal: true, failed: false))
        var oldChunks = 0
        for await _ in oldStream { oldChunks += 1 }
        var newTexts: [String] = []
        for await chunk in newStream { newTexts.append(chunk.text) }
        XCTAssertEqual(oldChunks, 0)
        XCTAssertEqual(newTexts, ["fresh"])
    }

    func testRelayRequestFinishDeliversFinalResultWithinGrace() async {
        let relay = TranscriptRelay()
        let (generation, stream) = relay.begin()
        relay.handle(.init(generation: generation, text: "sear for", isFinal: false, failed: false))

        relay.requestFinish(grace: .seconds(5))
        XCTAssertTrue(relay.isFinishing)
        XCTAssertTrue(relay.isActive, "stream stays open for the final result")
        relay.handle(.init(generation: generation, text: "sear for four minutes", isFinal: true, failed: false))

        var texts: [String] = []
        for await chunk in stream { texts.append(chunk.text) }
        XCTAssertEqual(texts, ["sear for", "sear for four minutes"])
        XCTAssertFalse(relay.isActive)
        XCTAssertFalse(relay.isFinishing)
    }

    func testRelayRequestFinishClosesAfterGraceWhenNoFinalArrives() async {
        let relay = TranscriptRelay()
        let (generation, stream) = relay.begin()
        relay.handle(.init(generation: generation, text: "partial", isFinal: false, failed: false))
        relay.requestFinish(grace: .milliseconds(30))

        var texts: [String] = []
        for await chunk in stream { texts.append(chunk.text) }   // returns once the grace elapses
        XCTAssertEqual(texts, ["partial"])
        XCTAssertFalse(relay.isActive)
    }

    func testRelayFailureClosesStream() async {
        let relay = TranscriptRelay()
        let (generation, stream) = relay.begin()
        relay.handle(.init(generation: generation, text: nil, isFinal: false, failed: true))
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertFalse(relay.isActive)
    }

    func testRelaySinkHopsToMainActorAndRespectsGeneration() async {
        let relay = TranscriptRelay()
        let (generation, stream) = relay.begin()
        let sink = relay.makeSink()
        let detached = Task.detached {
            sink(.init(generation: generation, text: "from a background thread", isFinal: true, failed: false))
        }
        await detached.value
        var texts: [String] = []
        for await chunk in stream { texts.append(chunk.text) }
        XCTAssertEqual(texts, ["from a background thread"])
    }

    // MARK: - SystemAudioOutput continuations

    func testSpeakSpeakStopLeaksNoContinuation() async throws {
        let audio = SystemAudioOutput()
        let first = Task { await audio.speak("One.") }
        try await Task.sleep(for: .milliseconds(50))   // let the first utterance register
        XCTAssertTrue(audio.isSpeaking)
        let second = Task { await audio.speak("Two.") }   // interrupts the first
        try await Task.sleep(for: .milliseconds(50))
        audio.stop()

        let completed = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await first.value; await second.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        XCTAssertTrue(completed, "every speak() must resume after stop(); a leaked continuation would hang")
        XCTAssertFalse(audio.isSpeaking)
    }

    func testStopWithoutSpeakingIsSafe() {
        let audio = SystemAudioOutput()
        audio.stop()
        XCTAssertFalse(audio.isSpeaking)
    }

    func testEmptyTextIsIgnored() async {
        let audio = SystemAudioOutput()
        await audio.speak("")
        XCTAssertFalse(audio.isSpeaking)
    }
}
