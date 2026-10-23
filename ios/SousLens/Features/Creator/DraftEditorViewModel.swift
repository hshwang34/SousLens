import Foundation
import Observation
import os

/// Owns one draft: the editable form, debounced autosave (PATCH), server validation, preview
/// and the explicit publish confirmation (CLAUDE.md: publishing is never silent).
@MainActor
@Observable
final class DraftEditorViewModel: Identifiable {
    enum SaveStatus: Equatable {
        case saved
        /// Edited; the debounce timer is running.
        case pending
        case saving
        /// Transport or server failure; the same body may succeed on Retry.
        case failed(String)
        /// The server refused the content (PATCH 422 VALIDATION_ERROR): retrying the same body can't
        /// help, the creator has to change the field. Shown inline with the server's reason.
        case rejected(String)

        var label: String {
            switch self {
            case .saved: return "Saved"
            case .pending, .saving: return "Saving…"
            case .failed: return "Couldn’t save"
            case .rejected(let reason): return "Couldn’t save · \(reason)"
            }
        }

        var isFailure: Bool {
            switch self {
            case .failed, .rejected: return true
            default: return false
            }
        }
    }

    enum PublishPhase: Equatable {
        case idle
        case confirming
        case publishing
        case published(PublishResult)
        case failed(String)
    }

    let id: UUID
    private(set) var draft: Draft
    private(set) var validation: DraftValidation
    private(set) var saveStatus: SaveStatus = .saved
    private(set) var publishPhase: PublishPhase = .idle
    /// Version the next publish will create; nil until known (fetched for edits of published recipes).
    private(set) var nextVersionNumber: Int?
    /// True when the server says this draft is already published (status, or a 409 on PATCH):
    /// nothing here can be saved or published again; editing the recipe creates a new draft.
    private(set) var isPublishedReadOnly: Bool
    let creator: Creator

    var form: DraftForm {
        didSet {
            guard form != oldValue else { return }
            markDirty()
        }
    }

    var debounce: Duration

    private let service: RecipeService
    private let logger = Logger(subsystem: "com.souslens.ios", category: "editor")
    private var dirty = false
    private var autosaveTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(draft: Draft, service: RecipeService, creator: Creator, nextVersionNumber: Int? = nil, debounce: Duration = .milliseconds(800)) {
        self.id = draft.id
        self.draft = draft
        self.validation = draft.validation
        self.form = DraftForm(draft: draft)
        self.service = service
        self.creator = creator
        self.debounce = debounce
        self.nextVersionNumber = nextVersionNumber ?? (draft.recipeId == nil ? 1 : nil)
        self.isPublishedReadOnly = draft.status == .published
    }

    // MARK: - Entry points

    /// Profile → "Create recipe": `POST /recipes/drafts {}`.
    static func createNew(service: RecipeService, creator: Creator, debounce: Duration = .milliseconds(800)) async throws -> DraftEditorViewModel {
        let draft = try await service.createDraft(.empty)
        return DraftEditorViewModel(draft: draft, service: service, creator: creator, debounce: debounce)
    }

    /// Profile → Drafts → continue.
    static func open(draftId: UUID, service: RecipeService, creator: Creator, debounce: Duration = .milliseconds(800)) async throws -> DraftEditorViewModel {
        let draft = try await service.draft(id: draftId)
        return DraftEditorViewModel(draft: draft, service: service, creator: creator, debounce: debounce)
    }

    /// Recipe detail → "Edit" (REC-06). A 409 means a draft for this recipe is already open; that
    /// draft is loaded instead of failing.
    static func forEditing(recipeId: UUID, latestVersionNumber: Int?, service: RecipeService, creator: Creator, debounce: Duration = .milliseconds(800)) async throws -> DraftEditorViewModel {
        let draft: Draft
        do {
            draft = try await service.editRecipe(id: recipeId)
        } catch let error as APIError {
            guard let existing = error.conflictingDraftId else { throw error }
            draft = try await service.draft(id: existing)
        }
        return DraftEditorViewModel(draft: draft, service: service, creator: creator,
                                    nextVersionNumber: latestVersionNumber.map { $0 + 1 }, debounce: debounce)
    }

    /// Best effort: for a draft that belongs to a published recipe, learn the current version so
    /// the confirmation can say "Publish version N?".
    func resolveNextVersionNumber() async {
        guard nextVersionNumber == nil, let recipeId = draft.recipeId else { return }
        if let detail = try? await service.recipe(id: recipeId) {
            nextVersionNumber = detail.versionNumber + 1
        }
    }

    // MARK: - Validation surfaced inline

    var problems: [DraftProblem] { validation.problems }

    func problems(for field: String) -> [DraftProblem] { validation.problems(for: field) }

    /// Problems attached to one array row: `ingredients[2]…` or pydantic-style `ingredients.2…`.
    func problems(in collection: String, row index: Int) -> [DraftProblem] {
        validation.problems.filter {
            DraftValidation.field($0.field, isWithin: "\(collection)[\(index)]")
                || DraftValidation.field($0.field, isWithin: "\(collection).\(index)")
        }
    }

    /// Section-level problems only (not attributed to a row).
    func sectionProblems(_ collection: String) -> [DraftProblem] { validation.problems(exactly: collection) }

    // MARK: - Autosave

    var hasUnsavedChanges: Bool { dirty || saveTask != nil }

    private func markDirty() {
        // A published draft is read-only on the server (PATCH → 409); never queue a save for it.
        guard !isPublishedReadOnly else { return }
        dirty = true
        if saveStatus.isFailure {
            // Keep the failure visible until a save succeeds; a retry is one tap away.
        } else {
            saveStatus = .pending
        }
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    /// "Retry" on a failed save: no debounce.
    func retrySave() async {
        autosaveTask?.cancel()
        await save()
    }

    /// Waits for the debounced autosave and any in-flight save (tests, publish).
    func flush() async {
        autosaveTask?.cancel()
        await save()
        // Another save may have started meanwhile (the autosave task, or an edit made during the
        // last PATCH). Keep going until nothing is in flight and nothing is waiting; a failed save
        // stops the loop (its status stays `.failed` / `.rejected`).
        while saveTask != nil || (dirty && saveStatus == .pending) {
            autosaveTask?.cancel()
            await save()
        }
    }

    private func save() async {
        // One PATCH at a time. The in-flight task clears `saveTask` itself before it finishes, so
        // this loop always makes progress (no spin on an already-completed task).
        while let inFlight = saveTask {
            await inFlight.value
        }
        guard dirty, !isPublishedReadOnly else { return }
        dirty = false
        saveStatus = .saving
        let patch = form.patch()
        let task = Task { [service, id] in
            defer { self.saveTask = nil }
            do {
                let updated = try await service.updateDraft(id: id, patch)
                self.draft = updated
                self.validation = updated.validation
                self.saveStatus = self.dirty ? .pending : .saved
            } catch {
                let apiError = error as? APIError
                var message = apiError?.userMessage ?? error.localizedDescription
                if apiError?.status == 409 {
                    // Contract: PATCH on a draft that has been published → 409 STATE_CONFLICT.
                    message = "This draft was already published and can’t be changed. Use Edit on the recipe to start a new version."
                    self.isPublishedReadOnly = true
                }
                self.logger.error("autosave failed: \(message, privacy: .public)")
                // A read-only draft can never take these edits, so they are not "unsaved work"
                // to retry; the failure message stays visible.
                self.dirty = !self.isPublishedReadOnly
                if apiError?.status == 422 {
                    self.saveStatus = .rejected(apiError?.userMessage ?? message)
                } else {
                    self.saveStatus = .failed(message)
                }
            }
        }
        saveTask = task
        await task.value
        if dirty, case .pending = saveStatus {
            scheduleAutosave()
        }
    }

    // MARK: - Preview

    func previewDetail() -> RecipeDetail {
        form.previewDetail(draft: draft, creator: creator, versionNumber: nextVersionNumber ?? 1)
    }

    // MARK: - Publish

    /// The button is enabled only when the server has said the last saved state is publishable.
    var canPublish: Bool {
        guard validation.publishable, !isPublishedReadOnly else { return false }
        switch publishPhase {
        case .confirming, .publishing, .published: return false
        case .idle, .failed: return true
        }
    }

    var publishConfirmationTitle: String {
        if let version = nextVersionNumber { return "Publish version \(version)?" }
        return "Publish a new version?"
    }

    static let publishConfirmationMessage = "This snapshot can’t be edited; later edits create a new version."

    func requestPublish() {
        guard canPublish else { return }
        publishPhase = .confirming
    }

    func cancelPublish() {
        if case .confirming = publishPhase { publishPhase = .idle }
        if case .failed = publishPhase { publishPhase = .idle }
    }

    /// Only ever called from the confirmation sheet's Publish button.
    func confirmPublish() async {
        guard case .confirming = publishPhase else { return }
        publishPhase = .publishing
        await flush()
        if case .rejected(let reason) = saveStatus {
            publishPhase = .failed("Your latest changes weren’t accepted (\(reason)). Fix them, then publish.")
            return
        }
        if case .failed(let message) = saveStatus {
            publishPhase = .failed("Your latest changes didn’t save (\(message)). Retry saving, then publish.")
            return
        }
        guard validation.publishable else {
            publishPhase = .failed("Fix the problems shown in the editor, then publish.")
            return
        }
        do {
            let result = try await service.publishDraft(id: id)
            publishPhase = .published(result)
        } catch let error as APIError {
            if let problems = error.validationProblems {
                validation = DraftValidation(publishable: false, problems: problems)
            }
            if error.isTransportFailure, let recovered = await recoverPublishOutcome() {
                publishPhase = .published(recovered)
                return
            }
            publishPhase = .failed(error.isTransportFailure
                ? "\(error.userMessage) The recipe may or may not have been published; check My recipes before trying again."
                : error.userMessage)
        } catch {
            publishPhase = .failed(error.localizedDescription)
        }
    }

    /// The request may have reached the server even though the response didn't reach us. Re-read
    /// the draft: if it is now `published`, the publish happened, so report success rather than a
    /// failure the creator might "fix" by publishing twice.
    private func recoverPublishOutcome() async -> PublishResult? {
        guard let latest = try? await service.draft(id: id), latest.status == .published,
              let recipeId = latest.recipeId ?? draft.recipeId
        else { return nil }
        draft = latest
        isPublishedReadOnly = true
        if let detail = try? await service.recipe(id: recipeId) {
            return PublishResult(recipeId: recipeId, recipeVersionId: detail.recipeVersionId,
                                 versionNumber: detail.versionNumber, shareUrl: nil)
        }
        // Published, but we could not learn the version; fall back to what we expected.
        guard let expected = nextVersionNumber else { return nil }
        return PublishResult(recipeId: recipeId, recipeVersionId: latest.id, versionNumber: expected, shareUrl: nil)
    }

    var publishResult: PublishResult? {
        if case .published(let result) = publishPhase { return result }
        return nil
    }
}
