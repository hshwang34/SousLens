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
    // While a Done is unconfirmed its body is fixed (the same key must carry the same body), so
    // edits are refused until it is confirmed or discarded.
    var result: OutcomeResult? {
        get { cooking.endDraft.result }
        set { if !editsLocked { cooking.endDraft.result = newValue } }
    }
    var note: String {
        get { cooking.endDraft.note }
        set {
            guard !editsLocked else { return }
            cooking.endDraft.note = newValue.count > Self.maxNoteLength ? String(newValue.prefix(Self.maxNoteLength)) : newValue
        }
    }
    /// Off by default: saving a private variation is an explicit choice.
    var saveChanges: Bool {
        get { cooking.endDraft.saveChanges }
        set { if !editsLocked { cooking.endDraft.saveChanges = newValue } }
    }

    var editsLocked: Bool { cooking.isCompletePending }
    static let lockedMessage = "Your Done hasn’t been confirmed yet, so it can’t be changed. Reconnect to send it, or discard it to edit."

    /// The same "Send it again / Discard" choice as the cooking screen's offline banner.
    var asksToResendStaleTap: Bool { cooking.asksToResendStaleTap }
    var pendingTapText: String? { cooking.pendingTapText }

    func resendStaleTap() async { await cooking.resendStaleTap() }
    func discardStaleTap() async { await cooking.discardStaleTap() }
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
    var canFinish: Bool { result != nil && !isFinishing && (cooking.canSendCommands || (editsLocked && !cooking.isSending)) }

    /// Returns true when the server confirmed the session is completed.
    func finish() async -> Bool {
        // A Done is already waiting: re-send that exact one (or ask, if it's stale) — never a second.
        if editsLocked {
            isFinishing = true
            defer { isFinishing = false }
            await cooking.reconnect()
            return cooking.session?.status == .completed
        }
        guard let result, canFinish else { return false }
        isFinishing = true
        defer { isFinishing = false }
        let ok = await cooking.complete(result: result, saveChanges: canSaveChanges && saveChanges, note: note)
        return ok && cooking.session?.status == .completed
    }
}
