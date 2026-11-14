import CoreImage
import Foundation
import ImageIO
import os
import XCTest
@testable import Umma

/// Brief 016 PR 4: camera frame stream for live scan.
@MainActor
final class LiveFrameStreamTests: XCTestCase {
    private func frame(_ seconds: TimeInterval) -> CapturedFrame {
        CapturedFrame(jpegData: Data([0xFF, 0xD8]), capturedAt: Date(timeIntervalSinceReferenceDate: seconds))
    }

    // MARK: - Throttle

    func testThrottleAdmitsAtMostMaxFPS() {
        var throttle = FrameThrottle(maxFPS: 1)
        XCTAssertTrue(throttle.admit(at: 10.0))
        XCTAssertFalse(throttle.admit(at: 10.5))
        XCTAssertFalse(throttle.admit(at: 10.99))
        XCTAssertTrue(throttle.admit(at: 11.0))
        XCTAssertFalse(throttle.admit(at: 11.4))
        XCTAssertTrue(throttle.admit(at: 12.2))
    }

    func testThrottleSanitisesRequestedRate() {
        XCTAssertEqual(FrameThrottle(maxFPS: 0).minInterval, 1)
        XCTAssertEqual(FrameThrottle(maxFPS: -3).minInterval, 1)
        XCTAssertEqual(FrameThrottle(maxFPS: .nan).minInterval, 1)
        XCTAssertEqual(FrameThrottle(maxFPS: 1000).minInterval, 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(FrameThrottle(maxFPS: 2).minInterval, 0.5, accuracy: 1e-9)
    }

    func testHubThrottles30FPSCameraToRequestedRateAndOnlyEncodesAdmittedFrames() async {
        let hub = LiveFrameHub(buffering: .unbounded)
        let stream = hub.makeStream(maxFPS: 1, longEdge: 768)
        hub.setDelivering(true)
        var encodes = 0
        var yielded = 0
        for index in 0..<150 { // 5 s of 30 fps buffers
            let time = 100 + Double(index) / 30
            if hub.offer(at: time, make: { _ in encodes += 1; return self.frame(time) }) { yielded += 1 }
        }
        XCTAssertEqual(yielded, encodes, "only admitted frames are encoded")
        XCTAssertLessThanOrEqual(yielded, 5)
        XCTAssertGreaterThanOrEqual(yielded, 4)
        hub.finish()
        var times: [TimeInterval] = []
        for await frame in stream { times.append(frame.capturedAt.timeIntervalSinceReferenceDate) }
        XCTAssertEqual(times.count, yielded)
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, 1 - 1e-9)
        }
    }

    func testHubPassesRequestedLongEdgeToEncoder() {
        let hub = LiveFrameHub()
        let stream = hub.makeStream(maxFPS: 1, longEdge: 512)
        defer { withExtendedLifetime(stream) {} } // a dropped stream terminates and releases the hub
        hub.setDelivering(true)
        var seen: CGFloat?
        hub.offer(at: 1) { longEdge in seen = longEdge; return self.frame(1) }
        XCTAssertEqual(seen, 512)
    }

    // MARK: - Lifecycle

    func testFinishEndsTheStream() async {
        let hub = LiveFrameHub(buffering: .unbounded)
        let stream = hub.makeStream(maxFPS: 1, longEdge: 768)
        hub.setDelivering(true)
        XCTAssertTrue(hub.offer(at: 1) { _ in self.frame(1) })
        hub.finish()
        XCTAssertFalse(hub.isDelivering)
        XCTAssertFalse(hub.offer(at: 5) { _ in self.frame(5) })
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 1, "the frame before stop is delivered, then the stream ends")
    }

    func testCancellingTheConsumerStopsDelivery() async throws {
        let hub = LiveFrameHub()
        let stream = hub.makeStream(maxFPS: 30, longEdge: 768)
        hub.setDelivering(true)
        let consumer = Task {
            var received = 0
            for await _ in stream { received += 1 }
            return received
        }
        XCTAssertTrue(hub.wantsFrames)
        consumer.cancel()
        _ = await consumer.value
        XCTAssertFalse(hub.wantsFrames, "a cancelled consumer must release the hub")
        var encoded = false
        XCTAssertFalse(hub.offer(at: 10) { _ in encoded = true; return self.frame(10) })
        XCTAssertFalse(encoded, "no pixels are touched once nobody is listening")
    }

    func testNotDeliveringYieldsNothingAndNeverEncodes() {
        let hub = LiveFrameHub()
        let stream = hub.makeStream(maxFPS: 1, longEdge: 768)
        defer { withExtendedLifetime(stream) {} }
        XCTAssertFalse(hub.wantsFrames)
        var encoded = false
        XCTAssertFalse(hub.offer(at: 1) { _ in encoded = true; return self.frame(1) })
        XCTAssertFalse(encoded)
    }

    func testNewStreamFinishesThePreviousOne() async {
        let hub = LiveFrameHub()
        let first = hub.makeStream(maxFPS: 1, longEdge: 768)
        _ = hub.makeStream(maxFPS: 1, longEdge: 768)
        var count = 0
        for await _ in first { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testStopDuringEncodeDropsTheFrame() async {
        let hub = LiveFrameHub(buffering: .unbounded)
        let stream = hub.makeStream(maxFPS: 1, longEdge: 768)
        hub.setDelivering(true)
        let yielded = hub.offer(at: 1) { _ in
            hub.finish() // stopPreview lands while the frame is being encoded
            return self.frame(1)
        }
        XCTAssertFalse(yielded)
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testFailedEncodeDoesNotSpendTheThrottleSlot() {
        let hub = LiveFrameHub(buffering: .unbounded)
        let stream = hub.makeStream(maxFPS: 1, longEdge: 768)
        defer { withExtendedLifetime(stream) {} }
        hub.setDelivering(true)
        XCTAssertFalse(hub.offer(at: 1) { _ in nil }, "encode failed")
        XCTAssertTrue(hub.offer(at: 1.1) { _ in self.frame(1.1) }, "the next buffer may use the slot")
        XCTAssertFalse(hub.offer(at: 1.5) { _ in self.frame(1.5) })
    }

    /// The phone camera enables its video connection from these transitions (photo-only screens
    /// with no consumer get no buffers).
    func testConsumerChangesAreReportedForConnectionToggling() async {
        let hub = LiveFrameHub()
        let seen = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        hub.setConsumerChangeHandler { [weak hub] in
            let now = hub?.hasConsumer ?? false
            seen.withLock { $0.append(now) }
        }
        XCTAssertFalse(hub.hasConsumer)

        let first = hub.makeStream(maxFPS: 1, longEdge: 768)
        XCTAssertTrue(hub.hasConsumer)
        hub.finish() // stopPreview
        XCTAssertFalse(hub.hasConsumer)
        for await _ in first {}

        let second = hub.makeStream(maxFPS: 1, longEdge: 768)
        let consumer = Task { for await _ in second {} }
        XCTAssertTrue(hub.hasConsumer)
        consumer.cancel()
        await consumer.value
        XCTAssertFalse(hub.hasConsumer, "cancelling the consumer turns frames off")
        XCTAssertEqual(seen.withLock { $0 }, [true, false, true, false])
    }

    func testHubDeliversAgainAfterStopStartAndFreshStream() async {
        let hub = LiveFrameHub(buffering: .unbounded)
        let first = hub.makeStream(maxFPS: 1, longEdge: 768)
        hub.setDelivering(true)
        XCTAssertTrue(hub.offer(at: 1) { _ in self.frame(1) })
        hub.finish()
        for await _ in first {}

        let second = hub.makeStream(maxFPS: 1, longEdge: 768)
        XCTAssertFalse(hub.offer(at: 3) { _ in self.frame(3) }, "nothing until the preview runs again")
        hub.setDelivering(true) // startPreview completed
        XCTAssertTrue(hub.offer(at: 4) { _ in self.frame(4) })
        hub.finish()
        var times: [TimeInterval] = []
        for await frame in second { times.append(frame.capturedAt.timeIntervalSinceReferenceDate) }
        XCTAssertEqual(times, [4])
    }

    // MARK: - Start gate (a superseded start never delivers)

    func testSupersededStartNeverDeliversFrames() {
        var gate = CaptureStartGate()
        let stale = gate.begin()
        gate.supersede() // stopPreview while the start was awaiting permission / startRunning
        XCTAssertFalse(PhoneCameraSource.shouldDeliverFrames(token: stale, gate: gate, sessionActive: true))

        let hub = LiveFrameHub()
        let stream = hub.makeStream(maxFPS: 1, longEdge: 768)
        defer { withExtendedLifetime(stream) {} }
        hub.setDelivering(PhoneCameraSource.shouldDeliverFrames(token: stale, gate: gate, sessionActive: true))
        XCTAssertFalse(hub.offer(at: 1) { _ in self.frame(1) })

        let newer = gate.begin()
        XCTAssertFalse(PhoneCameraSource.shouldDeliverFrames(token: stale, gate: gate, sessionActive: true),
                       "an older start stays stale after a newer one begins")
        XCTAssertTrue(PhoneCameraSource.shouldDeliverFrames(token: newer, gate: gate, sessionActive: true))
        XCTAssertFalse(PhoneCameraSource.shouldDeliverFrames(token: newer, gate: gate, sessionActive: false),
                       "an interrupted session delivers nothing")
        XCTAssertFalse(PhoneCameraSource.shouldDeliverFrames(token: nil, gate: gate, sessionActive: true))
    }

    // MARK: - Phone camera (simulator: no hardware, but the stream contract still holds)

    func testPhoneCameraStopFinishesTheStreamAndPhotoPathIsUnchanged() async {
        let camera = PhoneCameraSource()
        let stream = camera.frames()
        await camera.stopPreview()
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
        do {
            _ = try await camera.captureFrame()
            XCTFail("photo capture still requires a running preview")
        } catch {
            XCTAssertEqual(error as? CaptureError, .notRunning)
        }
    }

    // MARK: - Encoder

    private func decodedSize(_ data: Data?) -> CGSize? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    private func solid(_ width: CGFloat, _ height: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func testEncoderDownscalesToLongEdgeAsJPEG() {
        let context = CIContext()
        let data = LiveFrameEncoder.encode(solid(1920, 1080), longEdge: 768, context: context)
        XCTAssertEqual(data?.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(decodedSize(data), CGSize(width: 768, height: 432))
    }

    func testEncoderKeepsPortraitAfterRotationAndNeverUpscales() {
        let context = CIContext()
        let upright = solid(1920, 1080).oriented(.right)
        XCTAssertEqual(decodedSize(LiveFrameEncoder.encode(upright, longEdge: 768, context: context)),
                       CGSize(width: 432, height: 768))
        XCTAssertEqual(decodedSize(LiveFrameEncoder.encode(solid(400, 300), longEdge: 768, context: context)),
                       CGSize(width: 400, height: 300))
        XCTAssertNil(LiveFrameEncoder.encode(CIImage.empty(), context: context))
    }

    // MARK: - Fake

    func testFakeYieldsScriptedFramesThrottledUntilStopped() async throws {
        let camera = FakeFrameStreamingCameraSource(scriptedFrames: [frame(0), frame(0.5), frame(1.2), frame(1.9), frame(2.3)])
        let stream = camera.frames(maxFPS: 1, longEdge: 768)
        try await camera.startPreview()
        XCTAssertTrue(camera.activeIndicator)
        XCTAssertTrue(camera.send(frame(3.4)))
        XCTAssertFalse(camera.send(frame(3.9)), "throttled")
        await camera.stopPreview()
        XCTAssertFalse(camera.send(frame(10)), "nothing after stop")
        var times: [TimeInterval] = []
        for await frame in stream { times.append(frame.capturedAt.timeIntervalSinceReferenceDate) }
        XCTAssertEqual(times, [0, 1.2, 2.3, 3.4])
    }

    func testFakeDeliversNothingBeforeStartAndRespectsUnavailable() async {
        let camera = FakeFrameStreamingCameraSource(scriptedFrames: [frame(0)])
        let stream = camera.frames()
        defer { withExtendedLifetime(stream) {} }
        XCTAssertFalse(camera.send(frame(5)), "no frames before the preview runs")

        let unavailable = FakeFrameStreamingCameraSource(isAvailable: false)
        do {
            try await unavailable.startPreview()
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? CaptureError, .unavailable(.phone, reason: "Fake source marked unavailable."))
        }
    }

    func testFakeStopStartFreshStreamDeliversAgain() async throws {
        let camera = FakeFrameStreamingCameraSource(scriptedFrames: [frame(0)])
        let first = camera.frames()
        try await camera.startPreview()
        await camera.stopPreview()
        var firstCount = 0
        for await _ in first { firstCount += 1 }
        XCTAssertEqual(firstCount, 1)

        try await camera.startPreview()
        let second = camera.frames()
        XCTAssertTrue(camera.send(frame(5)))
        await camera.stopPreview()
        var times: [TimeInterval] = []
        for await frame in second { times.append(frame.capturedAt.timeIntervalSinceReferenceDate) }
        XCTAssertEqual(times, [0, 5], "the fresh stream replays the script, then takes new frames")
    }

    func testFakeStillCapturesPhotos() async throws {
        let camera = FakeFrameStreamingCameraSource(scriptedFrames: [frame(7)])
        try await camera.startPreview()
        let captured = try await camera.captureFrame()
        XCTAssertEqual(captured, frame(7))
    }

    // MARK: - Flag

    func testLiveScanFlagDefaultsOffAndLeavesAdaptersAlone() {
        let defaults = freshDefaults()
        let flags = CaptureFeatureFlags.load(from: defaults)
        XCTAssertFalse(flags.liveScan)
        XCTAssertEqual(flags, .allOn)
        XCTAssertFalse(CaptureFeatureFlags.allOn.liveScan)
        defaults.set(true, forKey: CaptureFeatureFlags.Key.liveScan)
        XCTAssertTrue(CaptureFeatureFlags.load(from: defaults).liveScan)
        XCTAssertEqual(CaptureFeatureFlags.Key.liveScan, "feature.capture.liveScan")
    }
}
