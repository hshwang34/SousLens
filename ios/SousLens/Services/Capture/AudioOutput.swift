import Foundation

/// How fast an utterance is read. `.slow` is the cooking screen's **Slower** button (PRD §6.1).
enum SpeechPace: String, Sendable, Equatable {
    case normal
    case slow
}

/// Spoken output. `speak` returns when the utterance finishes or is stopped.
@MainActor
protocol AudioOutput: AnyObject {
    var isAvailable: Bool { get }
    var isSpeaking: Bool { get }

    func speak(_ text: String, pace: SpeechPace) async
    func stop()
}

extension AudioOutput {
    func speak(_ text: String) async {
        await speak(text, pace: .normal)
    }
}
