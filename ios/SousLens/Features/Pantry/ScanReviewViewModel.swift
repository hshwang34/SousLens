import Foundation
import Observation

/// One candidate in Scan review. Everything is editable; nothing is pantry truth until Confirm.
struct ReviewRow: Identifiable, Equatable {
    /// Index of the candidate in the observation.
    let id: Int
    let candidate: PantryCandidate
    var name: String
    var quantityText: String
    var unit: String?
    var accepted: Bool
    /// Existing pantry item this probably duplicates (server hint, or a 409's `existing`).
    var duplicateOf: UUID?
    var duplicateName: String?
    var duplicateChoice: DuplicateChoice?

    init(index: Int, candidate: PantryCandidate, existingName: String?, isDemo: Bool = false) {
        id = index
        self.candidate = candidate
        name = candidate.rawLabel.isEmpty ? (candidate.canonicalName ?? "") : candidate.rawLabel
        quantityText = QuantityInput.text(candidate.quantity)
        unit = candidate.unit
        // "Not sure" (and anything the server marked ignore) starts unticked; so does every demo
        // (mock photo) candidate, which describes a sample, not the user's photo.
        accepted = !isDemo && candidate.confidenceBin != .unknown && candidate.action == .add
        duplicateOf = candidate.duplicateOf
        duplicateName = candidate.duplicateOf == nil ? nil : (existingName ?? candidate.canonicalName ?? candidate.rawLabel)
    }

    /// "Likely — estimate". Bins are UX labels, never calibrated (PRD §8.3).
    var confidenceText: String { "\(candidate.confidenceBin.label) · estimate" }

    var evidenceText: String? {
        guard let evidence = candidate.evidence, !evidence.isEmpty else { return nil }
        return evidence
    }

    var quantity: QuantityInput { QuantityInput.parse(quantityText) }
    var cleanName: String { DraftText.singleLine(name, max: PantryLimits.name) }

    var quantityEdited: Bool {
        quantity.value != candidate.quantity || unit != candidate.unit
    }

    /// The photo count is an estimate until the user types their own number.
    var isEstimate: Bool { quantity.value != nil && candidate.quantityIsEstimate && !quantityEdited }

    var duplicateText: String? { duplicateName.map { "You already have \($0)" } }

    var needsDuplicateChoice: Bool { accepted && duplicateOf != nil && duplicateChoice == nil }

    var problem: String? {
        guard accepted else { return nil }
        if cleanName.isEmpty { return "Add a name or untick this item." }
        if quantity == .invalid { return "Quantity must be a number greater than 0." }
        return nil
    }

    func newItem(source: PantrySource) -> NewPantryItem {
        NewPantryItem(
            rawLabel: cleanName,
            quantity: quantity.value,
            unit: unit,
            storageLocation: nil,
            note: nil,
            source: source,
            confidence: candidate.confidence,
            quantityIsEstimate: isEstimate,
            resolution: duplicateOf.flatMap { existing in duplicateChoice?.resolution(existingId: existing) }
        )
    }
}

/// Scan review (PRD §6, J2 step 4, PAN-04): per-item accept/reject, edits, duplicate resolution.
@MainActor
@Observable
final class ScanReviewViewModel {
    let observation: PantryObservation
    var rows: [ReviewRow]
    private(set) var isConfirming = false
    private(set) var error: String?
    /// Shown after a 409: which items need a Merge / Keep both answer.
    private(set) var conflictMessage: String?
    /// Server-confirmed items once Confirm succeeds.
    private(set) var confirmed: [PantryItem]?
    /// 409 `STATE_CONFLICT`: this review was already confirmed (e.g. a retried request). The view
    /// says so and closes; nothing is retried.
    private(set) var alreadyAdded = false

    static let alreadyAddedMessage = "These items were already added."

    /// Provenance sent with every item: `voice` for dictated text, `manual` for typed text,
    /// `photo` for photos.
    let source: PantrySource
    private let service: PantryService
    private let now: @MainActor () -> Date
    private var existingNames: [UUID: String]

    static let expiredMessage = "This scan expired — scan again."

    init(observation: PantryObservation, existingItems: [PantryItem], service: PantryService,
         source: PantrySource? = nil, now: @escaping @MainActor () -> Date = { Date() }) {
        self.observation = observation
        self.service = service
        self.now = now
        self.source = source ?? observation.mode.source
        let names = Dictionary(existingItems.map { ($0.id, $0.rawLabel) }, uniquingKeysWith: { first, _ in first })
        existingNames = names
        let isDemo = observation.isDemoPhoto
        rows = observation.candidates.enumerated().map { index, candidate in
            ReviewRow(index: index, candidate: candidate, existingName: candidate.duplicateOf.flatMap { names[$0] }, isDemo: isDemo)
        }
    }

    var isExpired: Bool { now() >= observation.expiresAt }

    var unknowns: [String] { observation.unknowns }
    var showsDemoBanner: Bool { observation.isDemoPhoto }
    var acceptedRows: [ReviewRow] { rows.filter(\.accepted) }

    var sourceLabel: String {
        observation.mode == .transcript ? "From what you said" : "From your photo"
    }

    /// Why Confirm is disabled, if it is.
    var blockingMessage: String? {
        let accepted = acceptedRows
        if accepted.isEmpty { return "Tick at least one item to add." }
        let undecided = accepted.filter(\.needsDuplicateChoice).count
        if undecided > 0 {
            return undecided == 1
                ? "Choose Merge or Keep both for the item you already have."
                : "Choose Merge or Keep both for the \(undecided) items you already have."
        }
        if accepted.contains(where: { $0.problem != nil }) { return "Fix the highlighted items first." }
        return nil
    }

    var canConfirm: Bool { blockingMessage == nil && !isConfirming && confirmed == nil && !alreadyAdded }

    var confirmTitle: String {
        let count = acceptedRows.count
        return count == 1 ? "Add 1 item" : "Add \(count) items"
    }

    // MARK: Edits

    func setAccepted(_ id: Int, _ accepted: Bool) { update(id) { $0.accepted = accepted } }
    func setName(_ id: Int, _ name: String) { update(id) { $0.name = String(name.prefix(PantryLimits.name)) } }
    func setQuantityText(_ id: Int, _ text: String) { update(id) { $0.quantityText = text } }
    func setUnit(_ id: Int, _ unit: String?) { update(id) { $0.unit = unit } }
    func choose(_ id: Int, _ choice: DuplicateChoice) {
        update(id) { $0.duplicateChoice = choice }
        if !rows.contains(where: \.needsDuplicateChoice) { conflictMessage = nil }
    }

    private func update(_ id: Int, _ change: (inout ReviewRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    // MARK: Confirm

    /// Sends only accepted rows, with the observation id. A 409 re-opens the duplicate choice for
    /// the listed conflicts and sends nothing more until the user answers.
    @discardableResult
    func confirm() async -> [PantryItem]? {
        guard !isExpired else {
            error = Self.expiredMessage
            return nil
        }
        guard canConfirm else {
            error = blockingMessage
            return nil
        }
        let accepted = acceptedRows
        let items = accepted.map { $0.newItem(source: source) }
        isConfirming = true
        error = nil
        conflictMessage = nil
        defer { isConfirming = false }
        do {
            let result = try await service.addPantryItems(items, observationId: observation.observationId)
            confirmed = result
            return result
        } catch let api as APIError {
            if let conflicts = api.pantryConflicts, !conflicts.isEmpty {
                applyConflicts(conflicts, sent: accepted)
            } else if api.isObservationAlreadyConfirmed {
                alreadyAdded = true
                error = nil
            } else if api.status == 404 || api.status == 410 {
                handleNotFound(api, sent: accepted)
            } else {
                error = "Couldn’t add: \(api.pantryMessage)"
            }
            return nil
        } catch {
            self.error = "Couldn’t add: \(error.pantryMessage)"
            return nil
        }
    }

    static let mergeTargetGoneMessage = "That item no longer exists — pick Merge again or Keep both."

    /// 404/410 on confirm: either the observation expired (24 h TTL) or a `merge_into` target was
    /// deleted meanwhile. Only the latter reopens the choice.
    private func handleNotFound(_ api: APIError, sent: [ReviewRow]) {
        let mergeRows = sent.filter { $0.duplicateChoice == .merge && $0.duplicateOf != nil }
        if api.status == 410 || mergeRows.isEmpty || Self.refersToObservation(api) {
            error = Self.expiredMessage
            return
        }
        let target = Self.missingTarget(api)
        let affected = mergeRows.filter { target == nil || $0.duplicateOf == target }
        for row in (affected.isEmpty ? mergeRows : affected) {
            update(row.id) { $0.duplicateChoice = nil }
        }
        error = Self.mergeTargetGoneMessage
    }

    private static func refersToObservation(_ api: APIError) -> Bool {
        guard case .server(_, _, let message, _, _, let details) = api else { return false }
        if message.localizedCaseInsensitiveContains("observation") { return true }
        guard let details else { return false }
        if details["observation_id"] != nil { return true }
        for key in ["field", "resource", "param"] {
            if let value = details[key]?.stringValue, value.localizedCaseInsensitiveContains("observation") { return true }
        }
        return false
    }

    /// The pantry id the 404 names, when it says (`details.merge_into` or `details.id`).
    private static func missingTarget(_ api: APIError) -> UUID? {
        guard let details = api.details else { return nil }
        for key in ["merge_into", "id", "pantry_item_id"] {
            if let raw = details[key]?.stringValue, let id = UUID(uuidString: raw) { return id }
        }
        return nil
    }

    private func applyConflicts(_ conflicts: [PantryConflict], sent: [ReviewRow]) {
        var affected = 0
        for conflict in conflicts where sent.indices.contains(conflict.index) {
            let rowId = sent[conflict.index].id
            existingNames[conflict.existing.id] = conflict.existing.rawLabel
            update(rowId) { row in
                row.duplicateOf = conflict.existing.id
                row.duplicateName = conflict.existing.rawLabel
                row.duplicateChoice = nil
            }
            affected += 1
        }
        if affected == 0 {
            error = "Some items are already in your pantry, but the server didn’t say which. Nothing was added."
        } else {
            conflictMessage = affected == 1
                ? "1 item is already in your pantry. Choose Merge or Keep both, then add again."
                : "\(affected) items are already in your pantry. Choose Merge or Keep both for each, then add again."
        }
    }
}
