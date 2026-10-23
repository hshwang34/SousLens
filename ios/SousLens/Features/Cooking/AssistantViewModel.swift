import Foundation
import Observation

/// Assistant drawer (PRD §6, COOK-03/04, Appendix A): typed questions, grounded answers.
///
/// The coach never changes state. A `proposed_action` is rendered as a question button; only a
/// tap on it sends a (confirmed) command, through the cooking screen's command path.
@MainActor
@Observable
final class AssistantViewModel {
    struct Turn: Identifiable, Equatable {
        let id: UUID
        let query: String
        let response: AskResponse
        /// The server's `step_index` when the question was asked.
        let stepIndexAtAsk: Int
        var proposalUsed = false

        var segments: [AnswerSegment] { AnswerSegment.split(response.answerText) }
    }

    static let maxQueryLength = 500

    var query = "" {
        didSet {
            if query.count > Self.maxQueryLength { query = String(query.prefix(Self.maxQueryLength)) }
        }
    }
    private(set) var turns: [Turn] = []
    private(set) var isAsking = false
    private(set) var errorMessage: String?

    private let sessionId: UUID
    private let service: CookingService
    private let audio: any AudioOutput
    /// The cooking screen's canonical Session (for `grounded_revision`, badges and staleness).
    private let currentSession: @MainActor () -> CookingSession?
    /// Sends a tapped proposal as a confirmed command; returns true when the server accepted it.
    var onProposal: (@MainActor (ProposedAction) async -> Bool)?

    init(sessionId: UUID, service: CookingService, audio: any AudioOutput,
         currentSession: @escaping @MainActor () -> CookingSession?) {
        self.sessionId = sessionId
        self.service = service
        self.audio = audio
        self.currentSession = currentSession
    }

    var canAsk: Bool {
        !isAsking && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && currentSession() != nil
    }

    func ask() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking, let session = currentSession() else { return }
        isAsking = true
        errorMessage = nil
        defer { isAsking = false }
        do {
            let response = try await service.ask(sessionId: sessionId, query: text, groundedRevision: session.revision)
            turns.append(Turn(id: response.messageId, query: text, response: response, stepIndexAtAsk: session.stepIndex))
            query = ""
        } catch let error as APIError where error == .cancelled {
            return
        } catch let error as APIError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func message(for error: APIError) -> String {
        if error.isRateLimited {
            return "You’ve asked a lot this hour. Try again in a little while — the step on screen still has everything the recipe says."
        }
        if error.isTransportFailure {
            return "Can’t reach the coach right now. The step on screen still has everything the recipe says."
        }
        if let status = error.status, status >= 500 {
            return "The coach couldn’t answer right now. Try again, or follow the step on screen."
        }
        return error.userMessage
    }

    /// "Based on previous step": the server said so, or the step moved since the question.
    func isStale(_ turn: Turn) -> Bool {
        if turn.response.stale { return true }
        guard let session = currentSession() else { return false }
        return session.stepIndex != turn.stepIndexAtAsk
    }

    func badges(for turn: Turn) -> [GroundingBadge] {
        GroundingBadge.badges(for: turn.response.grounding, session: currentSession())
    }

    /// The proposal button, if the answer carries one the user hasn't used yet.
    func proposal(for turn: Turn) -> ProposedAction? {
        guard !turn.proposalUsed, let action = turn.response.proposedAction, action.isSupported else { return nil }
        // A stale proposal (the step already moved) is not offered.
        if isStale(turn) { return nil }
        return action
    }

    func proposalTitle(for turn: Turn) -> String? {
        proposal(for: turn)?.buttonTitle(stepsCount: currentSession()?.stepsCount)
    }

    /// The user tapped the proposal: that tap is the confirmation.
    func acceptProposal(turnId: UUID) async {
        guard let index = turns.firstIndex(where: { $0.id == turnId }),
              let action = proposal(for: turns[index]),
              let onProposal
        else { return }
        if await onProposal(action) {
            if let current = turns.firstIndex(where: { $0.id == turnId }) { turns[current].proposalUsed = true }
        }
    }

    func readAloud(turnId: UUID) async {
        guard let turn = turns.first(where: { $0.id == turnId }) else { return }
        await audio.speak(turn.response.answerText, pace: .normal)
    }
}
