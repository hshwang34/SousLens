#if GLASSES
import Foundation
import MWDATCamera
import MWDATCore
import Observation
import UIKit
import os

/// The glasses camera behind `CameraSource` (brief 009), on DAT 1.0.1:
/// `createSession(deviceSelector:)` → `start()` → `addCamera(config:)` → `camera.stream.start()`,
/// frames via `stream.videoFramePublisher` + `frame.makeUIImage()`. No experimental API: a capture
/// is the latest stream frame at the moment of the tap (not `Camera.photo`).
///
/// Same race protection as `PhoneCameraSource`: every start/stop bumps a `CaptureStartGate`, and a
/// start that resumes after a newer stop/start gives up. A `DeviceSession` is never restarted
/// (stopped is terminal, and paused must not be restarted): every start builds a fresh session.
///
/// Stream and session errors are reported to `onIssue` (availability + banner). This type has no
/// way to reach a cooking session.
@MainActor
@Observable
final class GlassesCameraSource: CameraSource, FramePreviewProviding {
    let kind: CaptureSourceKind = .glasses
    /// Readiness comes from the controller's snapshot (registered, permitted, linked, unblocked).
    @ObservationIgnored var readiness: @MainActor () -> Bool = { false }
    var isAvailable: Bool { readiness() }
    private(set) var activeIndicator = false
    private(set) var phase: GlassesStreamPhase = .idle
    /// Latest frame, display only. Dropped on stop; never written anywhere.
    private(set) var previewFrame: UIImage?
    private(set) var framesReceived = 0

    /// Stream/session problems, for the controller (snapshot.issue → banner + fallback).
    @ObservationIgnored var onIssue: (@MainActor (GlassesIssue) -> Void)?
    @ObservationIgnored var onPhase: (@MainActor (GlassesStreamPhase) -> Void)?

    /// The connected glasses the controller is watching. A `SpecificDeviceSelector` for it avoids
    /// `AutoDeviceSelector` not having latched a device yet (`noEligibleDevice`), as in Retrace.
    @ObservationIgnored var connectedDevice: @MainActor () -> DeviceIdentifier? = { nil }

    /// How long a start waits for the session, then for the stream.
    @ObservationIgnored var startTimeout: Duration = .seconds(20)

    private let wearables: any WearablesInterface
    private let streamConfiguration: StreamConfiguration
    /// Long-lived fallback selector (it latches a device asynchronously after creation).
    private let autoSelector: AutoDeviceSelector
    @ObservationIgnored private var startGate = CaptureStartGate()
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var sessionState: DeviceSessionState = .idle
    @ObservationIgnored private var streamState: StreamState = .stopped
    @ObservationIgnored private var failure: GlassesIssue?
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    /// Bumped on teardown so listener callbacks from an old session are ignored.
    @ObservationIgnored private var sessionGeneration = 0
    private let logger = Logger(subsystem: "com.souslens.ios.glasses", category: "camera")
    private let observers = NotificationObserverBag()

    init(wearables: any WearablesInterface,
         configuration: StreamConfiguration = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)) {
        self.wearables = wearables
        streamConfiguration = configuration
        autoSelector = AutoDeviceSelector(wearables: wearables)
        // PRD §14: no lingering stream after backgrounding (Meta's sample does the same).
        observers.add(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.stopPreview() }
        })
    }

    func startPreview() async throws {
        guard isAvailable else {
            throw CaptureError.unavailable(.glasses, reason: "Glasses aren’t ready.")
        }
        wantsRunning = true
        let token = startGate.begin()
        // Never resume an old (possibly paused) session: tear it down and build a new one.
        teardown()
        setPhase(.connecting)

        let status: PermissionStatus
        do {
            status = try await wearables.checkPermissionStatus(.camera)
        } catch {
            try await superseded(unless: token)
            fail(.failed("Couldn’t check the glasses camera permission."))
            throw CaptureError.failed("Couldn’t check the glasses camera permission.")
        }
        try await superseded(unless: token)
        guard status == .granted else {
            fail(.permissionDenied)
            throw CaptureError.permissionDenied(
                permission: "Glasses camera",
                explainer: "Allow the glasses camera in Settings → Glasses (it opens Meta AI)."
            )
        }

        let session: DeviceSession
        do {
            let selector: any DeviceSelector = connectedDevice().map { SpecificDeviceSelector(device: $0) } ?? autoSelector
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            logger.error("createSession: \(String(describing: error), privacy: .public)")
            let issue = GlassesStateMapping.issue(error) ?? .failed("The glasses session didn’t start.")
            fail(issue)
            throw CaptureError.unavailable(.glasses, reason: issue.statusText)
        }
        self.session = session
        observe(session)
        do {
            try session.start()
        } catch {
            logger.error("session.start: \(String(describing: error), privacy: .public)")
            let issue = GlassesStateMapping.issue(error) ?? .failed("The glasses session didn’t start.")
            fail(issue)
            throw CaptureError.unavailable(.glasses, reason: issue.statusText)
        }
        try await waitUntil(token: token) { $0.sessionState == .started }

        let camera: Camera
        do {
            guard let added = try session.addCamera(config: streamConfiguration) else {
                fail(.failed("The glasses camera isn’t available."))
                throw CaptureError.unavailable(.glasses, reason: "The glasses camera isn’t available.")
            }
            camera = added
        } catch let error as DeviceSessionError {
            let issue = GlassesStateMapping.issue(error) ?? .failed("The glasses camera isn’t available.")
            fail(issue)
            throw CaptureError.unavailable(.glasses, reason: issue.statusText)
        }
        self.camera = camera
        observe(camera.stream)
        camera.stream.start()
        try await waitUntil(token: token) { $0.streamState == .streaming }
    }

    func captureFrame() async throws -> CapturedFrame {
        guard activeIndicator else { throw CaptureError.notRunning }
        guard let frame = previewFrame else {
            throw CaptureError.failed("No picture from the glasses yet. Try again in a moment.")
        }
        guard let jpeg = frame.jpegData(compressionQuality: 0.85) else {
            throw CaptureError.failed("The glasses picture couldn’t be encoded.")
        }
        return CapturedFrame(jpegData: jpeg, capturedAt: Date())
    }

    func stopPreview() async {
        wantsRunning = false
        startGate.supersede()
        teardown()
    }

    // MARK: - Start helpers

    /// Throws `.cancelled` if a newer start/stop happened while we were suspended. A losing start
    /// tears down only when the latest intent is "stopped", like `PhoneCameraSource`.
    private func superseded(unless token: Int) async throws {
        guard !startGate.isCurrent(token) else { return }
        if !wantsRunning { teardown() }
        throw CaptureError.cancelled
    }

    /// Polls state written by the listeners until `condition`, a failure, or the timeout.
    private func waitUntil(token: Int, _ condition: (GlassesCameraSource) -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startTimeout)
        while true {
            try await superseded(unless: token)
            if let failure {
                teardown(keepIssue: true)
                throw CaptureError.unavailable(.glasses, reason: failure.statusText)
            }
            if condition(self) { return }
            if sessionState == .stopped {
                logger.error("session stopped while starting")
                fail(.disconnected)
                throw CaptureError.unavailable(.glasses, reason: GlassesIssue.disconnected.statusText)
            }
            if clock.now >= deadline {
                fail(.timeout)
                throw CaptureError.unavailable(.glasses, reason: GlassesIssue.timeout.statusText)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Listeners

    private func observe(_ session: DeviceSession) {
        let generation = sessionGeneration
        tokens.append(session.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.apply(sessionState: state, generation: generation) }
        })
        tokens.append(session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.apply(sessionError: error, generation: generation) }
        })
    }

    private func observe(_ stream: MWDATCamera.Stream) {
        let generation = sessionGeneration
        tokens.append(stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.apply(streamState: state, generation: generation) }
        })
        tokens.append(stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.apply(streamError: error, generation: generation) }
        })
        tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
            // Decoded off the main thread; only the latest image is kept, in memory.
            guard let image = frame.makeUIImage() else { return }
            let box = ImageBox(image: image)
            Task { @MainActor in self?.apply(frame: box.image, generation: generation) }
        })
    }

    private func apply(sessionState state: DeviceSessionState, generation: Int) {
        guard generation == sessionGeneration else { return }
        sessionState = state
        switch state {
        case .paused:
            // Never restart a paused session; it resumes on its own or stops.
            activeIndicator = false
            setPhase(.paused)
        case .stopped:
            if wantsRunning, failure == nil { fail(.disconnected) }
            teardown(keepIssue: true)
        default:
            break
        }
    }

    private func apply(sessionError error: DeviceSessionError, generation: Int) {
        guard generation == sessionGeneration, let issue = GlassesStateMapping.issue(error) else { return }
        logger.error("glasses session error: \(String(describing: error), privacy: .public)")
        fail(issue)
        teardown(keepIssue: true)
    }

    private func apply(streamState state: StreamState, generation: Int) {
        guard generation == sessionGeneration else { return }
        streamState = state
        activeIndicator = GlassesStateMapping.activeIndicator(state)
        setPhase(GlassesStateMapping.phase(state))
        if !activeIndicator { previewFrame = nil }
    }

    private func apply(streamError error: StreamError, generation: Int) {
        guard generation == sessionGeneration else { return }
        logger.error("glasses stream error: \(String(describing: error), privacy: .public)")
        fail(GlassesStateMapping.issue(error))
        teardown(keepIssue: true)
    }

    private func apply(frame: UIImage, generation: Int) {
        guard generation == sessionGeneration, streamState == .streaming else { return }
        previewFrame = frame
        framesReceived += 1
    }

    // MARK: - Teardown

    private func fail(_ issue: GlassesIssue) {
        failure = issue
        onIssue?(issue)
    }

    private func setPhase(_ phase: GlassesStreamPhase) {
        guard self.phase != phase else { return }
        self.phase = phase
        onPhase?(phase)
    }

    /// Stops the camera and the session (both terminal) and forgets every frame.
    private func teardown(keepIssue: Bool = false) {
        sessionGeneration += 1
        let oldTokens = tokens
        tokens.removeAll()
        if !oldTokens.isEmpty {
            Task { for token in oldTokens { await token.cancel() } }
        }
        camera?.stop()
        camera = nil
        session?.stop()
        session = nil
        sessionState = .idle
        streamState = .stopped
        activeIndicator = false
        previewFrame = nil
        if !keepIssue { failure = nil }
        setPhase(.idle)
    }
}

/// Carries a freshly decoded frame to the main actor (the SDK hands it over as `sending`).
private struct ImageBox: @unchecked Sendable {
    let image: UIImage
}
#endif
