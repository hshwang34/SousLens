import Foundation
import SwiftUI

/// Pure formatting for the cooking screen (unit-tested without a view).
enum CookingFormatting {
    /// "10-min", "90-sec", "1-hr 30-min"-style compact durations for the timer prompt.
    static func shortDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)-sec" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)-hr" }
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600 + 30) / 60
            return minutes == 0 ? "\(hours)-hr" : "\(hours)-hr \(minutes)-min"
        }
        let minutes = seconds / 60, rest = seconds % 60
        return rest == 0 ? "\(minutes)-min" : "\(minutes)-min \(rest)-sec"
    }

    /// DECISIONS #14: "Start a 10-min simmer timer?"
    static func timerPrompt(_ timer: SuggestedTimer) -> String {
        "Start a \(shortDuration(timer.durationSeconds)) \(timer.label.lowercased()) timer?"
    }

    /// "9:59", "1:02:03"; never negative.
    static func countdown(_ seconds: Int) -> String {
        let value = max(seconds, 0)
        let h = value / 3600, m = (value % 3600) / 60, s = value % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func spokenCountdown(_ seconds: Int) -> String {
        let value = max(seconds, 0)
        let m = value / 60, s = value % 60
        if m == 0 { return "\(s) seconds left" }
        return s == 0 ? "\(m) minutes left" : "\(m) minutes \(s) seconds left"
    }
}

/// One running/finished timer, computed from the absolute `target_at` (COOK-06).
struct TimerRow: Identifiable, Equatable {
    let id: UUID
    let label: String
    let remainingSeconds: Int
    let isDone: Bool

    var countdownText: String { isDone ? "Done" : CookingFormatting.countdown(remainingSeconds) }
    var accessibilityLabel: String {
        isDone ? "\(label) timer done" : "\(label) timer, \(CookingFormatting.spokenCountdown(remainingSeconds))"
    }

    /// Cancelled timers are hidden; a running timer past its target reads as done even before the
    /// server says so (the server reports it `done` on the next read).
    static func rows(for timers: [SessionTimer], now: Date) -> [TimerRow] {
        timers
            .filter { $0.status != .cancelled }
            .sorted { $0.targetAt < $1.targetAt }
            .map { timer in
                let remaining = Int(timer.targetAt.timeIntervalSince(now).rounded(.up))
                return TimerRow(id: timer.id, label: timer.label, remainingSeconds: max(remaining, 0),
                                isDone: timer.status == .done || remaining <= 0)
            }
    }
}

/// A grounding reference rendered as a badge ("Step 3", "Creator note", …).
struct GroundingBadge: Hashable, Identifiable {
    let text: String
    let systemImage: String
    var id: String { text }

    static func badges(for refs: [GroundingRef], session: CookingSession?) -> [GroundingBadge] {
        var seen = Set<String>()
        return refs.compactMap { ref in
            let badge = badge(for: ref, session: session)
            guard seen.insert(badge.text).inserted else { return nil }
            return badge
        }
    }

    static func badge(for ref: GroundingRef, session: CookingSession?) -> GroundingBadge {
        switch ref.type {
        case "recipe_step":
            if let session, let index = session.steps.firstIndex(where: { $0.stepId == ref.id })
                ?? session.recipe.orderedSteps.firstIndex(where: { $0.id == ref.id }) {
                return GroundingBadge(text: "Step \(index + 1)", systemImage: "list.number")
            }
            return GroundingBadge(text: "Recipe step", systemImage: "list.number")
        case "ingredient":
            let name = session?.recipe.ingredients.first { $0.id == ref.id }?.name
            return GroundingBadge(text: name.map { "Ingredient: \($0)" } ?? "Ingredient", systemImage: "carrot")
        case "creator_note":
            return GroundingBadge(text: "Creator note", systemImage: "person.text.rectangle")
        case "adaptation":
            return GroundingBadge(text: "Your swap", systemImage: "arrow.triangle.swap")
        default:
            return GroundingBadge(text: ref.type.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "doc.text")
        }
    }
}

/// "The recipe says … My suggestion: …" split into labelled paragraphs, as returned.
struct AnswerSegment: Equatable, Identifiable {
    let heading: String?
    let text: String
    var id: String { (heading ?? "") + text }

    static func split(_ answer: String) -> [AnswerSegment] {
        let marker = "My suggestion:"
        guard let range = answer.range(of: marker) else {
            return [AnswerSegment(heading: nil, text: answer.trimmingCharacters(in: .whitespacesAndNewlines))]
        }
        let before = answer[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = answer[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        var segments: [AnswerSegment] = []
        if !before.isEmpty { segments.append(AnswerSegment(heading: nil, text: before)) }
        if !after.isEmpty { segments.append(AnswerSegment(heading: "My suggestion", text: after)) }
        return segments
    }
}

extension QualitativeLevel {
    /// Swap confidence, in words (PRD §13.4: qualitative, not a score).
    var confidenceText: String {
        switch self {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low confidence"
        }
    }

    /// Coach `uncertainty`.
    var uncertaintyText: String {
        switch self {
        case .low: return "Low uncertainty"
        case .medium: return "Some uncertainty"
        case .high: return "High uncertainty — double-check"
        }
    }
}

extension ProposedAction {
    /// The question on the proposal button. Tapping it is the confirmation.
    func buttonTitle(stepsCount: Int?) -> String {
        switch command {
        case .next: return "Go to next step?"
        case .back: return "Go back a step?"
        case .jumpToStep:
            if let stepIndex { return "Go to step \(stepIndex + 1)?" }
            return "Go to that step?"
        case .startTimer:
            if let timer { return CookingFormatting.timerPrompt(SuggestedTimer(label: timer.label, durationSeconds: timer.durationSeconds)) }
            return "Start a timer?"
        default:
            return "Do this?"
        }
    }

    /// Only step moves and timers are actionable from the coach (contract: next|back|jump_to_step|start_timer).
    var isSupported: Bool {
        switch command {
        case .next, .back: return true
        case .jumpToStep: return stepIndex != nil
        case .startTimer: return timer.map { (1...86_400).contains($0.durationSeconds) } ?? false
        default: return false
        }
    }
}

/// Control layout for the cooking screen by Dynamic Type size (PRD §14: accessibility sizes must
/// still fit Back / Next and keep the step text scrollable above the controls).
struct CookingLayout: Equatable {
    /// Back / Pause / Next in one row, or stacked.
    let stacksNavigation: Bool
    /// Repeat / Slower / Ask / Look columns: one floating row of 4 at regular sizes (brief 006),
    /// a 2×2 grid at accessibility sizes.
    let toolColumns: Int
    /// The controls scroll with the step instead of being pinned below it.
    let controlsScrollWithContent: Bool

    static func forSize(_ size: DynamicTypeSize) -> CookingLayout {
        size.isAccessibilitySize
            ? CookingLayout(stacksNavigation: true, toolColumns: 2, controlsScrollWithContent: true)
            : CookingLayout(stacksNavigation: false, toolColumns: 4, controlsScrollWithContent: false)
    }
}
