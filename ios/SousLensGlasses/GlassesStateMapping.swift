#if GLASSES
import Foundation
import MWDATCamera
import MWDATCore

/// Pure DAT 1.0.1 → SousLens mappings (unit-tested in SousLensGlassesTests). Every outcome is a
/// camera-availability value or a banner; none of these types can reach a cooking session.
enum GlassesStateMapping {
    static func registration(_ state: RegistrationState) -> GlassesRegistration {
        switch state {
        case .unavailable: return .unavailable("Meta AI isn’t available. Install Meta AI and turn on Developer Mode.")
        case .available: return .notRegistered
        case .registering: return .registering
        case .registered: return .registered
        }
    }

    static func permission(_ status: PermissionStatus) -> GlassesPermission {
        switch status {
        case .granted: return .granted
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }

    static func link(_ state: LinkState) -> GlassesLink {
        switch state {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnected: return .disconnected
        }
    }

    /// Battery at or below this (and not charging) blocks the camera before the glasses do.
    static let lowBatteryPercent = 5

    /// Conditions read from the device itself (hinges, heat, battery, compatibility).
    static func deviceIssue(_ state: DeviceState) -> GlassesIssue? {
        if state.hingeState == .closed { return .hingesClosed }
        switch state.thermalLevel {
        case .severe, .critical, .emergency, .shutdown: return .thermalHot
        default: break
        }
        if let battery = state.batteryLevel, battery <= lowBatteryPercent, state.chargingState != .charging {
            return .batteryLow
        }
        switch state.compatibility {
        case .deviceUpdateRequired, .sdkUpdateRequired: return .updateRequired
        default: break
        }
        return nil
    }

    /// Every `StreamError` maps to an issue (availability + banner) only.
    static func issue(_ error: StreamError) -> GlassesIssue {
        switch error {
        case .hingesClosed: return .hingesClosed
        case .thermalHot: return .thermalHot
        case .batteryLow: return .batteryLow
        case .peakPowerLimit: return .peakPowerLimit
        case .permissionDenied: return .permissionDenied
        case .timeout: return .timeout
        case .deviceNotFound, .deviceNotConnected: return .disconnected
        case .internalError, .videoStreamingError, .audioStreamingError, .photoCaptureFailed:
            return .failed("The glasses camera stopped.")
        @unknown default:
            return .failed("The glasses camera stopped.")
        }
    }

    static func issue(_ error: DeviceSessionError) -> GlassesIssue? {
        switch error {
        case .thermalCritical, .thermalEmergency: return .thermalHot
        case .batteryCritical: return .batteryLow
        case .peakPowerShutdown: return .peakPowerLimit
        case .noEligibleDevice: return .disconnected
        case .datAppOnTheGlassesUpdateRequired, .insufficientSDKVersion: return .updateRequired
        // Non-blocking compatibility warning (DAT 1.0): keep going.
        case .dwaOutOfStuRange: return nil
        case .sessionAlreadyStopped, .sessionAlreadyExists, .sessionIdle, .capabilityAlreadyActive,
             .capabilityNotFound, .dwaUnavailable, .unexpectedError:
            return .failed("The glasses session stopped.")
        @unknown default:
            return .failed("The glasses session stopped.")
        }
    }

    static func phase(_ state: StreamState) -> GlassesStreamPhase {
        switch state {
        case .streaming: return .streaming
        case .paused: return .paused
        case .starting, .waitingForDevice: return .connecting
        case .stopping, .stopped: return .idle
        }
    }

    /// The "glasses camera on" indicator is lit only while frames can actually flow.
    static func activeIndicator(_ state: StreamState) -> Bool {
        state == .streaming
    }
}
#endif
