import Foundation
import UIKit

// Brief 009. DAT-free model of the glasses so shared code (settings, source picker, tests of the
// public app) never imports MWDAT. Only `SousLensGlasses/` maps DAT types into these.
//
// Invariant (CLAUDE.md "honest device state"): every glasses condition below changes camera
// AVAILABILITY and a visible banner only. Nothing here can reach the cooking session.

/// Meta AI registration of this app.
enum GlassesRegistration: Equatable, Sendable {
    /// SDK not configured (Info.plist problem) or Meta AI missing.
    case unavailable(String)
    case notRegistered
    case registering
    case registered
}

/// The glasses-camera permission granted in Meta AI (separate from the iPhone camera permission).
enum GlassesPermission: Equatable, Sendable {
    case unknown
    case granted
    case denied
}

/// Bluetooth/Wi-Fi link to the glasses.
enum GlassesLink: Equatable, Sendable {
    case noDevice
    case connecting
    case connected
    case disconnected
}

/// Camera stream lifecycle as the user sees it.
enum GlassesStreamPhase: Equatable, Sendable {
    case idle
    /// Session or stream starting, or waiting for the device.
    case connecting
    case streaming
    /// Paused by the glasses (e.g. taken off). Never restarted from here; it resumes or stops.
    case paused
}

/// A condition that makes the glasses camera unusable right now.
enum GlassesIssue: Equatable, Sendable {
    case hingesClosed
    case batteryLow
    case thermalHot
    case peakPowerLimit
    case permissionDenied
    case timeout
    case disconnected
    case updateRequired
    case failed(String)

    /// Short device-state line for Settings.
    var statusText: String {
        switch self {
        case .hingesClosed: return "Glasses folded"
        case .batteryLow: return "Glasses battery low"
        case .thermalHot: return "Glasses too warm"
        case .peakPowerLimit: return "Glasses power limit"
        case .permissionDenied: return "Camera not allowed in Meta AI"
        case .timeout: return "Glasses didn’t respond"
        case .disconnected: return "Glasses disconnected"
        case .updateRequired: return "Update needed in Meta AI"
        case .failed(let message): return message
        }
    }

    /// The fallback banner shown wherever the camera is used.
    var bannerText: String {
        let reason: String
        switch self {
        case .hingesClosed: reason = "The glasses are folded."
        case .batteryLow: reason = "The glasses battery is low."
        case .thermalHot: reason = "The glasses are too warm. Let them cool down."
        case .peakPowerLimit: reason = "The glasses hit a power limit."
        case .permissionDenied: reason = "Camera access isn’t allowed in Meta AI."
        case .timeout: reason = "The glasses didn’t respond."
        case .disconnected: reason = "The glasses disconnected."
        case .updateRequired: reason = "The glasses or Meta AI need an update."
        case .failed(let message): reason = message
        }
        return "Glasses camera unavailable. \(reason) Using the iPhone camera."
    }
}

/// Everything the UI needs to know about the glasses, as one value.
struct GlassesSnapshot: Equatable, Sendable {
    var registration: GlassesRegistration = .notRegistered
    var permission: GlassesPermission = .unknown
    var link: GlassesLink = .noDevice
    var stream: GlassesStreamPhase = .idle
    var issue: GlassesIssue?
    var deviceName: String?
    var batteryLevel: Int?

    /// The glasses camera can be offered in the source picker: registered, permitted, linked and
    /// not blocked. A stream does not need to be running (the user starts it with a tap).
    var isCameraReady: Bool {
        registration == .registered && permission == .granted && link == .connected && issue == nil
    }

    /// One line for the Settings device-state row.
    var statusText: String {
        if let issue { return issue.statusText }
        switch registration {
        case .unavailable(let why): return why
        case .notRegistered: return "Not registered with Meta AI"
        case .registering: return "Registering in Meta AI…"
        case .registered: break
        }
        switch link {
        case .noDevice: return "No glasses found"
        case .connecting: return "Connecting…"
        case .disconnected: return "Glasses disconnected"
        case .connected: break
        }
        switch stream {
        case .idle: return permission == .granted ? "Connected" : "Connected · camera not allowed yet"
        case .connecting: return "Starting camera…"
        case .streaming: return "Streaming"
        case .paused: return "Paused"
        }
    }
}

/// The glasses as seen by shared UI. Implemented with DAT only in the glasses build
/// (`DATGlassesController`) and by `FakeGlassesController` in tests and previews.
@MainActor
protocol GlassesController: AnyObject {
    var snapshot: GlassesSnapshot { get }
    /// The glasses camera behind the shared `CameraSource` protocol.
    var camera: any CameraSource { get }
    /// Opens Meta AI to register (user tap only).
    func register() async
    func unregister() async
    /// Asks Meta AI for the glasses-camera permission (user tap only).
    func requestCameraPermission() async
    /// "Try glasses again" after a stream error (user tap). Device-reported conditions (folded,
    /// too warm) stay until the glasses report them gone.
    func clearStreamIssue()
    /// Lets the SDK consume a Meta AI callback URL. Returns true when it was one.
    func handleOpenURL(_ url: URL) async -> Bool
}

/// A camera that shows its live feed as images (the glasses stream) rather than a preview layer.
@MainActor
protocol FramePreviewProviding: AnyObject {
    /// Latest decoded frame while streaming; nil otherwise. Display only, never stored.
    var previewFrame: UIImage? { get }
}
