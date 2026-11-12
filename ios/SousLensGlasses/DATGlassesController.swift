#if GLASSES
import Foundation
import MWDATCamera
import MWDATCore
import Observation
import os

/// Configures DAT once at launch (glasses build only; called from `AppEnvironment.live`).
@MainActor
enum GlassesBootstrap {
    static func makeController() -> any GlassesController {
        do {
            try Wearables.configure()
        } catch {
            // `.alreadyConfigured` is fine (tests configure too); anything else is an Info.plist
            // problem, shown in Settings → Glasses rather than crashing.
            if error != .alreadyConfigured {
                Logger(subsystem: "com.souslens.ios.glasses", category: "dat")
                    .error("Wearables.configure failed: \(String(describing: error), privacy: .public)")
                return DATGlassesController.unconfigured(reason: "Glasses SDK setup failed: \(error.description)")
            }
        }
        return DATGlassesController(wearables: Wearables.shared)
    }
}

/// `GlassesController` on DAT 1.0.1. Holds registration, permission and device state, and owns
/// the `GlassesCameraSource`. Deliberately knows nothing about cooking sessions.
@MainActor
@Observable
final class DATGlassesController: GlassesController {
    private(set) var snapshot = GlassesSnapshot()
    let glassesCamera: GlassesCameraSource?
    private let fallbackCamera = FakeCameraSource(kind: .glasses, isAvailable: false)
    var camera: any CameraSource { glassesCamera ?? fallbackCamera }

    private let wearables: (any WearablesInterface)?
    @ObservationIgnored private var tokens: [any AnyListenerToken] = []
    @ObservationIgnored private var deviceToken: (any AnyListenerToken)?
    @ObservationIgnored private var observedDevice: DeviceIdentifier?
    /// From the device's own state (hinges, heat, battery, compatibility). Clears itself.
    @ObservationIgnored private var deviceIssue: GlassesIssue?
    /// From the last stream/session error. Cleared by a reconnect, the matching device state
    /// recovering, or the user tapping "Try glasses again".
    @ObservationIgnored private var streamIssue: GlassesIssue?
    private let logger = Logger(subsystem: "com.souslens.ios.glasses", category: "controller")

    init(wearables: any WearablesInterface) {
        self.wearables = wearables
        let camera = GlassesCameraSource(wearables: wearables)
        glassesCamera = camera
        camera.readiness = { [weak self] in self?.snapshot.isCameraReady ?? false }
        camera.onIssue = { [weak self] issue in self?.streamFailed(issue) }
        camera.onPhase = { [weak self] phase in self?.snapshot.stream = phase }
        camera.connectedDevice = { [weak self] in
            guard let self, snapshot.link == .connected else { return nil }
            return observedDevice
        }
        startListening(wearables)
    }

    private init(unavailable reason: String) {
        wearables = nil
        glassesCamera = nil
        snapshot.registration = .unavailable(reason)
    }

    static func unconfigured(reason: String) -> DATGlassesController {
        DATGlassesController(unavailable: reason)
    }

    // MARK: - User actions

    func register() async {
        guard let wearables else { return }
        do {
            try await wearables.startRegistration()
        } catch {
            logger.error("startRegistration: \(String(describing: error), privacy: .public)")
            snapshot.registration = error == .metaAINotInstalled
                ? .unavailable("Install Meta AI to register your glasses.")
                : GlassesStateMapping.registration(wearables.registrationState)
        }
    }

    func unregister() async {
        guard let wearables else { return }
        await camera.stopPreview()
        do {
            try await wearables.startUnregistration()
        } catch {
            logger.error("startUnregistration: \(String(describing: error), privacy: .public)")
        }
    }

    func requestCameraPermission() async {
        guard let wearables else { return }
        do {
            let status = try await wearables.requestPermission(.camera)
            applyPermission(GlassesStateMapping.permission(status))
        } catch {
            logger.error("requestPermission: \(String(describing: error), privacy: .public)")
            await refreshPermission()
        }
    }

    func handleOpenURL(_ url: URL) async -> Bool {
        guard let wearables, url.scheme?.lowercased() == "souslensglasses" else { return false }
        do {
            let handled = try await wearables.handleUrl(url)
            await refreshPermission()
            return handled
        } catch {
            logger.error("handleUrl: \(String(describing: error), privacy: .public)")
            return true
        }
    }

    /// "Try glasses again" after a stream error: clears the stream issue only.
    func clearStreamIssue() {
        streamIssue = nil
        recomputeIssue()
    }

    // MARK: - Listening

    private func startListening(_ wearables: any WearablesInterface) {
        applyRegistration(wearables.registrationState)
        tokens.append(wearables.addRegistrationStateListener { [weak self] state in
            Task { @MainActor in self?.applyRegistration(state) }
        })
        applyDevices(wearables.devices)
        tokens.append(wearables.addDevicesListener { [weak self] devices in
            Task { @MainActor in self?.applyDevices(devices) }
        })
    }

    private func applyRegistration(_ state: RegistrationState) {
        snapshot.registration = GlassesStateMapping.registration(state)
        if state == .registered {
            Task { await refreshPermission() }
        } else {
            snapshot.permission = .unknown
        }
    }

    /// Reads the glasses-camera permission. It needs a linked device, which can lag the link state
    /// by a moment, so a `noDevice`-style failure is retried briefly while linked.
    @ObservationIgnored private var permissionRefreshing = false
    @ObservationIgnored private var previousHinge: HingeState = .unknown

    func refreshPermission() async {
        guard let wearables, !permissionRefreshing else { return }
        permissionRefreshing = true
        defer { permissionRefreshing = false }
        for attempt in 0..<40 {
            guard snapshot.registration == .registered else { return }
            do {
                let status = try await wearables.checkPermissionStatus(.camera)
                applyPermission(GlassesStateMapping.permission(status))
                return
            } catch {
                logger.info("checkPermissionStatus (\(attempt)): \(String(describing: error), privacy: .public)")
                guard snapshot.link == .connected else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func applyPermission(_ permission: GlassesPermission) {
        snapshot.permission = permission
        if permission == .granted, streamIssue == .permissionDenied {
            streamIssue = nil
            recomputeIssue()
        }
    }

    private func applyDevices(_ devices: [DeviceIdentifier]) {
        guard let wearables else { return }
        let first = devices.first
        guard first != observedDevice else { return }
        observedDevice = first
        if let old = deviceToken {
            deviceToken = nil
            Task { await old.cancel() }
        }
        guard let first, let device = wearables.deviceForIdentifier(first) else {
            snapshot.link = .noDevice
            snapshot.deviceName = nil
            snapshot.batteryLevel = nil
            deviceIssue = nil
            recomputeIssue()
            return
        }
        snapshot.deviceName = device.nameOrId()
        // Delivered immediately and on every change (DAT 1.0).
        deviceToken = device.addDeviceStateListener { [weak self] state in
            Task { @MainActor in self?.applyDeviceState(state) }
        }
    }

    func applyDeviceState(_ state: DeviceState) {
        logger.debug("device state: \(String(describing: state), privacy: .public)")
        let previousLink = snapshot.link
        snapshot.link = GlassesStateMapping.link(state.linkState)
        snapshot.batteryLevel = state.batteryLevel
        deviceIssue = GlassesStateMapping.deviceIssue(state)
        // A reconnect, or the device reporting the stream's problem gone, clears the stream issue.
        if previousLink != .connected, snapshot.link == .connected {
            streamIssue = nil
            // The permission check needs a linked device; re-read it on every (re)connect.
            Task { await refreshPermission() }
        }
        // Unfolding (hinges reported open again) clears whatever the fold did to the stream; a
        // heat/battery stream error clears once the device itself reports it gone.
        let unfolded = previousHinge != .open && state.hingeState == .open
        if let issue = streamIssue, issue != .permissionDenied, deviceIssue == nil,
           unfolded || [.hingesClosed, .thermalHot, .batteryLow].contains(issue) && state.hingeState == .open {
            streamIssue = nil
        }
        previousHinge = state.hingeState
        recomputeIssue()
        if snapshot.link == .connected, snapshot.permission == .unknown, !permissionRefreshing {
            Task { await refreshPermission() }
        }
    }

    private func streamFailed(_ issue: GlassesIssue) {
        streamIssue = issue
        if issue == .permissionDenied { snapshot.permission = .denied }
        recomputeIssue()
    }

    private func recomputeIssue() {
        snapshot.issue = deviceIssue ?? streamIssue
    }
}
#endif
