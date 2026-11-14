import AVFoundation
import Foundation
import Speech
import os

/// Free tier (brief 012): continuous on-device speech recognition and the Apple voice, both on
/// one voice-processing `AVAudioEngine` so iOS echo cancellation hears Umma's voice as the
/// reference and removes it from the mic.
///
/// - Recognition rolls tasks (`RecognitionRoller`) at pauses and before Apple's ~1-minute limit,
///   so a 45-minute session never loses words, and every segment is stamped on one audio clock.
/// - Voice activity comes from mic levels (`VoiceActivityDetector`), independent of recognition.
/// - While Umma speaks the mic feeds nothing to recognition (the session also flushes the
///   hypothesis when speech ends and after the echo tail), so Umma never hears itself.
/// - Timestamps use host time since `start`, paused time included, so the session can put them
///   on its own clock.
/// - Pause finalizes the words already heard, then stops the engine. Interruptions are reported
///   (the session pauses and waits for the user); route changes update the honest input label.
///
/// Threading: the mic tap, recognizer and synthesizer callbacks are built by `nonisolated`
/// factories and reach the main actor through `post`, tagged with the run generation.
@MainActor
final class OnDeviceVoiceTransport: VoiceTransport {
    let tier: VoiceTier = .free
    let isAvailable: Bool
    let notice: String? = nil
    private(set) var inputLabel = VoiceInputLabel.builtIn

    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private let tap = VoiceInputTap()
    private let speech = EngineSpeechPlayer()
    private var roller = RecognitionRoller()
    private var requests: [Int: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var tasks: [Int: SFSpeechRecognitionTask] = [:]
    private var onEvent: (@MainActor @Sendable (VoiceTransportEvent) -> Void)?
    private var startGate = CaptureStartGate()
    private var generation = 0
    private var isRunning = false
    private var isInputPaused = false
    private var failures = 0
    private var speakGeneration = 0
    private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var rollTicker: Task<Void, Never>?
    private let observers = NotificationObserverBag()
    private let logger = Logger(subsystem: "com.umma.ios", category: "voice")

    init(enabled: Bool = true, locale: Locale = .current) {
        let recognizer = SFSpeechRecognizer(locale: locale)
        self.recognizer = recognizer
        #if targetEnvironment(simulator)
        isAvailable = false
        #else
        isAvailable = enabled && (recognizer?.isAvailable ?? false)
        #endif
        observeAudioSession()
    }

    // MARK: - VoiceTransport

    func start(onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws {
        guard isAvailable, recognizer != nil else {
            throw CaptureError.unavailable(.phone, reason: "On-device speech recognition is not available.")
        }
        if isRunning { stop() }
        let token = startGate.begin()
        try await Self.ensurePermissions()
        guard startGate.isCurrent(token) else { throw CaptureError.cancelled }

        generation += 1
        self.onEvent = onEvent
        roller = RecognitionRoller()
        failures = 0
        do {
            let session = AVAudioSession.sharedInstance()
            previousAudio = (session.category, session.mode, session.categoryOptions)
            // voiceChat pairs with voice processing and allows Bluetooth HFP inputs.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try engine.inputNode.setVoiceProcessingEnabled(true)
            speech.attach(to: engine)
            tap.reset(originSeconds: VoiceInputTap.nowSeconds())
            installTap()
            engine.prepare()
            try engine.start()
        } catch {
            logger.error("voice start failed: \(error.localizedDescription, privacy: .public)")
            teardown()
            throw error
        }
        isRunning = true
        isInputPaused = false
        refreshInputLabel()
        beginTask()
        startRollTicker()
    }

    func stop() {
        startGate.supersede()
        guard isRunning else { return }
        teardown()
    }

    func setInputPaused(_ paused: Bool) {
        guard isRunning, paused != isInputPaused else { return }
        isInputPaused = paused
        if paused {
            tap.setPaused(true)
            // Keep what was heard: the retired task finalizes it while the engine is paused.
            roll(discard: false)
            engine.pause()
        } else {
            do {
                // An interruption may have deactivated the session, and a route change while
                // paused may have changed the input format: re-activate and re-tap first.
                try AVAudioSession.sharedInstance().setActive(true)
                installTap()
                try engine.start()
            } catch {
                post(.failed("The microphone could not restart."))
                return
            }
            refreshInputLabel()
            tap.setGated(false)
            tap.setPaused(false)
            // The task opened at pause heard nothing and may have timed out: start fresh.
            roll(discard: true)
        }
    }

    func flushHypothesis() {
        guard isRunning else { return }
        roll(discard: true)
    }

    func speak(_ text: String) async {
        guard isRunning, engine.isRunning else { return }
        speakGeneration += 1
        let mine = speakGeneration
        // The mic feeds recognition nothing while Umma talks; the task gets a clean start.
        tap.setGated(true)
        roll(discard: true)
        await speech.speak(text)
        if mine == speakGeneration { tap.setGated(false) }
    }

    func stopSpeaking() {
        speech.stop()
    }

    // MARK: - Recognition tasks

    private func beginTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        let id = roller.beginTask(atAudioMs: tap.nowMs)
        requests[id] = request
        tap.setRequest(request)
        tasks[id] = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeResultHandler(task: id, sink: makeResultSink())
        )
    }

    /// New task first (the mic switches to it), then the old one's audio ends so it finalizes.
    private func roll(discard: Bool) {
        failures = 0
        let old = roller.currentTask
        roller.retireCurrent(discard: discard)
        beginTask()
        requests.removeValue(forKey: old)?.endAudio()
        if discard { tasks.removeValue(forKey: old)?.cancel() }
    }

    private func handleResult(_ result: RecognizerResult, generation resultGeneration: Int) {
        guard resultGeneration == generation, isRunning else { return }
        if result.failed || result.isFinal {
            let event = result.failed
                ? roller.taskEnded(result.task)
                : roller.result(task: result.task, text: result.text, isFinal: true, pieces: result.pieces)
            tasks[result.task] = nil
            requests[result.task] = nil
            if let event { post(event) }
            if result.task == roller.currentTask, !isInputPaused {
                // The live task died (long silence, recognizer hiccup): carry on with a new one.
                failures = result.failed ? failures + 1 : 0
                if failures > 3 { post(.failed("Speech recognition stopped working.")) } else { beginTask() }
            }
            return
        }
        failures = 0
        if let event = roller.result(task: result.task, text: result.text, isFinal: false, pieces: result.pieces) {
            post(event)
        }
    }

    private func startRollTicker() {
        rollTicker?.cancel()
        rollTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                let audioMs = tap.nowMs
                if isRunning, !isInputPaused, roller.shouldRoll(audioMs: audioMs, silentForMs: tap.silentFor(atMs: audioMs)) {
                    roll(discard: false)
                }
            }
        }
    }

    // MARK: - Audio plumbing

    private func installTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                         block: Self.makeTapBlock(tap: tap, sink: makeSink()))
    }

    private func teardown() {
        isRunning = false
        generation += 1
        rollTicker?.cancel()
        rollTicker = nil
        speech.stop()
        tap.setRequest(nil)
        requests.values.forEach { $0.endAudio() }
        tasks.values.forEach { $0.cancel() }
        requests = [:]
        tasks = [:]
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            // Hand the app back the audio setup it had before voice mode.
            if let previous = previousAudio {
                try session.setCategory(previous.0, mode: previous.1, options: previous.2)
            }
        } catch {
            logger.debug("audio session restore: \(error.localizedDescription, privacy: .public)")
        }
        previousAudio = nil
    }

    private func post(_ event: VoiceTransportEvent) {
        onEvent?(event)
    }

    private func makeSink() -> @Sendable (VoiceTransportEvent) -> Void {
        let runGeneration = generation
        return { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == runGeneration, self.isRunning else { return }
                self.post(event)
            }
        }
    }

    private func makeResultSink() -> @Sendable (RecognizerResult) -> Void {
        let runGeneration = generation
        return { [weak self] result in
            Task { @MainActor in self?.handleResult(result, generation: runGeneration) }
        }
    }

    private func refreshInputLabel() {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        let label = VoiceInputLabel.label(portType: input?.portType, portName: input?.portName)
        guard label != inputLabel else { return }
        inputLabel = label
        if isRunning { post(.inputChanged(label: label)) }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in self?.interruption(began: began) }
        })
        observers.add(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshInputLabel() }
        })
        observers.add(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.engineConfigurationChanged() }
        })
    }

    /// The session pauses on `began` and stays paused; the mic only reopens through
    /// `setInputPaused(false)`, which re-activates the audio session first.
    private func interruption(began: Bool) {
        guard isRunning else { return }
        post(.interruption(began: began))
    }

    /// A route change stops the engine and may change the input format: re-tap and restart.
    /// While paused nothing restarts; resume re-taps.
    private func engineConfigurationChanged() {
        guard isRunning, !isInputPaused else { return }
        installTap()
        do { try engine.start() } catch { post(.failed("The microphone changed and could not restart.")) }
    }

    // MARK: - Nonisolated factories (callbacks must not inherit main-actor isolation)

    nonisolated private static func makeTapBlock(tap: VoiceInputTap, sink: @escaping @Sendable (VoiceTransportEvent) -> Void) -> AVAudioNodeTapBlock {
        { buffer, when in
            let seconds = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : VoiceInputTap.nowSeconds()
            if let activity = tap.process(buffer, atSeconds: seconds) { sink(.voiceActivity(activity)) }
        }
    }

    nonisolated private static func makeResultHandler(task: Int, sink: @escaping @Sendable (RecognizerResult) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let segments = result?.bestTranscription.segments ?? []
            let value = RecognizerResult(
                task: task,
                text: result?.bestTranscription.formattedString ?? "",
                isFinal: result?.isFinal ?? false,
                failed: error != nil && !(result?.isFinal ?? false),
                pieces: segments.map { .init(timestamp: $0.timestamp, duration: $0.duration) }
            )
            sink(value)
        }
    }

    nonisolated private static func ensurePermissions() async throws {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            throw CaptureError.permissionDenied(
                permission: "Speech Recognition",
                explainer: "Voice mode turns what you say into text on this iPhone. Allow Speech Recognition in Settings → Umma."
            )
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw CaptureError.permissionDenied(
                permission: "Microphone",
                explainer: "Voice mode listens only while it's on, and you can see it on screen. Allow microphone access in Settings → Umma."
            )
        }
    }
}

/// One recognizer callback, copied out of the non-Sendable result on the recognizer's queue.
private struct RecognizerResult: Sendable {
    let task: Int
    let text: String
    let isFinal: Bool
    let failed: Bool
    let pieces: [RecognitionRoller.Piece]
}

/// The honest input name for the voice bar. A Bluetooth headset is named as one; it is never
/// called "glasses" here (that needs the verified HFP route check of the glasses adapter).
enum VoiceInputLabel {
    static let builtIn = "iPhone mic"

    static func label(portType: AVAudioSession.Port?, portName: String?) -> String {
        switch portType {
        case .builtInMic?, nil: builtIn
        case .headsetMic?: "Headset mic"
        case .bluetoothHFP?: "Bluetooth mic" + (portName.map { " (\($0))" } ?? "")
        case .usbAudio?: "USB mic"
        case .carAudio?: "Car mic"
        default: portName ?? "External mic"
        }
    }
}

/// Mic tap state shared with the audio thread: where buffers go, the clock and the
/// voice-activity detector, under one lock. Time is host time since `reset`, so it keeps running
/// through pauses, gating and engine restarts.
final class VoiceInputTap: @unchecked Sendable {
    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var paused = false
        /// Umma is speaking: the mic must not reach recognition or voice activity.
        var gated = false
        var originSeconds: Double = 0
        var detector = VoiceActivityDetector()
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let now: @Sendable () -> Double

    init(now: @escaping @Sendable () -> Double = VoiceInputTap.nowSeconds) {
        self.now = now
    }

    /// Host-time seconds (`mach_absolute_time`), the same base as `AVAudioTime.hostTime`.
    static func nowSeconds() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// Milliseconds since `reset`, wall time.
    var nowMs: Int64 {
        let origin = state.withLockUnchecked { $0.originSeconds }
        return Self.ms(now() - origin)
    }

    func silentFor(atMs: Int64) -> Int64 { state.withLockUnchecked { $0.detector.silentFor(atMs: atMs) } }

    func reset(originSeconds: Double) {
        state.withLockUnchecked { $0 = State(); $0.originSeconds = originSeconds }
    }

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        state.withLockUnchecked { $0.request = request }
    }

    func setPaused(_ paused: Bool) { state.withLockUnchecked { $0.paused = paused } }

    func setGated(_ gated: Bool) { state.withLockUnchecked { $0.gated = gated } }

    /// Audio thread: forward the buffer and return a voice-activity change. `atSeconds` is the
    /// buffer's host time.
    func process(_ buffer: AVAudioPCMBuffer, atSeconds: Double) -> Bool? {
        let level = buffer.floatChannelData.map {
            VoiceActivityDetector.levelDb(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength)))
        } ?? -160
        return state.withLockUnchecked { state -> Bool? in
            guard !state.paused, !state.gated else { return nil }
            state.request?.append(buffer)
            return state.detector.process(levelDb: level, atMs: Self.ms(atSeconds - state.originSeconds))
        }
    }

    /// Whether a buffer would reach recognition right now (tests).
    var isFeeding: Bool { state.withLockUnchecked { !$0.paused && !$0.gated } }

    private static func ms(_ seconds: Double) -> Int64 { Int64((max(0, seconds) * 1000).rounded()) }
}

/// The Apple voice rendered into the engine (not the system output), so voice processing uses it
/// as the echo reference. `speak` returns when playback ends or `stop()` cuts it off.
final class EngineSpeechPlayer: @unchecked Sendable {
    private struct State {
        var generation = 0
        var format: AVAudioFormat?
        var converter: AVAudioConverter?
        var pending: CheckedContinuation<Void, Never>?
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let player = AVAudioPlayerNode()
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func attach(to engine: AVAudioEngine) {
        if player.engine == nil { engine.attach(player) }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1)
        state.withLockUnchecked { $0.format = format }
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func speak(_ text: String) async {
        stop()
        guard let format = state.withLockUnchecked({ $0.format }) else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let generation = state.withLockUnchecked { state -> Int in
                state.generation += 1
                state.converter = nil
                state.pending = continuation
                return state.generation
            }
            // Safety net: if the synthesizer never sends its empty end buffer, don't hold the
            // session in "speaking" (and its mic gated) forever.
            let deadline = Self.timeout(for: text)
            Task { [weak self] in
                try? await Task.sleep(for: deadline)
                self?.finish(generation: generation)
            }
            synthesizer.write(utterance) { [weak self] buffer in
                self?.receive(buffer, generation: generation, format: format)
            }
        }
    }

    /// Cuts speech off. Bumps the generation first, so synthesizer buffers still in flight are
    /// dropped instead of being scheduled (or played on a stopped engine).
    func stop() {
        state.withLockUnchecked { $0.generation += 1 }
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        finish(generation: nil)
    }

    /// Whether buffers for `generation` would still play (tests).
    func isCurrent(_ generation: Int) -> Bool { state.withLockUnchecked { $0.generation == generation } }

    var currentGeneration: Int { state.withLockUnchecked { $0.generation } }

    /// Generous: about 8 characters a second at the slowest, plus slack.
    static func timeout(for text: String) -> Duration {
        .milliseconds(5000 + 125 * text.count)
    }

    private func playIfPossible(_ generation: Int) {
        guard isCurrent(generation), player.engine?.isRunning == true, !player.isPlaying else { return }
        player.play()
    }

    private func receive(_ buffer: AVAudioBuffer, generation: Int, format: AVAudioFormat) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        guard pcm.frameLength > 0 else {
            // The synthesizer is done: resume once everything scheduled has played. A one-frame
            // silent marker carries the completion.
            guard isCurrent(generation), player.engine?.isRunning == true,
                  let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return }
            marker.frameLength = 1
            marker.floatChannelData?[0][0] = 0
            player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.finish(generation: generation)
            }
            playIfPossible(generation)
            return
        }
        let converted: AVAudioPCMBuffer? = state.withLockUnchecked { state in
            guard state.generation == generation else { return nil }
            if state.converter == nil { state.converter = AVAudioConverter(from: pcm.format, to: format) }
            return state.converter.flatMap { Self.convert(pcm, with: $0, to: format) }
        }
        guard let converted, isCurrent(generation), player.engine?.isRunning == true else { return }
        player.scheduleBuffer(converted)
        playIfPossible(generation)
    }

    /// Resumes the waiting `speak` (only the current one when `generation` is given).
    private func finish(generation: Int?) {
        let pending = state.withLockUnchecked { state -> CheckedContinuation<Void, Never>? in
            guard generation == nil || generation == state.generation else { return nil }
            defer { state.pending = nil }
            return state.pending
        }
        pending?.resume()
    }

    private static func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        // The converter calls the block synchronously, inside `convert`, so the buffer never
        // actually crosses threads.
        nonisolated(unsafe) let source = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            let first = supplied.withLock { done in
                defer { done = true }
                return !done
            }
            status.pointee = first ? .haveData : .noDataNow
            return first ? source : nil
        }
        return error == nil ? output : nil
    }
}
