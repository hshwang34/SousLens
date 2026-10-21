import AVFoundation
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
/// Slice 0 does not expose a preview surface (`AVCaptureVideoPreviewLayer`); that arrives with the
/// pantry-scan screen. `startPreview()` here means "run the session so frames can be captured".
@MainActor
@Observable
final class PhoneCameraSource: CameraSource {
    let kind: CaptureSourceKind = .phone
    let isAvailable: Bool
    private(set) var activeIndicator = false

    private let pipeline = CameraPipeline()
    /// Bumped by every start/stop; a start that resumes after a newer stop/start gives up.
    private var startGate = CaptureStartGate()
    /// Latest caller intent. A superseded start only stops the session if the latest intent is
    /// "stopped" — it must never tear down a newer start that is running.
    private var wantsRunning = false
    private let observers = NotificationObserverBag()
    private let logger = Logger(subsystem: "com.souslens.ios", category: "camera")

    init(enabled: Bool = true) {
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

        try await ensurePermission()
        try await superseded(unless: token)

        await pipeline.observe(Self.makeEventSink(owner: self))
        try await superseded(unless: token)

        try await pipeline.start()
        try await superseded(unless: token)
        activeIndicator = await pipeline.isRunning()
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

    func captureFrame() async throws -> CapturedFrame {
        guard activeIndicator else { throw CaptureError.notRunning }
        let data = try await pipeline.capturePhoto()
        return CapturedFrame(jpegData: data, capturedAt: Date())
    }

    func stopPreview() async {
        wantsRunning = false
        startGate.supersede()
        await pipeline.stop()
        activeIndicator = await pipeline.isRunning()
    }

    private func apply(_ event: CameraSessionEvent) {
        if case .runtimeError(let message) = event {
            logger.error("capture session runtime error: \(message, privacy: .public)")
        }
        activeIndicator = CameraRunState.activeIndicator(after: event)
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
        explainer: "SousLens needs the camera to scan your pantry and look at a step when you ask. Allow camera access in Settings → SousLens."
    )
}

/// Owns the non-Sendable AVCapture objects and their notifications.
private actor CameraPipeline {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
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

    func start() throws {
        if !configured {
            try configure()
        }
        if !session.isRunning {
            session.startRunning()
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
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
        configured = true
    }
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
