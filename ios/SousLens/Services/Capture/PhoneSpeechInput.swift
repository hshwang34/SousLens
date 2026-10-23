import AVFoundation
import Foundation
import Observation
import Speech
import os

/// Push-to-talk speech via `SFSpeechRecognizer` + `AVAudioEngine`. Listens only between
/// `startListening()` and `stop()`; no wake word (PRD §6.1).
///
/// Threading: the tap block and the recognition handler are built by `nonisolated` factories so
/// they never run as main-actor work; results reach the UI through `TranscriptRelay.makeSink()`.
/// `stop()` ends audio, tears the engine down, and lets the relay hold the stream open for
/// `finalResultGrace` so the recognizer's final transcript is still delivered.
@MainActor
@Observable
final class PhoneSpeechInput: SpeechInput {
    let kind: CaptureSourceKind = .phone
    let isAvailable: Bool
    private(set) var isListening = false

    /// How long `stop()` waits for the recognizer's `isFinal` result before closing the stream.
    var finalResultGrace: Duration = .milliseconds(1500)

    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private let relay = TranscriptRelay()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startGate = CaptureStartGate()
    private let observers = NotificationObserverBag()
    private let logger = Logger(subsystem: "com.souslens.ios", category: "speech")

    init(enabled: Bool = true, locale: Locale = .current) {
        let recognizer = SFSpeechRecognizer(locale: locale)
        self.recognizer = recognizer
        #if targetEnvironment(simulator)
        isAvailable = false
        #else
        isAvailable = enabled && (recognizer?.isAvailable ?? false)
        #endif
        relay.onFinished = { [weak self] generation in
            self?.sessionDidFinish(generation)
        }
        observeAudioSession()
    }

    func startListening() async throws -> AsyncStream<TranscriptChunk> {
        guard isAvailable, let recognizer else {
            throw CaptureError.unavailable(.phone, reason: "Speech recognition is not available on this device.")
        }
        if isListening { stop() }
        let startToken = startGate.begin()

        try await Self.ensurePermissions()
        // A stop() that arrived while the permission prompt was up wins: nothing may start.
        guard startGate.isCurrent(startToken) else {
            teardownAudio()
            finalizeRecognizer()
            throw CaptureError.cancelled
        }

        let (generation, stream) = relay.begin()
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(request: request))
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(
                with: request,
                resultHandler: Self.makeResultHandler(generation: generation, sink: relay.makeSink())
            )
            isListening = true
            return stream
        } catch {
            logger.error("startListening failed: \(error.localizedDescription, privacy: .public)")
            teardownAudio()
            finalizeRecognizer()
            relay.cancel()
            throw error
        }
    }

    /// Ends audio input immediately; the transcript stream closes once the final result arrives or
    /// after `finalResultGrace`, whichever comes first.
    func stop() {
        startGate.supersede()
        guard isListening else { return }
        isListening = false
        teardownAudio()
        request?.endAudio()
        relay.requestFinish(grace: finalResultGrace)
    }

    // MARK: - Lifecycle helpers

    private func sessionDidFinish(_ generation: Int) {
        guard generation == relay.generation else { return }
        if isListening {
            // Recognizer finished (final result or error) while we were still listening.
            isListening = false
            teardownAudio()
        }
        finalizeRecognizer()
    }

    private func teardownAudio() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.debug("audio session deactivate: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finalizeRecognizer() {
        task?.cancel()
        task = nil
        request = nil
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stop() }
        })
        observers.add(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // Our own `setCategory` posts `.categoryChange`; only react to a device coming or going
            // (headset/glasses connect or disconnect), where the input we were using is no longer true.
            guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                || raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
            else { return }
            Task { @MainActor in self?.stop() }
        })
    }

    // MARK: - Nonisolated factories (callbacks must not inherit main-actor isolation)

    nonisolated private static func makeTapBlock(request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func makeResultHandler(
        generation: Int,
        sink: @escaping @Sendable (TranscriptRelay.Event) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            sink(TranscriptRelay.Event(
                generation: generation,
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                failed: error != nil
            ))
        }
    }

    nonisolated private static func ensurePermissions() async throws {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw CaptureError.permissionDenied(
                permission: "Speech Recognition",
                explainer: "SousLens turns what you say into text so the coach can answer. Allow Speech Recognition in Settings → SousLens."
            )
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            throw CaptureError.permissionDenied(
                permission: "Microphone",
                explainer: "SousLens listens only while you hold the talk button. Allow microphone access in Settings → SousLens."
            )
        }
    }
}
