import Foundation
import Observation

/// Session end (J4 step 7, COOK-08): outcome, private note, optional "Save my changes".
/// **Done** sends the note and then `complete`; nothing is saved until that tap.
/// What the user has entered on Session end so far.
struct SessionEndDraft: Equatable {
    var result: OutcomeResult?
    var note = ""
    var saveChanges = false
}

@MainActor
@Observable
final class SessionEndViewModel {
    static let maxNoteLength = 2000

    // The draft lives on the cooking model so an offline failure (sheet closed, retried later)
    // never loses it.
    var result: OutcomeResult? {
        get { cooking.endDraft.result }
        set { cooking.endDraft.result = newValue }
    }
    var note: String {
        get { cooking.endDraft.note }
        set { cooking.endDraft.note = newValue.count > Self.maxNoteLength ? String(newValue.prefix(Self.maxNoteLength)) : newValue }
    }
    /// Off by default: saving a private variation is an explicit choice.
    var saveChanges: Bool {
        get { cooking.endDraft.saveChanges }
        set { cooking.endDraft.saveChanges = newValue }
    }
    private(set) var isFinishing = false

    private let cooking: CookingViewModel

    init(cooking: CookingViewModel) {
        self.cooking = cooking
    }

    var session: CookingSession? { cooking.session }
    var adaptations: [SessionAdaptation] { session?.adaptations ?? [] }
    /// "Save my changes" only makes sense when there are changes.
    var showsSaveChanges: Bool { !adaptations.isEmpty }
    /// A swap that conflicts with the user's allergies is never saved for next time: undo it first.
    var hasAllergyConflict: Bool { adaptations.contains(where: \.conflictsWithAllergies) }
    var canSaveChanges: Bool { showsSaveChanges && !hasAllergyConflict }
    var stepsSummary: String? {
        guard let session else { return nil }
        return "\(session.stepsCount) step\(session.stepsCount == 1 ? "" : "s") · \(session.recipe.title)"
    }
    var errorMessage: String? { cooking.errorMessage }
    /// Offline inside the sheet: offer Reconnect right here.
    var showsReconnect: Bool { cooking.isOffline }
    var isReconnecting: Bool { cooking.isSending }

    func reconnect() async {
        await cooking.reconnect()
    }
    var canFinish: Bool { result != nil && !isFinishing && cooking.canSendCommands }

    /// Returns true when the server confirmed the session is completed.
    func finish() async -> Bool {
        guard let result, canFinish else { return false }
        isFinishing = true
        defer { isFinishing = false }
        let ok = await cooking.complete(result: result, saveChanges: canSaveChanges && saveChanges, note: note)
        return ok && cooking.session?.status == .completed
    }
}
