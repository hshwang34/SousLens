import Foundation
import XCTest
@testable import SousLens

/// Fix round 1, item 14: backend error mappings landing in parallel.
@MainActor
final class Slice2BackendAddendumTests: XCTestCase {
    private func transcript() throws -> PantryObservation {
        try PantryFixtures.decode(PantryObservation.self, PantryFixtures.observationTranscriptJSON)
    }

    func testAlreadyConfirmedObservation409ClosesWithoutRetry() async throws {
        let service = FakePantryService()
        service.addHandler = { _, _ in
            throw APIError.server(status: 409, code: "STATE_CONFLICT", message: "Observation already confirmed.", retryable: false, correlationId: nil)
        }
        let model = ScanReviewViewModel(observation: try transcript(), existingItems: [], service: service)
        model.setAccepted(1, false)
        let result = await model.confirm()
        XCTAssertNil(result)
        XCTAssertTrue(model.alreadyAdded)
        XCTAssertNil(model.error)
        XCTAssertNil(model.conflictMessage, "not treated as a duplicate")
        XCTAssertFalse(model.canConfirm, "no retry")
        XCTAssertEqual(ScanReviewViewModel.alreadyAddedMessage, "These items were already added.")
        await model.confirm()
        XCTAssertEqual(service.addCalls.count, 1)
    }

    func testDuplicate409IsStillADuplicateNotAlreadyAdded() throws {
        let error = try PantryFixtures.duplicateError()
        XCTAssertFalse(error.isObservationAlreadyConfirmed)
        XCTAssertNotNil(error.pantryConflicts)
    }

    func testExpired404OnConfirm() async throws {
        let service = FakePantryService()
        service.addHandler = { _, _ in
            throw APIError.server(status: 404, code: "NOT_FOUND", message: "Not found.", retryable: false, correlationId: nil)
        }
        let model = ScanReviewViewModel(observation: try transcript(), existingItems: [], service: service)
        model.setAccepted(1, false)
        await model.confirm()
        XCTAssertEqual(model.error, "This scan expired — scan again.")
    }

    func testProviderUnavailableAndInvalidOutputOfferRetryAndKeepTranscript() async throws {
        let expected = try transcript()
        for (status, code) in [(503, "PROVIDER_UNAVAILABLE"), (502, "AI_OUTPUT_INVALID")] {
            let service = FakePantryService()
            let attempts = TestCounter()
            service.transcriptHandler = { _ in
                if attempts.next() == 1 {
                    throw APIError.server(status: status, code: code, message: "upstream", retryable: true, correlationId: nil)
                }
                return expected
            }
            let model = SpeakCaptureViewModel(speech: FakeSpeechInput(), service: service)
            model.transcript = "honey"
            await model.findItems()
            XCTAssertEqual(model.message, "Couldn’t read that right now — try again.", code)
            XCTAssertTrue(model.canRetry)
            XCTAssertEqual(model.transcript, "honey", "kept for the retry")
            await model.findItems()
            XCTAssertEqual(model.observation, expected)
            XCTAssertFalse(model.canRetry)
        }
    }

    func testPhotoReadFailureKeepsPhotoForRetry() async throws {
        let service = FakePantryService()
        service.photoHandler = { _ in
            throw APIError.server(status: 503, code: "PROVIDER_UNAVAILABLE", message: "upstream", retryable: true, correlationId: nil)
        }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let model = ScanCaptureViewModel(camera: FakeCameraSource(), service: service,
                                         encode: { PantryPhotoUpload(jpegData: $0, pixelWidth: 1, pixelHeight: 1) })
        await model.usePickedPhoto(jpeg)
        await model.findItems()
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.message, "Couldn’t read that right now — try again.")
        XCTAssertEqual(model.photoData, jpeg)
    }

    func testOtherErrorsAreNotRetryReads() {
        XCTAssertFalse(APIError.server(status: 429, code: "RATE_LIMITED", message: "x", retryable: true, correlationId: nil).isReadFailure)
        XCTAssertFalse(APIError.server(status: 409, code: "DUPLICATE_PANTRY_ITEM", message: "x", retryable: false, correlationId: nil).isObservationAlreadyConfirmed)
    }

    func testZeroAndNegativeQuantitiesAreRejectedEverywhere() throws {
        for text in ["0", "0.0", "-1", "-0.5"] {
            XCTAssertEqual(QuantityInput.parse(text), .invalid, text)
            XCTAssertFalse(PantryItemForm(name: "honey", quantityText: text).isValid, text)
        }
        let model = ScanReviewViewModel(observation: try transcript(), existingItems: [], service: FakePantryService())
        model.setAccepted(1, false)
        model.setQuantityText(0, "0")
        XCTAssertNotNil(model.rows[0].problem)
        XCTAssertFalse(model.canConfirm, "0 is never sent")
    }

    func testEstimatedPantryAmountOffersFixAmountInsteadOfStillHaveIt() async throws {
        // Stale *and* estimated: the amount is what needs checking.
        let estimated = try PantryFixtures.decode(PantryItem.self, PantryFixtures.itemJSON(
            quantity: "1", unit: "\"count\"", estimate: true, source: "photo", confirmed: "2026-09-01T00:00:00Z"))
        let service = FakePantryService()
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        service.fitHandler = { _ in fit }
        service.listHandler = { [estimated] }
        let now = ISO8601Flexible.parse("2026-10-23T12:00:00Z")!
        let model = PantryFitViewModel(recipeVersionId: fit.recipeVersionId, recipeTitle: "T", service: service, now: { now })
        await model.load()
        let row = try XCTUnwrap(model.sections.first { $0.kind == .available }?.rows.first)   // gochujang ↔ estimated item
        XCTAssertEqual(row.actions, [.fixAmount])
        XCTAssertEqual(row.actions.first?.title, "Fix amount")
        XCTAssertEqual(model.pantryItem(for: row), estimated)
    }
}
