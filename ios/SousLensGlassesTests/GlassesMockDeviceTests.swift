import MWDATCore
import MWDATMockDevice
import XCTest
@testable import SousLensGlasses

/// Brief 009, driven by MockDeviceKit (DAT 1.0.1): the real `DATGlassesController` and
/// `GlassesCameraSource` against simulated Ray-Ban Meta glasses.
@MainActor
final class GlassesMockDeviceTests: XCTestCase {
    var device: (any MockGlasses)?
    var controller: DATGlassesController!

    func setUpGlasses(permissionsGranted: Bool = true) async throws {
        try? Wearables.configure()
        // Enabled once per process: disable/enable cycles between tests left the mock link flaky.
        if !MockDeviceKit.shared.isEnabled {
            MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))
        }
        let status: PermissionStatus = permissionsGranted ? .granted : .denied
        MockDeviceKit.shared.permissions.set(.camera, status)
        MockDeviceKit.shared.permissions.setRequestResult(.camera, result: status)
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
        device = glasses
        let feed = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "glasses_feed", withExtension: "mp4"))
        glasses.services.camera.setCameraFeed(fileURL: feed)
        glasses.powerOn()
        glasses.unfold()
        glasses.don()
        controller = DATGlassesController(wearables: Wearables.shared)
        controller.glassesCamera?.startTimeout = .seconds(30)
    }

    override func tearDown() async throws {
        if let controller { await controller.camera.stopPreview() }
        controller = nil
        if let device { await MockDeviceKit.shared.unpairDevice(device) }
        device = nil
        MockDeviceKit.shared.permissions.set(.camera, .granted)
        MockDeviceKit.shared.permissions.setRequestResult(.camera, result: .granted)
        try await super.tearDown()
    }

    func readyController() async throws {
        try await setUpGlasses()
        await waitUntil("glasses ready", timeout: 40) { self.controller.snapshot.isCameraReady }
    }

    func streamingScan(service: PantryService = RecordingPantryService()) async throws -> ScanCaptureViewModel {
        try await readyController()
        let scan = ScanCaptureViewModel(camera: FakeCameraSource(kind: .phone), service: service, glasses: controller)
        XCTAssertEqual(scan.availableSources, [.phone, .glasses])
        await scan.selectSource(.glasses)
        await scan.startCamera()
        XCTAssertNil(scan.message)
        await waitUntil("glasses streaming") { scan.cameraOn && self.controller.glassesCamera?.previewFrame != nil }
        return scan
    }

    // MARK: - Connect

    func testConnectReportsRegisteredPermittedConnected() async throws {
        try await readyController()
        let snapshot = controller.snapshot
        XCTAssertEqual(snapshot.registration, .registered)
        XCTAssertEqual(snapshot.permission, .granted)
        XCTAssertEqual(snapshot.link, .connected)
        XCTAssertNil(snapshot.issue)
        XCTAssertEqual(snapshot.statusText, "Connected")
        XCTAssertNotNil(snapshot.deviceName)
        XCTAssertTrue(controller.camera.isAvailable)
        XCTAssertFalse(controller.camera.activeIndicator, "nothing streams until the user taps")
    }

    // MARK: - Stream → pantry scan

    func testStreamCaptureFeedsPantryScanThroughTheSameEndpointAndKeepsNoFrame() async throws {
        let service = RecordingPantryService()
        let scan = try await streamingScan(service: service)
        XCTAssertEqual(scan.camera.kind, .glasses)
        XCTAssertEqual(scan.cameraOnLabel, "Glasses camera on")
        XCTAssertEqual(controller.snapshot.stream, .streaming)
        XCTAssertEqual(controller.snapshot.statusText, "Streaming")

        await scan.capture()
        XCTAssertNil(scan.message)
        let jpeg = try XCTUnwrap(scan.photoData)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "a JPEG from the latest stream frame")
        // The camera stops straight after the tap and the live frame is dropped.
        XCTAssertFalse(scan.cameraOn)
        XCTAssertFalse(controller.camera.activeIndicator)
        XCTAssertNil(controller.glassesCamera?.previewFrame)

        await scan.findItems()
        XCTAssertEqual(service.photos.count, 1, "same PantryService.observePhoto path as the iPhone camera")
        XCTAssertGreaterThan(service.photos.first?.pixelWidth ?? 0, 0)
        XCTAssertNil(scan.photoData, "photo dropped once the server answered")
        XCTAssertNotNil(scan.observation)
    }

    // MARK: - Disconnect mid-stream

    func testDisconnectMidStreamFallsBackWithBannerAndLeavesCookingSessionAlone() async throws {
        let cookingService = RecordingCookingService()
        let cooking = CookingSessionStore(service: cookingService, cache: InMemorySessionCache(),
                                          owner: { SessionOwner(userId: UUID(), server: "http://localhost:8000") })
        await cooking.refresh()
        let activeBefore = try XCTUnwrap(cooking.active)
        let epochBefore = cooking.epoch
        let callsBefore = cookingService.calls

        let scan = try await streamingScan()
        device?.powerOff()

        await waitUntil("fallback after disconnect") { !scan.cameraOn && scan.activeSource == .phone }
        XCTAssertFalse(controller.snapshot.isCameraReady)
        let banner = try XCTUnwrap(scan.glassesBanner)
        XCTAssertTrue(banner.hasSuffix("Using the iPhone camera."), banner)
        XCTAssertEqual(scan.camera.kind, .phone)
        XCTAssertEqual(scan.availableSources, [.phone], "glasses hidden until ready again")
        XCTAssertNil(controller.glassesCamera?.previewFrame)

        // The cooking session is untouched: same summary, no reset, not a single call.
        XCTAssertEqual(cooking.active, activeBefore)
        XCTAssertEqual(cooking.epoch, epochBefore)
        XCTAssertNil(cooking.presented)
        XCTAssertEqual(cookingService.calls, callsBefore)
    }

    // MARK: - Permission denied

    func testPermissionDeniedHidesGlassesCameraAndExplains() async throws {
        try await setUpGlasses(permissionsGranted: false)
        await waitUntil("registered + linked") {
            self.controller.snapshot.registration == .registered && self.controller.snapshot.link == .connected
        }
        await controller.requestCameraPermission()
        XCTAssertEqual(controller.snapshot.permission, .denied)
        XCTAssertFalse(controller.snapshot.isCameraReady)

        let scan = ScanCaptureViewModel(camera: FakeCameraSource(kind: .phone), service: RecordingPantryService(), glasses: controller)
        XCTAssertEqual(scan.availableSources, [.phone])
        XCTAssertFalse(scan.showsSourcePicker)

        let settings = GlassesSettingsViewModel(glasses: controller)
        XCTAssertEqual(settings.permissionText, "Not allowed")
        XCTAssertTrue(settings.canRequestPermission, "the user can ask again from Settings → Glasses")
        XCTAssertFalse(settings.canStartPreview)

        do {
            try await controller.camera.startPreview()
            XCTFail("must not stream without the glasses camera permission")
        } catch {
            XCTAssertFalse(controller.camera.activeIndicator)
        }
    }

    // MARK: - Hinges closed

    func testFoldingMidStreamBlocksGlassesThenUnfoldOffersThemAgain() async throws {
        let scan = try await streamingScan()
        device?.fold()

        // MockDeviceKit 1.0.1 reports a fold either as hinges closed or (when the session ends
        // first) as the device ending the session / dropping the link. Every variant must fall back.
        await waitUntil("glasses blocked") { !self.controller.snapshot.isCameraReady }
        await waitUntil("camera off") { !scan.cameraOn }
        XCTAssertEqual(scan.activeSource, .phone)
        let issue = controller.snapshot.issue
        XCTAssertTrue(issue != nil || controller.snapshot.link != .connected, "a fold must block the glasses camera")
        XCTAssertNotNil(scan.glassesBanner)
        XCTAssertTrue(scan.glassesBanner?.hasSuffix("Using the iPhone camera.") ?? false)
        if issue == .hingesClosed {
            XCTAssertEqual(scan.glassesBanner, GlassesIssue.hingesClosed.bannerText)
            XCTAssertEqual(controller.snapshot.statusText, "Glasses folded")
        }

        device?.unfold()
        await waitUntil("glasses offered again") { self.controller.snapshot.isCameraReady }
        XCTAssertEqual(scan.availableSources, [.phone, .glasses])
        XCTAssertNil(scan.glassesBanner)
        XCTAssertFalse(scan.cameraOn, "unfolding never restarts the camera by itself")
    }

    // MARK: - Battery / thermal

    func testLowBatteryAndHeatBlockTheCamera() async throws {
        try await readyController()
        device?.setBatteryLevel(2)
        await waitUntil("battery low") { self.controller.snapshot.issue == .batteryLow }
        XCTAssertFalse(controller.camera.isAvailable)
        device?.setBatteryLevel(70)
        await waitUntil("battery ok") { self.controller.snapshot.issue == nil }

        device?.setThermalLevel(.critical)
        await waitUntil("too warm") { self.controller.snapshot.issue == .thermalHot }
        XCTAssertEqual(controller.snapshot.statusText, "Glasses too warm")
        device?.setThermalLevel(.none)
        await waitUntil("cooled") { self.controller.snapshot.isCameraReady }
    }

    // MARK: - Start gate

    func testStopDuringStartWinsAndNothingKeepsStreaming() async throws {
        try await readyController()
        let camera = try XCTUnwrap(controller.glassesCamera)
        let start = Task { @MainActor in
            do {
                try await camera.startPreview()
                return "started"
            } catch let error as CaptureError {
                return error == .cancelled ? "cancelled" : "failed"
            } catch {
                return "failed"
            }
        }
        await Task.yield()
        await camera.stopPreview()
        let outcome = await start.value
        XCTAssertEqual(outcome, "cancelled")
        try? await Task.sleep(for: .seconds(2))
        XCTAssertFalse(camera.activeIndicator)
        XCTAssertNil(camera.previewFrame)
        XCTAssertEqual(camera.phase, .idle)
    }
}
