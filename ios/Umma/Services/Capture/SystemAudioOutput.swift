import AVFoundation
import Foundation
import Observation
import os

/// `AVSpeechSynthesizer`-backed `AudioOutput`. Works on the simulator too.
///
/// Each `speak` awaits its own utterance: the delegate keys continuations by the utterance
/// object, so a finish/cancel for an older utterance can never resume a newer caller, and
/// `stop()` resumes every pending caller so nothing leaks.
@MainActor
@Observable
final class SystemAudioOutput: AudioOutput {
    let isAvailable: Bool
    private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeechDelegate()
    private var current: ObjectIdentifier?

    init(enabled: Bool = true) {
        isAvailable = enabled
        synthesizer.delegate = delegate
    }

    /// A new utterance interrupts the one in flight (the coach says one thing at a time).
    func speak(_ text: String, pace: SpeechPace) async {
        guard isAvailable, !text.isEmpty else { return }
        interrupt()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (pace == .slow ? 0.7 : 0.95)
        let id = ObjectIdentifier(utterance)
        current = id
        isSpeaking = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.register(id) { continuation.resume() }
            synthesizer.speak(utterance)
        }

        // Only the utterance that is still current may clear the indicator.
        if current == id {
            current = nil
            isSpeaking = false
        }
    }

    func stop() {
        interrupt()
        current = nil
        isSpeaking = false
    }

    /// Unconditional: `stopSpeaking` also flushes utterances that are queued but not yet speaking.
    private func interrupt() {
        synthesizer.stopSpeaking(at: .immediate)
        delegate.resumeAll()
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let pending = OSAllocatedUnfairLock<[ObjectIdentifier: @Sendable () -> Void]>(initialState: [:])

    func register(_ id: ObjectIdentifier, _ resume: @escaping @Sendable () -> Void) {
        pending.withLock { $0[id] = resume }
    }

    func resumeAll() {
        let callbacks = pending.withLock { table -> [@Sendable () -> Void] in
            let all = Array(table.values)
            table.removeAll()
            return all
        }
        callbacks.forEach { $0() }
    }

    private func resume(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let callback = pending.withLock { $0.removeValue(forKey: id) }
        callback?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume(utterance)
    }
}
