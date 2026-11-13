import Foundation
import Observation

/// Profile: my published recipes (`GET /me/recipes`) and my open drafts (`GET /recipes/drafts`).
@MainActor
@Observable
final class MyRecipesViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case error(message: String, retryable: Bool)
    }

    private(set) var phase: Phase = .idle
    private(set) var recipes: [MyRecipe] = []
    private(set) var drafts: [DraftSummary] = []
    /// Non-fatal message from the last action (unpublish / delete / open failure).
    var actionError: String?
    private(set) var busyRecipeIds: Set<UUID> = []
    private(set) var busyDraftIds: Set<UUID> = []

    private let service: RecipeService

    init(service: RecipeService) {
        self.service = service
    }

    func load() async {
        if recipes.isEmpty, drafts.isEmpty { phase = .loading }
        await fetch()
    }

    func refresh() async {
        await fetch()
    }

    private func fetch() async {
        let recipesTask = Task { [service] in try await service.myRecipes() }
        let draftsTask = Task { [service] in try await service.listDrafts() }
        do {
            let recipes = try await recipesTask.value
            let drafts = try await draftsTask.value
            self.recipes = recipes
            // Published drafts are history, not work in progress.
            self.drafts = drafts.filter { $0.status != .published }
            phase = .loaded
        } catch {
            let apiError = error as? APIError
            if apiError == .cancelled { return }
            phase = .error(message: apiError?.userMessage ?? error.localizedDescription, retryable: apiError?.isRetryable ?? true)
        }
    }

    /// After the confirmation dialog. On success the recipe stays listed with its new visibility.
    @discardableResult
    func unpublish(recipeId: UUID) async -> Bool {
        busyRecipeIds.insert(recipeId)
        defer { busyRecipeIds.remove(recipeId) }
        actionError = nil
        do {
            let result = try await service.unpublishRecipe(id: recipeId)
            recipes = recipes.map { item in
                item.id == recipeId ? MyRecipe(card: item.card, visibility: result.visibility, hasOpenDraft: item.hasOpenDraft) : item
            }
            return true
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            return false
        }
    }

    /// After the confirmation dialog.
    @discardableResult
    func deleteDraft(id: UUID) async -> Bool {
        busyDraftIds.insert(id)
        defer { busyDraftIds.remove(id) }
        actionError = nil
        do {
            let recipeId = drafts.first(where: { $0.id == id })?.recipeId
            try await service.deleteDraft(id: id)
            drafts.removeAll { $0.id == id }
            // The parent recipe (if any) no longer has an open draft.
            if let recipeId {
                recipes = recipes.map { $0.id == recipeId ? MyRecipe(card: $0.card, visibility: $0.visibility, hasOpenDraft: false) : $0 }
            }
            return true
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            return false
        }
    }
}
