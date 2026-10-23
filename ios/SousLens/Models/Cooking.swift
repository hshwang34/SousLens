import Foundation

// Brief 005 DTOs (`docs/product/briefs/005-api-contract.md`), snake_case on the wire via
// `JSONCoding`. Unknown enum members decode to a conservative case instead of failing the payload.

// MARK: - Food preferences (SUB-02)

/// `GET/PUT /me/preferences`. Allergies are hard blocks on substitutions; "avoid" is a preference.
struct FoodPreferences: Codable, Sendable, Equatable {
    var allergies: [String]
    var avoid: [String]
    var updatedAt: Date?

    init(allergies: [String] = [], avoid: [String] = [], updatedAt: Date? = nil) {
        self.allergies = allergies
        self.avoid = avoid
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allergies = try container.decodeIfPresent([String].self, forKey: .allergies) ?? []
        avoid = try container.decodeIfPresent([String].self, forKey: .avoid) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// PUT body: the two lists only (`updated_at` is the server's).
    struct Update: Encodable, Equatable {
        let allergies: [String]
        let avoid: [String]
    }

    var update: Update { Update(allergies: allergies, avoid: avoid) }
}

// MARK: - Substitutions (SUB-01/02/05, PRD §8.4)

/// Where a swap came from. Anything that is not the vetted seed table is labelled as AI (§13.4).
enum SwapSource: String, Codable, Sendable, Hashable {
    case rule
    case ai

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SwapSource(rawValue: raw) ?? .ai
    }

    /// PRD §13.4 / DECISIONS #14.
    var label: String {
        switch self {
        case .rule: return "Common swap"
        case .ai: return "AI suggested adaptation"
        }
    }
}

/// Qualitative only (PRD §13.4: confidence is not a calibrated number).
enum QualitativeLevel: String, Codable, Sendable, Hashable {
    case high, medium, low

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QualitativeLevel(rawValue: raw) ?? .low
    }
}

struct AdjustedStep: Codable, Sendable, Hashable {
    let stepId: String
    let instruction: String
}

struct SubstitutionSuggestion: Codable, Sendable, Hashable, Identifiable {
    let suggestionId: UUID
    let source: SwapSource
    let candidate: String
    let kind: String
    let ratioOrAmount: String?
    let rationale: String?
    let impactFlavor: String?
    let impactTexture: String?
    let adjustedSteps: [AdjustedStep]
    let confidence: QualitativeLevel
    let risks: [String]
    let allergyWarning: String?
    let requiresUserConfirmation: Bool

    var id: UUID { suggestionId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestionId = try c.decode(UUID.self, forKey: .suggestionId)
        source = try c.decodeIfPresent(SwapSource.self, forKey: .source) ?? .ai
        candidate = try c.decode(String.self, forKey: .candidate)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "flavor_adaptation"
        ratioOrAmount = try c.decodeIfPresent(String.self, forKey: .ratioOrAmount)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
        impactFlavor = try c.decodeIfPresent(String.self, forKey: .impactFlavor)
        impactTexture = try c.decodeIfPresent(String.self, forKey: .impactTexture)
        adjustedSteps = try c.decodeIfPresent([AdjustedStep].self, forKey: .adjustedSteps) ?? []
        confidence = try c.decodeIfPresent(QualitativeLevel.self, forKey: .confidence) ?? .low
        risks = try c.decodeIfPresent([String].self, forKey: .risks) ?? []
        allergyWarning = try c.decodeIfPresent(String.self, forKey: .allergyWarning)
        // Every swap needs approval regardless of what the payload says (SUB-03).
        requiresUserConfirmation = try c.decodeIfPresent(Bool.self, forKey: .requiresUserConfirmation) ?? true
    }
}

struct SubstitutionRequest: Encodable, Sendable, Equatable {
    let recipeVersionId: UUID
    let ingredientRef: String
}

struct SubstitutionResult: Codable, Sendable, Equatable {
    let recipeVersionId: UUID
    let ingredientRef: String
    let targetIngredient: String
    let suggestions: [SubstitutionSuggestion]
    let cannotSubstitute: Bool
    let reason: String?
    let safetyNotice: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipeVersionId = try c.decode(UUID.self, forKey: .recipeVersionId)
        ingredientRef = try c.decode(String.self, forKey: .ingredientRef)
        targetIngredient = try c.decode(String.self, forKey: .targetIngredient)
        suggestions = try c.decodeIfPresent([SubstitutionSuggestion].self, forKey: .suggestions) ?? []
        cannotSubstitute = try c.decodeIfPresent(Bool.self, forKey: .cannotSubstitute) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        safetyNotice = try c.decodeIfPresent(String.self, forKey: .safetyNotice)
    }
}

/// One adaptation as sent in `POST /sessions` and `approve_adaptation`: either a suggestion id
/// from `/substitutions/suggest`, or an explicit replacement (a reused private variation).
struct AdaptationInput: Codable, Sendable, Hashable {
    let ingredientRef: String
    var suggestionId: UUID? = nil
    var replacement: String? = nil
    var ratioOrAmount: String? = nil
    var source: SwapSource? = nil
    var reason: String? = nil

    static func suggestion(_ id: UUID, ingredientRef: String) -> AdaptationInput {
        AdaptationInput(ingredientRef: ingredientRef, suggestionId: id)
    }
}

// MARK: - Sessions (COOK-01..08, PRD §8.6, §10.3)

enum SessionStatus: String, Codable, Sendable, Hashable {
    case created, active, paused, completed, abandoned

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // An unknown status is treated as ended: the app never drives a session it can't read.
        self = SessionStatus(rawValue: raw) ?? .abandoned
    }

    /// Still resumable (the `?status=active` filter: created / active / paused).
    var isOpen: Bool { self == .created || self == .active || self == .paused }
}

struct SessionAdaptation: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let ingredientRef: String
    let original: String
    let replacement: String
    let ratioOrAmount: String?
    let source: SwapSource
    let label: String?
    let reason: String?
    let approvedAt: Date?

    /// Derived from `source`, never from free text, so an AI swap can't be shown as a vetted one.
    var displayLabel: String { source.label }
}

struct SuggestedTimer: Codable, Sendable, Hashable {
    let label: String
    let durationSeconds: Int
}

struct SessionStep: Codable, Sendable, Hashable, Identifiable {
    let stepId: String
    let order: Int
    let instruction: String
    let originalInstruction: String
    let adapted: Bool
    let adaptationIds: [UUID]
    let suggestedTimer: SuggestedTimer?

    var id: String { stepId }

    init(stepId: String, order: Int, instruction: String, originalInstruction: String,
         adapted: Bool, adaptationIds: [UUID], suggestedTimer: SuggestedTimer?) {
        self.stepId = stepId
        self.order = order
        self.instruction = instruction
        self.originalInstruction = originalInstruction
        self.adapted = adapted
        self.adaptationIds = adaptationIds
        self.suggestedTimer = suggestedTimer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stepId = try c.decode(String.self, forKey: .stepId)
        order = try c.decode(Int.self, forKey: .order)
        instruction = try c.decode(String.self, forKey: .instruction)
        originalInstruction = try c.decodeIfPresent(String.self, forKey: .originalInstruction) ?? instruction
        adapted = try c.decodeIfPresent(Bool.self, forKey: .adapted) ?? false
        adaptationIds = try c.decodeIfPresent([UUID].self, forKey: .adaptationIds) ?? []
        suggestedTimer = try c.decodeIfPresent(SuggestedTimer.self, forKey: .suggestedTimer)
    }
}

enum TimerStatus: String, Codable, Sendable, Hashable {
    case running, done, cancelled

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TimerStatus(rawValue: raw) ?? .cancelled
    }
}

struct SessionTimer: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let stepIndex: Int?
    let label: String
    /// Absolute (COOK-06): the countdown is always `targetAt - now`, so it survives relaunch.
    let targetAt: Date
    let status: TimerStatus
}

struct SessionNote: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
}

enum OutcomeResult: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case cooked
    case partly
    case didntWork = "didnt_work"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cooked: return "Cooked it"
        case .partly: return "Partly"
        case .didntWork: return "Didn’t work"
        }
    }
}

struct SessionOutcome: Codable, Sendable, Hashable {
    let result: OutcomeResult
    let savedChanges: Bool?
}

struct PantrySnapshotItem: Codable, Sendable, Hashable {
    let pantryItemId: UUID?
    let normalizedName: String
}

/// The canonical session. The app renders exactly this; it never edits `stepIndex` itself.
struct CookingSession: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let recipeVersionId: UUID
    let recipeId: UUID
    let status: SessionStatus
    let stepIndex: Int
    let stepsCount: Int
    let revision: Int
    let recipe: RecipeDetail
    let adaptations: [SessionAdaptation]
    let steps: [SessionStep]
    let timers: [SessionTimer]
    let notes: [SessionNote]
    let outcome: SessionOutcome?
    let pantrySnapshot: [PantrySnapshotItem]
    let startedAt: Date?
    let endedAt: Date?
    let updatedAt: Date

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        recipeVersionId = try c.decode(UUID.self, forKey: .recipeVersionId)
        recipeId = try c.decode(UUID.self, forKey: .recipeId)
        status = try c.decode(SessionStatus.self, forKey: .status)
        stepIndex = try c.decode(Int.self, forKey: .stepIndex)
        stepsCount = try c.decode(Int.self, forKey: .stepsCount)
        revision = try c.decode(Int.self, forKey: .revision)
        recipe = try c.decode(RecipeDetail.self, forKey: .recipe)
        adaptations = try c.decodeIfPresent([SessionAdaptation].self, forKey: .adaptations) ?? []
        steps = (try c.decodeIfPresent([SessionStep].self, forKey: .steps) ?? []).sorted { $0.order < $1.order }
        timers = try c.decodeIfPresent([SessionTimer].self, forKey: .timers) ?? []
        notes = try c.decodeIfPresent([SessionNote].self, forKey: .notes) ?? []
        outcome = try c.decodeIfPresent(SessionOutcome.self, forKey: .outcome)
        pantrySnapshot = try c.decodeIfPresent([PantrySnapshotItem].self, forKey: .pantrySnapshot) ?? []
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// The step the server says is current. Falls back to the pinned recipe's text if the session
    /// view is missing a step (never invents one).
    var currentStep: SessionStep? {
        if steps.indices.contains(stepIndex) { return steps[stepIndex] }
        let ordered = recipe.orderedSteps
        guard ordered.indices.contains(stepIndex) else { return nil }
        let step = ordered[stepIndex]
        return SessionStep(stepId: step.id, order: step.order, instruction: step.instruction,
                           originalInstruction: step.instruction, adapted: false, adaptationIds: [], suggestedTimer: nil)
    }

    /// Cues, warnings and creator note for the current step come from the pinned recipe version.
    var currentRecipeStep: RecipeStep? {
        guard let stepId = currentStep?.stepId else { return nil }
        return recipe.steps.first { $0.id == stepId }
    }

    var isLastStep: Bool { stepIndex >= stepsCount - 1 }

    func summary() -> SessionSummary {
        SessionSummary(id: id, recipeVersionId: recipeVersionId, recipeId: recipeId, title: recipe.title,
                       status: status, stepIndex: stepIndex, stepsCount: stepsCount, updatedAt: updatedAt)
    }
}

/// `GET /sessions?status=active` item (resume banner).
struct SessionSummary: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let recipeVersionId: UUID
    let recipeId: UUID
    let title: String
    let status: SessionStatus
    let stepIndex: Int
    let stepsCount: Int
    let updatedAt: Date
}

struct CreateSessionRequest: Encodable, Sendable, Equatable {
    let recipeVersionId: UUID
    let adaptations: [AdaptationInput]
}

// MARK: - Commands (§11.1)

enum SessionCommandKind: String, Codable, Sendable, Hashable {
    case start, next, back, pause, resume, complete, abandon
    case jumpToStep = "jump_to_step"
    case approveAdaptation = "approve_adaptation"
    case revertAdaptation = "revert_adaptation"
    case startTimer = "start_timer"
    case cancelTimer = "cancel_timer"
}

enum CommandSource: String, Codable, Sendable, Hashable {
    case iosButton = "ios_button"
    case iosVoice = "ios_voice"
    case iosAssistant = "ios_assistant"
}

struct TimerRequest: Codable, Sendable, Hashable {
    let label: String
    let durationSeconds: Int
}

struct OutcomeInput: Codable, Sendable, Hashable {
    let result: OutcomeResult
    let saveChanges: Bool
}

/// The command body. Built only from an explicit user action, so `userConfirmed` is always true.
struct SessionCommand: Codable, Sendable, Hashable {
    let command: SessionCommandKind
    let expectedRevision: Int
    let userConfirmed: Bool
    let clientSource: CommandSource
    var stepIndex: Int? = nil
    var adaptation: AdaptationInput? = nil
    var adaptationId: UUID? = nil
    var timer: TimerRequest? = nil
    var timerId: UUID? = nil
    var outcome: OutcomeInput? = nil

    /// A user-confirmed command. There is deliberately no initializer that sends `false`.
    static func confirmed(_ command: SessionCommandKind, revision: Int, source: CommandSource = .iosButton) -> SessionCommand {
        SessionCommand(command: command, expectedRevision: revision, userConfirmed: true, clientSource: source)
    }
}

// MARK: - Ask (COOK-03/04, Appendix A)

struct AskRequest: Encodable, Sendable, Equatable {
    let query: String
    let groundedRevision: Int
}

struct GroundingRef: Codable, Sendable, Hashable {
    let type: String
    let id: String
}

struct ProposedAction: Codable, Sendable, Hashable {
    let command: SessionCommandKind
    let stepIndex: Int?
    let timer: TimerRequest?
}

struct AskResponse: Codable, Sendable, Hashable {
    let messageId: UUID
    let answerText: String
    let grounding: [GroundingRef]
    let groundedSessionRevision: Int
    let stale: Bool
    let uncertainty: QualitativeLevel
    let safetyNotice: String?
    let proposedAction: ProposedAction?
    let requiresConfirmation: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(UUID.self, forKey: .messageId)
        answerText = try c.decode(String.self, forKey: .answerText)
        grounding = try c.decodeIfPresent([GroundingRef].self, forKey: .grounding) ?? []
        groundedSessionRevision = try c.decode(Int.self, forKey: .groundedSessionRevision)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        uncertainty = try c.decodeIfPresent(QualitativeLevel.self, forKey: .uncertainty) ?? .high
        safetyNotice = try c.decodeIfPresent(String.self, forKey: .safetyNotice)
        // A proposal for a command the app doesn't know is dropped, not guessed at.
        proposedAction = try? c.decodeIfPresent(ProposedAction.self, forKey: .proposedAction)
        requiresConfirmation = try c.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? true
    }
}

struct NoteRequest: Encodable, Sendable, Equatable {
    let text: String
}

// MARK: - Private variation (COOK-08)

/// CONTRACT GUESS: the brief shows `{"adaptations": [...]}` without the element shape; we read the
/// Session adaptation shape leniently (only `ingredient_ref` + `replacement` are required).
struct VariationAdaptation: Codable, Sendable, Hashable {
    let ingredientRef: String
    let original: String?
    let replacement: String
    let ratioOrAmount: String?
    let source: SwapSource
    let reason: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ingredientRef = try c.decode(String.self, forKey: .ingredientRef)
        original = try c.decodeIfPresent(String.self, forKey: .original)
        replacement = try c.decode(String.self, forKey: .replacement)
        ratioOrAmount = try c.decodeIfPresent(String.self, forKey: .ratioOrAmount)
        source = try c.decodeIfPresent(SwapSource.self, forKey: .source) ?? .ai
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    var input: AdaptationInput {
        AdaptationInput(ingredientRef: ingredientRef, replacement: replacement, ratioOrAmount: ratioOrAmount,
                        source: source, reason: reason)
    }
}

struct PrivateVariation: Codable, Sendable, Equatable {
    let adaptations: [VariationAdaptation]
    let savedAt: Date?
}

// MARK: - Error details

extension APIError {
    var errorCode: String? {
        if case .server(_, let code, _, _, _, _) = self { return code }
        return nil
    }

    /// `409 STATE_CONFLICT` / `409 INVALID_TRANSITION` carry the latest Session in `details.session`.
    var latestSession: CookingSession? {
        guard case .server(_, _, _, _, _, let details) = self,
              let session = details?["session"],
              let data = try? JSONEncoder().encode(session)
        else { return nil }
        return try? JSONCoding.makeDecoder().decode(CookingSession.self, from: data)
    }

    var isStateConflict: Bool { errorCode == "STATE_CONFLICT" }
    var isInvalidTransition: Bool { errorCode == "INVALID_TRANSITION" }
    var isConfirmationRequired: Bool { errorCode == "CONFIRMATION_REQUIRED" }
    var isNotFound: Bool { status == 404 }
}
