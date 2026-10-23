import Foundation
import Observation

/// `GET /v1/me/saved`, newest-saved first.
@MainActor
@Observable
final class SavedViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case error(message: String, retryable: Bool)
    }

    private(set) var phase: Phase = .idle
    private(set) var cards: [RecipeCard] = []

    private let service: RecipeService
    private var fetchTask: Task<Result<[RecipeCard], Error>, Never>?

    init(service: RecipeService) {
        self.service = service
    }

    func load() async {
        if cards.isEmpty { phase = .loading }
        await fetch()
    }

    func refresh() async {
        await fetch()
    }

    private func fetch() async {
        fetchTask?.cancel()
        let task = Task { [service] () -> Result<[RecipeCard], Error> in
            do { return .success(try await service.mySaved()) } catch { return .failure(error) }
        }
        fetchTask = task
        let result = await task.value
        guard fetchTask == task else { return }
        switch result {
        case .success(let items):
            cards = items
            phase = items.isEmpty ? .empty : .loaded
        case .failure(let error):
            let apiError = error as? APIError
            if apiError == .cancelled { return }
            phase = .error(message: apiError?.userMessage ?? error.localizedDescription, retryable: apiError?.isRetryable ?? true)
        }
    }
}
