import Foundation
import Observation

@MainActor
@Observable
final class ExploreViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case error(message: String, retryable: Bool)
    }

    /// Bound to the search field; debounced into `query`.
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }

    private(set) var query = ""
    private(set) var phase: Phase = .idle
    private(set) var cards: [RecipeCard] = []
    /// Set when the cards on screen came from disk because the server was unreachable.
    private(set) var offlineNotice: String?
    private(set) var cachedAt: Date?

    var debounce: Duration = .milliseconds(300)
    var pageSize = 20

    private let service: RecipeService
    private let cache: RecipeCaching
    private var searchTask: Task<Void, Never>?
    private var fetchTask: Task<Result<RecipePage, Error>, Never>?

    init(service: RecipeService, cache: RecipeCaching, debounce: Duration = .milliseconds(300)) {
        self.service = service
        self.cache = cache
        self.debounce = debounce
    }

    /// Waits for the debounced search scheduled by the last `searchText` change (tests).
    func awaitPendingSearch() async {
        await searchTask?.value
    }

    var isShowingCached: Bool { offlineNotice != nil }

    /// First appearance: paint cached cards immediately, then fetch.
    func load() async {
        if cards.isEmpty, query.isEmpty, let cached = cache.load(), !cached.items.isEmpty {
            cards = cached.items
            cachedAt = cached.savedAt
            phase = .loaded
        }
        await fetch()
    }

    /// Pull-to-refresh and the Retry button.
    func refresh() async {
        await fetch()
    }

    func submitSearchNow() async {
        searchTask?.cancel()
        query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        await fetch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let pending = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            guard pending != query else { return }
            query = pending
            await fetch()
        }
    }

    private func fetch() async {
        fetchTask?.cancel()
        let currentQuery = query
        let task = Task { [service, cache, pageSize] () -> Result<RecipePage, Error> in
            do {
                let page = try await service.listRecipes(
                    query: currentQuery.isEmpty ? nil : currentQuery,
                    tag: nil,
                    cursor: nil,
                    limit: pageSize
                )
                if currentQuery.isEmpty {
                    try? cache.save(page.items)
                }
                return .success(page)
            } catch {
                return .failure(error)
            }
        }
        fetchTask = task
        if cards.isEmpty { phase = .loading }

        let result = await task.value
        // A newer fetch superseded this one; let it own the state.
        guard fetchTask == task, currentQuery == query else { return }

        switch result {
        case .success(let page):
            cards = page.items
            offlineNotice = nil
            cachedAt = nil
            phase = page.items.isEmpty ? .empty : .loaded
        case .failure(let error):
            let apiError = error as? APIError
            if apiError == .cancelled { return }
            let message = apiError?.userMessage ?? error.localizedDescription
            let retryable = apiError?.isRetryable ?? true
            if currentQuery.isEmpty, let cached = cache.load(), !cached.items.isEmpty {
                cards = cached.items
                cachedAt = cached.savedAt
                offlineNotice = message
                phase = .loaded
            } else {
                cards = []
                phase = .error(message: message, retryable: retryable)
            }
        }
    }
}
