import Foundation
import Observation

/// Brief 015 first-run onboarding. A small step machine over injected services, so tests drive
/// it without UI. Nothing is saved without a tap: role, taste and follows each save on their own
/// explicit action, allergies through the same editor as Profile (each add/remove is a tap).
@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: String, CaseIterable, Sendable {
        case welcome, role, allergies, taste, follow, pantry, done

        /// Shown in the progress label ("Step 2 of 5"). Welcome and Done aren't counted.
        var isCounted: Bool { self != .welcome && self != .done }
        var isSkippable: Bool { self == .taste || self == .follow || self == .pantry }
    }

    /// The full flow (brief 015).
    static let allSteps: [Step] = Step.allCases

    let steps: [Step]
    private(set) var index = 0
    var step: Step { steps[index] }

    // Role
    var role: User.Role?
    // Allergies: an explicit answer is required (DECISIONS #27). "No allergies" only while the
    // list is empty; adding one clears it.
    var saysNoAllergies = false
    let preferences: PreferencesViewModel
    // Taste
    private(set) var diets: [String] = []
    private(set) var cuisines: [String] = []
    var skillLevel: String?

    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var isFinished = false

    private let service: OnboardingService
    private let onUserUpdated: @MainActor (User) -> Void
    private var tastePrefilled = false

    init(service: OnboardingService,
         preferencesService: PreferencesService,
         steps: [Step] = OnboardingViewModel.allSteps,
         onUserUpdated: @escaping @MainActor (User) -> Void) {
        precondition(steps.first == .welcome && steps.last == .done, "onboarding starts at welcome and ends at done")
        self.steps = steps
        self.service = service
        self.preferences = PreferencesViewModel(service: preferencesService)
        self.onUserUpdated = onUserUpdated
    }

    // MARK: - Progress

    var countedSteps: [Step] { steps.filter(\.isCounted) }

    /// 1-based position among counted steps, `nil` on Welcome / Done.
    var countedPosition: Int? {
        countedSteps.firstIndex(of: step).map { $0 + 1 }
    }

    var progress: Double {
        steps.count > 1 ? Double(index) / Double(steps.count - 1) : 1
    }

    var canGoBack: Bool { index > 0 && step != .done && !isWorking }
    var canSkip: Bool { step.isSkippable && !isWorking }

    var hasAllergies: Bool { !preferences.entries(.allergies).isEmpty }

    var canContinue: Bool {
        guard !isWorking else { return false }
        switch step {
        case .welcome, .taste, .follow, .pantry, .done:
            return true
        case .role:
            return role != nil
        case .allergies:
            return preferences.phase == .loaded && !preferences.isSaving && (hasAllergies || saysNoAllergies)
        }
    }

    // MARK: - Actions

    func start() async {
        await preferences.load()
        prefillTaste()
    }

    func toggleNoAllergies() {
        guard !hasAllergies else {
            saysNoAllergies = false
            return
        }
        saysNoAllergies.toggle()
    }

    func toggleDiet(_ id: String) { diets.toggle(id) }
    func toggleCuisine(_ id: String) { cuisines.toggle(id) }

    func back() {
        guard canGoBack else { return }
        errorMessage = nil
        index -= 1
    }

    func skip() {
        guard canSkip else { return }
        errorMessage = nil
        advance()
    }

    /// Saves what this step owns, then moves on. A failed save stays on the step with a message.
    func continueTapped() async {
        guard canContinue else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch step {
            case .role:
                if let role { onUserUpdated(try await service.setRole(role)) }
            case .allergies:
                if hasAllergies { saysNoAllergies = false }
            case .taste:
                var next = preferences.preferences
                next.diets = diets
                next.cuisines = cuisines
                next.skillLevel = skillLevel
                _ = try await service.updateTaste(next)
            case .done:
                onUserUpdated(try await service.completeOnboarding())
                isFinished = true
                return
            case .welcome, .follow, .pantry:
                break
            }
            advance()
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func advance() {
        if index < steps.count - 1 { index += 1 }
    }

    /// A returning user who quit mid-way sees what they already saved.
    private func prefillTaste() {
        guard !tastePrefilled, preferences.phase == .loaded else { return }
        tastePrefilled = true
        diets = preferences.preferences.diets
        cuisines = preferences.preferences.cuisines
        skillLevel = preferences.preferences.skillLevel
    }
}

private extension Array where Element == String {
    mutating func toggle(_ value: String) {
        if let i = firstIndex(of: value) { remove(at: i) } else { append(value) }
    }
}
