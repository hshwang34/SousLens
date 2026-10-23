import Foundation

/// Everything a step row displays, computed without SwiftUI so tests can assert the exact
/// labels (PRD §13.4 provenance pill included) without a view-inspection library.
struct StepRowPresentation: Equatable, Sendable {
    let numberText: String
    let instruction: String
    /// "About 4 min" when the creator estimated a duration.
    let timePill: String?
    /// Transparency label for any step that is not creator-authored; nil otherwise.
    let provenancePill: String?
    let successCues: [String]
    let warnings: [String]
    /// "Creator note: …" when present and non-empty.
    let creatorNoteText: String?
    let accessibilityLabel: String

    init(number: Int, step: RecipeStep) {
        numberText = String(number)
        instruction = step.instruction
        timePill = step.estimatedMinutes.map { "About \(RecipeFormatting.minutes($0))" }
        provenancePill = step.provenanceLabel
        successCues = step.successCues
        warnings = step.warnings
        if let note = step.creatorNote, !note.isEmpty {
            creatorNoteText = "Creator note: \(note)"
        } else {
            creatorNoteText = nil
        }
        accessibilityLabel = "Step \(number)"
    }

    /// Pills in display order (time, then provenance).
    var pills: [String] { [timePill, provenancePill].compactMap { $0 } }
}

/// The "Steps" section header: title plus the recipe-wide provenance pill.
struct StepsHeaderPresentation: Equatable, Sendable {
    let title = "Steps"
    let provenancePill: String

    init(detail: RecipeDetail) {
        provenancePill = detail.headerProvenanceLabel
    }
}
