import Foundation

/// Push-to-talk transcript source. `startListening()` yields partial + final chunks until `stop()`.
@MainActor
protocol SpeechInput: AnyObject {
    var kind: CaptureSourceKind { get }
    var isAvailable: Bool { get }
    var isListening: Bool { get }

    func startListening() async throws -> AsyncStream<TranscriptChunk>
    func stop()
}
