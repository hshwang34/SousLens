import Foundation
import UIKit
import XCTest
@testable import SousLens

/// Brief 004 DTO decoding/encoding and request shapes through the `URLProtocol` stub.
final class PantryDTOTests: XCTestCase {
    func testPantryListDecodesEveryContractField() throws {
        let items = try PantryFixtures.decode(ItemsResponse<PantryItem>.self, PantryFixtures.listJSON).items
        XCTAssertEqual(items.count, 2)
        let gochujang = items[0]
        XCTAssertEqual(gochujang.id, UUID(uuidString: PantryFixtures.gochujangId))
        XCTAssertEqual(gochujang.rawLabel, "Gochujang")
        XCTAssertEqual(gochujang.normalizedName, "gochujang")
        XCTAssertEqual(gochujang.ingredientId, UUID(uuidString: PantryFixtures.ingredientId))
        XCTAssertNil(gochujang.quantity)
        XCTAssertNil(gochujang.unit)
        XCTAssertFalse(gochujang.quantityIsEstimate)
        XCTAssertEqual(gochujang.storageLocation, .fridge)
        XCTAssertNil(gochujang.note)
        XCTAssertEqual(gochujang.source, .manual)
        XCTAssertNil(gochujang.confidence)
        XCTAssertEqual(gochujang.lastConfirmedAt, ISO8601Flexible.parse("2026-10-20T09:00:00Z"))
        let onion = items[1]
        XCTAssertEqual(onion.quantity, 2)
        XCTAssertEqual(onion.unit, "count")
        XCTAssertEqual(onion.source, .voice)
        XCTAssertEqual(onion.confidence, 0.93)
        XCTAssertNil(onion.storageLocation)
    }

    func testUnknownEnumValuesDecodeConservatively() throws {
        let json = PantryFixtures.itemJSON(location: "\"cellar\"", source: "glasses")
        let item = try PantryFixtures.decode(PantryItem.self, json)
        XCTAssertEqual(item.storageLocation, .unrecognized("cellar"), "unknown location kept verbatim")
        XCTAssertEqual(item.storageLocation?.rawValue, "cellar")
        XCTAssertEqual(item.source, .other, "unknown source is neutral, not Manual or Photo")
        XCTAssertEqual(item.source.badge, "Other")
        let status = try JSONCoding.makeDecoder().decode([FitStatus].self, from: Data(#"["maybe"]"#.utf8))
        XCTAssertEqual(status, [.uncertain], "an unknown fit status is never 'available'")
        let bin = try JSONCoding.makeDecoder().decode([ConfidenceBin].self, from: Data(#"["low"]"#.utf8))
        XCTAssertEqual(bin, [.unknown])
    }

    func testTranscriptObservationDecodes() throws {
        let observation = try PantryFixtures.decode(PantryObservation.self, PantryFixtures.observationTranscriptJSON)
        XCTAssertEqual(observation.observationId, UUID(uuidString: PantryFixtures.observationId))
        XCTAssertEqual(observation.mode, .transcript)
        XCTAssertEqual(observation.provider, "mock")
        XCTAssertFalse(observation.isDemoPhoto, "demo banner is for photos only")
        XCTAssertTrue(observation.requiresConfirmation)
        XCTAssertEqual(observation.candidates.count, 4)
        XCTAssertEqual(observation.candidates[1].duplicateOf, UUID(uuidString: PantryFixtures.onionId))
        XCTAssertEqual(observation.candidates[1].quantity, 2)
        XCTAssertEqual(observation.candidates[3].confidenceBin, .unknown)
        XCTAssertNil(observation.candidates[3].canonicalName)
        XCTAssertEqual(observation.candidates[3].action, .ignore)
    }

    func testPhotoObservationDecodesUnknownsAndDemoFlag() throws {
        let observation = try PantryFixtures.decode(PantryObservation.self, PantryFixtures.observationPhotoJSON)
        XCTAssertEqual(observation.mode, .photo)
        XCTAssertTrue(observation.isDemoPhoto)
        XCTAssertEqual(observation.unknowns, ["contents of the unlabeled jar"])
        XCTAssertTrue(observation.candidates[1].quantityIsEstimate)
        XCTAssertEqual(observation.expiresAt, ISO8601Flexible.parse("2099-10-24T09:00:00.5Z"))
    }

    func testCandidateToleratesMissingOptionalKeys() throws {
        // The fixture file shape (no bin / estimate / duplicate keys) still decodes, cautiously.
        let json = #"{"raw_label":"Gochujang","canonical_name":"gochujang","quantity":null,"unit":null,"confidence":0.91,"evidence":"package label","action":"add"}"#
        let candidate = try PantryFixtures.decode(PantryCandidate.self, json)
        XCTAssertEqual(candidate.confidenceBin, .unknown)
        XCTAssertFalse(candidate.quantityIsEstimate)
        XCTAssertNil(candidate.duplicateOf)
    }

    func testFitDecodes() throws {
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        XCTAssertEqual(fit.recipeVersionId, UUID(uuidString: PantryFixtures.versionId))
        XCTAssertFalse(fit.canMake)
        XCTAssertEqual(fit.coverage, 0.5)
        XCTAssertEqual(fit.counts, FitCounts(available: 2, uncertain: 1, missing: 1, optionalMissing: 1))
        XCTAssertEqual(fit.items.map(\.status), [.available, .available, .uncertain, .missing, .optionalMissing])
        XCTAssertEqual(fit.items[2].reason, "You have 1 egg; the recipe needs 3.")
        XCTAssertEqual(fit.items[2].required, FitQuantity(quantity: 3, unit: "count"))
        XCTAssertEqual(fit.items[2].pantryQuantity, FitQuantity(quantity: 1, unit: "count"))
        XCTAssertNil(fit.items[1].pantryQuantity)
    }

    func testDuplicate409ExposesConflicts() throws {
        let error = try PantryFixtures.duplicateError()
        let conflicts = try XCTUnwrap(error.pantryConflicts)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].index, 0)
        XCTAssertEqual(conflicts[0].existing.id, UUID(uuidString: PantryFixtures.onionId))
        XCTAssertEqual(conflicts[0].existing.rawLabel, "Onions")
        XCTAssertFalse(error.isRateLimited)
        XCTAssertNil(APIError.server(status: 409, code: "STATE_CONFLICT", message: "x", retryable: false, correlationId: nil).pantryConflicts)
    }

    func testNewItemEncodingOmitsAbsentOptionalsAndEncodesResolutions() throws {
        let encoder = JSONCoding.makeEncoder()
        let merge = NewPantryItem(rawLabel: "onions", quantity: 2, unit: "count", source: .voice, confidence: 0.9,
                                  quantityIsEstimate: false, resolution: .mergeInto(UUID(uuidString: PantryFixtures.onionId)!))
        let mergeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(merge)) as? [String: Any])
        XCTAssertEqual(mergeJSON["raw_label"] as? String, "onions")
        XCTAssertEqual(mergeJSON["source"] as? String, "voice")
        XCTAssertEqual(mergeJSON["quantity_is_estimate"] as? Bool, false)
        XCTAssertEqual((mergeJSON["resolution"] as? [String: Any])?["merge_into"] as? String, PantryFixtures.onionId)
        XCTAssertNil(mergeJSON["storage_location"])
        XCTAssertNil(mergeJSON["note"])

        let keep = NewPantryItem(rawLabel: "onions", source: .manual, resolution: .keepBoth)
        let keepJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(keep)) as? [String: Any])
        XCTAssertEqual((keepJSON["resolution"] as? [String: Any])?["keep_both"] as? Bool, true)
        XCTAssertNil(keepJSON["confidence"])
    }

    func testPatchSendsOnlyChangedFieldsAndClearsAsNull() throws {
        let patch = PantryItemPatch(quantity: .some(nil), storageLocation: .some(.pantry))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.makeEncoder().encode(patch)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["quantity", "storage_location"])
        XCTAssertTrue(json["quantity"] is NSNull)
        XCTAssertEqual(json["storage_location"] as? String, "pantry")
        XCTAssertTrue(PantryItemPatch().isEmpty)
    }

    func testUnrecognizedLocationRoundTripsAndIsNotSentWhenUntouched() throws {
        let item = try PantryFixtures.decode(PantryItem.self, PantryFixtures.itemJSON(location: "\"cellar\""))
        XCTAssertEqual(item.storageLocation?.label, "Cellar")
        var form = PantryItemForm(item: item)
        form.note = "top shelf"
        let patch = form.patch(from: item)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.makeEncoder().encode(patch)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["note"], "an unknown location is never overwritten")
        XCTAssertEqual(String(decoding: try JSONCoding.makeEncoder().encode([StorageLocation.unrecognized("cellar")]), as: UTF8.self), #"["cellar"]"#)
    }
}

final class PantryAPIClientTests: XCTestCase {
    private func makeClient() -> APIClient {
        APIClient(
            session: StubURLProtocol.makeSession(),
            baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
            tokenProvider: InMemoryTokenStore(token: "tok")
        )
    }

    private func route(_ table: [String: (Int, String)]) {
        StubURLProtocol.install { request in
            let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            guard let (status, body) = table[key] else {
                return (.stub(request, status: 404), Data(#"{"error":{"code":"NOT_FOUND","message":"no route \#(key)","retryable":false}}"#.utf8))
            }
            return (.stub(request, status: status), Data(body.utf8))
        }
    }

    private func body(_ request: URLRequest) throws -> Data {
        try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map(readAll))
    }

    func testListPantry() async throws {
        route(["GET /v1/pantry": (200, PantryFixtures.listJSON)])
        let items = try await makeClient().listPantry()
        XCTAssertEqual(items.map(\.normalizedName), ["gochujang", "onion"])
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testAddSendsItemsAndObservationId() async throws {
        route(["POST /v1/pantry": (201, PantryFixtures.listJSON)])
        let observation = UUID(uuidString: PantryFixtures.observationId)!
        _ = try await makeClient().addPantryItems([NewPantryItem(rawLabel: "honey", source: .voice, confidence: 0.9, quantityIsEstimate: false)],
                                                  observationId: observation)
        let json = try XCTUnwrap(StubURLProtocol.requests.first).jsonBody()
        XCTAssertEqual(json["observation_id"] as? String, PantryFixtures.observationId)
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["raw_label"] as? String, "honey")
        XCTAssertEqual(items.first?["source"] as? String, "voice")
    }

    func testManualAddSendsNullObservationId() async throws {
        route(["POST /v1/pantry": (201, PantryFixtures.listJSON)])
        _ = try await makeClient().addPantryItems([NewPantryItem(rawLabel: "honey", source: .manual)], observationId: nil)
        let json = try XCTUnwrap(StubURLProtocol.requests.first).jsonBody()
        XCTAssertTrue(json["observation_id"] is NSNull)
    }

    func testAdd409ThrowsDuplicateWithConflicts() async throws {
        route(["POST /v1/pantry": (409, PantryFixtures.duplicateJSON)])
        do {
            _ = try await makeClient().addPantryItems([NewPantryItem(rawLabel: "onions", source: .voice)], observationId: nil)
            XCTFail("expected 409")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.pantryConflicts?.first?.existing.rawLabel, "Onions")
            XCTAssertEqual(error.correlationId, "c-dup")
        }
    }

    func testPatchConfirmDeletePaths() async throws {
        let id = PantryFixtures.gochujangId
        route([
            "PATCH /v1/pantry/\(id)": (200, PantryFixtures.itemJSON()),
            "POST /v1/pantry/\(id)/confirm": (200, PantryFixtures.itemJSON()),
            "DELETE /v1/pantry/\(id)": (204, ""),
        ])
        let client = makeClient()
        let uuid = UUID(uuidString: id)!
        _ = try await client.updatePantryItem(id: uuid, PantryItemPatch(quantity: .some(1), unit: .some("cup"), note: .some("half full")))
        _ = try await client.confirmPantryItem(id: uuid)
        try await client.deletePantryItem(id: uuid)
        XCTAssertEqual(StubURLProtocol.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
                       ["PATCH /v1/pantry/\(id)", "POST /v1/pantry/\(id)/confirm", "DELETE /v1/pantry/\(id)"])
        let patch = try StubURLProtocol.requests[0].jsonBody()
        XCTAssertEqual(patch["unit"] as? String, "cup")
        XCTAssertEqual(patch["note"] as? String, "half full")
        XCTAssertEqual(try StubURLProtocol.requests[1].jsonBody().count, 0, "confirm sends {}")
    }

    func testTranscriptObservationIsJSON() async throws {
        route(["POST /v1/pantry/observations": (201, PantryFixtures.observationTranscriptJSON)])
        let observation = try await makeClient().observeTranscript("chicken thighs, two onions")
        XCTAssertEqual(observation.candidates.count, 4)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try request.jsonBody()
        XCTAssertEqual(json["mode"] as? String, "transcript")
        XCTAssertEqual(json["transcript"] as? String, "chicken thighs, two onions")
    }

    func testObservation429IsRateLimited() async throws {
        route(["POST /v1/pantry/observations": (429, PantryFixtures.rateLimitedJSON)])
        do {
            _ = try await makeClient().observeTranscript("honey")
            XCTFail("expected 429")
        } catch let error as APIError {
            XCTAssertTrue(error.isRateLimited)
            XCTAssertEqual(error.status, 429)
            XCTAssertTrue(error.isRetryable)
            XCTAssertTrue(error.pantryMessage.contains("Try again later"))
        }
    }

    func testPhotoObservationIsMultipart() async throws {
        route(["POST /v1/pantry/observations": (201, PantryFixtures.observationPhotoJSON)])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9])
        let observation = try await makeClient().observePhoto(PantryPhotoUpload(jpegData: jpeg, pixelWidth: 10, pixelHeight: 10, fixture: "gochujang_jar"))
        XCTAssertTrue(observation.isDemoPhoto)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let raw = try body(request)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"mode\"\r\n\r\nphoto\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"fixture\"\r\n\r\ngochujang_jar\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"image\"; filename=\"pantry.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
        XCTAssertNotNil(raw.range(of: jpeg), "image bytes are sent verbatim")
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testFitPostsEmptyObject() async throws {
        route(["POST /v1/recipe-versions/\(PantryFixtures.versionId)/fit": (200, PantryFixtures.fitJSON)])
        let fit = try await makeClient().fit(recipeVersionId: UUID(uuidString: PantryFixtures.versionId)!)
        XCTAssertEqual(fit.items.count, 5)
        XCTAssertEqual(try StubURLProtocol.requests.first?.jsonBody().count, 0)
    }
}

final class MultipartAndImageEncodingTests: XCTestCase {
    func testMultipartLayoutWithoutFixture() {
        let form = MultipartFormData.pantryPhoto(PantryPhotoUpload(jpegData: Data("JPEG".utf8), pixelWidth: 1, pixelHeight: 1), boundary: "B")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=B")
        let expected = "--B\r\nContent-Disposition: form-data; name=\"mode\"\r\n\r\nphoto\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"image\"; filename=\"pantry.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nJPEG\r\n"
            + "--B--\r\n"
        XCTAssertEqual(String(decoding: form.encoded(), as: UTF8.self), expected)
    }

    func testTargetSizeKeepsAspectAndNeverUpscales() {
        XCTAssertEqual(PantryImageEncoder.targetSize(for: CGSize(width: 4032, height: 3024), maxLongEdge: 1600), CGSize(width: 1600, height: 1200))
        XCTAssertEqual(PantryImageEncoder.targetSize(for: CGSize(width: 3024, height: 4032), maxLongEdge: 1600), CGSize(width: 1200, height: 1600))
        XCTAssertEqual(PantryImageEncoder.targetSize(for: CGSize(width: 800, height: 600), maxLongEdge: 1600), CGSize(width: 800, height: 600))
    }

    private func noisyImageData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            var generator = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: height, by: 8) {
                for x in stride(from: 0, to: width, by: 8) {
                    UIColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                            blue: .random(in: 0...1, using: &generator), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        return image.pngData() ?? Data()
    }

    func testEncodeDownscalesToLongEdgeAndOutputsJPEG() throws {
        let upload = try PantryImageEncoder.encode(noisyImageData(width: 2400, height: 1800))
        XCTAssertEqual(upload.pixelWidth, 1600)
        XCTAssertEqual(upload.pixelHeight, 1200)
        XCTAssertLessThanOrEqual(upload.jpegData.count, PantryImageEncoder.maxBytes)
        XCTAssertEqual(Array(upload.jpegData.prefix(2)), [0xFF, 0xD8], "JPEG magic bytes")
        let decoded = try XCTUnwrap(UIImage(data: upload.jpegData))
        XCTAssertEqual(decoded.size.width * decoded.scale, 1600)
    }

    func testEncodeStepsQualityDownToFitTheCap() throws {
        let data = noisyImageData(width: 800, height: 800)
        let generous = try PantryImageEncoder.encode(data)
        let capped = try PantryImageEncoder.encode(data, maxBytes: generous.jpegData.count - 1)
        XCTAssertLessThan(capped.jpegData.count, generous.jpegData.count)
    }

    func testEncodeThrowsWhenNothingFits() {
        XCTAssertThrowsError(try PantryImageEncoder.encode(noisyImageData(width: 400, height: 400), maxBytes: 100)) { error in
            XCTAssertEqual(error as? PantryImageEncoder.EncodeError, .tooLarge)
        }
        XCTAssertThrowsError(try PantryImageEncoder.encode(Data("not an image".utf8))) { error in
            XCTAssertEqual(error as? PantryImageEncoder.EncodeError, .unreadable)
        }
    }
}
