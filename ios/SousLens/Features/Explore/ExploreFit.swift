import Foundation
import Observation

/// What an Explore card says about the pantry (brief 006): "You have 9 of 10". Uses the same
/// strict rule as Pantry fit (FIT-03): "everything" only when nothing required is missing or
/// uncertain, and the chip never says "safe" or "can make it".
struct CardFitSummary: Equatable, Sendable {
    let availableCount: Int
    let requiredCount: Int
    /// Server says can-make AND no required line is missing or uncertain.
    let hasEverything: Bool

    init(fit: PantryFit) {
        let required = fit.items.filter { !$0.optional }
        availableCount = required.filter { $0.status == .available }.count
        requiredCount = required.count
        hasEverything = fit.canMake && required.allSatisfy { $0.status == .available }
    }

    /// Nil when nothing matched: an empty pantry shouldn't paint "0 of 10" on every card.
    var chipText: String? {
        guard requiredCount > 0 else { return nil }
        if hasEverything { return "You have all \(requiredCount)" }
        guard availableCount > 0 else { return nil }
        return "You have \(availableCount) of \(requiredCount)"
    }
}

/// Explore's filter chips. "Can make now" keeps only cards whose fit `hasEverything`; a tag chip
/// keeps cards with that tag. Filtering is client-side over the cards already loaded.
enum ExploreFilter: Hashable, Sendable {
    case all
    case canMakeNow
    case tag(String)

    var title: String {
        switch self {
        case .all: "All"
        case .canMakeNow: "Can make now"
        case .tag(let tag): tag.capitalized
        }
    }

    var identifier: String {
        switch self {
        case .all: "explore.filter.all"
        case .canMakeNow: "explore.filter.canMakeNow"
        case .tag(let tag): "explore.filter.tag.\(tag)"
        }
    }

    /// All, Can make now, then the most common tags on screen (at most `maxTags`).
    static func chips(for cards: [RecipeCard], maxTags: Int = 4) -> [ExploreFilter] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, tag) in cards.flatMap(\.tags).enumerated() {
            counts[tag, default: 0] += 1
            if firstSeen[tag] == nil { firstSeen[tag] = index }
        }
        let tags = counts.keys.sorted {
            counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : firstSeen[$0]! < firstSeen[$1]!
        }
        return [.all, .canMakeNow] + tags.prefix(maxTags).map { .tag($0) }
    }

    func apply(to cards: [RecipeCard], fits: [UUID: CardFitSummary]) -> [RecipeCard] {
        switch self {
        case .all: cards
        case .canMakeNow: cards.filter { fits[$0.recipeVersionId]?.hasEverything == true }
        case .tag(let tag): cards.filter { $0.tags.contains(tag) }
        }
    }
}

/// Loads the pantry fit for each card on screen (`POST /recipe-versions/{id}/fit`, read-only and
/// deterministic). A failed fit just means no chip: it is a hint, never a gate.
@MainActor
@Observable
final class ExploreFitLoader {
    private(set) var fits: [UUID: CardFitSummary] = [:]
    /// The (pantry revision, versions) the current `fits` were computed for.
    private var loadedKey: String?
    private let fit: @Sendable (UUID) async throws -> PantryFit

    init(fit: @escaping @Sendable (UUID) async throws -> PantryFit) {
        self.fit = fit
    }

    /// At most this many fit requests in flight at once.
    nonisolated static let maxConcurrent = 6

    /// Refetches only when the cards or the pantry changed. A load that was cancelled (the user
    /// opened a recipe mid-load) or where every fit failed doesn't count as loaded, so the next
    /// call retries instead of keeping empty chips.
    func load(versionIds: [UUID], pantryRevision: Int) async {
        let key = "\(pantryRevision):" + versionIds.map(\.uuidString).joined(separator: ",")
        guard key != loadedKey, !versionIds.isEmpty else { return }
        loadedKey = key
        let fit = self.fit
        let ids = Array(Set(versionIds))
        var results: [UUID: CardFitSummary] = [:]
        await withTaskGroup(of: (UUID, CardFitSummary?).self) { group in
            var next = 0
            func addNext() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask {
                    let summary = try? await fit(id)
                    return (id, summary.map(CardFitSummary.init(fit:)))
                }
            }
            for _ in 0..<min(Self.maxConcurrent, ids.count) { addNext() }
            for await (id, summary) in group {
                if let summary { results[id] = summary }
                if !Task.isCancelled { addNext() }
            }
        }
        guard key == loadedKey else { return }
        guard !Task.isCancelled else {
            loadedKey = nil
            return
        }
        if results.isEmpty { loadedKey = nil }
        fits = results
    }
}
