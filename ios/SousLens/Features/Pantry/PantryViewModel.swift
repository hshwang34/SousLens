import Foundation
import Observation

/// My Pantry (PRD §6): the confirmed list, sorted by name, with provenance and freshness.
/// Every write is a user action on a specific row; nothing here changes the pantry on its own.
@MainActor
@Observable
final class PantryViewModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case error(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [PantryItem] = []
    /// Inline message after a failed row action (delete / still have it).
    private(set) var actionError: String?
    /// Rows with a request in flight (their buttons are disabled).
    private(set) var busyItemIds: Set<UUID> = []

    private let service: PantryService
    private let now: @MainActor () -> Date
    /// Fired after any confirmed server write, so other screens (recipe fit) can refresh.
    var onChanged: (@MainActor () -> Void)?

    init(service: PantryService, now: @escaping @MainActor () -> Date = { Date() }) {
        self.service = service
        self.now = now
    }

    var rows: [PantryRowPresentation] {
        let reference = now()
        return items.map { PantryRowPresentation(item: $0, now: reference) }
    }

    var isEmpty: Bool { phase == .loaded && items.isEmpty }

    func item(id: UUID) -> PantryItem? { items.first { $0.id == id } }

    /// Last request wins: a slow earlier load (or one that started before a local write) is dropped.
    private var loadGeneration = 0

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if items.isEmpty { phase = .loading }
        do {
            let fetched = try await service.listPantry()
            guard generation == loadGeneration else { return }
            items = Self.sorted(fetched)
            phase = .loaded
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            guard generation == loadGeneration else { return }
            // Keep a list we already have; only an empty screen turns into an error screen.
            if items.isEmpty {
                phase = .error(error.pantryMessage)
            } else {
                actionError = error.pantryMessage
            }
        }
    }

    /// The view asks "Delete X?" first; this runs only after that confirmation.
    func delete(id: UUID) async {
        guard !busyItemIds.contains(id) else { return }
        busyItemIds.insert(id)
        actionError = nil
        defer { busyItemIds.remove(id) }
        do {
            try await service.deletePantryItem(id: id)
            loadGeneration += 1   // a load already in flight may still list it
            items.removeAll { $0.id == id }
            onChanged?()
        } catch {
            actionError = "Couldn’t delete: \(error.pantryMessage)"
        }
    }

    /// "Still have it" → `POST /pantry/{id}/confirm`.
    func confirmStillHave(id: UUID) async {
        guard !busyItemIds.contains(id) else { return }
        busyItemIds.insert(id)
        actionError = nil
        defer { busyItemIds.remove(id) }
        do {
            apply([try await service.confirmPantryItem(id: id)])
            onChanged?()
        } catch {
            actionError = "Couldn’t update: \(error.pantryMessage)"
        }
    }

    /// Server-confirmed items from an add, merge or edit replace (or join) the list.
    func apply(_ updated: [PantryItem]) {
        loadGeneration += 1   // a load already in flight predates these server-confirmed items
        var byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in updated { byId[item.id] = item }
        items = Self.sorted(Array(byId.values))
        if phase != .loaded { phase = .loaded }
    }

    func clearActionError() { actionError = nil }

    static func sorted(_ items: [PantryItem]) -> [PantryItem] {
        items.sorted {
            let lhs = $0.normalizedName.localizedLowercase
            let rhs = $1.normalizedName.localizedLowercase
            if lhs != rhs { return lhs < rhs }
            if $0.rawLabel != $1.rawLabel { return $0.rawLabel.localizedLowercase < $1.rawLabel.localizedLowercase }
            return $0.createdAt < $1.createdAt
        }
    }
}

/// Add or edit one pantry item (manual sheet). A duplicate on add (409) stops and asks
/// Merge / Keep both; it is never resolved without the user's choice (PAN-04).
@MainActor
@Observable
final class PantryItemEditorModel: Identifiable {
    enum Mode: Equatable {
        case add
        case edit(PantryItem)
    }

    let id = UUID()
    let mode: Mode
    var form: PantryItemForm
    private(set) var isSaving = false
    private(set) var error: String?
    /// The existing item a 409 named; the sheet shows the Merge / Keep both choice while set.
    private(set) var conflict: PantryItem?
    /// Set when the save finished on the server; the sheet dismisses.
    private(set) var saved: [PantryItem]?

    private let service: PantryService

    init(mode: Mode, form: PantryItemForm? = nil, service: PantryService) {
        self.mode = mode
        self.service = service
        switch mode {
        case .add: self.form = form ?? PantryItemForm()
        case .edit(let item): self.form = form ?? PantryItemForm(item: item)
        }
    }

    var title: String {
        if case .edit = mode { return "Edit item" }
        return "Add pantry item"
    }

    var canSave: Bool { form.isValid && !isSaving && conflict == nil }

    @discardableResult
    func save() async -> [PantryItem]? {
        guard form.isValid, !isSaving else {
            error = form.validationMessage
            return nil
        }
        switch mode {
        case .add: return await add(resolution: nil)
        case .edit(let item): return await edit(item)
        }
    }

    /// The user's answer to the duplicate prompt.
    @discardableResult
    func resolve(_ choice: DuplicateChoice) async -> [PantryItem]? {
        guard let existing = conflict else { return nil }
        conflict = nil
        return await add(resolution: choice.resolution(existingId: existing.id))
    }

    func cancelConflict() { conflict = nil }

    private func add(resolution: PantryResolution?) async -> [PantryItem]? {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let result = try await service.addPantryItems([form.newItem(resolution: resolution)], observationId: nil)
            saved = result
            return result
        } catch let api as APIError {
            if let conflicts = api.pantryConflicts, let first = conflicts.first {
                conflict = first.existing
            } else {
                error = "Couldn’t add: \(api.pantryMessage)"
            }
            return nil
        } catch {
            self.error = "Couldn’t add: \(error.pantryMessage)"
            return nil
        }
    }

    private func edit(_ item: PantryItem) async -> [PantryItem]? {
        isSaving = true
        error = nil
        defer { isSaving = false }
        let patch = form.patch(from: item)
        if patch.isEmpty {
            saved = [item]
            return [item]
        }
        do {
            var updated = try await service.updatePantryItem(id: item.id, patch)
            // A quantity the user typed is not an estimate (the backend clears the flag too).
            if patch.quantity != nil, updated.quantityIsEstimate {
                updated = updated.withQuantityIsEstimate(false)
            }
            saved = [updated]
            return [updated]
        } catch {
            self.error = "Couldn’t save: \(error.pantryMessage)"
            return nil
        }
    }
}
