import Foundation

// Brief 004 (Slice 2) wire types. Shapes follow `docs/product/briefs/004-api-contract.md`
// exactly; enums decode unknown values leniently so an additive backend change never breaks the
// pantry screen.

/// Where a pantry item came from (PAN-05). DECISIONS: typed text is `manual`, dictated text is
/// `voice`, photos are `photo`. The client only ever sends those three.
enum PantrySource: String, Codable, Sendable, CaseIterable {
    case manual
    case voice
    case photo
    /// Anything the server sends that this build doesn't know. Shown neutrally, never sent.
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PantrySource(rawValue: raw) ?? .other
    }

    /// Provenance badge text.
    var badge: String {
        switch self {
        case .manual: return "Manual"
        case .voice: return "Voice"
        case .photo: return "Photo"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: return "hand.point.up.left"
        case .voice: return "mic"
        case .photo: return "camera"
        case .other: return "questionmark.circle"
        }
    }
}

/// Storage location. A value this build doesn't know is kept verbatim (`unrecognized`) so an
/// edit never overwrites it with something else.
enum StorageLocation: Sendable, Hashable, Identifiable {
    case fridge
    case freezer
    case pantry
    case counter
    case other
    case unrecognized(String)

    /// The choices the editor offers.
    static let known: [StorageLocation] = [.fridge, .freezer, .pantry, .counter, .other]

    init(rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .unrecognized(rawValue)
    }

    var rawValue: String {
        switch self {
        case .fridge: return "fridge"
        case .freezer: return "freezer"
        case .pantry: return "pantry"
        case .counter: return "counter"
        case .other: return "other"
        case .unrecognized(let raw): return raw
        }
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fridge: return "Fridge"
        case .freezer: return "Freezer"
        case .pantry: return "Pantry"
        case .counter: return "Counter"
        case .other: return "Other"
        case .unrecognized(let raw): return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

extension StorageLocation: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The contract's unit list. `nil` (no unit) is always allowed.
enum PantryUnits {
    static let all: [String] = ["count", "g", "kg", "oz", "lb", "ml", "l", "tsp", "tbsp", "cup", "fl_oz"]

    static func label(_ unit: String) -> String {
        switch unit {
        case "count": return "count"
        case "fl_oz": return "fl oz"
        case "l": return "L"
        default: return unit
        }
    }
}

/// `GET /pantry` item.
struct PantryItem: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let rawLabel: String
    let normalizedName: String
    let ingredientId: UUID?
    let quantity: Double?
    let unit: String?
    let quantityIsEstimate: Bool
    let storageLocation: StorageLocation?
    let note: String?
    let source: PantrySource
    let confidence: Double?
    let lastConfirmedAt: Date
    let createdAt: Date
    let updatedAt: Date

    /// Same item with the estimate flag changed (a typed quantity is no longer an estimate).
    func withQuantityIsEstimate(_ value: Bool) -> PantryItem {
        PantryItem(id: id, rawLabel: rawLabel, normalizedName: normalizedName, ingredientId: ingredientId,
                   quantity: quantity, unit: unit, quantityIsEstimate: value, storageLocation: storageLocation,
                   note: note, source: source, confidence: confidence, lastConfirmedAt: lastConfirmedAt,
                   createdAt: createdAt, updatedAt: updatedAt)
    }
}

/// `{"merge_into": id}` or `{"keep_both": true}` (PAN-04). Only ever set by an explicit user choice.
enum PantryResolution: Sendable, Hashable {
    case mergeInto(UUID)
    case keepBoth
}

extension PantryResolution: Encodable {
    private enum Keys: String, CodingKey {
        case mergeInto = "merge_into"
        case keepBoth = "keep_both"
    }

    func encode(to encoder: Encoder) throws {
        // Explicit raw keys: the shared encoder's snake_case conversion leaves them unchanged.
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .mergeInto(let id): try container.encode(id.uuidString.lowercased(), forKey: .mergeInto)
        case .keepBoth: try container.encode(true, forKey: .keepBoth)
        }
    }
}

/// `NewItem` in `POST /pantry`.
struct NewPantryItem: Encodable, Sendable, Hashable {
    var rawLabel: String
    var quantity: Double?
    var unit: String?
    var storageLocation: StorageLocation?
    var note: String?
    var source: PantrySource
    var confidence: Double?
    var quantityIsEstimate: Bool?
    var resolution: PantryResolution?

    private enum CodingKeys: String, CodingKey {
        case rawLabel, quantity, unit, storageLocation, note, source, confidence, quantityIsEstimate, resolution
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawLabel, forKey: .rawLabel)
        try container.encodeIfPresent(quantity, forKey: .quantity)
        try container.encodeIfPresent(unit, forKey: .unit)
        try container.encodeIfPresent(storageLocation, forKey: .storageLocation)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(quantityIsEstimate, forKey: .quantityIsEstimate)
        try container.encodeIfPresent(resolution, forKey: .resolution)
    }
}

struct CreatePantryItemsRequest: Encodable, Sendable {
    let items: [NewPantryItem]
    let observationId: UUID?

    private enum CodingKeys: String, CodingKey { case items, observationId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        // Always present: `null` for manual adds, the observation id for reviewed candidates.
        try container.encode(observationId.map { $0.uuidString.lowercased() }, forKey: .observationId)
    }
}

/// `PATCH /pantry/{id}`. Only fields the user changed are sent: the outer optional is "changed?",
/// the inner one is the value (`nil` → JSON `null`, i.e. cleared).
struct PantryItemPatch: Encodable, Sendable, Hashable {
    var rawLabel: String?
    var quantity: Double??
    var unit: String??
    var storageLocation: StorageLocation??
    var note: String??

    init(rawLabel: String? = nil, quantity: Double?? = .none, unit: String?? = .none,
         storageLocation: StorageLocation?? = .none, note: String?? = .none) {
        self.rawLabel = rawLabel
        self.quantity = quantity
        self.unit = unit
        self.storageLocation = storageLocation
        self.note = note
    }

    var isEmpty: Bool {
        rawLabel == nil && quantity == nil && unit == nil && storageLocation == nil && note == nil
    }

    var changesQuantity: Bool { quantity != nil || unit != nil }

    private enum CodingKeys: String, CodingKey { case rawLabel, quantity, unit, storageLocation, note }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rawLabel, forKey: .rawLabel)
        if let quantity { try container.encode(quantity, forKey: .quantity) }
        if let unit { try container.encode(unit, forKey: .unit) }
        if let storageLocation { try container.encode(storageLocation, forKey: .storageLocation) }
        if let note { try container.encode(note, forKey: .note) }
    }
}

// MARK: - Observations (PAN-02, PAN-03)

enum ObservationMode: String, Codable, Sendable {
    case transcript
    case photo

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ObservationMode(rawValue: raw) ?? .photo
    }

    var source: PantrySource { self == .transcript ? .voice : .photo }
}

/// PRD §8.3 UX bins. Labelled as estimates; never presented as calibrated.
enum ConfidenceBin: String, Codable, Sendable, CaseIterable {
    case high
    case medium
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConfidenceBin(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .high: return "Likely"
        case .medium: return "Maybe"
        case .unknown: return "Not sure"
        }
    }
}

enum CandidateAction: String, Codable, Sendable {
    case add
    case ignore

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CandidateAction(rawValue: raw) ?? .ignore
    }
}

struct PantryCandidate: Codable, Sendable, Hashable {
    let rawLabel: String
    let canonicalName: String?
    let quantity: Double?
    let unit: String?
    var quantityIsEstimate: Bool = false
    let confidence: Double?
    let confidenceBin: ConfidenceBin
    let evidence: String?
    let action: CandidateAction
    var duplicateOf: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case rawLabel, canonicalName, quantity, unit, quantityIsEstimate, confidence, confidenceBin, evidence, action, duplicateOf
    }

    init(rawLabel: String, canonicalName: String?, quantity: Double?, unit: String?, quantityIsEstimate: Bool = false,
         confidence: Double?, confidenceBin: ConfidenceBin, evidence: String?, action: CandidateAction, duplicateOf: UUID? = nil) {
        self.rawLabel = rawLabel
        self.canonicalName = canonicalName
        self.quantity = quantity
        self.unit = unit
        self.quantityIsEstimate = quantityIsEstimate
        self.confidence = confidence
        self.confidenceBin = confidenceBin
        self.evidence = evidence
        self.action = action
        self.duplicateOf = duplicateOf
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawLabel = try c.decode(String.self, forKey: .rawLabel)
        canonicalName = try c.decodeIfPresent(String.self, forKey: .canonicalName)
        quantity = try c.decodeIfPresent(Double.self, forKey: .quantity)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        quantityIsEstimate = try c.decodeIfPresent(Bool.self, forKey: .quantityIsEstimate) ?? false
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        // Missing bin → the most cautious one (default off in review).
        confidenceBin = try c.decodeIfPresent(ConfidenceBin.self, forKey: .confidenceBin) ?? .unknown
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence)
        action = try c.decodeIfPresent(CandidateAction.self, forKey: .action) ?? .ignore
        duplicateOf = try c.decodeIfPresent(UUID.self, forKey: .duplicateOf)
    }
}

/// `POST /pantry/observations` → 201. Candidates are proposals only; nothing is in the pantry yet.
struct PantryObservation: Codable, Sendable, Hashable, Identifiable {
    let observationId: UUID
    let mode: ObservationMode
    let provider: String
    let candidates: [PantryCandidate]
    let unknowns: [String]
    let requiresConfirmation: Bool
    let expiresAt: Date

    var id: UUID { observationId }

    /// PRD Appendix C / DECISIONS #11: a mock photo result is a fixture, not a detection.
    var isDemoPhoto: Bool { mode == .photo && provider == "mock" }
}

/// One photo ready for the multipart upload (already downscaled + compressed).
struct PantryPhotoUpload: Sendable, Equatable {
    let jpegData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    /// Mock-mode only: selects `fixtures/expected_outputs/pantry_observations/<stem>.json`.
    var fixture: String? = nil
}

// MARK: - Recipe fit (FIT-01..03)

enum FitStatus: String, Codable, Sendable, CaseIterable {
    case available
    case uncertain
    case missing
    case optionalMissing = "optional_missing"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // An unrecognised status is never shown as "available" (FIT-03).
        self = FitStatus(rawValue: raw) ?? .uncertain
    }
}

struct FitQuantity: Codable, Sendable, Hashable {
    let quantity: Double?
    let unit: String?
}

struct FitCounts: Codable, Sendable, Hashable {
    let available: Int
    let uncertain: Int
    let missing: Int
    let optionalMissing: Int
}

struct FitItem: Codable, Sendable, Hashable, Identifiable {
    let ingredientRef: String
    let name: String
    let optional: Bool
    let status: FitStatus
    let reason: String
    let required: FitQuantity?
    let pantryItemId: UUID?
    let pantryQuantity: FitQuantity?
    let conversionNote: String?

    var id: String { ingredientRef }
}

struct PantryFit: Codable, Sendable, Hashable {
    let recipeVersionId: UUID
    let canMake: Bool
    let coverage: Double
    let counts: FitCounts
    let items: [FitItem]
    let computedAt: Date
}

// MARK: - 409 DUPLICATE_PANTRY_ITEM

struct PantryConflict: Codable, Sendable, Hashable {
    /// Index into the `items` array of the rejected request.
    let index: Int
    let existing: PantryItem
}

extension APIError {
    /// `409 DUPLICATE_PANTRY_ITEM` → `details.conflicts`. Nil for any other error, or when the
    /// details can't be read (the caller then treats the 409 as a plain failure, never as success).
    var pantryConflicts: [PantryConflict]? {
        guard case .server(let status, let code, _, _, _, let details) = self,
              code == "DUPLICATE_PANTRY_ITEM" || (status == 409 && details?["conflicts"] != nil),
              let conflicts = details?["conflicts"],
              let data = try? JSONEncoder().encode(conflicts)
        else { return nil }
        return try? JSONCoding.makeDecoder().decode([PantryConflict].self, from: data)
    }

    var isRateLimited: Bool {
        if case .server(_, let code, _, _, _, _) = self, code == "RATE_LIMITED" { return true }
        return status == 429
    }
}
