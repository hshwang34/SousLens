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

/// Control layout for the cooking screen by Dynamic Type size (PRD §14, brief 013 Part C). The
/// control bar is pinned at every size and the step scrolls above it, so step text never runs
/// under the controls. At accessibility sizes Back drops its word (VoiceOver still says "Back")
/// so Tools, Back, Pause and Next keep fitting on one row, and the bar's chrome stops growing
/// at `chromeSizeLimit` while the step text keeps scaling.
struct CookingLayout: Equatable {
    /// Back shows only its chevron.
    let backIsIconOnly: Bool
    /// The offline bar shows its longer explanation line.
    let showsOfflineDetail: Bool

    /// Header and control bar stop scaling here, so they never crowd out the step at AX5.
    static let chromeSizeLimit: DynamicTypeSize = .accessibility2
    /// Landscape and iPad keep step lines to a comfortable measure.
    static let readableWidth: CGFloat = 720

    static func forSize(_ size: DynamicTypeSize) -> CookingLayout {
        size.isAccessibilitySize
            ? CookingLayout(backIsIconOnly: true, showsOfflineDetail: false)
            : CookingLayout(backIsIconOnly: false, showsOfflineDetail: true)
    }
}

/// What sits around the step on the calm cooking screen (brief 013 Part C, DECISIONS #23, PM
/// answer Q1 = A). Safety and allergy notices are always visible, solid, directly under the step,
/// collapsed to one row when there are several but never hidden or auto-dismissed. Swap tips
/// ("Not an exact match."), the creator's note and the "look for" cues fold into a notes chip.
/// Wording is passed through verbatim: nothing here rewrites a safety line (DECISIONS #15).
struct CookingNotices: Equatable {
    struct Notice: Equatable, Hashable, Identifiable {
        enum Kind: Equatable, Hashable { case allergy, safety }
        let kind: Kind
        let text: String
        var id: String { text }
    }

    struct Note: Equatable, Hashable, Identifiable {
        enum Kind: Equatable, Hashable { case swapTip, creatorNote, lookFor }
        let kind: Kind
        let text: String
        var id: String { "\(kind)·\(text)" }
    }

    /// Shown under the step, most important first (allergy > food safety: PRD §13 precedence).
    let inline: [Notice]
    /// Folded into the "n notes" chip and its sheet.
    let notes: [Note]

    static let empty = CookingNotices(inline: [], notes: [])

    /// The notices the collapsed row always shows in full: up to two. When both kinds exist, the
    /// first allergy line AND the first food-safety line, so a food-safety line is never hidden
    /// only because allergy lines sort first. Shown in their original order.
    var leadNotices: [Notice] {
        var picked: [Notice] = []
        if let allergy = inline.first(where: { $0.kind == .allergy }) { picked.append(allergy) }
        if let safety = inline.first(where: { $0.kind == .safety }) { picked.append(safety) }
        for notice in inline where picked.count < 2 && !picked.contains(notice) { picked.append(notice) }
        return inline.filter { picked.contains($0) }
    }
    var leadNotice: Notice? { leadNotices.first }
    /// How many more notices the collapsed row holds ("+2 more").
    var collapsedCount: Int { max(inline.count - leadNotices.count, 0) }
    var moreText: String? { collapsedCount > 0 ? "+\(collapsedCount) more" : nil }
    /// The row is an allergy row (danger colours) when any notice in it is about an allergy.
    var leadsWithAllergy: Bool { inline.contains { $0.kind == .allergy } }
    /// VoiceOver always hears every notice, collapsed or not, with the DECISIONS #15 prefix.
    var accessibilityLabel: String? {
        guard !inline.isEmpty else { return nil }
        return inline.map { "Safety warning: \($0.text)" }.joined(separator: " ")
    }

    var notesChipText: String? {
        switch notes.count {
        case 0: return nil
        case 1: return "1 note"
        default: return "\(notes.count) notes"
        }
    }

    static func make(stepWarnings: [String], cautions: [SwapCaution], creatorNote: String?,
                     successCues: [String]) -> CookingNotices {
        var inline: [Notice] = []
        var notes: [Note] = []
        var seen = Set<String>()
        func add(_ notice: Notice) {
            let text = notice.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { return }
            inline.append(Notice(kind: notice.kind, text: text))
        }
        func add(_ note: Note) {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { return }
            notes.append(Note(kind: note.kind, text: text))
        }
        // Allergy first: the swap's label check, worded as the badge always worded it.
        for warning in cautions.compactMap(\.allergyWarning) {
            add(Notice(kind: .allergy, text: "Check the label: \(warning)"))
        }
        // Then the step's own warnings (creator warnings and food-safety rules): always inline.
        for warning in stepWarnings { add(Notice(kind: .safety, text: warning)) }
        // Then the swaps' cautions: the safety notice always inline, risks by what they say.
        for caution in cautions {
            if let notice = caution.safetyNotice { add(Notice(kind: .safety, text: notice)) }
        }
        for risk in cautions.flatMap(\.risks) {
            if isFoldableTip(risk) {
                add(Note(kind: .swapTip, text: risk))
            } else {
                add(Notice(kind: mentionsAllergen(risk) ? .allergy : .safety, text: risk))
            }
        }
        if let creatorNote { add(Note(kind: .creatorNote, text: creatorNote)) }
        for cue in successCues { add(Note(kind: .lookFor, text: cue)) }
        // A notice outranks a duplicate note, and allergy outranks safety (stable within a kind).
        inline = inline.filter { $0.kind == .allergy } + inline.filter { $0.kind == .safety }
        return CookingNotices(inline: inline, notes: notes)
    }

    /// Swap risks are free text (vetted rules or the advisor) with no category, so the safe
    /// default is inline. A risk folds into the notes chip ONLY when it matches the short
    /// culinary-tip allow-list AND carries no safety signal at all. Anything unknown stays
    /// inline under the step.
    static func isFoldableTip(_ text: String) -> Bool {
        let lower = normalized(text)
        guard matchesTip(lower) else { return false }
        return !hasSafetySignal(lower)
    }

    /// The inverse, kept for callers and tests that ask the safety question directly.
    static func isSafetyLine(_ text: String) -> Bool { !isFoldableTip(text) }

    static func hasSafetySignal(_ text: String) -> Bool {
        let lower = normalized(text)
        if safetySignals.contains(where: { lower.contains($0) }) { return true }
        return safetyPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    private static func matchesTip(_ lower: String) -> Bool {
        if lower == "not an exact match." || lower == "not an exact match" { return true }
        return tipPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// Lowercased, curly apostrophes straightened.
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clearly culinary-only tips: taste, texture, colour/appearance, a pinch, burning, sweeter /
    /// saltier, "a little …".
    private static let tipPatterns = [
        #"\btast"#, #"\btextur"#, #"\bcolou?r"#, #"\bappearance\b"#, #"^add a pinch\b"#,
        #"^burns\b"#, #"\bslightly (sweeter|saltier)\b"#, #"\ba little\b"#,
    ]

    private static let safetySignals = [
        "contain", "contamin", "cross-", "allerg", "peanut", "shellfish", "fish", "sesame", "gluten",
        "wheat", "dairy", "milk", "cheese", "cream", "sulph", "sulfit", "anchov", "hour", "refriger",
        "reheat", "steaming", "pink", "wash hands", "wash your hands", "pickl", "preserv", "infant",
        "pregnan", "don't", "do not", "avoid", "never", "not suitable", "unsafe", "toxic", "danger",
    ]

    private static let safetyPatterns = [
        #"\braw\b"#, #"\beggs?\b"#, #"\bnuts?\b"#, #"\bsoy"#, #"\boats?\b"#,
        #"\bcan(s|ned|ning)?\b"#, #"\d+\s*(°|degrees?)?\s*[fc]\b"#,
    ]

    /// An allergen named together with a cue that it is about the allergen ("Contains soy.",
    /// "Still soy.", "check the label"): such notices use the allergy styling.
    static func mentionsAllergen(_ text: String) -> Bool {
        let lower = normalized(text)
        if lower.contains("allerg") || lower.contains("check the label") { return true }
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        guard !words.isDisjoint(with: allergenWords) else { return false }
        return allergenCues.contains { lower.contains($0) }
    }

    private static let allergenCues = ["contain", "still", "-free", " free", "trace", "same allergen", "may have"]

    private static let allergenWords: Set<String> = [
        "peanut", "peanuts", "nut", "nuts", "almond", "almonds", "cashew", "cashews", "walnut",
        "walnuts", "pecan", "pecans", "hazelnut", "hazelnuts", "pistachio", "pistachios", "milk",
        "dairy", "lactose", "cheese", "cream", "egg", "eggs", "soy", "soya", "wheat", "gluten",
        "barley", "rye", "oat", "oats", "sesame", "fish", "shellfish", "shrimp", "prawn", "prawns",
        "crab", "lobster", "mollusc", "molluscs", "anchovy", "anchovies", "celery", "mustard",
        "lupin", "sulfite", "sulfites", "sulphite", "sulphites", "coconut",
    ]
}

/// The small header pill that says the step text is adapted, or showing the recipe as written.
/// The Show original / Show adapted switch itself lives in the ⋯ menu.
struct AdaptedIndicator: Equatable {
    let text: String
    let accessibilityLabel: String
    let menuToggleTitle: String

    static func make(sourceLabel: String?, showingOriginal: Bool) -> AdaptedIndicator? {
        guard let sourceLabel else { return nil }
        return showingOriginal
            ? AdaptedIndicator(text: "Original", accessibilityLabel: "Showing the original recipe text",
                               menuToggleTitle: "Show adapted step")
            : AdaptedIndicator(text: "Adapted", accessibilityLabel: "Adapted · \(sourceLabel)",
                               menuToggleTitle: "Show original step")
    }
}
