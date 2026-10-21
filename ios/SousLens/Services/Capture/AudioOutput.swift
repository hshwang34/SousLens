import Foundation

/// Spoken output. `speak` returns when the utterance finishes or is stopped.
@MainActor
protocol AudioOutput: AnyObject {
    var isAvailable: Bool { get }
    var isSpeaking: Bool { get }

    func speak(_ text: String) async
    func stop()
}
