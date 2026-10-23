import Foundation
@testable import SousLens

/// Inline JSON matching `docs/product/briefs/004-api-contract.md` field for field.
enum PantryFixtures {
    static let gochujangId = "0b6f3f3e-2c1a-4b7e-9a51-0d3c9f0a1111"
    static let onionId = "0b6f3f3e-2c1a-4b7e-9a51-0d3c9f0a2222"
    static let observationId = "5d0e8a8c-7b7a-4c11-8d55-6a2f6c0c3333"
    static let versionId = "9a7c1f2e-0d4b-4e8a-b1c2-3d4e5f6a4444"
    static let ingredientId = "1e2d3c4b-5a69-4788-9aab-bccddeef5555"

    static func itemJSON(id: String = gochujangId, raw: String = "Gochujang", normalized: String = "gochujang",
                         quantity: String = "null", unit: String = "null", estimate: Bool = false,
                         location: String = "\"fridge\"", note: String = "null", source: String = "manual",
                         confidence: String = "null", confirmed: String = "2026-10-20T09:00:00Z") -> String {
        """
        {"id":"\(id)","raw_label":"\(raw)","normalized_name":"\(normalized)","ingredient_id":"\(ingredientId)",
         "quantity":\(quantity),"unit":\(unit),"quantity_is_estimate":\(estimate),"storage_location":\(location),
         "note":\(note),"source":"\(source)","confidence":\(confidence),
         "last_confirmed_at":"\(confirmed)","created_at":"2026-10-01T09:00:00.123456Z","updated_at":"2026-10-20T09:00:00+00:00"}
        """
    }

    static var listJSON: String {
        #"{"items":["# + itemJSON() + "," + itemJSON(id: onionId, raw: "Onions", normalized: "onion", quantity: "2.0", unit: "\"count\"",
                                                        location: "null", source: "voice", confidence: "0.93") + "]}"
    }

    static let observationTranscriptJSON = """
    {"observation_id":"\(observationId)","mode":"transcript","provider":"mock",
     "candidates":[
       {"raw_label":"chicken thighs","canonical_name":"chicken thigh","quantity":null,"unit":null,"quantity_is_estimate":false,
        "confidence":0.95,"confidence_bin":"high","evidence":"you said “chicken thighs”","action":"add","duplicate_of":null},
       {"raw_label":"onions","canonical_name":"onion","quantity":2,"unit":"count","quantity_is_estimate":false,
        "confidence":0.92,"confidence_bin":"high","evidence":"you said “two onions”","action":"add","duplicate_of":"\(onionId)"},
       {"raw_label":"gochujang","canonical_name":"gochujang","quantity":null,"unit":null,"quantity_is_estimate":false,
        "confidence":0.7,"confidence_bin":"medium","evidence":"you said “gochujang”","action":"add","duplicate_of":null},
       {"raw_label":"something red","canonical_name":null,"quantity":null,"unit":null,"quantity_is_estimate":false,
        "confidence":0.3,"confidence_bin":"unknown","evidence":"unclear","action":"ignore","duplicate_of":null}
     ],
     "unknowns":[],"requires_confirmation":true,"expires_at":"2099-10-24T09:00:00Z"}
    """

    static let observationPhotoJSON = """
    {"observation_id":"\(observationId)","mode":"photo","provider":"mock",
     "candidates":[
       {"raw_label":"Gochujang","canonical_name":"gochujang","quantity":null,"unit":null,"quantity_is_estimate":false,
        "confidence":0.91,"confidence_bin":"high","evidence":"package label","action":"add","duplicate_of":null},
       {"raw_label":"eggs","canonical_name":"egg","quantity":3,"unit":"count","quantity_is_estimate":true,
        "confidence":0.8,"confidence_bin":"medium","evidence":"three visible in the carton","action":"add","duplicate_of":null},
       {"raw_label":"unlabeled jar","canonical_name":null,"quantity":null,"unit":null,"quantity_is_estimate":false,
        "confidence":0.17,"confidence_bin":"unknown","evidence":"contents not identifiable","action":"ignore","duplicate_of":null}
     ],
     "unknowns":["contents of the unlabeled jar"],"requires_confirmation":true,"expires_at":"2099-10-24T09:00:00.5Z"}
    """

    static let fitJSON = """
    {"recipe_version_id":"\(versionId)","can_make":false,"coverage":0.5,
     "counts":{"available":2,"uncertain":1,"missing":1,"optional_missing":1},
     "items":[
       {"ingredient_ref":"ing-1","name":"gochujang","optional":false,"status":"available","reason":"You have gochujang.",
        "required":{"quantity":3,"unit":"tbsp"},"pantry_item_id":"\(gochujangId)","pantry_quantity":{"quantity":null,"unit":null},"conversion_note":null},
       {"ingredient_ref":"ing-2","name":"honey","optional":false,"status":"available","reason":"You have honey.",
        "required":{"quantity":1,"unit":"tbsp"},"pantry_item_id":null,"pantry_quantity":null,"conversion_note":null},
       {"ingredient_ref":"ing-3","name":"eggs","optional":false,"status":"uncertain","reason":"You have 1 egg; the recipe needs 3.",
        "required":{"quantity":3,"unit":"count"},"pantry_item_id":"\(onionId)","pantry_quantity":{"quantity":1,"unit":"count"},"conversion_note":null},
       {"ingredient_ref":"ing-4","name":"soy sauce","optional":false,"status":"missing","reason":"Not in your pantry.",
        "required":{"quantity":2,"unit":"tbsp"},"pantry_item_id":null,"pantry_quantity":null,"conversion_note":null},
       {"ingredient_ref":"ing-5","name":"sesame seeds","optional":true,"status":"optional_missing","reason":"Optional; not in your pantry.",
        "required":{"quantity":1,"unit":"tsp"},"pantry_item_id":null,"pantry_quantity":null,"conversion_note":null}
     ],
     "computed_at":"2026-10-23T10:00:00Z"}
    """

    static let canMakeFitJSON = """
    {"recipe_version_id":"\(versionId)","can_make":true,"coverage":1.0,
     "counts":{"available":1,"uncertain":0,"missing":0,"optional_missing":1},
     "items":[
       {"ingredient_ref":"ing-1","name":"gochujang","optional":false,"status":"available","reason":"You have gochujang.",
        "required":null,"pantry_item_id":"\(gochujangId)","pantry_quantity":null,"conversion_note":null},
       {"ingredient_ref":"ing-5","name":"sesame seeds","optional":true,"status":"optional_missing","reason":"Optional; not in your pantry.",
        "required":null,"pantry_item_id":null,"pantry_quantity":null,"conversion_note":null}
     ],
     "computed_at":"2026-10-23T10:00:00Z"}
    """

    static var duplicateJSON: String {
        #"{"error":{"code":"DUPLICATE_PANTRY_ITEM","message":"Some items are already in your pantry.","retryable":false,"correlation_id":"c-dup","details":{"conflicts":[{"index":0,"existing":"# + itemJSON(id: onionId, raw: "Onions", normalized: "onion", quantity: "2.0", unit: "\"count\"", source: "voice") + "}]}}}"
    }

    static let rateLimitedJSON = #"{"error":{"code":"RATE_LIMITED","message":"Too many pantry scans. Try again later.","retryable":true,"correlation_id":"c-429"}}"#

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: Data(json.utf8))
    }

    static func item(id: String = gochujangId, raw: String = "Gochujang", normalized: String = "gochujang",
                     source: String = "manual", confirmed: String = "2026-10-20T09:00:00Z") -> PantryItem {
        // Fixtures are static; a decode failure here is a test bug.
        try! decode(PantryItem.self, itemJSON(id: id, raw: raw, normalized: normalized, source: source, confirmed: confirmed)) // swiftlint:disable:this force_try
    }

    static func duplicateError() throws -> APIError {
        let envelope = try decode(APIErrorEnvelope.self, duplicateJSON)
        return .server(status: 409, code: envelope.error.code, message: envelope.error.message,
                       retryable: envelope.error.retryable, correlationId: envelope.error.correlationId, details: envelope.error.details)
    }
}

/// Scriptable `PantryService`.
final class FakePantryService: PantryService, @unchecked Sendable {
    enum Call: Equatable {
        case list
        case add([NewPantryItem], UUID?)
        case update(UUID, PantryItemPatch)
        case confirm(UUID)
        case delete(UUID)
        case transcript(String)
        case photo(PantryPhotoUpload)
        case fit(UUID)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    /// Optional suspension per call (after it is recorded); lets tests order responses.
    var suspend: (@Sendable (Call) async -> Void)?

    var listHandler: @Sendable () throws -> [PantryItem] = { [] }
    var addHandler: @Sendable ([NewPantryItem], UUID?) throws -> [PantryItem] = { _, _ in [] }
    var updateHandler: @Sendable (UUID, PantryItemPatch) throws -> PantryItem = { _, _ in throw APIError.http(status: 599, correlationId: nil) }
    var confirmHandler: @Sendable (UUID) throws -> PantryItem = { _ in throw APIError.http(status: 599, correlationId: nil) }
    var deleteHandler: @Sendable (UUID) throws -> Void = { _ in }
    var transcriptHandler: @Sendable (String) throws -> PantryObservation = { _ in throw APIError.http(status: 599, correlationId: nil) }
    var photoHandler: @Sendable (PantryPhotoUpload) throws -> PantryObservation = { _ in throw APIError.http(status: 599, correlationId: nil) }
    var fitHandler: @Sendable (UUID) throws -> PantryFit = { _ in throw APIError.http(status: 599, correlationId: nil) }

    func listPantry() async throws -> [PantryItem] { record(.list); await suspend?(.list); return try listHandler() }
    func addPantryItems(_ items: [NewPantryItem], observationId: UUID?) async throws -> [PantryItem] {
        record(.add(items, observationId)); return try addHandler(items, observationId)
    }
    func updatePantryItem(id: UUID, _ patch: PantryItemPatch) async throws -> PantryItem {
        record(.update(id, patch)); return try updateHandler(id, patch)
    }
    func confirmPantryItem(id: UUID) async throws -> PantryItem { record(.confirm(id)); return try confirmHandler(id) }
    func deletePantryItem(id: UUID) async throws { record(.delete(id)); try deleteHandler(id) }
    func observeTranscript(_ transcript: String) async throws -> PantryObservation {
        record(.transcript(transcript)); return try transcriptHandler(transcript)
    }
    func observePhoto(_ photo: PantryPhotoUpload) async throws -> PantryObservation {
        record(.photo(photo)); return try photoHandler(photo)
    }
    func fit(recipeVersionId: UUID) async throws -> PantryFit {
        record(.fit(recipeVersionId)); await suspend?(.fit(recipeVersionId)); return try fitHandler(recipeVersionId)
    }

    var addCalls: [[NewPantryItem]] {
        calls.compactMap { if case .add(let items, _) = $0 { return items } else { return nil } }
    }
}

/// One-shot latch a test opens to release a suspended fake call.
actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Thread-safe counter for `@Sendable` fake hooks.
final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Mutable value shared with `@Sendable` fake handlers.
final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
