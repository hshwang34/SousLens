import AVFoundation
import CoreImage
import Foundation
import Observation
import UIKit
import os

/// What the capture session reports about itself. `activeIndicator` is derived from these (plus
/// `AVCaptureSession.isRunning` right after start/stop), never from a flag we set optimistically.
enum CameraSessionEvent: Sendable, Equatable {
    case started
    case stopped
    case interrupted
    case interruptionEnded
    case runtimeError(String)
}

enum CameraRunState {
    static func activeIndicator(after event: CameraSessionEvent) -> Bool {
        switch event {
        case .started, .interruptionEnded: return true
        case .stopped, .interrupted, .runtimeError: return false
        }
    }
}

/// AVFoundation-backed `CameraSource`. The session lives inside `pipeline` (an actor) so
/// `startRunning()` never blocks the main thread and non-Sendable AV objects stay isolated.
///
/// `startPreview()` runs the session so frames can be captured; the pantry-scan screen shows it
/// through `CameraPreviewProviding` (an `AVCaptureVideoPreviewLayer`, device only).
///
/// Live scan (brief 016) reads `frames()`: an `AVCaptureVideoDataOutput` on the same session feeds
/// `frameHub`, which throttles and downsizes. The session keeps the `.photo` preset, so still capture
/// is unchanged; with that preset the video output delivers preview-sized buffers (roughly screen
/// size), which is all a 768 px frame needs.
@MainActor
@Observable
final class PhoneCameraSource: FrameStreamingCameraSource, CameraPreviewProviding {
    let kind: CaptureSourceKind = .phone
    let isAvailable: Bool
    private(set) var activeIndicator = false

    private let pipeline: CameraPipeline
    private let frameHub = LiveFrameHub()
    /// Token of the start that completed and owns frame delivery. Any later start or stop makes
    /// it stale, so a superseded start never delivers frames.
    private var deliveryToken: Int?
    /// Bumped by every start/stop; a start that resumes after a newer stop/start gives up.
    private var startGate = CaptureStartGate()
    /// Latest caller intent. A superseded start only stops the session if the latest intent is
    /// "stopped" — it must never tear down a newer start that is running.
    private var wantsRunning = false
    private let observers = NotificationObserverBag()
    private let logger = Logger(subsystem: "com.umma.ios", category: "camera")

    init(enabled: Bool = true) {
        pipeline = CameraPipeline(frameHub: frameHub)
        #if targetEnvironment(simulator)
        isAvailable = false
        #else
        isAvailable = enabled && AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
        #endif
        // PRD §14: no lingering stream after backgrounding.
        observers.add(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.stopPreview() }
        })
    }

    func startPreview() async throws {
        guard isAvailable else {
            throw CaptureError.unavailable(.phone, reason: "No camera on this device or feature disabled.")
        }
        wantsRunning = true
        let token = startGate.begin()
        updateFrameDelivery()

        try await ensurePermission()
        try await superseded(unless: token)

        await pipeline.observe(Self.makeEventSink(owner: self))
        try await superseded(unless: token)

        try await pipeline.start()
        try await superseded(unless: token)
        activeIndicator = await pipeline.isRunning()
        // No await between this check and arming, so a stop that raced the line above wins.
        if startGate.isCurrent(token) { deliveryToken = token }
        updateFrameDelivery()
    }

    func frames(maxFPS: Double, longEdge: CGFloat) -> AsyncStream<CapturedFrame> {
        frameHub.makeStream(maxFPS: maxFPS, longEdge: longEdge)
    }

    /// Frames flow only from the start that is still current, while the session reports running.
    nonisolated static func shouldDeliverFrames(token: Int?, gate: CaptureStartGate, sessionActive: Bool) -> Bool {
        guard let token, sessionActive else { return false }
        return gate.isCurrent(token)
    }

    private func updateFrameDelivery() {
        frameHub.setDelivering(Self.shouldDeliverFrames(token: deliveryToken, gate: startGate, sessionActive: activeIndicator))
    }

    /// Throws `.cancelled` if a newer start/stop happened while we were suspended. Only when the
    /// latest intent is "stopped" does the losing start also stop the session.
    private func superseded(unless token: Int) async throws {
        guard !startGate.isCurrent(token) else { return }
        if !wantsRunning {
            await pipeline.stop()
            activeIndicator = await pipeline.isRunning()
        }
        throw CaptureError.cancelled
    }

    /// Connects a viewfinder layer to the running session. The session itself is never handed out.
    func attachPreview(to layer: AVCaptureVideoPreviewLayer) {
        pipeline.attach(layer)
    }

    func captureFrame() async throws -> CapturedFrame {
        guard activeIndicator else { throw CaptureError.notRunning }
        let data = try await pipeline.capturePhoto()
        return CapturedFrame(jpegData: data, capturedAt: Date())
    }

    func stopPreview() async {
        wantsRunning = false
        startGate.supersede()
        deliveryToken = nil
        frameHub.finish()
        await pipeline.stop()
        activeIndicator = await pipeline.isRunning()
    }

    private func apply(_ event: CameraSessionEvent) {
        if case .runtimeError(let message) = event {
            logger.error("capture session runtime error: \(message, privacy: .public)")
        }
        activeIndicator = CameraRunState.activeIndicator(after: event)
        updateFrameDelivery()
    }

    /// Built outside actor isolation so the notification callbacks never run as `@MainActor` work.
    nonisolated private static func makeEventSink(owner: PhoneCameraSource) -> @Sendable (CameraSessionEvent) -> Void {
        { [weak owner] event in
            Task { @MainActor in owner?.apply(event) }
        }
    }

    private func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw Self.deniedError }
        case .denied, .restricted:
            throw Self.deniedError
        @unknown default:
            throw Self.deniedError
        }
    }

    private static let deniedError = CaptureError.permissionDenied(
        permission: "Camera",
        explainer: "Umma needs the camera to scan your pantry and look at a step when you ask. Allow camera access in Settings → Umma."
    )
}

/// A camera that can show a live viewfinder. Only the phone camera does today.
@MainActor
protocol CameraPreviewProviding: AnyObject {
    func attachPreview(to layer: AVCaptureVideoPreviewLayer)
}

/// Owns the non-Sendable AVCapture objects and their notifications.
private actor CameraPipeline {
    /// Touched by this actor (configuration), by `sessionQueue` (start/stop, which block) and by
    /// `attach` (main thread, preview layer only), the split Apple's AVCam sample uses.
    /// Held in a Sendable box rather than `nonisolated(unsafe)`: older Swift 6 compilers (CI's
    /// Xcode) reject a non-Sendable value leaving a nonisolated(unsafe) context in `attach`.
    private let box = SessionBox(session: AVCaptureSession())
    private var session: AVCaptureSession { box.session }
    /// `startRunning()` / `stopRunning()` block for a noticeable time; they run here instead of on
    /// the actor's cooperative thread.
    private let sessionQueue = DispatchQueue(label: "com.umma.ios.camera.session")

    nonisolated func attach(_ layer: AVCaptureVideoPreviewLayer) {
        layer.session = box.session
    }

    private func onSessionQueue(_ work: @escaping @Sendable (AVCaptureSession) -> Void) async {
        let box = self.box
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                work(box.session)
                continuation.resume()
            }
        }
    }
    private let photoOutput = AVCapturePhotoOutput()
    /// Live-scan frames. Its delegate runs on `videoQueue` and does nothing unless the hub has a
    /// consumer, so it costs almost nothing while only photos are taken.
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.umma.ios.camera.frames", qos: .userInitiated)
    private let frameDelegate: LiveFrameDelegate
    private var configured = false

    init(frameHub: LiveFrameHub) {
        frameDelegate = LiveFrameDelegate(hub: frameHub)
    }
    private let observers = NotificationObserverBag()
    private var observing = false

    func isRunning() -> Bool { session.isRunning }

    func observe(_ sink: @escaping @Sendable (CameraSessionEvent) -> Void) {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        let pairs: [(Notification.Name, CameraSessionEvent)] = [
            (.AVCaptureSessionDidStartRunning, .started),
            (.AVCaptureSessionDidStopRunning, .stopped),
            (.AVCaptureSessionWasInterrupted, .interrupted),
            (.AVCaptureSessionInterruptionEnded, .interruptionEnded),
        ]
        for (name, event) in pairs {
            observers.add(center.addObserver(forName: name, object: session, queue: nil) { _ in sink(event) })
        }
        observers.add(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
            sink(.runtimeError(message))
        })
    }

    func start() async throws {
        if !configured {
            try configure()
        }
        await onSessionQueue { session in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() async {
        await onSessionQueue { session in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capturePhoto() async throws -> Data {
        guard session.isRunning else { throw CaptureError.notRunning }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        let delegate = PhotoCaptureDelegate()
        return try await withCheckedThrowingContinuation { continuation in
            delegate.resume = { result in continuation.resume(with: result) }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.unavailable(.phone, reason: "No back camera.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CaptureError.failed("Camera session rejected its input or output.")
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        // Optional: if the session refuses it, photos still work and live scan gets no frames.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(frameDelegate, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            Logger(subsystem: "com.umma.ios", category: "camera").error("camera session rejected the frame output")
        }
        configured = true
    }
}

/// Carries the session onto `sessionQueue`; access there is serialised by the queue.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}

/// Bridges the delegate callback into a continuation. Retained by AVFoundation until the callback.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(@Sendable (Result<Data, Error>) -> Void)?>(initialState: nil)

    var resume: (@Sendable (Result<Data, Error>) -> Void)? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let callback = lock.withLock { value -> (@Sendable (Result<Data, Error>) -> Void)? in
            let current = value
            value = nil
            return current
        }
        guard let callback else { return }
        if let error {
            callback(.failure(CaptureError.failed(error.localizedDescription)))
        } else if let data = photo.fileDataRepresentation() {
            callback(.success(data))
        } else {
            callback(.failure(CaptureError.failed("Photo had no JPEG representation.")))
        }
    }
}

/// Video-queue side of live scan: skips every buffer unless the hub wants a frame, then encodes the
/// admitted one (about once a second) right here, off the main actor.
private final class LiveFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let hub: LiveFrameHub
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(hub: LiveFrameHub) {
        self.hub = hub
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard hub.wantsFrames else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        hub.offer(at: time) { longEdge in
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
            // Sensor buffers are landscape; the app is portrait-only, so rotate to upright.
            let upright = CIImage(cvPixelBuffer: pixels).oriented(.right)
            guard let jpeg = LiveFrameEncoder.encode(upright, longEdge: longEdge, context: context) else { return nil }
            return CapturedFrame(jpegData: jpeg, capturedAt: Date())
        }
    }
}
