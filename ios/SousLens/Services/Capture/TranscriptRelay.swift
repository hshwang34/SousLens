import Foundation

/// Owns the transcript stream for one push-to-talk session and makes the recognizer's callbacks
/// safe to consume: every event carries the generation it was produced under, stale generations
/// are dropped, and `requestFinish` keeps the stream open for a bounded grace period so the final
/// (`isFinal`) transcript after `endAudio()` still reaches the consumer.
@MainActor
final class TranscriptRelay {
    struct Event: Sendable, Equatable {
        let generation: Int
        let text: String?
        let isFinal: Bool
        let failed: Bool
    }

    private(set) var generation = 0
    private var continuation: AsyncStream<TranscriptChunk>.Continuation?
    private var graceTask: Task<Void, Never>?
    /// Called once per session when its stream closes (final result, failure, grace timeout, or a
    /// newer `begin()`), with that session's generation.
    var onFinished: ((Int) -> Void)?

    var isActive: Bool { continuation != nil }
    /// True between `requestFinish` and the stream closing.
    var isFinishing: Bool { graceTask != nil }

    /// Closes any previous session and opens a new stream.
    func begin() -> (generation: Int, stream: AsyncStream<TranscriptChunk>) {
        finishCurrent()
        generation += 1
        let (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
        self.continuation = continuation
        return (generation, stream)
    }

    /// Thread-agnostic entry point for recognizer callbacks; hops to the main actor.
    nonisolated func makeSink() -> @Sendable (Event) -> Void {
        { event in
            Task { @MainActor in self.handle(event) }
        }
    }

    func handle(_ event: Event) {
        guard event.generation == generation, let continuation else { return }
        if let text = event.text, !text.isEmpty {
            continuation.yield(TranscriptChunk(text: text, isFinal: event.isFinal, receivedAt: Date()))
        }
        if event.isFinal || event.failed {
            finishCurrent()
        }
    }

    /// Stop was requested: keep the stream open up to `grace` for the final result, then close.
    func requestFinish(grace: Duration) {
        guard continuation != nil, graceTask == nil else { return }
        let myGeneration = generation
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, self.generation == myGeneration else { return }
            self.finishCurrent()
        }
    }

    /// Immediate close (failed start, deinit).
    func cancel() {
        finishCurrent()
    }

    private func finishCurrent() {
        graceTask?.cancel()
        graceTask = nil
        guard let continuation else { return }
        continuation.finish()
        self.continuation = nil
        onFinished?(generation)
    }
}
