import Foundation
import XCTest
@testable import SousLens

/// Inline JSON matching `docs/product/briefs/005-api-contract.md` field for field.
enum CookingFixtures {
    static let sessionId = "7e1f0c2a-4b3d-4e5f-8a9b-0c1d2e3f5001"
    static let otherSessionId = "7e1f0c2a-4b3d-4e5f-8a9b-0c1d2e3f5002"
    static let versionId = "383cfbdd-6896-5db0-89e0-a539f6bbdd0e"
    static let recipeId = "a185d1a4-2726-57b9-9b17-069262cbf492"
    static let adaptationId = "aa000000-0000-4000-8000-000000000001"
    static let suggestionRuleId = "5b000000-0000-4000-8000-000000000001"
    static let suggestionAiId = "5b000000-0000-4000-8000-000000000002"
    static let timerId = "70000000-0000-4000-8000-000000000001"
    static let messageId = "3e000000-0000-4000-8000-000000000001"

    static var sessionUUID: UUID { UUID(uuidString: sessionId)! } // swiftlint:disable:this force_unwrapping
    static var versionUUID: UUID { UUID(uuidString: versionId)! } // swiftlint:disable:this force_unwrapping

    static func recipeJSON() throws -> String {
        String(decoding: try Fixtures.data("recipe_detail"), as: UTF8.self)
    }

    struct TimerSpec {
        var id = CookingFixtures.timerId
        var stepIndex = 2
        var label = "Simmer"
        var targetAt: String
        var status = "running"
    }

    /// Step 1 (index 0) is adapted by a rule swap when `adapted`; step 3 (index 2) suggests a timer.
    static func sessionJSON(id: String = sessionId, status: String = "active", stepIndex: Int = 0, revision: Int = 1,
                            adapted: Bool = true, source: String = "rule", timers: [TimerSpec] = [],
                            outcome: String = "null") throws -> String {
        let recipe = try recipeJSON()
        let instructions = [
            "Make the marinade: whisk the gochujang, soy sauce, honey, sesame oil, garlic, ginger and rice vinegar.",
            "Add the chicken and toss until coated.",
            "Heat the oil and sear the chicken.",
            "Turn the pieces.",
            "Glaze with the remaining marinade.",
            "Rest the chicken.",
            "Serve with scallions.",
        ]
        let steps = instructions.enumerated().map { index, text -> String in
            let isAdapted = adapted && index == 0
            let instruction = isAdapted ? "Make the marinade: whisk the gochujang, soy sauce, honey, sesame oil, garlic, ginger and 1 tbsp lemon juice + 1/2 tsp sugar." : text
            let timer = index == 2 ? #"{"label":"Simmer","duration_seconds":600}"# : "null"
            return """
            {"step_id":"step-\(index + 1)","order":\(index),"instruction":"\(instruction)","original_instruction":"\(text)",
             "adapted":\(isAdapted),"adaptation_ids":\(isAdapted ? "[\"\(adaptationId)\"]" : "[]"),"suggested_timer":\(timer)}
            """
        }.joined(separator: ",")
        let label = source == "rule" ? "Common swap" : "AI suggested adaptation"
        let adaptations = adapted ? """
        [{"id":"\(adaptationId)","ingredient_ref":"ing-8","original":"rice vinegar","replacement":"lemon juice + a pinch of sugar",
          "ratio_or_amount":"1 tbsp lemon juice + 1/2 tsp sugar","source":"\(source)","label":"\(label)",
          "reason":"rice vinegar unavailable","approved_at":"2026-10-23T10:00:00Z"}]
        """ : "[]"
        let timersJSON = timers.map {
            #"{"id":"\#($0.id)","step_index":\#($0.stepIndex),"label":"\#($0.label)","target_at":"\#($0.targetAt)","status":"\#($0.status)"}"#
        }.joined(separator: ",")
        return """
        {"id":"\(id)","recipe_version_id":"\(versionId)","recipe_id":"\(recipeId)",
         "status":"\(status)","step_index":\(stepIndex),"steps_count":7,"revision":\(revision),
         "recipe":\(recipe),
         "adaptations":\(adaptations),
         "steps":[\(steps)],
         "timers":[\(timersJSON)],
         "notes":[],
         "outcome":\(outcome),
         "pantry_snapshot":[{"pantry_item_id":"0b6f3f3e-2c1a-4b7e-9a51-0d3c9f0a1111","normalized_name":"gochujang"}],
         "started_at":"2026-10-23T10:00:00Z","ended_at":null,"updated_at":"2026-10-23T10:05:00.123456Z"}
        """
    }

    static func session(id: String = sessionId, status: String = "active", stepIndex: Int = 0, revision: Int = 1,
                        adapted: Bool = true, source: String = "rule", timers: [TimerSpec] = []) throws -> CookingSession {
        try decode(CookingSession.self, sessionJSON(id: id, status: status, stepIndex: stepIndex, revision: revision,
                                                     adapted: adapted, source: source, timers: timers))
    }

    static func summaryJSON(id: String = sessionId, status: String = "active", stepIndex: Int = 2) -> String {
        """
        {"id":"\(id)","recipe_version_id":"\(versionId)","recipe_id":"\(recipeId)","title":"Gochujang Chicken Thighs",
         "status":"\(status)","step_index":\(stepIndex),"steps_count":7,"updated_at":"2026-10-23T10:05:00.123456Z"}
        """
    }

    static let substitutionsJSON = """
    {"recipe_version_id":"\(versionId)","ingredient_ref":"ing-8","target_ingredient":"rice vinegar",
     "suggestions":[
       {"suggestion_id":"\(suggestionRuleId)","source":"rule","candidate":"lemon juice + a pinch of sugar",
        "kind":"close_equivalent","ratio_or_amount":"1 tbsp lemon juice + 1/2 tsp sugar",
        "rationale":"Both bring bright acidity to the marinade.","impact_flavor":"Slightly more citrusy.",
        "impact_texture":"No change.","adjusted_steps":[{"step_id":"step-1","instruction":"…lemon juice…"}],
        "confidence":"high","risks":["A little sharper; add the sugar."],"allergy_warning":null,
        "requires_user_confirmation":true},
       {"suggestion_id":"\(suggestionAiId)","source":"ai","candidate":"apple cider vinegar",
        "kind":"flavor_adaptation","ratio_or_amount":"1 tbsp","rationale":"Similar acidity.",
        "impact_flavor":"Fruitier.","impact_texture":"No change.","adjusted_steps":[],
        "confidence":"medium","risks":[],"allergy_warning":"Contains sulfites, which overlap a sensitivity you listed. Check the label.",
        "requires_user_confirmation":true}
     ],
     "cannot_substitute":false,"reason":null,"safety_notice":null}
    """

    static let cannotSubstituteJSON = """
    {"recipe_version_id":"\(versionId)","ingredient_ref":"ing-1","target_ingredient":"boneless skinless chicken thighs",
     "suggestions":[],"cannot_substitute":true,
     "reason":"The chicken is the dish; there’s no swap we can stand behind.","safety_notice":"This recipe contains sesame, one of your allergies."}
    """

    static func askJSON(revision: Int = 1, stale: Bool = false, proposed: String = "null", safety: String = "null",
                        grounding: String = #"[{"type":"recipe_step","id":"step-1"},{"type":"creator_note","id":"step-1"}]"#) -> String {
        """
        {"message_id":"\(messageId)","answer_text":"The recipe says whisk until smooth. My suggestion: use a fork if you have no whisk.",
         "grounding":\(grounding),"grounded_session_revision":\(revision),"stale":\(stale),
         "uncertainty":"low","safety_notice":\(safety),"proposed_action":\(proposed),"requires_confirmation":\(proposed != "null")}
        """
    }

    static func errorJSON(code: String, message: String, details: String? = nil) -> String {
        let detailsPart = details.map { #","details":\#($0)"# } ?? ""
        return #"{"error":{"code":"\#(code)","message":"\#(message)","retryable":false,"correlation_id":"c-\#(code)"\#(detailsPart)}}"#
    }

    /// The `APIError` the client would throw for this envelope.
    static func apiError(status: Int, code: String, message: String = "nope", details: String? = nil) throws -> APIError {
        let envelope = try decode(APIErrorEnvelope.self, errorJSON(code: code, message: message, details: details))
        return .server(status: status, code: envelope.error.code, message: envelope.error.message,
                       retryable: envelope.error.retryable, correlationId: envelope.error.correlationId, details: envelope.error.details)
    }

    static func conflict(latest: String, code: String = "STATE_CONFLICT") throws -> APIError {
        try apiError(status: 409, code: code, message: "Session changed.", details: #"{"session":\#(latest)}"#)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: Data(json.utf8))
    }
}

/// Scriptable `CookingService` + `PreferencesService`.
final class FakeCookingService: CookingService, PreferencesService, @unchecked Sendable {
    enum Call: Equatable {
        case suggest(UUID, String)
        case create(UUID, [AdaptationInput])
        case active
        case session(UUID)
        case delete(UUID)
        case command(SessionCommand, key: String)
        case ask(String, Int)
        case note(String)
        case variation(UUID)
        case deleteVariation(UUID)
        case preferences
        case updatePreferences(FoodPreferences.Update)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }

    var commands: [(SessionCommand, String)] {
        calls.compactMap { if case .command(let command, let key) = $0 { return (command, key) } else { return nil } }
    }

    static let unscripted = APIError.http(status: 599, correlationId: "unscripted")

    var suggestHandler: @Sendable (UUID, String) throws -> SubstitutionResult = { _, _ in throw unscripted }
    var createHandler: @Sendable (UUID, [AdaptationInput]) throws -> CookingSession = { _, _ in throw unscripted }
    var activeHandler: @Sendable () throws -> [SessionSummary] = { [] }
    var sessionHandler: @Sendable (UUID) throws -> CookingSession = { _ in throw unscripted }
    var commandHandler: @Sendable (SessionCommand, String) throws -> CookingSession = { _, _ in throw unscripted }
    var askHandler: @Sendable (String, Int) throws -> AskResponse = { _, _ in throw unscripted }
    var noteHandler: @Sendable (String) throws -> SessionNote = { text in
        SessionNote(id: UUID(), text: text, createdAt: Date())
    }
    var variationHandler: @Sendable (UUID) throws -> PrivateVariation? = { _ in nil }
    var preferencesHandler: @Sendable () throws -> FoodPreferences = { FoodPreferences() }
    var updatePreferencesHandler: @Sendable (FoodPreferences) throws -> FoodPreferences = { $0 }

    func suggestSubstitutions(recipeVersionId: UUID, ingredientRef: String) async throws -> SubstitutionResult {
        record(.suggest(recipeVersionId, ingredientRef)); return try suggestHandler(recipeVersionId, ingredientRef)
    }
    func createSession(recipeVersionId: UUID, adaptations: [AdaptationInput]) async throws -> CookingSession {
        record(.create(recipeVersionId, adaptations)); return try createHandler(recipeVersionId, adaptations)
    }
    func activeSessions() async throws -> [SessionSummary] { record(.active); return try activeHandler() }
    func session(id: UUID) async throws -> CookingSession { record(.session(id)); return try sessionHandler(id) }
    func deleteSession(id: UUID) async throws { record(.delete(id)) }
    func sendCommand(sessionId: UUID, _ command: SessionCommand, idempotencyKey: String) async throws -> CookingSession {
        record(.command(command, key: idempotencyKey)); return try commandHandler(command, idempotencyKey)
    }
    func ask(sessionId: UUID, query: String, groundedRevision: Int) async throws -> AskResponse {
        record(.ask(query, groundedRevision)); return try askHandler(query, groundedRevision)
    }
    func addNote(sessionId: UUID, text: String) async throws -> SessionNote { record(.note(text)); return try noteHandler(text) }
    func myVariation(recipeVersionId: UUID) async throws -> PrivateVariation? {
        record(.variation(recipeVersionId)); return try variationHandler(recipeVersionId)
    }
    func deleteMyVariation(recipeVersionId: UUID) async throws { record(.deleteVariation(recipeVersionId)) }
    func preferences() async throws -> FoodPreferences { record(.preferences); return try preferencesHandler() }
    func updatePreferences(_ preferences: FoodPreferences) async throws -> FoodPreferences {
        record(.updatePreferences(preferences.update)); return try updatePreferencesHandler(preferences)
    }
}

/// A tiny Step Oracle for view-model tests: applies commands like the contract says (revision
/// check, idempotency by key, boundaries) and answers with fixture Sessions.
final class FakeOracle: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var status = "active"
    private(set) var stepIndex = 0
    private(set) var revision = 1
    private(set) var timers: [CookingFixtures.TimerSpec] = []
    private(set) var adapted = true
    private var seenKeys: [String: CookingSession] = [:]
    let now: @Sendable () -> Date
    private(set) var appliedCount = 0

    init(status: String = "active", stepIndex: Int = 0, revision: Int = 1, now: @escaping @Sendable () -> Date = { Date() }) {
        self.status = status
        self.stepIndex = stepIndex
        self.revision = revision
        self.now = now
    }

    func current() throws -> CookingSession {
        try lock.withLock { try snapshot() }
    }

    private func snapshot() throws -> CookingSession {
        try CookingFixtures.session(status: status, stepIndex: stepIndex, revision: revision, adapted: adapted, timers: timers)
    }

    /// Another device moved the session on.
    func externalNext() {
        lock.withLock { stepIndex += 1; revision += 1 }
    }

    func apply(_ command: SessionCommand, key: String) throws -> CookingSession {
        try lock.withLock {
            if let replay = seenKeys[key] { return replay }
            guard command.userConfirmed else {
                throw try CookingFixtures.apiError(status: 422, code: "CONFIRMATION_REQUIRED")
            }
            guard command.expectedRevision == revision else {
                throw try CookingFixtures.conflict(latest: CookingFixtures.sessionJSON(status: status, stepIndex: stepIndex, revision: revision, adapted: adapted))
            }
            var changed = true
            switch command.command {
            case .start: status = "active"; stepIndex = 0
            case .next:
                guard status == "active", stepIndex < 6 else {
                    throw try CookingFixtures.conflict(latest: CookingFixtures.sessionJSON(status: status, stepIndex: stepIndex, revision: revision, adapted: adapted), code: "INVALID_TRANSITION")
                }
                stepIndex += 1
            case .back: if stepIndex > 0 { stepIndex -= 1 } else { changed = false }
            case .pause: status = "paused"
            case .resume: status = "active"
            case .complete: status = "completed"
            case .abandon: status = "abandoned"
            case .startTimer:
                let target = now().addingTimeInterval(TimeInterval(command.timer?.durationSeconds ?? 0))
                timers.append(.init(stepIndex: stepIndex, label: command.timer?.label ?? "", targetAt: ISO8601DateFormatter().string(from: target)))
            case .cancelTimer:
                timers = timers.map { var t = $0; if t.id == command.timerId?.uuidString.lowercased() { t.status = "cancelled" }; return t }
            case .revertAdaptation: adapted = false
            case .jumpToStep: stepIndex = command.stepIndex ?? stepIndex
            case .approveAdaptation: adapted = true
            }
            if changed { revision += 1; appliedCount += 1 }
            let result = try snapshot()
            seenKeys[key] = result
            return result
        }
    }
}

/// Sequential keys so tests can assert exactly which key went with which tap.
@MainActor
final class KeyMinter {
    private(set) var minted: [String] = []
    func next() -> String {
        let key = "key-\(minted.count + 1)"
        minted.append(key)
        return key
    }
}
