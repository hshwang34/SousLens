import Foundation

/// Client-side caps for pantry text. The contract names none; these mirror the draft editor's
/// ingredient limits so a value the server would reject is never sent.
enum PantryLimits {
    static let name = 200
    static let unit = 32
    static let note = 500
    static let transcript = 2000
    static let maxQuantity = 100_000.0
}

/// PAN-05 freshness. DECISIONS #11: more than 14 days since the last confirmation → "Check this"
/// (and the backend's fit treats it as uncertain).
enum PantryFreshness {
    static let staleAfter: TimeInterval = 14 * 24 * 60 * 60

    static func isStale(lastConfirmedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastConfirmedAt) > staleAfter
    }

    static func days(since date: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / (24 * 60 * 60)))
    }

    static func label(lastConfirmedAt: Date, now: Date) -> String {
        switch days(since: lastConfirmedAt, now: now) {
        case 0: return "Confirmed today"
        case 1: return "Confirmed yesterday"
        case let n: return "Confirmed \(n) days ago"
        }
    }
}

enum PantryFormatting {
    /// "2", "1½ tbsp", "500 g". `count` is implied by the bare number.
    static func quantity(_ quantity: Double?, unit: String?) -> String? {
        let shownUnit = unit.flatMap { $0 == "count" ? nil : PantryUnits.label($0) }
        if quantity == nil, unit == "count" { return nil }
        return RecipeFormatting.quantity(quantity, unit: shownUnit)
    }
}

/// Merge into the existing item, or keep both as separate items (PAN-04). Never defaulted.
enum DuplicateChoice: String, Sendable, Hashable, CaseIterable {
    case merge
    case keepBoth

    var label: String {
        switch self {
        case .merge: return "Merge"
        case .keepBoth: return "Keep both"
        }
    }

    func resolution(existingId: UUID) -> PantryResolution {
        switch self {
        case .merge: return .mergeInto(existingId)
        case .keepBoth: return .keepBoth
        }
    }
}

/// What a pantry row shows. Built from a `PantryItem` and "now" so tests assert labels directly.
struct PantryRowPresentation: Identifiable, Equatable {
    let id: UUID
    let name: String
    let badge: String
    let badgeSystemImage: String
    let quantityText: String?
    /// Photo counts are estimates (contract `quantity_is_estimate`).
    let isEstimate: Bool
    let locationText: String?
    let freshnessText: String
    let isStale: Bool
    let note: String?

    init(item: PantryItem, now: Date) {
        id = item.id
        name = item.rawLabel
        badge = item.source.badge
        badgeSystemImage = item.source.systemImage
        quantityText = PantryFormatting.quantity(item.quantity, unit: item.unit)
        isEstimate = item.quantityIsEstimate && quantityText != nil
        locationText = item.storageLocation?.label
        freshnessText = PantryFreshness.label(lastConfirmedAt: item.lastConfirmedAt, now: now)
        isStale = PantryFreshness.isStale(lastConfirmedAt: item.lastConfirmedAt, now: now)
        note = item.note.flatMap { $0.isEmpty ? nil : $0 }
    }

    var accessibilityLabel: String {
        var parts = [name]
        if let quantityText { parts.append(isEstimate ? "\(quantityText), estimate" : quantityText) }
        if let locationText { parts.append(locationText) }
        parts.append("Source: \(badge)")
        parts.append(freshnessText)
        if isStale { parts.append("Check this") }
        return parts.joined(separator: ", ")
    }
}

enum QuantityInput: Equatable {
    case empty
    case valid(Double)
    case invalid

    /// Accepts "2", "1.5", "1,5". Must be > 0 and below `PantryLimits.maxQuantity`.
    static func parse(_ text: String) -> QuantityInput {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return .empty }
        guard let value = Double(trimmed), value.isFinite, value > 0, value <= PantryLimits.maxQuantity else { return .invalid }
        return .valid(value)
    }

    var value: Double? {
        if case .valid(let value) = self { return value }
        return nil
    }

    /// Text for an existing number ("2", "1.5").
    static func text(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded() { return String(Int(value)) }
        return String(value)
    }
}

/// Editable mirror of a pantry item for the add/edit sheet (PAN-01).
struct PantryItemForm: Equatable, Sendable {
    var name = ""
    var quantityText = ""
    var unit: String?
    var location: StorageLocation?
    var note = ""

    init(name: String = "", quantityText: String = "", unit: String? = nil, location: StorageLocation? = nil, note: String = "") {
        self.name = name
        self.quantityText = quantityText
        self.unit = unit
        self.location = location
        self.note = note
    }

    init(item: PantryItem) {
        name = item.rawLabel
        quantityText = QuantityInput.text(item.quantity)
        unit = item.unit
        location = item.storageLocation
        note = item.note ?? ""
    }

    var cleanName: String { DraftText.singleLine(name, max: PantryLimits.name) }
    var cleanNote: String? { DraftText.nonEmpty(DraftText.multiLine(note, max: PantryLimits.note)) }
    var quantity: QuantityInput { QuantityInput.parse(quantityText) }

    var validationMessage: String? {
        if cleanName.isEmpty { return "Add a name." }
        if quantity == .invalid { return "Quantity must be a number greater than 0." }
        return nil
    }

    var isValid: Bool { validationMessage == nil }

    func newItem(resolution: PantryResolution? = nil) -> NewPantryItem {
        let quantity = quantity.value
        return NewPantryItem(
            rawLabel: cleanName,
            quantity: quantity,
            unit: unit,
            storageLocation: location,
            note: cleanNote,
            source: .manual,
            confidence: nil,
            quantityIsEstimate: false,
            resolution: resolution
        )
    }

    func patch() -> PantryItemPatch {
        PantryItemPatch(rawLabel: cleanName, quantity: quantity.value, unit: unit, storageLocation: location, note: cleanNote)
    }
}

extension Error {
    /// The copy shown inline for any pantry failure.
    var pantryMessage: String {
        if let api = self as? APIError {
            if api.isRateLimited {
                return "You’ve scanned a lot in the last hour. Try again later, or add items by hand."
            }
            return api.userMessage
        }
        return (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
