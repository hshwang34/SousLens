import Foundation
import Observation

/// Scriptable `CameraSource` for tests, previews, and when the phone camera flag is off.
@MainActor
@Observable
final class FakeCameraSource: CameraSource {
    let kind: CaptureSourceKind
    var isAvailable: Bool
    private(set) var activeIndicator = false
    /// Frames returned by `captureFrame()`, in order; the last one repeats.
    var scriptedFrames: [CapturedFrame]
    var startError: CaptureError?
    private(set) var captureCount = 0

    init(kind: CaptureSourceKind = .phone, isAvailable: Bool = true, scriptedFrames: [CapturedFrame] = []) {
        self.kind = kind
        self.isAvailable = isAvailable
        self.scriptedFrames = scriptedFrames
    }

    func startPreview() async throws {
        guard isAvailable else { throw CaptureError.unavailable(kind, reason: "Fake source marked unavailable.") }
        if let startError { throw startError }
        activeIndicator = true
    }

    func captureFrame() async throws -> CapturedFrame {
        guard activeIndicator else { throw CaptureError.notRunning }
        defer { captureCount += 1 }
        if scriptedFrames.isEmpty {
            return CapturedFrame(jpegData: Data(), capturedAt: Date())
        }
        return scriptedFrames[min(captureCount, scriptedFrames.count - 1)]
    }

    func stopPreview() async {
        activeIndicator = false
    }
}

@MainActor
@Observable
final class FakeSpeechInput: SpeechInput {
    let kind: CaptureSourceKind
    var isAvailable: Bool
    private(set) var isListening = false
    /// Chunks yielded as soon as listening starts; the stream stays open until `stop()`.
    var scriptedChunks: [TranscriptChunk]
    private var continuation: AsyncStream<TranscriptChunk>.Continuation?

    init(kind: CaptureSourceKind = .phone, isAvailable: Bool = true, scriptedChunks: [TranscriptChunk] = []) {
        self.kind = kind
        self.isAvailable = isAvailable
        self.scriptedChunks = scriptedChunks
    }

    func startListening() async throws -> AsyncStream<TranscriptChunk> {
        guard isAvailable else { throw CaptureError.unavailable(kind, reason: "Fake source marked unavailable.") }
        let (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
        self.continuation = continuation
        isListening = true
        for chunk in scriptedChunks {
            continuation.yield(chunk)
        }
        return stream
    }

    /// Push an extra chunk while listening (simulates the user speaking).
    func emit(_ text: String, isFinal: Bool = false) {
        continuation?.yield(TranscriptChunk(text: text, isFinal: isFinal, receivedAt: Date()))
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        isListening = false
    }
}

@MainActor
@Observable
final class FakeAudioOutput: AudioOutput {
    var isAvailable: Bool
    private(set) var isSpeaking = false
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    func speak(_ text: String) async {
        guard isAvailable else { return }
        isSpeaking = true
        spoken.append(text)
        isSpeaking = false
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
    }
}
