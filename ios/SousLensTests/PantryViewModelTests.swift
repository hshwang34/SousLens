import Foundation
import XCTest
@testable import SousLens

@MainActor
final class PantryViewModelTests: XCTestCase {
    private let now = ISO8601Flexible.parse("2026-10-23T12:00:00Z")!

    private func makeModel(_ service: FakePantryService) -> PantryViewModel {
        let now = self.now
        return PantryViewModel(service: service, now: { now })
    }

    func testLoadSortsByNormalizedNameAndBuildsRows() async throws {
        let service = FakePantryService()
        service.listHandler = {
            [PantryFixtures.item(id: PantryFixtures.onionId, raw: "Onions", normalized: "onion", source: "voice"),
             PantryFixtures.item(raw: "Gochujang", normalized: "gochujang", source: "photo")]
        }
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.rows.map(\.name), ["Gochujang", "Onions"])
        XCTAssertEqual(model.rows.map(\.badge), ["Photo", "Voice"])
    }

    func testEmptyAndErrorStates() async {
        let service = FakePantryService()
        let model = makeModel(service)
        await model.load()
        XCTAssertTrue(model.isEmpty)
        service.listHandler = { throw APIError.unreachable(baseURL: "http://x", underlying: "down") }
        let failing = makeModel(service)
        await failing.load()
        guard case .error(let message) = failing.phase else { return XCTFail("expected error") }
        XCTAssertTrue(message.contains("Can’t reach"))
    }

    func testFreshnessLabelsAndStaleRule() throws {
        func row(_ confirmed: String, estimate: Bool = false, quantity: String = "null", unit: String = "null") throws -> PantryRowPresentation {
            let item = try PantryFixtures.decode(PantryItem.self, PantryFixtures.itemJSON(quantity: quantity, unit: unit, estimate: estimate, confirmed: confirmed))
            return PantryRowPresentation(item: item, now: now)
        }
        XCTAssertEqual(try row("2026-10-23T08:00:00Z").freshnessText, "Confirmed today")
        XCTAssertEqual(try row("2026-10-22T08:00:00Z").freshnessText, "Confirmed yesterday")
        let fourteen = try row("2026-10-09T12:00:00Z")
        XCTAssertEqual(fourteen.freshnessText, "Confirmed 14 days ago")
        XCTAssertFalse(fourteen.isStale, "exactly 14 days is not stale")
        let fifteen = try row("2026-10-08T11:00:00Z")
        XCTAssertEqual(fifteen.freshnessText, "Confirmed 15 days ago")
        XCTAssertTrue(fifteen.isStale)
        XCTAssertTrue(fifteen.accessibilityLabel.contains("Check this"))

        let estimate = try row("2026-10-23T08:00:00Z", estimate: true, quantity: "3", unit: "\"count\"")
        XCTAssertEqual(estimate.quantityText, "3")
        XCTAssertTrue(estimate.isEstimate)
        XCTAssertTrue(estimate.accessibilityLabel.contains("3, estimate"))
        let grams = try row("2026-10-23T08:00:00Z", quantity: "500", unit: "\"g\"")
        XCTAssertEqual(grams.quantityText, "500 g")
        XCTAssertFalse(grams.isEstimate)
        XCTAssertEqual(grams.locationText, "Fridge")
    }

    func testDeleteRemovesOnlyAfterServerSucceeds() async {
        let service = FakePantryService()
        let item = PantryFixtures.item()
        service.listHandler = { [item] }
        let model = makeModel(service)
        var changes = 0
        model.onChanged = { changes += 1 }
        await model.load()

        service.deleteHandler = { _ in throw APIError.http(status: 500, correlationId: nil) }
        await model.delete(id: item.id)
        XCTAssertEqual(model.items.count, 1, "a failed delete keeps the row")
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(changes, 0)

        service.deleteHandler = { _ in }
        await model.delete(id: item.id)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(service.calls.filter { $0 == .delete(item.id) }.count, 2)
    }

    func testStillHaveItReplacesItemWithServerCopy() async throws {
        let service = FakePantryService()
        let stale = PantryFixtures.item(confirmed: "2026-09-01T00:00:00Z")
        let fresh = PantryFixtures.item(confirmed: "2026-10-23T11:59:00Z")
        service.listHandler = { [stale] }
        service.confirmHandler = { _ in fresh }
        let model = makeModel(service)
        await model.load()
        XCTAssertTrue(model.rows[0].isStale)
        await model.confirmStillHave(id: stale.id)
        XCTAssertEqual(service.calls.last, .confirm(stale.id))
        XCTAssertFalse(model.rows[0].isStale)
        XCTAssertEqual(model.rows[0].freshnessText, "Confirmed today")
    }

    func testApplyMergesAndResorts() async {
        let service = FakePantryService()
        let model = makeModel(service)
        await model.load()
        model.apply([PantryFixtures.item(id: PantryFixtures.onionId, raw: "Onions", normalized: "onion")])
        model.apply([PantryFixtures.item(raw: "Honey", normalized: "honey")])
        XCTAssertEqual(model.items.map(\.rawLabel), ["Honey", "Onions"])
    }
}

@MainActor
final class PantryItemEditorModelTests: XCTestCase {
    func testFormValidationAndCleaning() {
        var form = PantryItemForm(name: "  \u{202E}Honey\n ", quantityText: "1,5", unit: "cup", location: .pantry, note: "  ")
        XCTAssertEqual(form.cleanName, "Honey")
        XCTAssertEqual(form.quantity, .valid(1.5))
        XCTAssertNil(form.cleanNote)
        XCTAssertTrue(form.isValid)
        let item = form.newItem()
        XCTAssertEqual(item.source, .manual)
        XCTAssertEqual(item.quantity, 1.5)
        XCTAssertNil(item.confidence)
        XCTAssertNil(item.resolution)
        form.quantityText = "-2"
        XCTAssertEqual(form.validationMessage, "Quantity must be a number greater than 0.")
        form.quantityText = ""
        form.name = "   "
        XCTAssertEqual(form.validationMessage, "Add a name.")
    }

    func testAddSucceeds() async {
        let service = FakePantryService()
        let saved = PantryFixtures.item(raw: "Honey", normalized: "honey")
        service.addHandler = { _, _ in [saved] }
        let model = PantryItemEditorModel(mode: .add, form: PantryItemForm(name: "Honey"), service: service)
        let result = await model.save()
        XCTAssertEqual(result, [saved])
        XCTAssertEqual(service.calls, [.add([PantryItemForm(name: "Honey").newItem()], nil)])
    }

    func testAdd409AsksAndResendsWithChosenResolution() async throws {
        let service = FakePantryService()
        let duplicate = try PantryFixtures.duplicateError()
        let merged = PantryFixtures.item(id: PantryFixtures.onionId, raw: "Onions", normalized: "onion")
        service.addHandler = { items, _ in
            if items.first?.resolution == nil { throw duplicate }
            return [merged]
        }
        let model = PantryItemEditorModel(mode: .add, form: PantryItemForm(name: "onion", quantityText: "3"), service: service)
        let first = await model.save()
        XCTAssertNil(first, "409 never counts as saved")
        XCTAssertEqual(model.conflict?.rawLabel, "Onions", "the user is asked")
        XCTAssertNil(model.error)
        XCTAssertFalse(model.canSave)

        let second = await model.resolve(.merge)
        XCTAssertEqual(second, [merged])
        XCTAssertEqual(service.addCalls.count, 2)
        XCTAssertEqual(service.addCalls[1].first?.resolution, .mergeInto(UUID(uuidString: PantryFixtures.onionId)!))
    }

    func testAdd409KeepBoth() async throws {
        let service = FakePantryService()
        let duplicate = try PantryFixtures.duplicateError()
        service.addHandler = { items, _ in
            if items.first?.resolution == nil { throw duplicate }
            return []
        }
        let model = PantryItemEditorModel(mode: .add, form: PantryItemForm(name: "onion"), service: service)
        await model.save()
        await model.resolve(.keepBoth)
        XCTAssertEqual(service.addCalls.last?.first?.resolution, .keepBoth)
    }

    func testEditSendsPatchWithClearedFields() async {
        let service = FakePantryService()
        let original = PantryFixtures.item()
        service.updateHandler = { _, _ in original }
        let model = PantryItemEditorModel(mode: .edit(original), service: service)
        XCTAssertEqual(model.form.name, "Gochujang")
        XCTAssertEqual(model.form.location, .fridge)
        model.form.location = nil
        model.form.note = "half a tub"
        let saved = await model.save()
        XCTAssertEqual(saved, [original])
        XCTAssertEqual(service.calls, [.update(original.id, PantryItemPatch(rawLabel: "Gochujang", quantity: nil, unit: nil, storageLocation: nil, note: "half a tub"))])
    }

    func testInvalidFormIsNotSent() async {
        let service = FakePantryService()
        let model = PantryItemEditorModel(mode: .add, form: PantryItemForm(name: ""), service: service)
        let result = await model.save()
        XCTAssertNil(result)
        XCTAssertEqual(model.error, "Add a name.")
        XCTAssertTrue(service.calls.isEmpty)
    }
}
