import AVFoundation
import XCTest
@testable import SousLensGlasses

/// Brief 009 "false-route attempt": in the glasses build, "Glasses microphone" needs a verified
/// Bluetooth HFP input. A2DP (output only) or a non-glasses headset must never produce it.
@MainActor
final class GlassesAudioRouteTests: XCTestCase {
    private let glassesHFP = AudioInputPort(type: .bluetoothHFP, name: "Ray-Ban Meta 0A1B")

    func testA2DPOnlyRouteNeverShowsGlassesMic() {
        // A2DP is an output port; with glasses on A2DP the inputs list is empty or the built-in mic.
        XCTAssertEqual(AudioInputLabel.label(for: [], glassesBuild: true), "iPhone microphone")
        XCTAssertEqual(AudioInputLabel.label(for: [AudioInputPort(type: .builtInMic, name: "iPhone Microphone")], glassesBuild: true),
                       "iPhone microphone")
        // Even a (bogus) A2DP port in the inputs, named like the glasses, isn't HFP.
        let fakeA2DP = AudioInputPort(type: .bluetoothA2DP, name: "Ray-Ban Meta 0A1B")
        XCTAssertNotEqual(AudioInputLabel.label(for: [fakeA2DP], glassesBuild: true), AudioInputLabel.glasses)
        XCTAssertFalse(AudioInputLabel.isGlassesMic([fakeA2DP], glassesBuild: true))
        XCTAssertFalse(AudioInputLabel.isGlassesMic([AudioInputPort(type: .bluetoothLE, name: "Ray-Ban Meta")], glassesBuild: true))
    }

    func testVerifiedGlassesHFPInputShowsGlassesMic() {
        XCTAssertEqual(AudioInputLabel.label(for: [glassesHFP], glassesBuild: true), "Glasses microphone")
        XCTAssertEqual(AudioInputLabel.label(for: [AudioInputPort(type: .bluetoothHFP, name: "Oakley Meta HSTN")], glassesBuild: true),
                       "Glasses microphone")
    }

    func testOtherHFPHeadsetIsNamedHonestly() {
        let airpods = AudioInputPort(type: .bluetoothHFP, name: "Jacob’s AirPods Pro")
        XCTAssertEqual(AudioInputLabel.label(for: [airpods], glassesBuild: true), "Bluetooth microphone (Jacob’s AirPods Pro)")
    }

    func testMonitorUpdatesOnRouteChange() async {
        let center = NotificationCenter()
        let route = RouteBox([AudioInputPort(type: .builtInMic, name: "iPhone Microphone")])
        let monitor = AudioRouteMonitor(glassesBuild: true, notificationCenter: center, read: { route.ports })
        XCTAssertEqual(monitor.inputLabel, "iPhone microphone")

        route.ports = [glassesHFP]
        center.post(name: AVAudioSession.routeChangeNotification, object: nil)
        await waitUntil("route re-read", timeout: 2) { monitor.inputLabel == "Glasses microphone" }
        XCTAssertTrue(monitor.isGlassesMic)

        // Glasses taken off / HFP dropped: back to the iPhone mic, never a stale glasses label.
        route.ports = []
        monitor.refresh()
        XCTAssertEqual(monitor.inputLabel, "iPhone microphone")
        XCTAssertFalse(monitor.isGlassesMic)
    }

    func testSpeechAllowsBluetoothHFPOnlyInGlassesBuild() {
        XCTAssertTrue(PhoneSpeechInput.categoryOptions(allowBluetoothInput: true).contains(.allowBluetoothHFP))
        XCTAssertFalse(PhoneSpeechInput.categoryOptions(allowBluetoothInput: false).contains(.allowBluetoothHFP))
    }

    func testGlassesBuildEnvironmentHasGlassesAndBluetoothSpeech() {
        // The host app's composition root (AppEnvironment.live) in the glasses build.
        let environment = AppEnvironment.live(defaults: UserDefaults(suiteName: "glasses.env.\(UUID())")!)
        XCTAssertNotNil(environment.glasses)
        XCTAssertTrue(environment.audioRoute.glassesBuild)
    }
}

@MainActor
final class RouteBox {
    var ports: [AudioInputPort]
    init(_ ports: [AudioInputPort]) { self.ports = ports }
}
