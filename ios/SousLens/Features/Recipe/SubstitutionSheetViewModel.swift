import Foundation
import Observation

/// A swap the user approved on the fit screen. Held there (revertible) and sent with
/// `POST /sessions` when they tap **Start cooking** (SUB-03: nothing is applied before that).
struct ApprovedSwap: Equatable, Identifiable, Sendable {
    let ingredientRef: String
    let ingredientName: String
    let candidate: String
    let ratioOrAmount: String?
    let source: SwapSource
    let input: AdaptationInput

    var id: String { ingredientRef }
    var label: String { source.label }

    init(ingredientName: String, suggestion: SubstitutionSuggestion, ingredientRef: String) {
        self.ingredientRef = ingredientRef
        self.ingredientName = ingredientName
        candidate = suggestion.candidate
        ratioOrAmount = suggestion.ratioOrAmount
        source = suggestion.source
        input = .suggestion(suggestion.suggestionId, ingredientRef: ingredientRef)
    }

    /// From a saved private variation ("Use my changes from last time").
    init(ingredientName: String, variation: VariationAdaptation) {
        ingredientRef = variation.ingredientRef
        self.ingredientName = ingredientName
        candidate = variation.replacement
        ratioOrAmount = variation.ratioOrAmount
        source = variation.source
        input = variation.input
    }
}

/// One suggestion card, everything PRD §8.4 asks to show.
struct SuggestionPresentation: Identifiable, Equatable {
    let id: UUID
    let candidate: String
    let amount: String?
    let why: String?
    let flavor: String?
    let texture: String?
    let confidence: String
    let risks: [String]
    let allergyWarning: String?
    let label: String
    let changesSteps: Int

    init(_ suggestion: SubstitutionSuggestion) {
        id = suggestion.suggestionId
        candidate = suggestion.candidate
        amount = suggestion.ratioOrAmount.flatMap { $0.isEmpty ? nil : $0 }
        why = suggestion.rationale.flatMap { $0.isEmpty ? nil : $0 }
        flavor = suggestion.impactFlavor.flatMap { $0.isEmpty ? nil : $0 }
        texture = suggestion.impactTexture.flatMap { $0.isEmpty ? nil : $0 }
        confidence = suggestion.confidence.confidenceText
        risks = suggestion.risks.filter { !$0.isEmpty }
        allergyWarning = suggestion.allergyWarning.flatMap { $0.isEmpty ? nil : $0 }
        label = suggestion.source.label
        changesSteps = suggestion.adjustedSteps.count
    }

    var accessibilityLabel: String {
        var parts = [label, candidate]
        if let amount { parts.append("Amount: \(amount)") }
        if let why { parts.append(why) }
        if let flavor { parts.append("Flavor: \(flavor)") }
        if let texture { parts.append("Texture: \(texture)") }
        parts.append(confidence)
        parts.append(contentsOf: risks.map { "Risk: \($0)" })
        if let allergyWarning { parts.append("Allergy warning: \(allergyWarning)") }
        return parts.joined(separator: ". ")
    }
}

/// "Find a swap" sheet for one Missing / Uncertain ingredient (J3 4–5, SUB-01/02/05).
@MainActor
@Observable
final class SubstitutionSheetViewModel {
    enum Phase: Equatable {
        case loading
        case suggestions([SuggestionPresentation])
        /// SUB-05: no suitable substitute. Never a fabricated one.
        case noSwap(reason: String)
        case error(String)
    }

    let recipeVersionId: UUID
    let ingredientRef: String
    let ingredientName: String
    private(set) var phase: Phase = .loading
    private(set) var safetyNotice: String?
    private(set) var targetIngredient: String
    private var result: SubstitutionResult?

    private let service: CookingService

    static let fallbackNoSwapReason = "There’s no substitute we can recommend for this one."

    init(recipeVersionId: UUID, ingredientRef: String, ingredientName: String, service: CookingService) {
        self.recipeVersionId = recipeVersionId
        self.ingredientRef = ingredientRef
        self.ingredientName = ingredientName
        targetIngredient = ingredientName
        self.service = service
    }

    func load() async {
        phase = .loading
        do {
            let result = try await service.suggestSubstitutions(recipeVersionId: recipeVersionId, ingredientRef: ingredientRef)
            self.result = result
            targetIngredient = result.targetIngredient.isEmpty ? ingredientName : result.targetIngredient
            safetyNotice = result.safetyNotice.flatMap { $0.isEmpty ? nil : $0 }
            if result.cannotSubstitute || result.suggestions.isEmpty {
                let reason = result.reason.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackNoSwapReason
                phase = .noSwap(reason: reason)
            } else {
                phase = .suggestions(result.suggestions.prefix(3).map(SuggestionPresentation.init))
            }
        } catch let error as APIError where error == .cancelled {
            return
        } catch let error as APIError {
            phase = .error(error.isTransportFailure
                           ? "Can’t reach the server to look for swaps. You can keep it missing and try again later."
                           : error.userMessage)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// **Use this swap** — an explicit approval. Nothing is sent to a session yet.
    func approve(suggestionId: UUID) -> ApprovedSwap? {
        guard let suggestion = result?.suggestions.first(where: { $0.suggestionId == suggestionId }) else { return nil }
        return ApprovedSwap(ingredientName: ingredientName, suggestion: suggestion, ingredientRef: ingredientRef)
    }
}
