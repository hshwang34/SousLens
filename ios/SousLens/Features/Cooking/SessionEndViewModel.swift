import Foundation
import Observation

/// Session end (J4 step 7, COOK-08): outcome, private note, optional "Save my changes".
/// **Done** sends the note and then `complete`; nothing is saved until that tap.
@MainActor
@Observable
final class SessionEndViewModel {
    static let maxNoteLength = 2000

    var result: OutcomeResult?
    var note = "" {
        didSet { if note.count > Self.maxNoteLength { note = String(note.prefix(Self.maxNoteLength)) } }
    }
    /// Off by default: saving a private variation is an explicit choice.
    var saveChanges = false
    private(set) var isFinishing = false

    private let cooking: CookingViewModel

    init(cooking: CookingViewModel) {
        self.cooking = cooking
    }

    var session: CookingSession? { cooking.session }
    var adaptations: [SessionAdaptation] { session?.adaptations ?? [] }
    /// "Save my changes" only makes sense when there are changes.
    var showsSaveChanges: Bool { !adaptations.isEmpty }
    var stepsSummary: String? {
        guard let session else { return nil }
        return "\(session.stepsCount) step\(session.stepsCount == 1 ? "" : "s") · \(session.recipe.title)"
    }
    var errorMessage: String? { cooking.errorMessage }
    var canFinish: Bool { result != nil && !isFinishing && cooking.canSendCommands }

    /// Returns true when the server confirmed the session is completed.
    func finish() async -> Bool {
        guard let result, canFinish else { return false }
        isFinishing = true
        defer { isFinishing = false }
        let ok = await cooking.complete(result: result, saveChanges: showsSaveChanges && saveChanges, note: note)
        return ok && cooking.session?.status == .completed
    }
}
