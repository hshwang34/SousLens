import Foundation

/// Monotonic milliseconds plus a periodic tick, injectable so silence timing is testable without
/// waiting. `VoiceSession` turns `nowMs` into "ms since the session started".
@MainActor
protocol VoiceClock: AnyObject {
    var nowMs: Int64 { get }
    func startTicking(everyMs interval: Int64, _ tick: @escaping @MainActor () -> Void)
    func stopTicking()
}

/// `ContinuousClock` time (keeps counting while the device sleeps) and a main-actor tick loop.
@MainActor
final class SystemVoiceClock: VoiceClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private var ticker: Task<Void, Never>?

    init() {
        origin = clock.now
    }

    var nowMs: Int64 {
        let elapsed = origin.duration(to: clock.now).components
        return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    func startTicking(everyMs interval: Int64, _ tick: @escaping @MainActor () -> Void) {
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval))
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}
