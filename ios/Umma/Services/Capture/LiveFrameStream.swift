import CoreImage
import Foundation
import ImageIO
import os

/// Brief 016 live scan: a camera that can also hand out a low-rate stream of small JPEG frames.
/// Frames are in memory only and never written to disk (brief 016: "never stored on the phone").
@MainActor
protocol FrameStreamingCameraSource: CameraSource {
    /// Frames flow only while the preview is running from a current start. At most one stream is
    /// live: a new call finishes the previous one. `stopPreview()` finishes it; cancelling the
    /// consuming task stops delivery.
    func frames(maxFPS: Double, longEdge: CGFloat) -> AsyncStream<CapturedFrame>
}

extension FrameStreamingCameraSource {
    func frames() -> AsyncStream<CapturedFrame> {
        frames(maxFPS: LiveFrameDefaults.maxFPS, longEdge: LiveFrameDefaults.longEdge)
    }
}

enum LiveFrameDefaults {
    /// Brief 016: "no more than 1 per second".
    static let maxFPS: Double = 1
    static let longEdge: CGFloat = 768
    static let jpegQuality: CGFloat = 0.6
    /// Upper bound on what a caller may ask for; the screen never needs more.
    static let fpsCeiling: Double = 30
}

/// Pure rate limiter: admits a frame only when `minInterval` has passed since the last admitted one.
/// Times are seconds on any monotonic clock (sample-buffer presentation time on device).
struct FrameThrottle: Sendable, Equatable {
    let minInterval: TimeInterval
    private(set) var lastAdmitted: TimeInterval?

    init(maxFPS: Double) {
        let fps = maxFPS.isFinite && maxFPS > 0 ? min(maxFPS, LiveFrameDefaults.fpsCeiling) : LiveFrameDefaults.maxFPS
        minInterval = 1 / fps
    }

    func allows(at time: TimeInterval) -> Bool {
        guard let lastAdmitted else { return true }
        return time - lastAdmitted >= minInterval
    }

    /// Spends the slot. Called only once a frame was actually produced.
    mutating func record(_ time: TimeInterval) {
        lastAdmitted = time
    }

    mutating func admit(at time: TimeInterval) -> Bool {
        guard allows(at: time) else { return false }
        record(time)
        return true
    }
}

/// Downscales a camera image and encodes it as JPEG. Synchronous; callers run it off the main
/// actor (the phone camera runs it on its video queue).
enum LiveFrameEncoder {
    static func encode(
        _ image: CIImage,
        longEdge: CGFloat = LiveFrameDefaults.longEdge,
        quality: CGFloat = LiveFrameDefaults.jpegQuality,
        context: CIContext
    ) -> Data? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        let target = PantryImageEncoder.targetSize(for: extent.size, maxLongEdge: longEdge)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / extent.width, y: target.height / extent.height))
            .cropped(to: CGRect(origin: .zero, size: target))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        return context.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: options)
    }
}

/// Hands frames from a capture queue to one `AsyncStream` consumer. Thread-safe: `offer` is called
/// on the camera's video queue, everything else on the main actor.
///
/// A frame is delivered only while `isDelivering` (the owner sets it from its start gate and session
/// state), a consumer exists, and the consumer's throttle admits it. The encode closure runs only
/// for admitted frames, outside the lock; a failed encode doesn't spend the throttle slot.
///
/// `onConsumerChange` fires (outside the lock) whenever a consumer arrives or leaves, so the phone
/// camera can switch its video connection off while nobody wants frames.
final class LiveFrameHub: @unchecked Sendable {
    private struct Consumer {
        let id: UUID
        let continuation: AsyncStream<CapturedFrame>.Continuation
        var throttle: FrameThrottle
        let longEdge: CGFloat
    }

    private struct State {
        var delivering = false
        var consumer: Consumer?
        var onConsumerChange: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let buffering: AsyncStream<CapturedFrame>.Continuation.BufferingPolicy

    /// Live scan wants the newest frame only; a slow consumer must never see a stale backlog.
    init(buffering: AsyncStream<CapturedFrame>.Continuation.BufferingPolicy = .bufferingNewest(1)) {
        self.buffering = buffering
    }

    func makeStream(maxFPS: Double, longEdge: CGFloat) -> AsyncStream<CapturedFrame> {
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: buffering)
        let id = UUID()
        let previous = state.withLock { state -> Consumer? in
            let old = state.consumer
            state.consumer = Consumer(id: id, continuation: continuation, throttle: FrameThrottle(maxFPS: maxFPS),
                                      longEdge: longEdge > 0 ? longEdge : LiveFrameDefaults.longEdge)
            return old
        }
        previous?.continuation.finish()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            let released = state.withLock { state -> Bool in
                guard state.consumer?.id == id else { return false }
                state.consumer = nil
                return true
            }
            if released { notifyConsumerChange() }
        }
        notifyConsumerChange()
        return stream
    }

    var hasConsumer: Bool {
        state.withLock { $0.consumer != nil }
    }

    func setConsumerChangeHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.onConsumerChange = handler }
    }

    private func notifyConsumerChange() {
        state.withLock { $0.onConsumerChange }?()
    }

    /// True while frames would be delivered. The video delegate checks it before touching pixels.
    var wantsFrames: Bool {
        state.withLock { $0.delivering && $0.consumer != nil }
    }

    var isDelivering: Bool {
        state.withLock { $0.delivering }
    }

    func setDelivering(_ delivering: Bool) {
        state.withLock { $0.delivering = delivering }
    }

    /// Stops delivery and finishes the current stream (preview stopped).
    func finish() {
        let consumer = state.withLock { state -> Consumer? in
            state.delivering = false
            let old = state.consumer
            state.consumer = nil
            return old
        }
        consumer?.continuation.finish()
        if consumer != nil { notifyConsumerChange() }
    }

    /// Offers a frame captured at `time`. Returns true if one was yielded.
    @discardableResult
    func offer(at time: TimeInterval, make: (_ longEdge: CGFloat) -> CapturedFrame?) -> Bool {
        let admitted = state.withLock { state -> (id: UUID, longEdge: CGFloat)? in
            guard state.delivering, let consumer = state.consumer, consumer.throttle.allows(at: time) else { return nil }
            return (consumer.id, consumer.longEdge)
        }
        guard let admitted, let frame = make(admitted.longEdge) else { return false }
        // Re-check: a stop or cancel while encoding drops the frame.
        return state.withLock { state in
            guard state.delivering, let consumer = state.consumer, consumer.id == admitted.id,
                  consumer.throttle.allows(at: time) else { return false }
            state.consumer?.throttle.record(time)
            if case .terminated = consumer.continuation.yield(frame) { return false }
            return true
        }
    }
}
