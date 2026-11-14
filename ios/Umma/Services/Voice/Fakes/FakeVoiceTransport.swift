import Foundation

/// Scriptable `VoiceTransport` for tests, previews, the simulator, and when the on-device voice
/// flag is off (then constructed with `isAvailable: false`).
@MainActor
final class FakeVoiceTransport: VoiceTransport {
    let tier: VoiceTier
    var isAvailable: Bool
    var inputLabel: String
    var notice: String?
    var startError: Error?
    /// Optional suspension inside `start` (stands in for the permission prompt).
    var beforeStart: (@MainActor () async -> Void)?
    /// When true, `speak` suspends until `finishSpeaking()` or `stopSpeaking()`.
    var holdsSpeech = false

    private(set) var isRunning = false
    private(set) var isInputPaused = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var flushCount = 0
    private(set) var stopSpeakingCount = 0
    private(set) var spoken: [String] = []
    /// The handler from the most recent `start`; kept after `stop()` so tests can deliver late events.
    private var handler: (@MainActor @Sendable (VoiceTransportEvent) -> Void)?
    private var pendingSpeech: [CheckedContinuation<Void, Never>] = []

    init(tier: VoiceTier = .free, isAvailable: Bool = true, inputLabel: String = "iPhone mic", notice: String? = nil) {
        self.tier = tier
        self.isAvailable = isAvailable
        self.inputLabel = inputLabel
        self.notice = notice
    }

    var isSpeaking: Bool { !pendingSpeech.isEmpty }

    func start(onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws {
        guard isAvailable else {
            throw CaptureError.unavailable(.phone, reason: "Voice is off on this device.")
        }
        startCount += 1
        handler = onEvent
        if let beforeStart { await beforeStart() }
        if let startError { throw startError }
        isRunning = true
        isInputPaused = false
    }

    func stop() {
        stopCount += 1
        isRunning = false
        finishSpeaking()
    }

    func setInputPaused(_ paused: Bool) {
        isInputPaused = paused
    }

    func flushHypothesis() {
        flushCount += 1
    }

    func speak(_ text: String) async {
        spoken.append(text)
        guard holdsSpeech else { return }
        await withCheckedContinuation { pendingSpeech.append($0) }
    }

    func stopSpeaking() {
        stopSpeakingCount += 1
        finishSpeaking()
    }

    /// Ends every utterance in flight, as if it played to the end.
    func finishSpeaking() {
        let pending = pendingSpeech
        pendingSpeech = []
        pending.forEach { $0.resume() }
    }

    /// Delivers an event through the latest handler, even after `stop()` (to test stale events).
    func emit(_ event: VoiceTransportEvent) {
        handler?(event)
    }
}

/// Manual clock: `advance(byMs:)` moves time forward in tick-sized steps, ticking at each one.
@MainActor
final class FakeVoiceClock: VoiceClock {
    private(set) var nowMs: Int64
    private var interval: Int64 = 250
    private var tick: (@MainActor () -> Void)?

    init(nowMs: Int64 = 1_000_000) {
        self.nowMs = nowMs
    }

    var isTicking: Bool { tick != nil }

    func startTicking(everyMs interval: Int64, _ tick: @escaping @MainActor () -> Void) {
        self.interval = max(1, interval)
        self.tick = tick
    }

    func stopTicking() {
        tick = nil
    }

    func advance(byMs delta: Int64) {
        var remaining = delta
        while remaining > 0 {
            let step = min(interval, remaining)
            nowMs += step
            remaining -= step
            tick?()
        }
    }
}
