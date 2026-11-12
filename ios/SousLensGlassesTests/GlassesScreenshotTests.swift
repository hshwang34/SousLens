import SwiftUI
import UIKit
import XCTest
@testable import SousLensGlasses

/// Brief 009 screenshots of Settings → Glasses and the scan source picker, driven by MockDeviceKit.
/// Runs only when `SOUSLENS_GLASSES_SHOTS` names an output folder (JPEG, ≤1600 px).
extension GlassesMockDeviceTests {
    private var shotsFolder: URL? {
        guard let path = ProcessInfo.processInfo.environment["SOUSLENS_GLASSES_SHOTS"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func testCaptureGlassesScreenshots() async throws {
        guard let folder = shotsFolder else { throw XCTSkip("SOUSLENS_GLASSES_SHOTS not set") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await readyController()
        let route = AudioRouteMonitor(glassesBuild: true, read: { [] })

        // 1. Settings → Glasses, live preview streaming.
        let settings = GlassesSettingsViewModel(glasses: controller)
        await settings.startPreview()
        await waitUntil("preview frame") { self.controller.glassesCamera?.previewFrame != nil }
        try await snapshot(NavigationStack { GlassesSettingsView(model: settings, audioRoute: route) },
                           to: folder.appending(path: "01-glasses-settings-streaming.jpg"))
        try await snapshot(NavigationStack { GlassesSettingsView(model: settings, audioRoute: route) },
                           to: folder.appending(path: "01b-glasses-settings-streaming-dark.jpg"), dark: true)
        await settings.stopPreview()

        // 3. Pantry scan: source picker with the glasses camera streaming.
        let scan = ScanCaptureViewModel(camera: FakeCameraSource(kind: .phone, isAvailable: true),
                                        service: RecordingPantryService(), glasses: controller)
        await scan.selectSource(.glasses)
        try await snapshot(NavigationStack { ScanCaptureView(model: scan) { _ in } },
                           to: folder.appending(path: "03-scan-source-picker.jpg"))
        await scan.startCamera()
        await waitUntil("scan streaming") { scan.cameraOn && self.controller.glassesCamera?.previewFrame != nil }
        try await snapshot(NavigationStack { ScanCaptureView(model: scan) { _ in } },
                           to: folder.appending(path: "04-scan-glasses-camera-on.jpg"))

        // 4. Glasses folded mid-scan: fallback banner, iPhone camera.
        device?.fold()
        await waitUntil("fallback") { !scan.cameraOn && scan.glassesBanner != nil }
        try await snapshot(NavigationStack { ScanCaptureView(model: scan) { _ in } },
                           to: folder.appending(path: "05-scan-fallback-banner.jpg"))

        // 5. Settings while folded: honest device state, preview unavailable.
        try await snapshot(NavigationStack { GlassesSettingsView(model: settings, audioRoute: route) },
                           to: folder.appending(path: "02-glasses-settings-folded.jpg"))
    }

    /// Renders a view in a real window (Lists and pickers need UIKit) and writes a JPEG.
    private func snapshot(_ view: some View, to url: URL, dark: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: view.tint(SLColor.accent))
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .milliseconds(1200))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1600.0 / 852.0
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.85))
        try data.write(to: url)
    }
}
