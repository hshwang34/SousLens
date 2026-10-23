import Foundation
import Observation

/// One ingredient line on the Pantry fit screen.
struct FitRowPresentation: Identifiable, Equatable {
    let id: String
    let name: String
    let status: FitStatus
    let reason: String
    let requiredText: String?
    let haveText: String?
    let conversionNote: String?
    let pantryItemId: UUID?
    /// The matched pantry item was confirmed more than 14 days ago → offer "Still have it".
    let isStale: Bool
    /// The matched pantry amount is a photo estimate → offer "Fix amount" instead.
    let hasEstimatedAmount: Bool
    /// Brief 005: a substitution lookup is available (the screen has a cooking service).
    let swapsEnabled: Bool
    /// The swap the user approved for this line, if any (held on the fit screen, revertible).
    var swap: ApprovedSwap?

    init(item: FitItem, isStale: Bool, hasEstimatedAmount: Bool = false, swapsEnabled: Bool = false, swap: ApprovedSwap? = nil) {
        id = item.ingredientRef
        name = item.name
        status = item.status
        reason = item.reason
        requiredText = item.required.flatMap { PantryFormatting.quantity($0.quantity, unit: $0.unit) }
        haveText = item.pantryQuantity.flatMap { PantryFormatting.quantity($0.quantity, unit: $0.unit) }
        conversionNote = item.conversionNote.flatMap { $0.isEmpty ? nil : $0 }
        pantryItemId = item.pantryItemId
        self.isStale = isStale
        self.hasEstimatedAmount = hasEstimatedAmount && item.pantryItemId != nil
        self.swapsEnabled = swapsEnabled
        self.swap = swap
    }

    /// Missing items can be added to the pantry from here.
    var canAddToPantry: Bool { status == .missing || status == .optionalMissing }
    var canConfirmStillHave: Bool { isStale && pantryItemId != nil && !hasEstimatedAmount }
    var canFixAmount: Bool { hasEstimatedAmount }
    /// Required Missing and Uncertain lines can look for a swap (J3 step 4).
    var canFindSwap: Bool { swapsEnabled && (status == .missing || status == .uncertain) }

    enum Action: String, CaseIterable {
        case findSwap
        case undoSwap
        case addToPantry
        case stillHaveIt
        case fixAmount

        var title: String {
            switch self {
            case .findSwap: return "Find a swap"
            case .undoSwap: return "Undo swap"
            case .addToPantry: return "Add to pantry"
            case .stillHaveIt: return "Still have it"
            case .fixAmount: return "Fix amount"
            }
        }
    }

    /// What the row offers; the view renders these as buttons and as VoiceOver actions, so the
    /// combined accessibility element never hides them.
    var actions: [Action] {
        var actions: [Action] = []
        if swap != nil {
            actions.append(.undoSwap)
        } else if canFindSwap {
            actions.append(.findSwap)
        }
        if canAddToPantry { actions.append(.addToPantry) }
        if canFixAmount { actions.append(.fixAmount) }
        if canConfirmStillHave { actions.append(.stillHaveIt) }
        return actions
    }

    var statusLabel: String {
        switch status {
        case .available: return "Available"
        case .uncertain: return "Uncertain"
        case .missing: return "Missing"
        case .optionalMissing: return "Optional, missing"
        }
    }

    var accessibilityLabel: String {
        var parts = [name, statusLabel, reason]
        if let requiredText { parts.append("Recipe needs \(requiredText)") }
        if let swap { parts.append("Swap: \(swap.candidate), \(swap.label)") }
        if let conversionNote { parts.append(conversionNote) }
        return parts.joined(separator: ". ")
    }
}

struct FitSection: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case available, uncertain, missing, optional

        var title: String {
            switch self {
            case .available: return "Available"
            case .uncertain: return "Uncertain"
            case .missing: return "Missing"
            case .optional: return "Optional"
            }
        }

        var systemImage: String {
            switch self {
            case .available: return "checkmark.circle.fill"
            case .uncertain: return "questionmark.circle.fill"
            case .missing: return "xmark.circle.fill"
            case .optional: return "circle.dashed"
            }
        }
    }

    let kind: Kind
    let rows: [FitRowPresentation]
    var id: String { kind.rawValue }
}

/// Pantry fit (PRD §6, J3 steps 1–3, FIT-01..03). The headline never claims more than the
/// server's classification: "Can make it" appears only when `can_make` is true and no required
/// ingredient is uncertain or missing.
@MainActor
@Observable
final class PantryFitViewModel {
    enum Phase: Equatable {
        case loading
        case loaded(PantryFit)
        case error(String)
    }

    let recipeVersionId: UUID
    let recipeTitle: String
    private(set) var phase: Phase = .loading
    /// Pantry snapshot used only to tell which matched items are stale.
    private(set) var pantryItems: [PantryItem] = []
    private(set) var actionError: String?
    private(set) var busyItemIds: Set<UUID> = []

    private let service: PantryService
    private let cooking: CookingService?
    private let now: @MainActor () -> Date
    var onPantryChanged: (@MainActor () -> Void)?

    // Brief 005 — swaps held on this screen until Start cooking (SUB-03), keyed by ingredient_ref.
    private(set) var approvedSwaps: [String: ApprovedSwap] = [:]
    /// The user's saved private variation for this version ("Use my changes from last time").
    private(set) var variation: PrivateVariation?
    private(set) var isStarting = false
    private(set) var startError: String?

    init(recipeVersionId: UUID, recipeTitle: String, service: PantryService, cooking: CookingService? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.recipeVersionId = recipeVersionId
        self.recipeTitle = recipeTitle
        self.service = service
        self.cooking = cooking
        self.now = now
    }

    var fit: PantryFit? {
        if case .loaded(let fit) = phase { return fit }
        return nil
    }

    /// Last request wins: a slow earlier fit never replaces a newer one.
    private var loadGeneration = 0

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if fit == nil { phase = .loading }
        actionError = nil
        async let fitResult = service.fit(recipeVersionId: recipeVersionId)
        // Staleness is a nice-to-have: a failed pantry read only hides "Still have it".
        async let pantryResult = try? service.listPantry()
        do {
            let fit = try await fitResult
            let pantry = await pantryResult ?? []
            guard generation == loadGeneration else { return }
            pantryItems = pantry
            phase = .loaded(fit)
        } catch let error as APIError where error == .cancelled {
            _ = await pantryResult
        } catch {
            _ = await pantryResult
            guard generation == loadGeneration else { return }
            if fit == nil {
                phase = .error(error.pantryMessage)
            } else {
                actionError = error.pantryMessage
            }
        }
    }

    // MARK: Presentation

    private var requiredItems: [FitItem] { fit?.items.filter { !$0.optional } ?? [] }

    /// "X of Y ingredients" — required items that are available, out of all required items.
    var coverageText: String? {
        guard fit != nil else { return nil }
        let required = requiredItems
        let available = required.filter { $0.status == .available }.count
        return "\(available) of \(required.count) ingredients"
    }

    var coverageAccessibilityLabel: String? {
        coverageText.map { "\($0) in your pantry. This is a guide, not a guarantee." }
    }

    var missingCount: Int { requiredItems.filter { $0.status == .missing }.count }
    var uncertainCount: Int { requiredItems.filter { $0.status == .uncertain }.count }

    /// FIT-03: no "can make it" if anything required is uncertain or missing.
    var canMake: Bool {
        guard let fit else { return false }
        return fit.canMake && missingCount == 0 && uncertainCount == 0
    }

    var headline: String? {
        guard fit != nil else { return nil }
        if canMake { return "Can make it" }
        if missingCount > 0 { return "You’re missing \(missingCount)" }
        if uncertainCount > 0 { return uncertainCount == 1 ? "Check 1 item" : "Check \(uncertainCount) items" }
        // Server said no but every required row is available (shouldn't happen): stay cautious.
        return "Check your pantry"
    }

    var subheadline: String? {
        guard fit != nil, !canMake else { return nil }
        if missingCount > 0, uncertainCount > 0 {
            return uncertainCount == 1 ? "and check 1 item" : "and check \(uncertainCount) items"
        }
        return nil
    }

    var sections: [FitSection] {
        guard let fit else { return [] }
        let reference = now()
        let staleIds = Set(pantryItems.filter { PantryFreshness.isStale(lastConfirmedAt: $0.lastConfirmedAt, now: reference) }.map(\.id))
        let estimatedIds = Set(pantryItems.filter { $0.quantityIsEstimate && $0.quantity != nil }.map(\.id))
        func rows(_ predicate: (FitItem) -> Bool) -> [FitRowPresentation] {
            fit.items.filter(predicate).map { item in
                FitRowPresentation(item: item,
                                   isStale: item.pantryItemId.map(staleIds.contains) ?? false,
                                   hasEstimatedAmount: item.pantryItemId.map(estimatedIds.contains) ?? false,
                                   swapsEnabled: cooking != nil && !item.optional,
                                   swap: approvedSwaps[item.ingredientRef])
            }
        }
        let all: [FitSection] = [
            FitSection(kind: .available, rows: rows { $0.status == .available && !$0.optional }),
            FitSection(kind: .uncertain, rows: rows { $0.status == .uncertain && !$0.optional }),
            FitSection(kind: .missing, rows: rows { $0.status == .missing && !$0.optional }),
            FitSection(kind: .optional, rows: rows { $0.optional || $0.status == .optionalMissing }),
        ]
        return all.filter { !$0.rows.isEmpty }
    }

    // MARK: Actions

    /// "Still have it" on a stale match, then re-check.
    func confirmStillHave(pantryItemId: UUID) async {
        guard !busyItemIds.contains(pantryItemId) else { return }
        busyItemIds.insert(pantryItemId)
        actionError = nil
        defer { busyItemIds.remove(pantryItemId) }
        do {
            _ = try await service.confirmPantryItem(id: pantryItemId)
            // The revision bump is the one reload path (the view re-runs `load()` on it).
            onPantryChanged?()
        } catch {
            actionError = "Couldn’t update: \(error.pantryMessage)"
        }
    }

    /// Prefilled manual add for a missing ingredient. Only the name is filled: the recipe's amount
    /// is not what the user has.
    /// The pantry item behind a row ("Fix amount" opens the editor on it).
    func pantryItem(for row: FitRowPresentation) -> PantryItem? {
        guard let id = row.pantryItemId else { return nil }
        return pantryItems.first { $0.id == id }
    }

    func addForm(for row: FitRowPresentation) -> PantryItemForm {
        PantryItemForm(name: row.name)
    }

    // MARK: Swaps and Start cooking (brief 005)

    var canSwap: Bool { cooking != nil }

    /// **Use this swap** in the sheet. Replaces any earlier swap for the same line.
    func approve(_ swap: ApprovedSwap) {
        approvedSwaps[swap.ingredientRef] = swap
        startError = nil
    }

    /// **Undo swap** — nothing was sent anywhere, so this is purely local.
    func revertSwap(ingredientRef: String) {
        approvedSwaps[ingredientRef] = nil
    }

    var approvedSwapList: [ApprovedSwap] {
        approvedSwaps.values.sorted { $0.ingredientName.localizedCaseInsensitiveCompare($1.ingredientName) == .orderedAscending }
    }

    /// Offer "Use my changes from last time" only when a variation exists and isn't applied yet.
    var canUseVariation: Bool {
        guard let variation, !variation.adaptations.isEmpty else { return false }
        return variation.adaptations.contains { approvedSwaps[$0.ingredientRef]?.input != $0.input }
    }

    func loadVariation() async {
        guard let cooking else { return }
        // Best effort: no variation (404 → nil) or a failed read just hides the offer.
        variation = try? await cooking.myVariation(recipeVersionId: recipeVersionId)
    }

    /// Explicit tap: fills the swaps from the saved variation (still revertible, still unsent).
    func useVariation() {
        guard let variation else { return }
        let names = Dictionary((fit?.items ?? []).map { ($0.ingredientRef, $0.name) }, uniquingKeysWith: { first, _ in first })
        for adaptation in variation.adaptations {
            let name = names[adaptation.ingredientRef] ?? adaptation.original ?? adaptation.ingredientRef
            approvedSwaps[adaptation.ingredientRef] = ApprovedSwap(ingredientName: name, variation: adaptation)
        }
    }

    /// **Start cooking**: `POST /sessions` pinning this version with the approved swaps. The
    /// returned Session (status `created`) is started by the cooking screen on the same tap.
    func startCooking() async -> CookingSession? {
        guard let cooking, !isStarting else { return nil }
        isStarting = true
        startError = nil
        defer { isStarting = false }
        do {
            return try await cooking.createSession(recipeVersionId: recipeVersionId,
                                                   adaptations: approvedSwapList.map(\.input))
        } catch let error as APIError where error == .cancelled {
            return nil
        } catch {
            startError = "Couldn’t start cooking: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
            return nil
        }
    }

}
