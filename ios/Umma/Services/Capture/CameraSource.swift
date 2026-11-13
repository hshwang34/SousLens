import Foundation

/// PRD §9.4: one protocol for the phone camera today and the glasses camera later.
/// Capture is user-initiated: nothing runs until `startPreview()` and `stopPreview()` tears down.
@MainActor
protocol CameraSource: AnyObject {
    var kind: CaptureSourceKind { get }
    /// Hardware present and feature enabled. False on the simulator.
    var isAvailable: Bool { get }
    /// True while the capture session is running — drives the "camera active" indicator.
    var activeIndicator: Bool { get }

    func startPreview() async throws
    func captureFrame() async throws -> CapturedFrame
    func stopPreview() async
}
