import Foundation
import XCTest
@testable import SousLens

@MainActor
final class ScanReviewViewModelTests: XCTestCase {
    private func transcriptObservation() throws -> PantryObservation {
        try PantryFixtures.decode(PantryObservation.self, PantryFixtures.observationTranscriptJSON)
    }

    private func photoObservation() throws -> PantryObservation {
        try PantryFixtures.decode(PantryObservation.self, PantryFixtures.observationPhotoJSON)
    }

    private let existingOnion = PantryFixtures.item(id: PantryFixtures.onionId, raw: "Onions", normalized: "onion", source: "voice")

    func testDefaultAcceptStatesPerBin() throws {
        let model = ScanReviewViewModel(observation: try transcriptObservation(), existingItems: [existingOnion], service: FakePantryService())
        XCTAssertEqual(model.rows.map(\.candidate.confidenceBin), [.high, .high, .medium, .unknown])
        XCTAssertEqual(model.rows.map(\.accepted), [true, true, true, false], "unknown bin starts off; high and medium start on")
        XCTAssertEqual(model.rows.map(\.confidenceText), ["Likely · estimate", "Likely · estimate", "Maybe · estimate", "Not sure · estimate"])
        XCTAssertEqual(model.rows[0].evidenceText, "you said “chicken thighs”")
        XCTAssertEqual(model.rows[1].quantityText, "2")
        XCTAssertEqual(model.rows[1].unit, "count")
        XCTAssertFalse(model.showsDemoBanner)
    }

    func testMediumBinMarkedIgnoreStartsOff() {
        let candidate = PantryCandidate(rawLabel: "rice", canonicalName: "rice", quantity: nil, unit: nil, confidence: 0.7,
                                        confidenceBin: .medium, evidence: nil, action: .ignore)
        XCTAssertFalse(ReviewRow(index: 0, candidate: candidate, existingName: nil).accepted)
    }

    func testPhotoDemoBannerUnknownsAndEstimates() throws {
        let model = ScanReviewViewModel(observation: try photoObservation(), existingItems: [], service: FakePantryService())
        XCTAssertTrue(model.showsDemoBanner)
        XCTAssertEqual(model.unknowns, ["contents of the unlabeled jar"])
        XCTAssertEqual(model.rows.map(\.accepted), [true, true, false])
        XCTAssertTrue(model.rows[1].isEstimate, "photo count is an estimate")
        model.setQuantityText(1, "6")
        XCTAssertFalse(model.rows[1].isEstimate, "a number the user typed is not an estimate")
    }

    func testDuplicateNeedsChoiceBeforeConfirm() async throws {
        let service = FakePantryService()
        let model = ScanReviewViewModel(observation: try transcriptObservation(), existingItems: [existingOnion], service: service)
        XCTAssertEqual(model.rows[1].duplicateText, "You already have Onions")
        XCTAssertTrue(model.rows[1].needsDuplicateChoice)
        XCTAssertFalse(model.canConfirm)
        XCTAssertEqual(model.blockingMessage, "Choose Merge or Keep both for the item you already have.")
        let result = await model.confirm()
        XCTAssertNil(result)
        XCTAssertTrue(service.calls.isEmpty, "nothing is sent while a duplicate is undecided")

        // Unticking the duplicate also unblocks.
        model.setAccepted(1, false)
        XCTAssertTrue(model.canConfirm)
        model.setAccepted(1, true)
        model.choose(1, .merge)
        XCTAssertTrue(model.canConfirm)
    }

    func testConfirmSendsOnlyAcceptedRowsWithEditsAndObservationId() async throws {
        let service = FakePantryService()
        let added = [PantryFixtures.item()]
        service.addHandler = { _, _ in added }
        let observation = try transcriptObservation()
        let model = ScanReviewViewModel(observation: observation, existingItems: [existingOnion], service: service)
        model.choose(1, .keepBoth)
        model.setName(0, "chicken thighs (boneless)")
        model.setQuantityText(0, "2")
        model.setUnit(0, "lb")
        model.setAccepted(2, false)   // reject gochujang
        XCTAssertEqual(model.confirmTitle, "Add 2 items")

        let result = await model.confirm()
        XCTAssertEqual(result, added)
        guard case .add(let items, let observationId)? = service.calls.first else { return XCTFail("no add call") }
        XCTAssertEqual(observationId, observation.observationId)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], NewPantryItem(rawLabel: "chicken thighs (boneless)", quantity: 2, unit: "lb", source: .voice,
                                               confidence: 0.95, quantityIsEstimate: false, resolution: nil))
        XCTAssertEqual(items[1].rawLabel, "onions")
        XCTAssertEqual(items[1].quantity, 2)
        XCTAssertEqual(items[1].resolution, .keepBoth)
        XCTAssertFalse(items.contains { $0.rawLabel == "gochujang" || $0.rawLabel == "something red" })
        XCTAssertFalse(model.canConfirm, "confirm is one-shot")
    }

    func testMergeSendsMergeInto() async throws {
        let service = FakePantryService()
        let model = ScanReviewViewModel(observation: try transcriptObservation(), existingItems: [existingOnion], service: service)
        model.choose(1, .merge)
        await model.confirm()
        XCTAssertEqual(service.addCalls.first?[1].resolution, .mergeInto(existingOnion.id))
    }

    func testPhotoRowsKeepEstimateFlagAndSourcePhoto() async throws {
        let service = FakePantryService()
        let model = ScanReviewViewModel(observation: try photoObservation(), existingItems: [], service: service)
        await model.confirm()
        let items = try XCTUnwrap(service.addCalls.first)
        XCTAssertEqual(items.map(\.source), [.photo, .photo])
        XCTAssertEqual(items.map(\.quantityIsEstimate), [false, true])
    }

    func test409ReopensChoiceForListedConflictsOnly() async throws {
        let service = FakePantryService()
        let duplicate = try PantryFixtures.duplicateError()   // conflicts: [{index: 0, existing: Onions}]
        service.addHandler = { items, _ in
            if items[0].resolution == nil { throw duplicate }
            return []
        }
        // Photo observation: no server duplicate hints, so the 409 is the first we hear of it.
        let model = ScanReviewViewModel(observation: try photoObservation(), existingItems: [], service: service)
        XCTAssertTrue(model.canConfirm)
        let first = await model.confirm()
        XCTAssertNil(first)
        XCTAssertEqual(service.addCalls.count, 1)
        // index 0 of the *sent* items → row 0 (Gochujang)
        XCTAssertEqual(model.rows[0].duplicateText, "You already have Onions")
        XCTAssertEqual(model.rows[0].duplicateOf, UUID(uuidString: PantryFixtures.onionId))
        XCTAssertNil(model.rows[0].duplicateChoice, "never resolved silently")
        XCTAssertNil(model.rows[1].duplicateOf)
        XCTAssertNotNil(model.conflictMessage)
        XCTAssertFalse(model.canConfirm)

        model.choose(0, .keepBoth)
        XCTAssertNil(model.conflictMessage)
        let second = await model.confirm()
        XCTAssertNotNil(second)
        XCTAssertEqual(service.addCalls.count, 2)
        XCTAssertEqual(service.addCalls[1][0].resolution, .keepBoth)
        XCTAssertNil(service.addCalls[1][1].resolution)
    }

    func test409WithIndexMappedThroughRejectedRows() async throws {
        // Conflict index refers to the accepted subset, not the candidate list.
        let service = FakePantryService()
        let duplicate = try PantryFixtures.duplicateError()
        service.addHandler = { _, _ in throw duplicate }
        let model = ScanReviewViewModel(observation: try photoObservation(), existingItems: [], service: service)
        model.setAccepted(0, false)       // only "eggs" (row 1) is sent, at index 0
        await model.confirm()
        XCTAssertNil(model.rows[0].duplicateOf)
        XCTAssertEqual(model.rows[1].duplicateName, "Onions")
    }

    func testOtherErrorsSurfaceAndAllowRetry() async throws {
        let service = FakePantryService()
        service.addHandler = { _, _ in throw APIError.unreachable(baseURL: "http://x", underlying: "down") }
        let model = ScanReviewViewModel(observation: try photoObservation(), existingItems: [], service: service)
        let result = await model.confirm()
        XCTAssertNil(result)
        XCTAssertTrue(model.error?.hasPrefix("Couldn’t add") ?? false)
        XCTAssertTrue(model.canConfirm)
    }

    func testRowProblemsBlockConfirm() throws {
        let model = ScanReviewViewModel(observation: try photoObservation(), existingItems: [], service: FakePantryService())
        model.setName(0, "   ")
        XCTAssertEqual(model.rows[0].problem, "Add a name or untick this item.")
        XCTAssertEqual(model.blockingMessage, "Fix the highlighted items first.")
        model.setName(0, "Gochujang")
        model.setQuantityText(1, "lots")
        XCTAssertFalse(model.canConfirm)
        model.setAccepted(0, false)
        model.setAccepted(1, false)
        XCTAssertEqual(model.blockingMessage, "Tick at least one item to add.")
    }
}
