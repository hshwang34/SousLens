import MWDATCamera
import MWDATCore
import XCTest
@testable import SousLensGlasses

/// Brief 009: DAT 1.0.1 states map to camera availability + a banner, nothing else.
final class GlassesStateMappingTests: XCTestCase {
    func testRegistrationStates() {
        XCTAssertEqual(GlassesStateMapping.registration(.available), .notRegistered)
        XCTAssertEqual(GlassesStateMapping.registration(.registering), .registering)
        XCTAssertEqual(GlassesStateMapping.registration(.registered), .registered)
        guard case .unavailable = GlassesStateMapping.registration(.unavailable) else {
            return XCTFail("unavailable registration must say why")
        }
    }

    func testPermissionAndLink() {
        XCTAssertEqual(GlassesStateMapping.permission(.granted), .granted)
        XCTAssertEqual(GlassesStateMapping.permission(.denied), .denied)
        XCTAssertEqual(GlassesStateMapping.link(.connected), .connected)
        XCTAssertEqual(GlassesStateMapping.link(.connecting), .connecting)
        XCTAssertEqual(GlassesStateMapping.link(.disconnected), .disconnected)
    }

    func testDeviceStateIssues() {
        XCTAssertNil(GlassesStateMapping.deviceIssue(DeviceState(linkState: .connected, batteryLevel: 80, hingeState: .open, thermalLevel: .none)))
        XCTAssertEqual(GlassesStateMapping.deviceIssue(DeviceState(linkState: .connected, hingeState: .closed)), .hingesClosed)
        XCTAssertEqual(GlassesStateMapping.deviceIssue(DeviceState(thermalLevel: .severe)), .thermalHot)
        XCTAssertEqual(GlassesStateMapping.deviceIssue(DeviceState(thermalLevel: .emergency)), .thermalHot)
        XCTAssertNil(GlassesStateMapping.deviceIssue(DeviceState(thermalLevel: .moderate)))
        XCTAssertEqual(GlassesStateMapping.deviceIssue(DeviceState(batteryLevel: 3, chargingState: .notCharging)), .batteryLow)
        XCTAssertNil(GlassesStateMapping.deviceIssue(DeviceState(batteryLevel: 3, chargingState: .charging)),
                     "charging glasses aren't blocked for battery")
        XCTAssertEqual(GlassesStateMapping.deviceIssue(DeviceState(compatibility: .deviceUpdateRequired)), .updateRequired)
        // Folded beats every other condition: it's what the user can fix fastest.
        XCTAssertEqual(GlassesStateMapping.deviceIssue(DeviceState(batteryLevel: 2, hingeState: .closed, thermalLevel: .critical)), .hingesClosed)
    }

    func testEveryStreamErrorMapsToAnIssue() {
        let expected: [(StreamError, GlassesIssue)] = [
            (.hingesClosed, .hingesClosed), (.thermalHot, .thermalHot), (.batteryLow, .batteryLow),
            (.peakPowerLimit, .peakPowerLimit), (.permissionDenied, .permissionDenied), (.timeout, .timeout),
            (.deviceNotConnected("x"), .disconnected), (.deviceNotFound("x"), .disconnected),
        ]
        for (error, issue) in expected {
            XCTAssertEqual(GlassesStateMapping.issue(error), issue, "\(error)")
        }
        for error in [StreamError.internalError, .videoStreamingError, .audioStreamingError, .photoCaptureFailed] {
            guard case .failed = GlassesStateMapping.issue(error) else { return XCTFail("\(error)") }
        }
    }

    func testSessionErrors() {
        XCTAssertEqual(GlassesStateMapping.issue(DeviceSessionError.thermalCritical), .thermalHot)
        XCTAssertEqual(GlassesStateMapping.issue(DeviceSessionError.batteryCritical), .batteryLow)
        XCTAssertEqual(GlassesStateMapping.issue(DeviceSessionError.peakPowerShutdown), .peakPowerLimit)
        XCTAssertEqual(GlassesStateMapping.issue(DeviceSessionError.noEligibleDevice), .disconnected)
        XCTAssertEqual(GlassesStateMapping.issue(DeviceSessionError.insufficientSDKVersion), .updateRequired)
        XCTAssertNil(GlassesStateMapping.issue(DeviceSessionError.dwaOutOfStuRange), "non-blocking warning")
    }

    func testStreamPhaseAndIndicator() {
        XCTAssertEqual(GlassesStateMapping.phase(.streaming), .streaming)
        XCTAssertEqual(GlassesStateMapping.phase(.paused), .paused)
        XCTAssertEqual(GlassesStateMapping.phase(.waitingForDevice), .connecting)
        XCTAssertEqual(GlassesStateMapping.phase(.starting), .connecting)
        XCTAssertEqual(GlassesStateMapping.phase(.stopped), .idle)
        XCTAssertTrue(GlassesStateMapping.activeIndicator(.streaming))
        for state in [StreamState.paused, .starting, .waitingForDevice, .stopping, .stopped] {
            XCTAssertFalse(GlassesStateMapping.activeIndicator(state), "indicator must be off when \(state)")
        }
    }

    func testIssuesNeverReadyAndAlwaysBannerFallsBackToIPhone() {
        let issues: [GlassesIssue] = [.hingesClosed, .batteryLow, .thermalHot, .peakPowerLimit, .permissionDenied,
                                      .timeout, .disconnected, .updateRequired, .failed("x")]
        for issue in issues {
            var snapshot = GlassesSnapshot(registration: .registered, permission: .granted, link: .connected)
            XCTAssertTrue(snapshot.isCameraReady)
            snapshot.issue = issue
            XCTAssertFalse(snapshot.isCameraReady, "\(issue)")
            XCTAssertTrue(issue.bannerText.hasSuffix("Using the iPhone camera."), "\(issue)")
        }
    }
}
