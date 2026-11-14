import Foundation
import Observation

/// One visible, user-started voice session (brief 012; brief 014's recording screen reuses it).
///
/// State machine: idle → starting → listening ⇄ userSpeaking; consumers move it to thinking and
/// (via `say`) speaking, which return to listening; pause/resume from any live state; ended(reason)
/// on `stop()`, a spoken "stop", silence past `silenceTimeoutMs`, or a transport failure.
///
/// Time: everything is milliseconds since `start()` on the injected clock. Transcript offsets
/// from the transport are re-based onto that clock.
///
/// Self-hearing: while Umma speaks, and for `echoTailMs` after, mic transcripts are dropped
/// (only a final "stop" gets through), and the in-flight hypothesis is flushed, so the assistant's
/// words never become a user segment.
///
/// Races: `CaptureStartGate` makes a `stop()` during the transport's async start win; a session
/// generation drops events from a transport run that already ended; a speech generation keeps
/// an older `say` from flipping the state after a newer one, a pause, or a stop.
@MainActor
@Observable
final class VoiceSession {
    private(set) var state: VoiceState = .idle
    /// Last few final lines per side, oldest first.
    private(set) var userCaptions: [VoiceSegment] = []
    private(set) var assistantCaptions: [VoiceSegment] = []
    /// The user's in-flight hypothesis.
    private(set) var partial: VoiceSegment?
    private(set) var inputLabel: String
    /// Updated every tick while listening; 0 while paused, thinking or speaking.
    private(set) var silenceMs: Int64 = 0
    /// Session time of the last detected speech.
    private(set) var lastSpeechAt: Int64?

    let config: VoiceSessionConfig
    let transport: any VoiceTransport
    /// Receives segments, pauses and the end, in order.
    var onEvent: ((VoiceSessionEvent) -> Void)?

    private let clock: any VoiceClock
    private var originMs: Int64 = 0
    private var endedAtMs: Int64?
    /// Session time when the transport finished starting; transcript offsets count from here.
    private var transportOriginMs: Int64 = 0
    private var startGate = CaptureStartGate()
    private var generation = 0
    private var speechGeneration = 0
    private var silenceAnchorMs: Int64 = 0
    private var pauseReported = true
    private var echoGuardUntilMs: Int64 = .min
    private var nextSegmentId = 0
    private var tailFlushPending = false
    private var pausedAtMs: Int64?

    init(transport: any VoiceTransport, clock: any VoiceClock = SystemVoiceClock(), config: VoiceSessionConfig = .init()) {
        self.transport = transport
        self.clock = clock
        self.config = config
        inputLabel = transport.inputLabel
    }

    var notice: String? { transport.notice }

    /// Milliseconds since `start()`; frozen once ended.
    var elapsedMs: Int64 {
        switch state {
        case .idle: 0
        case .ended: (endedAtMs ?? originMs) - originMs
        default: clock.nowMs - originMs
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !state.isActive else { return }
        let token = startGate.begin()
        resetForStart()
        let myGeneration = generation
        state = .starting
        do {
            try await transport.start { [weak self] event in
                self?.handle(event, generation: myGeneration)
            }
        } catch {
            guard startGate.isCurrent(token) else { throw CaptureError.cancelled }
            finish(.failed(error.localizedDescription))
            throw error
        }
        guard startGate.isCurrent(token) else {
            // A newer start() owns the transport now; only tear down if nobody does.
            if !state.isActive { transport.stop() }
            throw CaptureError.cancelled
        }
        inputLabel = transport.inputLabel
        transportOriginMs = now
        silenceAnchorMs = now
        state = .listening
        clock.startTicking(everyMs: config.tickIntervalMs) { [weak self] in self?.tick() }
    }

    func stop() {
        startGate.supersede()
        guard state.isActive else { return }
        finish(.stopped)
    }

    func pause() {
        switch state {
        case .listening, .userSpeaking, .thinking, .speaking: break
        default: return
        }
        let wasSpeaking = state == .speaking
        speechGeneration += 1
        transport.stopSpeaking()
        closeAssistantCaption()
        // Mid-speech the hypothesis is echo; otherwise it is the user's words, which the
        // transport finalizes and the session still accepts for `pauseFinalGraceMs`.
        if wasSpeaking { transport.flushHypothesis() }
        transport.setInputPaused(true)
        tailFlushPending = false
        pausedAtMs = now
        silenceMs = 0
        state = .paused
    }

    /// Never called automatically: after an interruption the user resumes by hand (privacy).
    func resume() {
        guard state == .paused else { return }
        partial = nil
        transport.setInputPaused(false)
        quietFromNow()
        state = .listening
    }

    // MARK: - Consumer turn

    func beginThinking() {
        guard state == .listening || state == .userSpeaking else { return }
        state = .thinking
        silenceMs = 0
    }

    func endThinking() {
        guard state == .thinking else { return }
        quietFromNow()
        state = .listening
    }

    /// Speaks `text` as Umma and gates the mic transcript until it (plus the echo tail) is over.
    /// A newer `say` interrupts this one.
    func say(_ text: String) async {
        switch state {
        case .listening, .userSpeaking, .thinking, .speaking: break
        default: return
        }
        guard !text.isEmpty else { return }
        speechGeneration += 1
        let mine = speechGeneration
        if state == .speaking {
            transport.stopSpeaking()
            closeAssistantCaption()
        }
        // The user's in-flight words become a segment before the mic is cut (nothing is lost);
        // the transport then drops the hypothesis so no echo can merge into it.
        promotePartial()
        transport.flushHypothesis()
        tailFlushPending = false
        state = .speaking
        silenceMs = 0
        appendCaption(.assistant, text: text, startMs: now, endMs: now, isFinal: false)
        await transport.speak(text)
        guard mine == speechGeneration, state == .speaking else { return }
        closeAssistantCaption()
        // Drop whatever the mic picked up while Umma spoke, and again once the echo tail ends.
        transport.flushHypothesis()
        tailFlushPending = true
        echoGuardUntilMs = now + config.echoTailMs
        quietFromNow()
        state = .listening
    }

    // MARK: - Transport events

    private func handle(_ event: VoiceTransportEvent, generation eventGeneration: Int) {
        guard eventGeneration == generation, state.isActive, state != .starting else { return }
        switch event {
        case let .transcript(text, isFinal, startOffset, endOffset):
            handleTranscript(text, isFinal: isFinal, startOffset: startOffset, endOffset: endOffset)
        case .voiceActivity(let speaking):
            guard state != .paused, !isGated else { return }
            noteSpeech()
            if speaking, state == .listening { state = .userSpeaking }
            if !speaking, state == .userSpeaking, partial == nil { state = .listening }
        case .inputChanged(let label):
            inputLabel = label
        case .interruption(let began):
            // A call, Siri or an alarm pauses the session; it stays paused until the user taps
            // Resume, so the mic never reopens on its own.
            if began { pause() }
        case .failed(let message):
            finish(.failed(message))
        }
    }

    private func handleTranscript(_ text: String, isFinal: Bool, startOffset: Int64?, endOffset: Int64?) {
        if state == .paused {
            // Only the final for words heard before the pause, and only briefly.
            guard isFinal, let pausedAtMs, now - pausedAtMs <= config.pauseFinalGraceMs else { return }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGated {
            // Barge-in is limited to the stop command, and only from a transport that keeps
            // listening while Umma speaks (the on-device one gates its mic instead).
            if isFinal, VoiceCommand.parse(trimmed) == .stop { finish(.stopCommand) }
            return
        }
        guard !trimmed.isEmpty else { return }
        if state != .paused { noteSpeech() }
        // Session clock, clamped so segments never land in the future or run backwards.
        let endMs = min(endOffset.map { transportOriginMs + $0 } ?? now, now)
        let startMs = min(startOffset.map { transportOriginMs + $0 } ?? partial?.startMs ?? endMs, endMs)
        guard isFinal else {
            partial = VoiceSegment(id: -1, speaker: .user, text: trimmed, startMs: startMs, endMs: endMs, isFinal: false)
            if state == .listening { state = .userSpeaking }
            return
        }
        partial = nil
        if VoiceCommand.parse(trimmed) == .stop {
            finish(.stopCommand)
            return
        }
        let segment = appendCaption(.user, text: trimmed, startMs: startMs, endMs: endMs, isFinal: true)
        if state == .userSpeaking { state = .listening }
        onEvent?(.userSegment(segment))
    }

    // MARK: - Clock

    private func tick() {
        if state == .paused, let pausedAtMs, now - pausedAtMs > config.pauseFinalGraceMs {
            partial = nil
        }
        guard state == .listening || state == .userSpeaking else { return }
        if tailFlushPending, now >= echoGuardUntilMs {
            tailFlushPending = false
            transport.flushHypothesis()
        }
        silenceMs = max(0, now - silenceAnchorMs)
        if !pauseReported, silenceMs >= config.pauseThresholdMs {
            pauseReported = true
            if state == .userSpeaking { state = .listening }
            onEvent?(.pause(silenceMs: silenceMs))
        }
        if let timeout = config.silenceTimeoutMs, silenceMs >= timeout {
            finish(.silenceTimeout)
        }
    }

    // MARK: - Helpers

    private func promotePartial() {
        guard let partial else { return }
        self.partial = nil
        let segment = appendCaption(.user, text: partial.text, startMs: partial.startMs, endMs: now, isFinal: true)
        onEvent?(.userSegment(segment))
    }

    private var now: Int64 { clock.nowMs - originMs }

    private var isGated: Bool { state == .speaking || now < echoGuardUntilMs }

    private func noteSpeech() {
        lastSpeechAt = now
        silenceAnchorMs = now
        silenceMs = 0
        pauseReported = false
    }

    /// Silence restarts from now, and no pause is reported until the user speaks again (Umma
    /// finishing a line, or a resume, is not the user pausing).
    private func quietFromNow() {
        silenceAnchorMs = now
        silenceMs = 0
        pauseReported = true
    }

    private func resetForStart() {
        generation += 1
        speechGeneration += 1
        originMs = clock.nowMs
        endedAtMs = nil
        userCaptions = []
        assistantCaptions = []
        partial = nil
        silenceMs = 0
        lastSpeechAt = nil
        pauseReported = true
        echoGuardUntilMs = .min
        tailFlushPending = false
        pausedAtMs = nil
    }

    private func finish(_ reason: VoiceEndReason) {
        generation += 1
        speechGeneration += 1
        clock.stopTicking()
        transport.stopSpeaking()
        transport.stop()
        closeAssistantCaption()
        endedAtMs = clock.nowMs
        partial = nil
        state = .ended(reason)
        onEvent?(.ended(reason))
    }

    @discardableResult
    private func appendCaption(_ speaker: VoiceSpeaker, text: String, startMs: Int64, endMs: Int64, isFinal: Bool) -> VoiceSegment {
        nextSegmentId += 1
        let segment = VoiceSegment(id: nextSegmentId, speaker: speaker, text: text, startMs: startMs, endMs: endMs, isFinal: isFinal)
        switch speaker {
        case .user: userCaptions = Array((userCaptions + [segment]).suffix(config.captionLimit))
        case .assistant: assistantCaptions = Array((assistantCaptions + [segment]).suffix(config.captionLimit))
        }
        return segment
    }

    /// Stamps the end time on Umma's line once it finishes or is cut off.
    private func closeAssistantCaption() {
        guard let last = assistantCaptions.last, !last.isFinal else { return }
        assistantCaptions[assistantCaptions.count - 1] = VoiceSegment(
            id: last.id, speaker: .assistant, text: last.text, startMs: last.startMs, endMs: now, isFinal: true)
    }
}
