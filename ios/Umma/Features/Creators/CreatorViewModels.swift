import Foundation
import Observation

/// Brief 015 creator profile: summary, Follow toggle, their published recipes.
@MainActor
@Observable
final class CreatorProfileViewModel {
    enum Phase: Equatable { case loading, loaded, notFound, error(String) }

    let creatorId: UUID
    private(set) var phase: Phase = .loading
    private(set) var profile: CreatorProfile?
    private(set) var isTogglingFollow = false
    private(set) var followError: String?
    /// Fired after a follow / unfollow lands (Following feed and list refresh on change).
    var onFollowChanged: (() -> Void)?

    private let service: SocialService

    init(creatorId: UUID, service: SocialService) {
        self.creatorId = creatorId
        self.service = service
    }

    func load() async {
        if profile == nil { phase = .loading }
        do {
            profile = try await service.creator(id: creatorId)
            phase = .loaded
        } catch let error as APIError where error == .cancelled {
            return
        } catch let error as APIError where error.isNotFound {
            phase = .notFound
        } catch {
            phase = .error((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    /// One tap, saved right away; a failure puts the button back.
    func toggleFollow() async {
        guard var current = profile, !isTogglingFollow else { return }
        let was = current.creator.isFollowing
        isTogglingFollow = true
        followError = nil
        current.creator.isFollowing.toggle()
        profile = current
        defer { isTogglingFollow = false }
        do {
            let updated = was ? try await service.unfollow(creatorId: creatorId) : try await service.follow(creatorId: creatorId)
            profile?.creator = updated
            onFollowChanged?()
        } catch {
            profile?.creator.isFollowing = was
            followError = "Couldn’t update: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
        }
    }
}

/// Profile → Following: who you follow, swipe to unfollow.
@MainActor
@Observable
final class FollowingListViewModel {
    enum Phase: Equatable { case loading, loaded, error(String) }

    private(set) var phase: Phase = .loading
    private(set) var creators: [CreatorSummary] = []
    private(set) var actionError: String?
    var onFollowChanged: (() -> Void)?

    private let service: SocialService

    init(service: SocialService) {
        self.service = service
    }

    func load() async {
        if creators.isEmpty { phase = .loading }
        do {
            creators = try await service.following()
            phase = .loaded
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            phase = .error((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    /// Removes the row at once; puts it back if the server refuses.
    func unfollow(_ creatorId: UUID) async {
        guard let index = creators.firstIndex(where: { $0.id == creatorId }) else { return }
        let removed = creators.remove(at: index)
        actionError = nil
        do {
            _ = try await service.unfollow(creatorId: creatorId)
            onFollowChanged?()
        } catch let error as APIError where error.isNotFound {
            onFollowChanged?()  // already gone on the server
        } catch {
            creators.insert(removed, at: min(index, creators.count))
            actionError = "Couldn’t unfollow: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
        }
    }
}

/// Profile → "Diets, cuisines & skill": the brief 015 taste fields outside onboarding.
@MainActor
@Observable
final class TastePreferencesViewModel {
    enum Phase: Equatable { case loading, loaded, error(String) }

    private(set) var phase: Phase = .loading
    private(set) var saved = FoodPreferences()
    var diets: [String] = []
    var cuisines: [String] = []
    var skillLevel: String?
    private(set) var isSaving = false
    private(set) var saveError: String?

    private let preferences: PreferencesService
    private let onboarding: OnboardingService

    init(preferences: PreferencesService, onboarding: OnboardingService) {
        self.preferences = preferences
        self.onboarding = onboarding
    }

    var hasChanges: Bool {
        diets != saved.diets || cuisines != saved.cuisines || skillLevel != saved.skillLevel
    }

    func load() async {
        phase = .loading
        do {
            saved = try await preferences.preferences()
            diets = saved.diets
            cuisines = saved.cuisines
            skillLevel = saved.skillLevel
            phase = .loaded
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            phase = .error((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    func toggleDiet(_ id: String) { diets = diets.contains(id) ? diets.filter { $0 != id } : diets + [id] }
    func toggleCuisine(_ id: String) { cuisines = cuisines.contains(id) ? cuisines.filter { $0 != id } : cuisines + [id] }

    /// Explicit Save. Sends the stored allergies back unchanged with the new taste fields.
    func save() async -> Bool {
        guard hasChanges, !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        var next = saved
        next.diets = diets
        next.cuisines = cuisines
        next.skillLevel = skillLevel
        do {
            saved = try await onboarding.updateTaste(next)
            diets = saved.diets
            cuisines = saved.cuisines
            skillLevel = saved.skillLevel
            return true
        } catch {
            saveError = "Couldn’t save: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
            return false
        }
    }
}
