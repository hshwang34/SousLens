import AVFoundation
import Foundation
import XCTest
import os
@testable import Umma

/// Brief 012 PR 1, Free transport: the pure parts (task rolling and re-stamping, level-based
/// silence detection, the honest input label). Real audio needs a device.
final class OnDeviceVoiceTests: XCTestCase {
    private typealias Piece = RecognitionRoller.Piece

    // MARK: - Rolling and re-stamping

    func testPartialsAndFinalsAreRestampedFromTheTaskOrigin() {
        var roller = RecognitionRoller()
        let first = roller.beginTask(atAudioMs: 0)
        XCTAssertEqual(
            roller.result(task: first, text: "pork", isFinal: false, pieces: [Piece(timestamp: 0.5, duration: 0.4)]),
            .transcript(text: "pork", isFinal: false, startMs: 500, endMs: 900))
        roller.retireCurrent(discard: false)
        let second = roller.beginTask(atAudioMs: 41_000)
        XCTAssertEqual(
            roller.result(task: second, text: "kimchi", isFinal: false,
                          pieces: [Piece(timestamp: 1.25, duration: 0.5)]),
            .transcript(text: "kimchi", isFinal: false, startMs: 42_250, endMs: 42_750))
        XCTAssertEqual(
            roller.result(task: first, text: "pork belly", isFinal: true,
                          pieces: [Piece(timestamp: 0.5, duration: 0.4), Piece(timestamp: 0.9, duration: 0.6)]),
            .transcript(text: "pork belly", isFinal: true, startMs: 500, endMs: 1500),
            "the retired task's final still arrives, on the shared clock")
    }

    func testRetiredTaskPartialsAreSilentAndItFinalizesOnce() {
        var roller = RecognitionRoller()
        let first = roller.beginTask(atAudioMs: 0)
        _ = roller.result(task: first, text: "the old sour", isFinal: false, pieces: [])
        roller.retireCurrent(discard: false)
        _ = roller.beginTask(atAudioMs: 3000)
        XCTAssertNil(roller.result(task: first, text: "the old sour one", isFinal: false, pieces: []))
        XCTAssertEqual(roller.result(task: first, text: "the old sour one", isFinal: true, pieces: []),
                       .transcript(text: "the old sour one", isFinal: true))
        XCTAssertNil(roller.result(task: first, text: "the old sour one", isFinal: true, pieces: []))
    }

    func testTaskEndingWithoutFinalKeepsItsLastWords() {
        var roller = RecognitionRoller()
        let first = roller.beginTask(atAudioMs: 0)
        _ = roller.result(task: first, text: "about fifteen", isFinal: false, pieces: [])
        roller.retireCurrent(discard: false)
        _ = roller.beginTask(atAudioMs: 2000)
        _ = roller.result(task: first, text: "about fifteen minutes", isFinal: false, pieces: [])
        XCTAssertEqual(roller.taskEnded(first), .transcript(text: "about fifteen minutes", isFinal: true))
        XCTAssertNil(roller.taskEnded(first), "only once")
    }

    func testCurrentTaskDyingFlushesItsHypothesis() {
        var roller = RecognitionRoller()
        let task = roller.beginTask(atAudioMs: 0)
        _ = roller.result(task: task, text: "two cloves", isFinal: false, pieces: [])
        XCTAssertEqual(roller.taskEnded(task), .transcript(text: "two cloves", isFinal: true))
        XCTAssertFalse(roller.hasHypothesis)
    }

    func testDiscardedTaskNeverSpeaks() {
        var roller = RecognitionRoller()
        let task = roller.beginTask(atAudioMs: 0)
        _ = roller.result(task: task, text: "how long does it simmer", isFinal: false, pieces: [])
        roller.retireCurrent(discard: true)
        _ = roller.beginTask(atAudioMs: 1000)
        XCTAssertNil(roller.result(task: task, text: "how long does it simmer", isFinal: true, pieces: []))
        XCTAssertNil(roller.taskEnded(task))
    }

    func testRollPolicy() {
        var roller = RecognitionRoller()
        _ = roller.beginTask(atAudioMs: 10_000)
        XCTAssertFalse(roller.shouldRoll(audioMs: 12_000, silentForMs: 5_000), "young, nothing heard")
        XCTAssertTrue(roller.shouldRoll(audioMs: 50_000, silentForMs: 800), "old enough, at a pause")
        XCTAssertFalse(roller.shouldRoll(audioMs: 50_000, silentForMs: 100), "old, but mid-speech")
        XCTAssertTrue(roller.shouldRoll(audioMs: 65_000, silentForMs: 0), "hard limit even mid-speech")
        _ = roller.result(task: roller.currentTask, text: "rice", isFinal: false, pieces: [])
        XCTAssertFalse(roller.shouldRoll(audioMs: 12_000, silentForMs: 500))
        XCTAssertTrue(roller.shouldRoll(audioMs: 12_000, silentForMs: 800), "a pause finalizes the hypothesis")
    }

    func testUntimedPiecesLeaveStampingToTheSession() {
        XCTAssertTrue(RecognitionRoller.span([Piece(timestamp: 0, duration: 0)], origin: 5000) == (nil, nil))
        XCTAssertTrue(RecognitionRoller.span([], origin: 5000) == (nil, nil))
    }

    func testDiscardedTasksAreForgotten() {
        var roller = RecognitionRoller()
        for index in 0..<50 {
            let task = roller.beginTask(atAudioMs: Int64(index) * 1000)
            _ = roller.result(task: task, text: "echo", isFinal: false, pieces: [])
            roller.retireCurrent(discard: true)
            XCTAssertNil(roller.result(task: task, text: "echo", isFinal: true, pieces: []))
        }
        XCTAssertLessThanOrEqual(roller.trackedTaskCount, 1, "only the live task is tracked")
    }

    // MARK: - Mic tap: clock and gating

    private func buffer(level: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        buffer.frameLength = 960
        for index in 0..<960 { buffer.floatChannelData![0][index] = level }
        return buffer
    }

    func testTapClockIsWallTimeIncludingPauses() {
        let now = OSAllocatedUnfairLock(initialState: 100.0)
        let tap = VoiceInputTap(now: { now.withLock { $0 } })
        tap.reset(originSeconds: 100)
        now.withLock { $0 = 102 }
        XCTAssertEqual(tap.nowMs, 2000)
        tap.setPaused(true)
        now.withLock { $0 = 402 }
        tap.setPaused(false)
        XCTAssertEqual(tap.nowMs, 302_000, "five minutes paused still count")
    }

    func testTapFeedsNothingWhileGatedOrPaused() {
        let tap = VoiceInputTap(now: { 0 })
        tap.reset(originSeconds: 0)
        XCTAssertTrue(tap.isFeeding)
        tap.setGated(true)
        XCTAssertFalse(tap.isFeeding)
        // Loud "echo" while gated never registers as the user speaking.
        for index in 0..<20 {
            XCTAssertNil(tap.process(buffer(level: 0.5), atSeconds: Double(index) * 0.02))
        }
        tap.setGated(false)
        tap.setPaused(true)
        XCTAssertFalse(tap.isFeeding)
        tap.setPaused(false)
        let changes = (20..<40).compactMap { tap.process(buffer(level: 0.5), atSeconds: Double($0) * 0.02) }
        XCTAssertEqual(changes, [true])
        XCTAssertEqual(tap.silentFor(atMs: 1000), 0)
    }

    // MARK: - Speech playback

    func testStopInvalidatesBuffersStillInFlight() {
        let player = EngineSpeechPlayer()
        let before = player.currentGeneration
        player.stop()
        XCTAssertFalse(player.isCurrent(before), "late synthesizer buffers must be dropped after Stop")
        XCTAssertTrue(player.isCurrent(player.currentGeneration))
    }

    func testSpeakTimeoutScalesWithText() {
        XCTAssertEqual(EngineSpeechPlayer.timeout(for: ""), .milliseconds(5000))
        XCTAssertGreaterThan(EngineSpeechPlayer.timeout(for: String(repeating: "a", count: 200)), .seconds(20))
    }

    // MARK: - Voice activity from levels

    /// Feeds `levels` (dBFS) as 20 ms buffers starting at `fromMs`; returns the state changes.
    private func feed(_ detector: inout VoiceActivityDetector, _ levels: [Float], fromMs: Int64 = 0) -> [Bool] {
        levels.enumerated().compactMap { index, level in
            detector.process(levelDb: level, atMs: fromMs + Int64(index) * 20)
        }
    }

    func testSpeechNeedsAttackAndSilenceNeedsRelease() {
        var detector = VoiceActivityDetector()
        XCTAssertEqual(feed(&detector, Array(repeating: -65, count: 50)), [])
        XCTAssertEqual(feed(&detector, Array(repeating: -20, count: 3), fromMs: 1000), [], "a 60 ms click is not speech")
        XCTAssertEqual(feed(&detector, Array(repeating: -65, count: 10), fromMs: 1060), [])
        XCTAssertEqual(feed(&detector, Array(repeating: -20, count: 10), fromMs: 1260), [true])
        XCTAssertEqual(feed(&detector, Array(repeating: -65, count: 10), fromMs: 1460), [], "200 ms gap keeps speaking")
        XCTAssertTrue(detector.isSpeech)
        XCTAssertEqual(feed(&detector, Array(repeating: -65, count: 30), fromMs: 1660), [false])
        XCTAssertEqual(detector.lastSpeechAtMs, 1440)
        XCTAssertEqual(detector.silentFor(atMs: 2940), 1500)
    }

    func testSteadyKitchenNoiseRaisesTheFloor() {
        var detector = VoiceActivityDetector()
        // A loud extractor fan: -38 dBFS for 10 s. It may read as speech at first, then the floor
        // adapts, and talking has to rise above it.
        _ = feed(&detector, Array(repeating: -38, count: 500))
        XCTAssertGreaterThan(detector.noiseFloorDb, -45)
        XCTAssertFalse(detector.isSpeech)
        XCTAssertEqual(feed(&detector, Array(repeating: -18, count: 10), fromMs: 10_000), [true])
    }

    func testLevelOfSamples() {
        let silence = [Float](repeating: 0, count: 64)
        let full = [Float](repeating: 1, count: 64)
        let half = [Float](repeating: 0.5, count: 64)
        silence.withUnsafeBufferPointer { XCTAssertEqual(VoiceActivityDetector.levelDb($0), -160) }
        full.withUnsafeBufferPointer { XCTAssertEqual(VoiceActivityDetector.levelDb($0), 0, accuracy: 0.001) }
        half.withUnsafeBufferPointer { XCTAssertEqual(VoiceActivityDetector.levelDb($0), -6.02, accuracy: 0.01) }
    }

    // MARK: - Honest input label

    func testInputLabelNeverClaimsGlasses() {
        XCTAssertEqual(VoiceInputLabel.label(portType: .builtInMic, portName: "iPhone Microphone"), "iPhone mic")
        XCTAssertEqual(VoiceInputLabel.label(portType: nil, portName: nil), "iPhone mic")
        XCTAssertEqual(VoiceInputLabel.label(portType: .bluetoothHFP, portName: "Ray-Ban Meta"), "Bluetooth mic (Ray-Ban Meta)")
        XCTAssertEqual(VoiceInputLabel.label(portType: .headsetMic, portName: "Headset"), "Headset mic")
        for port in [AVAudioSession.Port.builtInMic, .bluetoothHFP, .headsetMic, .usbAudio, .carAudio] {
            XCTAssertFalse(VoiceInputLabel.label(portType: port, portName: "x").lowercased().contains("glasses"))
        }
    }

    // MARK: - Wiring

    @MainActor
    func testSimulatorTransportIsUnavailableSoTheFakeIsUsed() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(OnDeviceVoiceTransport().isAvailable)
        #endif
        XCTAssertFalse(OnDeviceVoiceTransport(enabled: false).isAvailable)
        let flags = CaptureFeatureFlags.load(from: UserDefaults(suiteName: "voice.\(UUID().uuidString)")!)
        XCTAssertTrue(flags.phoneVoice, "on by default")
    }
}
