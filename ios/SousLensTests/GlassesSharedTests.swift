import AVFoundation
import Foundation
import XCTest
@testable import SousLens

/// Brief 009, shared (DAT-free) code as compiled into the PUBLIC app: the source picker, fallback
/// banner, Settings → Glasses model and the honest mic label. DAT itself is tested in
/// SousLensGlassesTests with MockDeviceKit.
@MainActor
final class GlassesSourcePickerTests: XCTestCase {
    private func passthrough() -> @Sendable (Data) async throws -> PantryPhotoUpload {
        { PantryPhotoUpload(jpegData: $0, pixelWidth: 1, pixelHeight: 1) }
    }

    private func frame(_ byte: UInt8) -> CapturedFrame {
        CapturedFrame(jpegData: Data([byte]), capturedAt: Date())
    }

    func testPublicBuildHasNoPickerAndNoGlasses() {
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: FakePantryService(), encode: passthrough())
        XCTAssertFalse(model.showsSourcePicker)
        XCTAssertEqual(model.availableSources, [.phone])
        XCTAssertEqual(model.activeSource, .phone)
        XCTAssertNil(model.glassesBanner)
        XCTAssertEqual(model.cameraOnLabel, "Camera on")
    }

    func testGlassesOfferedOnlyWhenReady() {
        let glasses = FakeGlassesController(snapshot: GlassesSnapshot(registration: .registered, permission: .unknown, link: .connected))
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: FakePantryService(), glasses: glasses, encode: passthrough())
        XCTAssertEqual(model.availableSources, [.phone], "not permitted yet")
        XCTAssertFalse(model.showsSourcePicker)
        glasses.snapshot.permission = .granted
        XCTAssertEqual(model.availableSources, [.phone, .glasses])
        XCTAssertTrue(model.showsSourcePicker)
        glasses.snapshot.link = .connecting
        XCTAssertEqual(model.availableSources, [.phone])
    }

    func testGlassesCaptureIsUserTappedVisibleAndStopsRightAfter() async {
        let glasses = FakeGlassesController.ready()
        glasses.fakeCamera.scriptedFrames = [frame(7)]
        let phone = FakeCameraSource()
        let service = FakePantryService()
        let model = ScanCaptureViewModel(camera: phone, service: service, glasses: glasses, encode: passthrough())

        await model.selectSource(.glasses)
        XCTAssertFalse(model.cameraOn, "choosing a source never starts a camera")
        await model.startCamera()
        XCTAssertTrue(glasses.fakeCamera.activeIndicator)
        XCTAssertFalse(phone.activeIndicator)
        XCTAssertEqual(model.cameraOnLabel, "Glasses camera on")

        await model.capture()
        XCTAssertEqual(model.photoData, Data([7]))
        XCTAssertFalse(glasses.fakeCamera.activeIndicator, "stopped straight after the frame")
    }

    func testGlassesDroppingMidStreamFallsBackToIPhoneWithBanner() async {
        let glasses = FakeGlassesController.ready()
        let phone = FakeCameraSource()
        let model = ScanCaptureViewModel(camera: phone, service: FakePantryService(), glasses: glasses, encode: passthrough())
        await model.selectSource(.glasses)
        await model.startCamera()
        XCTAssertEqual(model.camera.kind, .glasses)

        // Glasses folded: the source stops itself and the controller reports the issue.
        await glasses.fakeCamera.stopPreview()
        glasses.snapshot.issue = .hingesClosed
        XCTAssertFalse(model.cameraOn)
        XCTAssertEqual(model.activeSource, .phone)
        XCTAssertEqual(model.camera.kind, .phone)
        XCTAssertEqual(model.glassesBanner, "Glasses camera unavailable. The glasses are folded. Using the iPhone camera.")
        XCTAssertTrue(model.showsSourcePicker, "the picker stays so the user sees the fallback")

        // The fallback actually uses the iPhone camera.
        await model.startCamera()
        XCTAssertTrue(phone.activeIndicator)
        XCTAssertFalse(glasses.fakeCamera.activeIndicator)
    }

    func testRetryClearsStreamIssue() {
        let glasses = FakeGlassesController.ready()
        glasses.snapshot.issue = .timeout
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: FakePantryService(), glasses: glasses, encode: passthrough())
        model.retryGlasses()
        XCTAssertEqual(glasses.clearIssueCount, 1)
        XCTAssertNil(glasses.snapshot.issue)
    }

    func testSwitchingSourceTurnsTheRunningCameraOff() async {
        let glasses = FakeGlassesController.ready()
        let phone = FakeCameraSource()
        let model = ScanCaptureViewModel(camera: phone, service: FakePantryService(), glasses: glasses, encode: passthrough())
        await model.startCamera()
        XCTAssertTrue(phone.activeIndicator)
        await model.selectSource(.glasses)
        XCTAssertFalse(phone.activeIndicator)
        XCTAssertFalse(glasses.fakeCamera.activeIndicator)
    }

    func testTearDownStopsBothSources() async {
        let glasses = FakeGlassesController.ready()
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: FakePantryService(), glasses: glasses, encode: passthrough())
        await model.selectSource(.glasses)
        await model.startCamera()
        await model.tearDown()
        XCTAssertFalse(glasses.fakeCamera.activeIndicator)
        XCTAssertNil(model.photoData)
    }

    func testGlassesPermissionDeniedDoesNotOfferIPhoneSettingsButton() async {
        let glasses = FakeGlassesController.ready()
        glasses.fakeCamera.startError = .permissionDenied(permission: "Glasses camera", explainer: "Allow it in Meta AI.")
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: FakePantryService(), glasses: glasses, encode: passthrough())
        await model.selectSource(.glasses)
        await model.startCamera()
        XCTAssertFalse(model.permissionDenied, "iOS Settings can't fix a Meta AI permission")
        XCTAssertTrue(model.message?.contains("Meta AI") ?? false)
    }
}

@MainActor
final class GlassesSettingsAndSnapshotTests: XCTestCase {
    func testSnapshotStatusLines() {
        XCTAssertEqual(GlassesSnapshot().statusText, "Not registered with Meta AI")
        var s = GlassesSnapshot(registration: .registered, permission: .granted, link: .connecting)
        XCTAssertEqual(s.statusText, "Connecting…")
        s.link = .connected
        XCTAssertEqual(s.statusText, "Connected")
        s.stream = .streaming
        XCTAssertEqual(s.statusText, "Streaming")
        s.stream = .paused
        XCTAssertEqual(s.statusText, "Paused")
        s.issue = .hingesClosed
        XCTAssertEqual(s.statusText, "Glasses folded")
        s.issue = .batteryLow
        XCTAssertEqual(s.statusText, "Glasses battery low")
        s.issue = .thermalHot
        XCTAssertEqual(s.statusText, "Glasses too warm")
    }

    func testSettingsFlowIsUserTapped() async throws {
        let glasses = FakeGlassesController()
        let model = GlassesSettingsViewModel(glasses: glasses)
        XCTAssertTrue(model.canRegister)
        XCTAssertFalse(model.canRequestPermission, "permission comes after registration")
        XCTAssertEqual(glasses.registerCount, 0)

        await model.register()
        XCTAssertEqual(glasses.registerCount, 1)
        XCTAssertEqual(model.registrationText, "Registered")
        XCTAssertTrue(model.canRequestPermission)

        await model.requestPermission()
        XCTAssertEqual(model.permissionText, "Allowed")
        XCTAssertFalse(model.canStartPreview, "no device linked yet")

        glasses.snapshot.link = .connected
        glasses.snapshot.batteryLevel = 64
        XCTAssertEqual(model.batteryText, "64%")
        XCTAssertTrue(model.canStartPreview)
        XCTAssertFalse(model.previewOn)
        await model.startPreview()
        XCTAssertTrue(model.previewOn)
        await model.stopPreview()
        XCTAssertFalse(model.previewOn)
    }

    func testIncomingURLGoesToGlassesFirstThenDeepLinks() async throws {
        let environment = AppEnvironment.preview(signedIn: true)
        XCTAssertNil(environment.glasses, "public/preview wiring has no glasses")
        let glasses = FakeGlassesController.ready()
        let withGlasses = AppEnvironment(serverSettings: environment.serverSettings, api: environment.api, auth: environment.auth,
                                         recipeCache: environment.recipeCache, captureFlags: .allOn,
                                         camera: FakeCameraSource(), speech: FakeSpeechInput(), audio: FakeAudioOutput(),
                                         glasses: glasses)
        withGlasses.forceSignedInForTests()
        await withGlasses.handleIncomingURL(try XCTUnwrap(URL(string: "souslensglasses://callback?x=1")))
        XCTAssertEqual(glasses.handledURLs.count, 1)
        XCTAssertTrue(withGlasses.exploreRoutes.isEmpty)

        let id = UUID()
        await withGlasses.handleIncomingURL(ShareLinks.custom(recipeId: id))
        XCTAssertEqual(glasses.handledURLs.count, 1, "share links aren't Meta AI callbacks")
        XCTAssertEqual(withGlasses.exploreRoutes, [.recipe(id: id, card: nil)])
    }
}

@MainActor
final class HonestMicLabelTests: XCTestCase {
    func testPublicBuildNeverClaimsGlassesMic() {
        let hfp = AudioInputPort(type: .bluetoothHFP, name: "Ray-Ban Meta 0A1B")
        XCTAssertEqual(AudioInputLabel.label(for: [hfp], glassesBuild: false), "Bluetooth microphone (Ray-Ban Meta 0A1B)")
        XCTAssertFalse(AudioInputLabel.isGlassesMic([hfp], glassesBuild: false))
    }

    func testA2DPOnlyOrNoInputIsTheIPhoneMic() {
        XCTAssertEqual(AudioInputLabel.label(for: [], glassesBuild: false), "iPhone microphone")
        XCTAssertEqual(AudioInputLabel.label(for: [AudioInputPort(type: .builtInMic, name: "iPhone Microphone")], glassesBuild: true),
                       "iPhone microphone")
        XCTAssertFalse(AudioInputLabel.isGlassesMic([AudioInputPort(type: .bluetoothA2DP, name: "Ray-Ban Meta")], glassesBuild: true))
    }

    func testPublicSpeechDoesNotRequestBluetoothInput() {
        XCTAssertEqual(PhoneSpeechInput.categoryOptions(allowBluetoothInput: false), .duckOthers)
    }

    func testListeningIndicatorNamesTheRouteMic() async {
        let speech = FakeSpeechInput()
        let box = LabelBox()
        box.value = "Glasses microphone"
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService(), micLabel: { box.value })
        await model.beginListening()
        XCTAssertEqual(model.listeningIndicator, "Listening… (Glasses microphone)")
        box.value = "iPhone microphone"
        XCTAssertEqual(model.listeningIndicator, "Listening… (iPhone microphone)", "updates with the route")
        model.endListening()
    }
}

@MainActor
private final class LabelBox {
    var value = ""
}
