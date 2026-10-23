import Foundation
import Observation

/// Profile → "Allergies & foods to avoid" (SUB-02, DECISIONS #14).
///
/// Allergies are hard blocks on substitutions; "avoid" is a soft preference. Each add / remove is
/// an explicit tap and is saved right away (`PUT /me/preferences`); a failed save rolls back.
/// The copy never claims anything is "safe" for the user (PRD §13.1).
@MainActor
@Observable
final class PreferencesViewModel {
    enum Kind: String, CaseIterable, Identifiable {
        case allergies, avoid
        var id: String { rawValue }

        var title: String {
            switch self {
            case .allergies: return "Allergies"
            case .avoid: return "Foods to avoid"
            }
        }

        var explanation: String {
            switch self {
            case .allergies:
                return "Swaps that contain these are never suggested. If a recipe itself contains one, you’ll see a notice."
            case .avoid:
                return "A preference, not a block: we skip these when we can and tell you when we did."
            }
        }

        var placeholder: String {
            switch self {
            case .allergies: return "e.g. peanuts, shellfish"
            case .avoid: return "e.g. cilantro"
            }
        }
    }

    enum Phase: Equatable {
        case loading
        case loaded
        case error(String)
    }

    static let maxLength = 60
    static let maxEntries = 30
    /// Footer under both lists (PRD §13.1: label verification, no "safe for you" claims).
    static let disclaimer = "SousLens can’t check labels or kitchens for you. Always read package labels and check with the people you cook for — a suggestion is never a guarantee that something is free of an allergen."

    private(set) var phase: Phase = .loading
    private(set) var preferences = FoodPreferences()
    private(set) var isSaving = false
    private(set) var saveError: String?
    // Assign only when over the cap: an unconditional write in `didSet` recurses under @Observable.
    var allergyDraft = "" { didSet { if allergyDraft.count > Self.maxLength { allergyDraft = String(allergyDraft.prefix(Self.maxLength)) } } }
    var avoidDraft = "" { didSet { if avoidDraft.count > Self.maxLength { avoidDraft = String(avoidDraft.prefix(Self.maxLength)) } } }

    private let service: PreferencesService

    init(service: PreferencesService) {
        self.service = service
    }

    func entries(_ kind: Kind) -> [String] {
        kind == .allergies ? preferences.allergies : preferences.avoid
    }

    func draft(_ kind: Kind) -> String {
        kind == .allergies ? allergyDraft : avoidDraft
    }

    func setDraft(_ kind: Kind, _ value: String) {
        if kind == .allergies { allergyDraft = value } else { avoidDraft = value }
    }

    func canAdd(_ kind: Kind) -> Bool {
        let value = Self.clean(draft(kind))
        guard !value.isEmpty, !isSaving, entries(kind).count < Self.maxEntries else { return false }
        return !entries(kind).contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    func load() async {
        phase = .loading
        do {
            preferences = try await service.preferences()
            phase = .loaded
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            phase = .error((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    func add(_ kind: Kind) async {
        guard canAdd(kind) else { return }
        let value = Self.clean(draft(kind))
        var next = preferences
        if kind == .allergies { next.allergies.append(value) } else { next.avoid.append(value) }
        if await save(next) { setDraft(kind, "") }
    }

    func remove(_ kind: Kind, at index: Int) async {
        var next = preferences
        if kind == .allergies {
            guard next.allergies.indices.contains(index) else { return }
            next.allergies.remove(at: index)
        } else {
            guard next.avoid.indices.contains(index) else { return }
            next.avoid.remove(at: index)
        }
        _ = await save(next)
    }

    /// Optimistic; the server's normalised lists replace ours ("peanuts" → "peanut").
    private func save(_ next: FoodPreferences) async -> Bool {
        guard !isSaving else { return false }
        let previous = preferences
        preferences = next
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            preferences = try await service.updatePreferences(next)
            return true
        } catch {
            preferences = previous
            saveError = "Couldn’t save: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
            return false
        }
    }

    /// Single line, no control characters, trimmed, ≤ 60 characters.
    static func clean(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character($0) }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }
}
