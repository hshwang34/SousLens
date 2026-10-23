import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SousLens

// QA gate for brief 004 (iOS half). Each test names the acceptance probe it closes.

private func decodeObservation(_ json: String) throws -> PantryObservation {
    try PantryFixtures.decode(PantryObservation.self, json)
}

// MARK: - Probe 1 / 2: Scan review gate

@MainActor
final class Slice2ReviewGateTests: XCTestCase {
    private let existingOnion = PantryFixtures.item(id: PantryFixtures.onionId, raw: "Onions", normalized: "onion", source: "voice")

    func testRejectingEveryCandidateSendsNothing() async throws {
        let service = FakePantryService()
        let model = ScanReviewViewModel(observation: try decodeObservation(PantryFixtures.observationPhotoJSON), existingItems: [], service: service)
        for row in model.rows { model.setAccepted(row.id, false) }
        XCTAssertTrue(model.acceptedRows.isEmpty)
        XCTAssertFalse(model.canConfirm)
        let result = await model.confirm()
        XCTAssertNil(result)
        XCTAssertTrue(service.calls.isEmpty, "rejecting all candidates must not call the server")
        XCTAssertNil(model.confirmed)
        XCTAssertEqual(model.error, "Tick at least one item to add.")
    }

    func testNothingIsWrittenUntilConfirmIsCalled() throws {
        let service = FakePantryService()
        let model = ScanReviewViewModel(observation: try decodeObservation(PantryFixtures.observationTranscriptJSON),
                                        existingItems: [existingOnion], service: service)
        model.setAccepted(0, true)
        model.setName(0, "edited")
        model.choose(1, .merge)
        XCTAssertTrue(service.calls.isEmpty, "edits and choices are local until Confirm")
    }

    func testEveryDuplicateRowNeedsAnAnswerAndCountIsPlural() async throws {
        let json = PantryFixtures.observationTranscriptJSON.replacingOccurrences(
            of: #""evidence":"you said “gochujang”","action":"add","duplicate_of":null"#,
            with: #""evidence":"you said “gochujang”","action":"add","duplicate_of":"\#(PantryFixtures.onionId)""#)
        XCTAssertNotEqual(json, PantryFixtures.observationTranscriptJSON, "fixture edit must apply")
        let service = FakePantryService()
        let model = ScanReviewViewModel(observation: try decodeObservation(json), existingItems: [existingOnion], service: service)
        XCTAssertEqual(model.rows.filter(\.needsDuplicateChoice).map(\.id), [1, 2])
        XCTAssertEqual(model.blockingMessage, "Choose Merge or Keep both for the 2 items you already have.")
        model.choose(1, .merge)
        XCTAssertFalse(model.canConfirm, "one answer is not enough while another duplicate is open")
        await model.confirm()
        XCTAssertTrue(service.calls.isEmpty)
        model.choose(2, .keepBoth)
        XCTAssertTrue(model.canConfirm)
        await model.confirm()
        let sent = try XCTUnwrap(service.addCalls.first)
        XCTAssertEqual(sent.map(\.resolution), [nil, .mergeInto(UUID(uuidString: PantryFixtures.onionId)!), .keepBoth])
    }

    func test409IndexCountsSentRowsOnlyWhenEarlierRowIsUnticked() async throws {
        // Rows: 0 chicken (unticked), 1 onions (kept both), 2 gochujang, 3 unknown (off).
        // Sent = [onions, gochujang]; the server flags sent index 1 -> row 2.
        let service = FakePantryService()
        let conflict = PantryFixtures.duplicateJSON.replacingOccurrences(of: #""index":0"#, with: #""index":1"#)
        let envelope = try PantryFixtures.decode(APIErrorEnvelope.self, conflict)
        let error = APIError.server(status: 409, code: envelope.error.code, message: envelope.error.message, retryable: false,
                                    correlationId: nil, details: envelope.error.details)
        service.addHandler = { _, _ in throw error }
        let model = ScanReviewViewModel(observation: try decodeObservation(PantryFixtures.observationTranscriptJSON),
                                        existingItems: [existingOnion], service: service)
        model.setAccepted(0, false)
        model.choose(1, .keepBoth)
        await model.confirm()
        XCTAssertEqual(service.addCalls.first?.map(\.rawLabel), ["onions", "gochujang"])
        XCTAssertEqual(model.rows[2].duplicateOf, UUID(uuidString: PantryFixtures.onionId))
        XCTAssertEqual(model.rows[2].duplicateName, "Onions")
        XCTAssertNil(model.rows[2].duplicateChoice, "not silently resolved")
        XCTAssertNil(model.rows[0].duplicateOf, "the unticked row (candidate index 1 of sent would be wrong) is untouched")
        XCTAssertNotNil(model.rows[1].duplicateChoice, "an earlier answer for a non-conflicting row survives")
        XCTAssertFalse(model.canConfirm)
        XCTAssertNotNil(model.conflictMessage)
    }

    func test409WithOutOfRangeIndexChangesNoRowAndSaysNothingWasAdded() async throws {
        let service = FakePantryService()
        let conflict = PantryFixtures.duplicateJSON.replacingOccurrences(of: #""index":0"#, with: #""index":9"#)
        let envelope = try PantryFixtures.decode(APIErrorEnvelope.self, conflict)
        service.addHandler = { _, _ in
            throw APIError.server(status: 409, code: envelope.error.code, message: envelope.error.message, retryable: false,
                                  correlationId: nil, details: envelope.error.details)
        }
        let model = ScanReviewViewModel(observation: try decodeObservation(PantryFixtures.observationPhotoJSON), existingItems: [], service: service)
        // Mock photo candidates start unticked (fix order #4); opt two in.
        model.setAccepted(0, true)
        model.setAccepted(1, true)
        await model.confirm()
        XCTAssertTrue(model.rows.allSatisfy { $0.duplicateOf == nil })
        XCTAssertTrue(model.error?.contains("Nothing was added") ?? false)
        XCTAssertNil(model.confirmed)
        XCTAssertTrue(model.canConfirm, "user can retry")
    }

    func testServerDuplicateHintOnUntickedRowDoesNotBlockConfirm() throws {
        let model = ScanReviewViewModel(observation: try decodeObservation(PantryFixtures.observationTranscriptJSON),
                                        existingItems: [existingOnion], service: FakePantryService())
        XCTAssertFalse(model.canConfirm)
        model.setAccepted(1, false)
        XCTAssertTrue(model.canConfirm)
    }

    func testTranscriptSourceIsVoiceAndPhotoSourceIsPhoto() {
        XCTAssertEqual(ObservationMode.transcript.source, .voice)
        XCTAssertEqual(ObservationMode.photo.source, .photo)
    }
}

// MARK: - Probe 5: honest mock labelling

@MainActor
final class Slice2DemoBannerTests: XCTestCase {
    func testBannerOnlyForMockPhotoObservations() throws {
        func banner(_ json: String) throws -> Bool {
            ScanReviewViewModel(observation: try decodeObservation(json), existingItems: [], service: FakePantryService()).showsDemoBanner
        }
        XCTAssertTrue(try banner(PantryFixtures.observationPhotoJSON), "mock + photo")
        XCTAssertFalse(try banner(PantryFixtures.observationTranscriptJSON), "mock + transcript has no banner")
        let geminiPhoto = PantryFixtures.observationPhotoJSON.replacingOccurrences(of: #""provider":"mock""#, with: #""provider":"gemini""#)
        XCTAssertNotEqual(geminiPhoto, PantryFixtures.observationPhotoJSON)
        XCTAssertFalse(try banner(geminiPhoto), "gemini + photo has no banner")
        let geminiTranscript = PantryFixtures.observationTranscriptJSON.replacingOccurrences(of: #""provider":"mock""#, with: #""provider":"gemini""#)
        XCTAssertFalse(try banner(geminiTranscript))
    }

    func testBannerCopyIsInTheViewVerbatim() throws {
        // The view string is the PM-approved copy (DECISIONS #11); guard against drift.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SousLens/Features/Pantry/ScanReviewView.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("Demo mode — not a real detection"))
    }
}

// MARK: - Probe 3 / 4: capture lifecycle

@MainActor
final class Slice2CaptureGateTests: XCTestCase {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    private func passthrough() -> @Sendable (Data) async throws -> PantryPhotoUpload {
        { PantryPhotoUpload(jpegData: $0, pixelWidth: 1, pixelHeight: 1) }
    }

    func testCameraStaysOffUntilStartCameraIsCalled() async {
        let camera = FakeCameraSource()
        let model = ScanCaptureViewModel(camera: camera, service: FakePantryService(), encode: passthrough())
        await model.capture()    // no preview: must not capture
        XCTAssertEqual(camera.captureCount, 0)
        XCTAssertFalse(camera.activeIndicator)
        XCTAssertFalse(model.hasPhoto)
    }

    func testCaptureFailureStillStopsCameraAndKeepsNoPhoto() async {
        // Fake with no scripted frames returns empty data; force a throw via unavailable-after-start.
        let camera = ThrowingCaptureCamera()
        let model = ScanCaptureViewModel(camera: camera, service: FakePantryService(), encode: passthrough())
        await model.startCamera()
        XCTAssertTrue(model.cameraOn)
        await model.capture()
        XCTAssertFalse(camera.activeIndicator, "camera off even when the capture failed")
        XCTAssertNil(model.photoData)
        XCTAssertNotNil(model.message)
    }

    func testTearDownStopsRunningCameraAndClearsPhoto() async {
        let camera = FakeCameraSource(scriptedFrames: [CapturedFrame(jpegData: jpeg, capturedAt: Date())])
        let model = ScanCaptureViewModel(camera: camera, service: FakePantryService(), encode: passthrough())
        await model.startCamera()
        await model.tearDown()
        XCTAssertFalse(camera.activeIndicator)
        await model.usePickedPhoto(jpeg)
        XCTAssertTrue(model.hasPhoto)
        await model.tearDown()
        XCTAssertNil(model.photoData, "photo cleared on sheet close")
    }

    func testDiscardAndCancelDropPhotoAndCamera() async {
        let camera = FakeCameraSource()
        let model = ScanCaptureViewModel(camera: camera, service: FakePantryService(), encode: passthrough())
        await model.usePickedPhoto(jpeg)
        model.discardPhoto()
        XCTAssertNil(model.photoData)
        await model.startCamera()
        await model.cancelCamera()
        XCTAssertFalse(model.cameraOn)
    }

    func testFindItemsNeverRunsWhileCameraIsLive() async {
        let service = FakePantryService()
        let camera = FakeCameraSource()
        let model = ScanCaptureViewModel(camera: camera, service: service, encode: passthrough())
        await model.usePickedPhoto(jpeg)
        await model.startCamera()   // restarting clears the previous photo
        XCTAssertNil(model.photoData)
        XCTAssertFalse(model.canFindItems)
    }

    func testCaptureSourcesNeverTouchDiskInThePantryPath() throws {
        // Static guard for probe 3: the pantry capture path has no file/URL-cache/photo-library APIs.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SousLens")
        let files = ["Features/Pantry/PantryCaptureViewModels.swift", "Features/Pantry/PantryCaptureViews.swift",
                     "Services/Capture/PantryImageEncoder.swift", "Services/Capture/PhoneCameraSource.swift"]
        let banned = [".write(to", "FileManager", "URLCache", "createFile", "temporaryDirectory",
                      "UIImageWriteToSavedPhotosAlbum", "PHPhotoLibrary", "writeToFile", "NSTemporaryDirectory"]
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for token in banned {
                XCTAssertFalse(text.contains(token), "\(file) uses \(token)")
            }
        }
    }

    // MARK: speech

    func testReleaseDuringPermissionPromptWinsAndNothingStaysLive() async {
        let speech = SuspendingSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        let starting = Task { await model.beginListening() }
        await speech.waitUntilStartRequested()
        XCTAssertTrue(model.isStarting)
        model.endListening()                    // finger lifted while the prompt is up
        speech.resumeStart()
        await starting.value
        await model.listenTask?.value
        XCTAssertFalse(speech.isListening, "microphone must not stay on after an early release")
        XCTAssertFalse(model.isListening)
        XCTAssertNil(model.listeningIndicator)
    }

    func testEndListeningIsIdempotentForSystemCancelledTouches() async {
        let speech = FakeSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        await model.beginListening()
        model.endListening()     // gesture cancelled by the system
        model.endListening()     // and again from scenePhase/onDisappear
        await model.listenTask?.value
        XCTAssertFalse(speech.isListening)
        XCTAssertFalse(model.isListening)
    }

    func testTypeInsteadWhileListeningStopsTheMic() async {
        let speech = FakeSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        await model.beginListening()
        model.typeInstead()
        XCTAssertFalse(speech.isListening)
        XCTAssertEqual(model.mode, .type)
    }

    func testToggleListeningForVoiceOver() async {
        let speech = FakeSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        await model.toggleListening()
        XCTAssertTrue(speech.isListening)
        await model.toggleListening()
        XCTAssertFalse(speech.isListening)
    }

    func testUnavailableSpeechNeverClaimsAnyMicrophone() async {
        let model = SpeakCaptureViewModel(speech: FakeSpeechInput(isAvailable: false), service: FakePantryService())
        XCTAssertNil(model.listeningIndicator)
        XCTAssertFalse(model.listeningIndicator?.localizedCaseInsensitiveContains("glasses") ?? false)
    }

    func testIndicatorNeverMentionsGlassesForAnyKind() async {
        for kind in [CaptureSourceKind.phone, .glasses] {
            let model = SpeakCaptureViewModel(speech: FakeSpeechInput(kind: kind), service: FakePantryService())
            await model.beginListening()
            XCTAssertFalse(model.listeningIndicator?.localizedCaseInsensitiveContains("glasses") ?? false)
            model.endListening()
        }
    }
}

@MainActor
private final class ThrowingCaptureCamera: CameraSource {
    let kind: CaptureSourceKind = .phone
    let isAvailable = true
    private(set) var activeIndicator = false
    func startPreview() async throws { activeIndicator = true }
    func captureFrame() async throws -> CapturedFrame { throw CaptureError.failed("sensor error") }
    func stopPreview() async { activeIndicator = false }
}

/// Speech source whose `startListening()` waits (like the system permission prompt) until resumed.
@MainActor
private final class SuspendingSpeechInput: SpeechInput {
    let kind: CaptureSourceKind = .phone
    let isAvailable = true
    private(set) var isListening = false
    private var gate: CheckedContinuation<Void, Never>?
    private var requested = false
    private var continuation: AsyncStream<TranscriptChunk>.Continuation?

    func waitUntilStartRequested() async {
        while !requested { await Task.yield() }
    }

    func resumeStart() { gate?.resume(); gate = nil }

    func startListening() async throws -> AsyncStream<TranscriptChunk> {
        requested = true
        await withCheckedContinuation { gate = $0 }
        let (stream, continuation) = AsyncStream<TranscriptChunk>.makeStream()
        self.continuation = continuation
        isListening = true
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
        isListening = false
    }
}

// MARK: - Probe 6: fit headline honesty and staleness

@MainActor
final class Slice2FitGateTests: XCTestCase {
    private let versionId = UUID(uuidString: PantryFixtures.versionId)!
    private let now = ISO8601Flexible.parse("2026-10-23T12:00:00Z")!

    private func model(_ fit: String, pantry: [PantryItem] = []) throws -> PantryFitViewModel {
        let service = FakePantryService()
        let decoded = try PantryFixtures.decode(PantryFit.self, fit)
        service.fitHandler = { _ in decoded }
        service.listHandler = { pantry }
        let now = self.now
        return PantryFitViewModel(recipeVersionId: versionId, recipeTitle: "T", service: service, now: { now })
    }

    func testCanMakeFalseWhenServerSaysTrueButARequiredLineIsMissing() async throws {
        let json = PantryFixtures.canMakeFitJSON.replacingOccurrences(
            of: #""name":"gochujang","optional":false,"status":"available""#, with: #""name":"gochujang","optional":false,"status":"missing""#)
        XCTAssertNotEqual(json, PantryFixtures.canMakeFitJSON)
        let vm = try model(json)
        await vm.load()
        XCTAssertFalse(vm.canMake)
        XCTAssertNotEqual(vm.headline, "Can make it")
    }

    func testServerCanMakeFalseIsNeverUpgradedEvenIfEveryRowIsAvailable() async throws {
        let json = PantryFixtures.canMakeFitJSON.replacingOccurrences(of: #""can_make":true"#, with: #""can_make":false"#)
        let vm = try model(json)
        await vm.load()
        XCTAssertFalse(vm.canMake)
        XCTAssertEqual(vm.headline, "Check your pantry")
    }

    func testUnknownStatusDecodesAsUncertainAndBlocksCanMake() async throws {
        let json = PantryFixtures.canMakeFitJSON.replacingOccurrences(
            of: #""name":"gochujang","optional":false,"status":"available""#, with: #""name":"gochujang","optional":false,"status":"plenty""#)
        let vm = try model(json)
        await vm.load()
        XCTAssertFalse(vm.canMake)
        XCTAssertEqual(vm.sections.first { $0.kind == .uncertain }?.rows.map(\.name), ["gochujang"])
    }

    func testOptionalUncertainDoesNotBlockCanMake() async throws {
        let vm = try model(PantryFixtures.canMakeFitJSON)
        await vm.load()
        XCTAssertTrue(vm.canMake)   // sesame (optional, missing) does not count
    }

    func testCopyNeverClaimsAGuarantee() async throws {
        for json in [PantryFixtures.fitJSON, PantryFixtures.canMakeFitJSON] {
            let vm = try model(json)
            await vm.load()
            let copy = [vm.headline, vm.subheadline, vm.coverageText].compactMap { $0 }.joined(separator: " ").lowercased()
            for phrase in ["guarantee", "100%", "definitely", "certain", "safe"] {
                XCTAssertFalse(copy.contains(phrase), "'\(phrase)' in: \(copy)")
            }
            XCTAssertTrue(vm.coverageAccessibilityLabel?.contains("This is a guide, not a guarantee.") ?? false)
        }
    }

    func testStillHaveItAppearsStrictlyAfterFourteenDays() async throws {
        // gochujang row (ing-1) matches gochujangId.
        let exactly = PantryFixtures.item(confirmed: "2026-10-09T12:00:00Z")      // 14 d 0 s
        let justOver = PantryFixtures.item(confirmed: "2026-10-09T11:59:59Z")     // 14 d 1 s
        let a = try model(PantryFixtures.fitJSON, pantry: [exactly]); await a.load()
        XCTAssertFalse(a.sections[0].rows[0].canConfirmStillHave, "exactly 14 days is not stale")
        let b = try model(PantryFixtures.fitJSON, pantry: [justOver]); await b.load()
        XCTAssertTrue(b.sections[0].rows[0].canConfirmStillHave)
    }

    func testStillHaveItFailureKeepsFitAndShowsError() async throws {
        let stale = PantryFixtures.item(confirmed: "2026-09-01T00:00:00Z")
        let service = FakePantryService()
        let decoded = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        service.fitHandler = { _ in decoded }
        service.listHandler = { [stale] }
        service.confirmHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        let vm = PantryFitViewModel(recipeVersionId: versionId, recipeTitle: "T", service: service)
        await vm.load()
        await vm.confirmStillHave(pantryItemId: stale.id)
        XCTAssertNotNil(vm.actionError)
        XCTAssertNotNil(vm.fit)
        XCTAssertEqual(service.calls.filter { $0 == .fit(versionId) }.count, 1, "no re-fit after a failed confirm")
    }

    func testFreshnessBoundaryInSecondsAndStaleRuleIsSharedByPantryList() {
        let base = ISO8601Flexible.parse("2026-10-23T12:00:00Z")!
        let fourteenDays: TimeInterval = 14 * 24 * 60 * 60
        XCTAssertFalse(PantryFreshness.isStale(lastConfirmedAt: base.addingTimeInterval(-fourteenDays), now: base))
        XCTAssertTrue(PantryFreshness.isStale(lastConfirmedAt: base.addingTimeInterval(-fourteenDays - 1), now: base))
        XCTAssertFalse(PantryFreshness.isStale(lastConfirmedAt: base.addingTimeInterval(-fourteenDays + 1), now: base))
        XCTAssertFalse(PantryFreshness.isStale(lastConfirmedAt: base.addingTimeInterval(60), now: base), "future timestamp is not stale")
    }
}

// MARK: - Probe 7: multipart + image encoding

final class Slice2UploadGateTests: XCTestCase {
    func testBoundariesAreUniquePerFormAndAbsentFromPayload() {
        let upload = PantryPhotoUpload(jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]), pixelWidth: 1, pixelHeight: 1)
        let boundaries = (0..<50).map { _ in MultipartFormData.pantryPhoto(upload).boundary }
        XCTAssertEqual(Set(boundaries).count, 50)
        for boundary in boundaries.prefix(3) {
            XCTAssertTrue(boundary.hasPrefix("SousLens-"))
            XCTAssertFalse(boundary.contains(" "))
            XCTAssertLessThanOrEqual(boundary.utf8.count, 70, "RFC 2046 max boundary length")
        }
        let form = MultipartFormData.pantryPhoto(upload)
        let body = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "--\(form.boundary)").count - 1, 3, "2 parts (mode, image) + closing delimiter")
    }

    func testPartNamesAndOrderAndCRLFFraming() {
        var upload = PantryPhotoUpload(jpegData: Data("JPEG".utf8), pixelWidth: 1, pixelHeight: 1)
        upload.fixture = "demo_counter"
        let form = MultipartFormData.pantryPhoto(upload, boundary: "B")
        XCTAssertEqual(form.parts.map(\.name), ["mode", "fixture", "image"])
        let bytes = [UInt8](form.encoded())
        // Every LF is preceded by CR (no bare LF framing).
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            XCTAssertGreaterThan(index, 0)
            XCTAssertEqual(bytes[index - 1], 0x0D, "bare LF at \(index)")
        }
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasSuffix("\r\n--B--\r\n"))
    }

    func testEmptyFixtureIsOmitted() {
        var upload = PantryPhotoUpload(jpegData: Data("J".utf8), pixelWidth: 1, pixelHeight: 1)
        upload.fixture = ""
        XCTAssertEqual(MultipartFormData.pantryPhoto(upload).parts.map(\.name), ["mode", "image"])
    }

    func testLimitIsFiveMillionBytes() {
        XCTAssertEqual(PantryImageEncoder.maxBytes, 5_000_000)
    }

    /// A JPEG carrying GPS + EXIF orientation 6 (as a phone camera writes it).
    private func jpegWithEXIFAndGPS(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let cg = try XCTUnwrap(image.cgImage)
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret-kitchen"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "X1"],
        ]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    func testEncodedUploadHasNoEXIFGPSOrTIFFMetadataAndIsUpright() throws {
        let input = try jpegWithEXIFAndGPS(width: 2400, height: 1200)
        // Precondition: the input really carries the metadata.
        let inSource = try XCTUnwrap(CGImageSourceCreateWithData(input as CFData, nil))
        let inProps = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(inSource, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(inProps[kCGImagePropertyGPSDictionary], "test input must carry GPS")

        let upload = try PantryImageEncoder.encode(input)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(upload.jpegData as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS must be stripped")
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment], "EXIF user comment must be stripped")
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        XCTAssertEqual(orientation, 1, "orientation baked into pixels, no EXIF rotation left")
        // Orientation 6 rotates the 2400x1200 frame to portrait before downscaling: 800 x 1600.
        XCTAssertEqual(upload.pixelWidth, 800)
        XCTAssertEqual(upload.pixelHeight, 1600)
        XCTAssertFalse(upload.jpegData.range(of: Data("secret-kitchen".utf8)) != nil)
        XCTAssertFalse(upload.jpegData.range(of: Data("TestCam".utf8)) != nil)
    }

    func testEncodedUploadWithinCapForLargeNoisyPhoto() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: 4000, height: 3000)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            var rng = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: 3000, by: 4) {
                for x in stride(from: 0, to: 4000, by: 4) {
                    UIColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                            blue: .random(in: 0...1, using: &rng), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        let upload = try PantryImageEncoder.encode(try XCTUnwrap(image.pngData()))
        XCTAssertLessThanOrEqual(upload.jpegData.count, 5_000_000)
        XCTAssertEqual(max(upload.pixelWidth, upload.pixelHeight), 1600)
    }
}
