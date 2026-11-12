import Foundation
import Observation
import UIKit

/// Scriptable glasses for previews and the public app's tests. No DAT.
@MainActor
@Observable
final class FakeGlassesController: GlassesController {
    var snapshot: GlassesSnapshot
    let fakeCamera: FakeCameraSource
    var camera: any CameraSource { fakeCamera }
    private(set) var registerCount = 0
    private(set) var permissionRequests = 0
    private(set) var handledURLs: [URL] = []

    init(snapshot: GlassesSnapshot = GlassesSnapshot(), camera: FakeCameraSource = FakeCameraSource(kind: .glasses)) {
        self.snapshot = snapshot
        fakeCamera = camera
    }

    func register() async {
        registerCount += 1
        snapshot.registration = .registered
    }

    func unregister() async {
        snapshot.registration = .notRegistered
    }

    func requestCameraPermission() async {
        permissionRequests += 1
        snapshot.permission = .granted
    }

    private(set) var clearIssueCount = 0

    func clearStreamIssue() {
        clearIssueCount += 1
        snapshot.issue = nil
    }

    func handleOpenURL(_ url: URL) async -> Bool {
        guard url.scheme == "souslensglasses" else { return false }
        handledURLs.append(url)
        return true
    }

    /// A ready, connected pair of glasses.
    static func ready() -> FakeGlassesController {
        FakeGlassesController(snapshot: GlassesSnapshot(
            registration: .registered, permission: .granted, link: .connected,
            stream: .idle, issue: nil, deviceName: "Ray-Ban Meta", batteryLevel: 80
        ))
    }
}
