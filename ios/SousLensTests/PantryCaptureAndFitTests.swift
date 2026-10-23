import Foundation
import UIKit
import XCTest
@testable import SousLens

@MainActor
final class SpeakCaptureViewModelTests: XCTestCase {
    private func observation() throws -> PantryObservation {
        try PantryFixtures.decode(PantryObservation.self, PantryFixtures.observationTranscriptJSON)
    }

    func testHoldShowsIndicatorAndLiveTranscriptThenReleaseLeavesEditableText() async throws {
        let speech = FakeSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        XCTAssertEqual(model.mode, .speak)
        XCTAssertNil(model.listeningIndicator)

        await model.beginListening()
        XCTAssertTrue(model.isListening)
        XCTAssertTrue(speech.isListening)
        XCTAssertEqual(model.listeningIndicator, "Listening… (iPhone microphone)")
        XCTAssertFalse(model.canFindItems, "can't submit while the mic is live")

        speech.emit("chicken thighs")
        speech.emit("chicken thighs, two onions", isFinal: true)
        model.endListening()
        await model.listenTask?.value

        XCTAssertFalse(model.isListening)
        XCTAssertFalse(speech.isListening, "audio stops on release")
        XCTAssertNil(model.listeningIndicator)
        XCTAssertEqual(model.transcript, "chicken thighs, two onions")
        model.transcript += " and honey"
        XCTAssertTrue(model.canFindItems)
    }

    func testGlassesKindNeverClaimsGlassesMicrophone() async {
        let speech = FakeSpeechInput(kind: .glasses)
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        await model.beginListening()
        XCTAssertEqual(model.listeningIndicator, "Listening…")
        model.endListening()
    }

    func testFindItemsPostsCleanedTranscript() async throws {
        let service = FakePantryService()
        let expected = try observation()
        service.transcriptHandler = { _ in expected }
        let model = SpeakCaptureViewModel(speech: FakeSpeechInput(), service: service)
        model.typeInstead()
        XCTAssertEqual(model.mode, .type)
        model.transcript = "  chicken thighs,\ntwo onions  "
        await model.findItems()
        XCTAssertEqual(service.calls, [.transcript("chicken thighs,\ntwo onions")])
        XCTAssertEqual(model.observation, expected)
    }

    func testTypeInsteadWorksWithoutMicrophone() async throws {
        let service = FakePantryService()
        let expected = try observation()
        service.transcriptHandler = { _ in expected }
        let model = SpeakCaptureViewModel(speech: FakeSpeechInput(isAvailable: false), service: service)
        XCTAssertEqual(model.mode, .type, "no mic → straight to typing")
        XCTAssertFalse(model.canSpeak)
        XCTAssertNotNil(model.message)
        await model.beginListening()
        XCTAssertFalse(model.isListening)
        model.transcript = "honey"
        await model.findItems()
        XCTAssertEqual(model.observation, expected)
    }

    func testPermissionDeniedShowsExplainerAndFallsBackToTyping() async {
        let speech = DenyingSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        await model.beginListening()
        XCTAssertTrue(model.permissionDenied)
        XCTAssertEqual(model.mode, .type)
        XCTAssertTrue(model.message?.contains("Allow microphone access in Settings") ?? false)
        XCTAssertTrue(model.message?.contains("type instead") ?? false)
    }

    func testEmptyTranscriptIsNotSentAndRateLimitIsExplained() async {
        let service = FakePantryService()
        service.transcriptHandler = { _ in
            throw APIError.server(status: 429, code: "RATE_LIMITED", message: "Too many", retryable: true, correlationId: nil)
        }
        let model = SpeakCaptureViewModel(speech: FakeSpeechInput(), service: service)
        model.transcript = "   "
        await model.findItems()
        XCTAssertTrue(service.calls.isEmpty)
        model.transcript = "honey"
        await model.findItems()
        XCTAssertNil(model.observation)
        XCTAssertTrue(model.message?.contains("Try again later") ?? false)
    }

    func testProvenanceTypedIsManualDictatedIsVoice() async throws {
        let service = FakePantryService()
        let expected = try observation()
        service.transcriptHandler = { _ in expected }

        let typed = SpeakCaptureViewModel(speech: FakeSpeechInput(), service: service)
        typed.typeInstead()
        typed.transcript = "honey"
        XCTAssertEqual(typed.transcriptSource, .manual)
        await typed.findItems()
        XCTAssertEqual(typed.observationSource, .manual)

        let speech = FakeSpeechInput()
        let dictated = SpeakCaptureViewModel(speech: speech, service: service)
        await dictated.beginListening()
        speech.emit("two onions", isFinal: true)
        dictated.endListening()
        await dictated.listenTask?.value
        XCTAssertEqual(dictated.transcriptSource, .voice)
        dictated.transcript += " and honey"          // edited after dictation: still voice
        XCTAssertEqual(dictated.transcriptSource, .voice)
        await dictated.findItems()
        XCTAssertEqual(dictated.observationSource, .voice)

        dictated.transcript = ""                     // cleared, then typed from scratch
        dictated.transcript = "rice"
        XCTAssertEqual(dictated.transcriptSource, .manual)
    }

    func testSilentHoldDoesNotMarkTextAsDictated() async {
        let speech = FakeSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        model.transcript = "honey"
        await model.beginListening()
        model.endListening()
        await model.listenTask?.value
        XCTAssertEqual(model.transcriptSource, .manual)
    }

    func testFastTapReleaseBeforeStartNeverLeavesMicOn() async {
        let speech = FakeSpeechInput()
        let latch = TestLatch()
        var reachedStart = false
        speech.beforeStart = {
            reachedStart = true
            await latch.wait()
        }
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        let press = Task { await model.beginListening() }
        while !reachedStart { await Task.yield() }
        model.endListening()                 // released before the start finished
        await latch.open()
        await press.value
        XCTAssertFalse(speech.isListening, "superseded start tears down")
        XCTAssertFalse(model.isListening)
        XCTAssertFalse(model.isStarting)
        XCTAssertNil(model.listenTask, "no transcript relay is opened")
        XCTAssertNil(model.listeningIndicator)

        // The next press works normally.
        speech.beforeStart = nil
        await model.beginListening()
        XCTAssertTrue(speech.isListening)
        XCTAssertEqual(speech.startCount, 2)
        model.endListening()
    }

    func testVoiceOverToggleCopyAndAutoStop() async {
        let speech = FakeSpeechInput()
        let model = SpeakCaptureViewModel(speech: speech, service: FakePantryService())
        model.toggleAutoStop = .milliseconds(50)
        await model.toggleListening()
        XCTAssertEqual(model.listenStyle, .toggle)
        XCTAssertEqual(model.listeningIndicator, "Listening until you tap Stop (iPhone microphone)")
        await model.listenTask?.value      // ends when the auto-stop fires
        XCTAssertFalse(speech.isListening, "toggle mode stops by itself")
        XCTAssertTrue(SpeakCaptureViewModel.toggleExplainer.contains("until you tap Stop"))
        XCTAssertTrue(SpeakCaptureViewModel.holdExplainer.contains("only while you hold"))

        await model.beginListening()
        XCTAssertEqual(model.listenStyle, .hold)
        XCTAssertEqual(model.listeningIndicator, "Listening… (iPhone microphone)")
        model.endListening()
    }

    func testTranscriptIsCapped() {
        let model = SpeakCaptureViewModel(speech: FakeSpeechInput(), service: FakePantryService())
        model.transcript = String(repeating: "a", count: PantryLimits.transcript + 50)
        XCTAssertEqual(model.transcript.count, PantryLimits.transcript)
    }
}

/// Speech source whose permission was refused.
@MainActor
private final class DenyingSpeechInput: SpeechInput {
    let kind: CaptureSourceKind = .phone
    let isAvailable = true
    private(set) var isListening = false

    func startListening() async throws -> AsyncStream<TranscriptChunk> {
        throw CaptureError.permissionDenied(
            permission: "Microphone",
            explainer: "SousLens listens only while you hold the talk button. Allow microphone access in Settings → SousLens."
        )
    }

    func stop() {}
}

@MainActor
final class ScanCaptureViewModelTests: XCTestCase {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    private func passthrough() -> @Sendable (Data) async throws -> PantryPhotoUpload {
        { data in PantryPhotoUpload(jpegData: data, pixelWidth: 1, pixelHeight: 1) }
    }

    func testCameraStartsOnlyOnTapAndStopsRightAfterTheFrame() async {
        let camera = FakeCameraSource(scriptedFrames: [CapturedFrame(jpegData: jpeg, capturedAt: Date())])
        let model = ScanCaptureViewModel(camera: camera, service: FakePantryService(), encode: passthrough())
        XCTAssertFalse(model.cameraOn, "no capture before the user taps")
        await model.startCamera()
        XCTAssertTrue(model.cameraOn)
        XCTAssertFalse(model.canFindItems)
        await model.capture()
        XCTAssertEqual(camera.captureCount, 1)
        XCTAssertFalse(camera.activeIndicator, "camera stops immediately after the frame")
        XCTAssertFalse(model.cameraOn)
        XCTAssertEqual(model.photoData, jpeg)
        XCTAssertTrue(model.canFindItems)
    }

    func testFindItemsSendsEncodedPhotoAndDropsIt() async throws {
        let service = FakePantryService()
        let expected = try PantryFixtures.decode(PantryObservation.self, PantryFixtures.observationPhotoJSON)
        service.photoHandler = { _ in expected }
        let camera = FakeCameraSource(scriptedFrames: [CapturedFrame(jpegData: jpeg, capturedAt: Date())])
        let model = ScanCaptureViewModel(camera: camera, service: service, fixture: "gochujang_jar", encode: passthrough())
        await model.startCamera()
        await model.capture()
        await model.findItems()
        XCTAssertEqual(service.calls, [.photo(PantryPhotoUpload(jpegData: jpeg, pixelWidth: 1, pixelHeight: 1, fixture: "gochujang_jar"))])
        XCTAssertEqual(model.observation, expected)
        XCTAssertNil(model.photoData, "the photo is not kept after the request")
    }

    func testFailedRequestKeepsPhotoInMemoryForRetryUntilTeardown() async {
        let service = FakePantryService()
        service.photoHandler = { _ in throw APIError.unreachable(baseURL: "http://x", underlying: "down") }
        let camera = FakeCameraSource()
        let model = ScanCaptureViewModel(camera: camera, service: service, encode: passthrough())
        await model.usePickedPhoto(jpeg)
        await model.findItems()
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.photoData, jpeg)
        await model.tearDown()
        XCTAssertNil(model.photoData)
        XCTAssertFalse(camera.activeIndicator)
    }

    func testChoosePhotoWorksWithoutCameraAndStopsAnyRunningCamera() async {
        let unavailable = FakeCameraSource(isAvailable: false)
        let model = ScanCaptureViewModel(camera: unavailable, service: FakePantryService(), encode: passthrough())
        XCTAssertFalse(model.canUseCamera)
        await model.startCamera()
        XCTAssertFalse(model.cameraOn)
        await model.usePickedPhoto(jpeg)
        XCTAssertTrue(model.canFindItems)

        let camera = FakeCameraSource()
        let running = ScanCaptureViewModel(camera: camera, service: FakePantryService(), encode: passthrough())
        await running.startCamera()
        await running.usePickedPhoto(jpeg)
        XCTAssertFalse(camera.activeIndicator)
    }

    func testCameraPermissionDeniedOffersChoosePhoto() async {
        let camera = FakeCameraSource()
        camera.startError = .permissionDenied(permission: "Camera", explainer: "Allow camera access in Settings → SousLens.")
        let model = ScanCaptureViewModel(camera: camera, service: FakePantryService(), encode: passthrough())
        await model.startCamera()
        XCTAssertTrue(model.permissionDenied)
        XCTAssertFalse(model.cameraOn)
        XCTAssertTrue(model.message?.contains("choose a photo") ?? false)
    }

    func testPhotoPickFailureShowsMessage() {
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: FakePantryService(), encode: passthrough())
        model.photoPickFailed()
        XCTAssertEqual(model.message, "That photo couldn’t be loaded. Try another one, or take a photo.")
        XCTAssertFalse(model.hasPhoto)
    }

    func testPreviewThumbnailIsBoundedAndUpright() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let data = try XCTUnwrap(big.jpegData(compressionQuality: 0.5))
        let made = await PantryImageEncoder.thumbnail(data)
        let thumbnail = try XCTUnwrap(made)
        XCTAssertEqual(max(thumbnail.size.width, thumbnail.size.height) * thumbnail.scale, 1600)
        let none = await PantryImageEncoder.thumbnail(Data("nope".utf8))
        XCTAssertNil(none)
    }

    func testEncodeFailureIsShownAndNothingIsSent() async {
        let service = FakePantryService()
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: service, encode: { _ in throw PantryImageEncoder.EncodeError.tooLarge })
        await model.usePickedPhoto(jpeg)
        await model.findItems()
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(model.message, PantryImageEncoder.EncodeError.tooLarge.errorDescription)
    }
}

@MainActor
final class PantryFitViewModelTests: XCTestCase {
    private let versionId = UUID(uuidString: PantryFixtures.versionId)!
    private let now = ISO8601Flexible.parse("2026-10-23T12:00:00Z")!

    private func makeModel(fit: String, pantry: [PantryItem] = []) throws -> (PantryFitViewModel, FakePantryService) {
        let service = FakePantryService()
        let decoded = try PantryFixtures.decode(PantryFit.self, fit)
        service.fitHandler = { _ in decoded }
        service.listHandler = { pantry }
        let now = self.now
        return (PantryFitViewModel(recipeVersionId: versionId, recipeTitle: "Gochujang Chicken", service: service, now: { now }), service)
    }

    func testSectionsHeadlineAndCoverage() async throws {
        let (model, service) = try makeModel(fit: PantryFixtures.fitJSON)
        await model.load()
        XCTAssertTrue(service.calls.contains(.fit(versionId)))
        XCTAssertEqual(model.sections.map(\.kind), [.available, .uncertain, .missing, .optional])
        XCTAssertEqual(model.sections[0].rows.map(\.name), ["gochujang", "honey"])
        XCTAssertEqual(model.sections[1].rows.first?.reason, "You have 1 egg; the recipe needs 3.")
        XCTAssertEqual(model.sections[2].rows.first?.name, "soy sauce")
        XCTAssertEqual(model.sections[3].rows.first?.name, "sesame seeds")
        XCTAssertFalse(model.canMake)
        XCTAssertEqual(model.headline, "You’re missing 1")
        XCTAssertEqual(model.subheadline, "and check 1 item")
        XCTAssertEqual(model.coverageText, "2 of 4 ingredients", "required only; optional excluded")
        XCTAssertTrue(model.coverageAccessibilityLabel?.contains("not a guarantee") ?? false)
        XCTAssertEqual(model.sections[0].rows.first?.requiredText, "3 tbsp")
        XCTAssertTrue(model.sections[2].rows[0].canAddToPantry)
        XCTAssertFalse(model.sections[0].rows[0].canAddToPantry)
    }

    func testCanMakeOnlyWhenServerSaysSoAndNothingRequiredIsUncertain() async throws {
        let (model, _) = try makeModel(fit: PantryFixtures.canMakeFitJSON)
        await model.load()
        XCTAssertTrue(model.canMake)
        XCTAssertEqual(model.headline, "Can make it")
        XCTAssertNil(model.subheadline)
        XCTAssertEqual(model.coverageText, "1 of 1 ingredients")

        // A server that says can_make but lists an uncertain required item is not believed (FIT-03).
        let contradictory = PantryFixtures.fitJSON.replacingOccurrences(of: #""can_make":false"#, with: #""can_make":true"#)
        let (cautious, _) = try makeModel(fit: contradictory)
        await cautious.load()
        XCTAssertFalse(cautious.canMake)
        XCTAssertNotEqual(cautious.headline, "Can make it")
    }

    func testUncertainOnlyHeadline() async throws {
        let onlyUncertain = PantryFixtures.fitJSON
            .replacingOccurrences(of: #""status":"missing""#, with: #""status":"uncertain""#)
        let (model, _) = try makeModel(fit: onlyUncertain)
        await model.load()
        XCTAssertEqual(model.headline, "Check 2 items")
        XCTAssertNil(model.subheadline)
    }

    func testStaleMatchOffersStillHaveItAndRefits() async throws {
        let stale = PantryFixtures.item(confirmed: "2026-09-01T00:00:00Z")   // gochujang id
        let (model, service) = try makeModel(fit: PantryFixtures.fitJSON, pantry: [stale])
        service.confirmHandler = { _ in stale }
        var changed = 0
        model.onPantryChanged = { changed += 1 }
        await model.load()
        let row = try XCTUnwrap(model.sections[0].rows.first)
        XCTAssertTrue(row.canConfirmStillHave)
        XCTAssertFalse(model.sections[0].rows[1].canConfirmStillHave, "honey has no pantry match")
        await model.confirmStillHave(pantryItemId: stale.id)
        XCTAssertEqual(changed, 1, "one reload path: the revision bump")
        XCTAssertEqual(service.calls.filter { $0 == .fit(versionId) }.count, 1, "no second, competing reload from the model")
        XCTAssertTrue(service.calls.contains(.confirm(stale.id)))
    }

    func testAddFormPrefillsNameOnly() async throws {
        let (model, _) = try makeModel(fit: PantryFixtures.fitJSON)
        await model.load()
        let missing = try XCTUnwrap(model.sections.first { $0.kind == .missing }?.rows.first)
        let form = model.addForm(for: missing)
        XCTAssertEqual(form.name, "soy sauce")
        XCTAssertEqual(form.quantityText, "", "the recipe's amount is not what the user has")
    }

    func testErrorStateAndPantryReadFailureIsNonFatal() async throws {
        let (model, service) = try makeModel(fit: PantryFixtures.fitJSON)
        service.listHandler = { throw APIError.http(status: 500, correlationId: nil) }
        await model.load()
        XCTAssertNotNil(model.fit, "fit still shows without the pantry snapshot")

        service.fitHandler = { _ in throw APIError.server(status: 404, code: "NOT_FOUND", message: "Recipe version not found.", retryable: false, correlationId: nil) }
        let (failing, failingService) = try makeModel(fit: PantryFixtures.fitJSON)
        failingService.fitHandler = service.fitHandler
        await failing.load()
        XCTAssertEqual(failing.phase, .error("Recipe version not found."))
        XCTAssertNil(failing.headline)
    }

    func testRowExposesStatusAndActionsForVoiceOver() async throws {
        let stale = PantryFixtures.item(confirmed: "2026-09-01T00:00:00Z")
        let (model, _) = try makeModel(fit: PantryFixtures.fitJSON, pantry: [stale])
        await model.load()
        let available = try XCTUnwrap(model.sections.first { $0.kind == .available }?.rows.first)
        XCTAssertEqual(available.actions, [.stillHaveIt])
        XCTAssertTrue(available.accessibilityLabel.hasPrefix("gochujang. Available."))
        let missing = try XCTUnwrap(model.sections.first { $0.kind == .missing }?.rows.first)
        XCTAssertEqual(missing.actions, [.addToPantry])
        XCTAssertTrue(missing.accessibilityLabel.contains("Missing"))
        XCTAssertEqual(missing.actions.map(\.title), ["Add to pantry"])
        let optional = try XCTUnwrap(model.sections.first { $0.kind == .optional }?.rows.first)
        XCTAssertTrue(optional.accessibilityLabel.contains("Optional, missing"))
        let honey = model.sections[0].rows[1]
        XCTAssertTrue(honey.actions.isEmpty)
    }

    func testSlowEarlierFitNeverReplacesNewerOne() async throws {
        let service = FakePantryService()
        let latch = TestLatch()
        let counter = TestCounter()
        let response = TestBox(try PantryFixtures.decode(PantryFit.self, PantryFixtures.canMakeFitJSON))
        service.suspend = { call in
            if case .fit = call, counter.next() == 1 { await latch.wait() }
        }
        service.fitHandler = { _ in response.value }
        let model = PantryFitViewModel(recipeVersionId: versionId, recipeTitle: "T", service: service)
        let slow = Task { await model.load() }
        while !service.calls.contains(.fit(versionId)) { await Task.yield() }
        response.value = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        await model.load()
        XCTAssertEqual(model.headline, "You’re missing 1")
        response.value = try PantryFixtures.decode(PantryFit.self, PantryFixtures.canMakeFitJSON)
        await latch.open()
        await slow.value
        XCTAssertEqual(model.headline, "You’re missing 1", "the slow, older fit is dropped")
    }
}
