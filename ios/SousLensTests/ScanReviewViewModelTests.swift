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

    /// Mock photo candidates start unticked; tick the two real-looking ones.
    private func tickPhotoRows(_ model: ScanReviewViewModel) {
        model.setAccepted(0, true)
        model.setAccepted(1, true)
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
        XCTAssertEqual(model.rows.map(\.accepted), [false, false, false], "demo candidates start unticked")
        XCTAssertEqual(model.blockingMessage, "Tick at least one item to add.")
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
        tickPhotoRows(model)
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
        tickPhotoRows(model)
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
        model.setAccepted(1, true)        // only "eggs" (row 1) is sent, at index 0
        await model.confirm()
        XCTAssertNil(model.rows[0].duplicateOf)
        XCTAssertEqual(model.rows[1].duplicateName, "Onions")
    }

    func testOtherErrorsSurfaceAndAllowRetry() async throws {
        let service = FakePantryService()
        service.addHandler = { _, _ in throw APIError.unreachable(baseURL: "http://x", underlying: "down") }
        let model = ScanReviewViewModel(observation: try photoObservation(), existingItems: [], service: service)
        tickPhotoRows(model)
        let result = await model.confirm()
        XCTAssertNil(result)
        XCTAssertTrue(model.error?.hasPrefix("Couldn’t add") ?? false)
        XCTAssertTrue(model.canConfirm)
    }

    func testRowProblemsBlockConfirm() throws {
        let model = ScanReviewViewModel(observation: try photoObservation(), existingItems: [], service: FakePantryService())
        tickPhotoRows(model)
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

    func testRealProviderPhotoKeepsBinDefaults() throws {
        let gemini = PantryFixtures.observationPhotoJSON.replacingOccurrences(of: #""provider":"mock""#, with: #""provider":"gemini""#)
        let model = ScanReviewViewModel(observation: try PantryFixtures.decode(PantryObservation.self, gemini), existingItems: [], service: FakePantryService())
        XCTAssertFalse(model.showsDemoBanner)
        XCTAssertEqual(model.rows.map(\.accepted), [true, true, false])
    }

    func testTypedTranscriptIsSentAsManualAndDictatedAsVoice() async throws {
        let service = FakePantryService()
        let typed = ScanReviewViewModel(observation: try transcriptObservation(), existingItems: [], service: service, source: .manual)
        typed.setAccepted(1, false)   // skip the duplicate
        await typed.confirm()
        XCTAssertEqual(Set(try XCTUnwrap(service.addCalls.last).map(\.source)), [.manual])
        let dictated = ScanReviewViewModel(observation: try transcriptObservation(), existingItems: [], service: service, source: .voice)
        dictated.setAccepted(1, false)
        await dictated.confirm()
        XCTAssertEqual(Set(try XCTUnwrap(service.addCalls.last).map(\.source)), [.voice])
    }

    func testExpiredObservationIsNotSentAndSaysScanAgain() async throws {
        let service = FakePantryService()
        let observation = try transcriptObservation()
        let later = observation.expiresAt.addingTimeInterval(1)
        let model = ScanReviewViewModel(observation: observation, existingItems: [], service: service, now: { later })
        XCTAssertTrue(model.isExpired)
        let result = await model.confirm()
        XCTAssertNil(result)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertEqual(model.error, "This scan expired — scan again.")
    }

    func testServer404Or410OnConfirmMeansExpired() async throws {
        for status in [404, 410] {
            let service = FakePantryService()
            service.addHandler = { _, _ in
                throw APIError.server(status: status, code: "NOT_FOUND", message: "Observation not found.", retryable: false, correlationId: nil)
            }
            let model = ScanReviewViewModel(observation: try transcriptObservation(), existingItems: [], service: service)
            model.setAccepted(1, false)
            await model.confirm()
            XCTAssertEqual(model.error, ScanReviewViewModel.expiredMessage, "status \(status)")
        }
    }

    func testDuplicateHintMatchesManualEditor() throws {
        XCTAssertEqual(DuplicateChoice.hint, "Merge updates your existing item; Keep both adds a second one.")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SousLens/Features/Pantry")
        for file in ["ScanReviewView.swift", "PantryItemEditorView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("DuplicateChoice.hint"), "\(file) shows the shared hint")
        }
    }
}
