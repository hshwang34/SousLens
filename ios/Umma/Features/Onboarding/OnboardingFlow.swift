import SwiftUI

/// Brief 015 first-run onboarding, shown by `RootView` until the server records it finished.
struct OnboardingFlow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: OnboardingViewModel?
    /// Direction of the last move, for the push transition.
    @State private var forward = true

    var steps: [OnboardingViewModel.Step] = OnboardingViewModel.allSteps

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background.ignoresSafeArea())
        .task {
            guard model == nil else { return }
            let auth = environment.auth
            let created = OnboardingViewModel(service: environment.api, preferencesService: environment.api, steps: steps) { user in
                auth.updateUser(user)
            }
            model = created
            await created.start()
        }
    }

    private func content(_ model: OnboardingViewModel) -> some View {
        VStack(spacing: 0) {
            OnboardingHeader(model: model) {
                forward = false
                withAnimation(.mise(reduceMotion: reduceMotion)) { model.back() }
            } onSkip: {
                forward = true
                withAnimation(.mise(reduceMotion: reduceMotion)) { model.skip() }
            }
            ScrollView {
                stepView(model)
                    .id(model.step)
                    .transition(.misePush(from: forward ? .trailing : .leading, reduceMotion: reduceMotion))
                    .padding(.horizontal, Spacing.screen)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            footer(model)
        }
    }

    @ViewBuilder
    private func stepView(_ model: OnboardingViewModel) -> some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .role: RoleStep(model: model)
        case .allergies: AllergiesStep(model: model)
        case .taste: TasteStep(model: model)
        case .follow, .pantry: EmptyView()  // brief 015 PR 9
        case .done: DoneStep(model: model)
        }
    }

    private func footer(_ model: OnboardingViewModel) -> some View {
        VStack(spacing: Spacing.sm) {
            if let error = model.errorMessage {
                Text(error)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("onboarding.error")
            }
            Button {
                forward = true
                Task {
                    await model.continueTapped()
                    // Land on Explore; a deep link that waited for onboarding still applies.
                    if model.isFinished { environment.selectedTab = .explore }
                }
            } label: {
                if model.isWorking {
                    ProgressView().tint(SLColor.onBrand)
                } else {
                    Text(Self.primaryTitle(model.step))
                }
            }
            .buttonStyle(SLButtonStyle(prominent: true))
            .disabled(!model.canContinue)
            .slDisabledAppearance(!model.canContinue)
            .accessibilityIdentifier("onboarding.continue")
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.md)
        .bottomBarScrim()
        .animation(.mise(reduceMotion: reduceMotion), value: model.step)
    }

    static func primaryTitle(_ step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return "Get started"
        case .done: return "Start cooking"
        default: return "Continue"
        }
    }
}

// MARK: - Header

private struct OnboardingHeader: View {
    let model: OnboardingViewModel
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(SLFont.headline)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
            }
            .opacity(model.canGoBack ? 1 : 0)
            .disabled(!model.canGoBack)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("onboarding.back")

            ProgressView(value: model.progress)
                .tint(SLColor.accent)
                .accessibilityLabel(model.countedPosition.map { "Step \($0) of \(model.countedSteps.count)" } ?? "Onboarding")

            Button("Skip", action: onSkip)
                .font(SLFont.subheadline.weight(.semibold))
                .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                .opacity(model.canSkip ? 1 : 0)
                .disabled(!model.canSkip)
                .accessibilityIdentifier("onboarding.skip")
        }
        .foregroundStyle(SLColor.textPrimary)
        .padding(.horizontal, Spacing.sm)
    }
}

/// Large title + supporting line used at the top of every step.
struct OnboardingTitle: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(SLFont.brandHeadline)
                .foregroundStyle(SLColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(SLFont.body)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Spacing.lg)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack(spacing: Spacing.md) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 72, height: 72)
                Text(verbatim: "umma").font(SLFont.wordmark).foregroundStyle(SLColor.accent)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Umma"))
            .accessibilityAddTraits(.isHeader)
            .padding(.top, Spacing.xl)

            Text("Record a recipe once. Teach anyone to cook it, with the ingredients they actually have.")
                .font(SLFont.title3)
                .foregroundStyle(SLColor.textPrimary)

            VStack(alignment: .leading, spacing: Spacing.lg) {
                bullet("person.2.fill", "Cook from people you trust", "Follow home cooks and keep their recipes close.")
                bullet("basket.fill", "Start from your kitchen", "Scan your pantry and see what you can make tonight.")
                bullet("waveform", "Guided, step by step", "Hands-free help while you cook, at your pace.")
            }
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(SLFont.title3)
                .foregroundStyle(SLColor.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(SLFont.headline).foregroundStyle(SLColor.textPrimary)
                Text(detail).font(SLFont.subheadline).foregroundStyle(SLColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RoleStep: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            OnboardingTitle(title: "What brings you here?", message: "You can do both. This just helps us set things up.")
            option(.cook, symbol: "frying.pan", title: "I want to cook", detail: "Find recipes that fit my kitchen and get guided while I cook.")
            option(.creator, symbol: "book.closed", title: "I want to share my family’s recipes", detail: "Record the dishes I make so others can cook them too.")
        }
    }

    private func option(_ role: User.Role, symbol: String, title: String, detail: String) -> some View {
        let selected = model.role == role
        return Button {
            model.role = role
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: symbol)
                    .font(SLFont.title3)
                    .foregroundStyle(selected ? SLColor.onAccent : SLColor.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title).font(SLFont.headline)
                    Text(detail).font(SLFont.subheadline).opacity(0.85)
                }
                .foregroundStyle(selected ? SLColor.onAccent : SLColor.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? SLColor.onAccent : SLColor.textSecondary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? SLColor.accent : SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("onboarding.role.\(role.rawValue)")
    }
}

private struct AllergiesStep: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        let prefs = model.preferences
        VStack(alignment: .leading, spacing: Spacing.lg) {
            OnboardingTitle(
                title: "Any food allergies?",
                message: "We use these to warn you about recipes and never to suggest a swap that contains them."
            )
            switch prefs.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .error(let message):
                EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn’t load your allergies", message: message,
                               primary: EmptyStateView.Action("Try again") { Task { await prefs.load() } })
            case .loaded:
                if model.hasAllergies {
                    ChipFlow(entries: prefs.entries(.allergies), isFlagged: prefs.isUnrecognized) { index in
                        Task { await prefs.remove(.allergies, at: index) }
                    }
                    .disabled(prefs.isSaving)
                }
                ForEach(prefs.unrecognizedEntries(.allergies), id: \.self) { entry in
                    Label(PreferencesViewModel.unrecognizedMessage(entry), systemImage: "exclamationmark.triangle.fill")
                        .font(SLFont.footnote)
                        .foregroundStyle(SLColor.warning)
                }
                HStack(spacing: Spacing.sm) {
                    TextField(PreferencesViewModel.Kind.allergies.placeholder,
                              text: Binding(get: { prefs.draft(.allergies) }, set: { prefs.setDraft(.allergies, $0) }))
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { Task { await prefs.add(.allergies) } }
                        .padding(.horizontal, Spacing.md)
                        .frame(minHeight: Metrics.minTapTarget)
                        .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .accessibilityLabel("Add an allergy")
                        .accessibilityIdentifier("onboarding.allergy.field")
                    Button("Add") { Task { await prefs.add(.allergies) } }
                        .buttonStyle(SLButtonStyle(prominent: false))
                        .frame(width: 88)
                        .disabled(!prefs.canAdd(.allergies))
                        .accessibilityIdentifier("onboarding.allergy.add")
                }
                if let error = prefs.saveError {
                    Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
                }
                SelectableChip(title: "I have no food allergies", isSelected: model.saysNoAllergies) {
                    model.toggleNoAllergies()
                }
                .disabled(model.hasAllergies)
                .opacity(model.hasAllergies ? 0.5 : 1)
                .accessibilityIdentifier("onboarding.allergy.none")

                Label {
                    Text(PreferencesViewModel.disclaimer).font(SLFont.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                .foregroundStyle(SLColor.textSecondary)
                .padding(.top, Spacing.sm)
            }
        }
    }
}

private struct TasteStep: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            OnboardingTitle(title: "Your taste", message: "Pick what fits. We use this to suggest recipes and cooks, never to hide anything.")
            group("Do you follow a diet?") {
                ForEach(TasteOptions.diets) { option in
                    SelectableChip(title: option.label, isSelected: model.diets.contains(option.id)) { model.toggleDiet(option.id) }
                }
            }
            group("Cuisines you love") {
                ForEach(TasteOptions.cuisines) { option in
                    SelectableChip(title: option.label, isSelected: model.cuisines.contains(option.id)) { model.toggleCuisine(option.id) }
                        .accessibilityIdentifier("onboarding.cuisine.\(option.id)")
                }
            }
            group("How comfortable are you in the kitchen?") {
                ForEach(TasteOptions.skillLevels) { option in
                    SelectableChip(title: option.label, isSelected: model.skillLevel == option.id) {
                        model.skillLevel = model.skillLevel == option.id ? nil : option.id
                    }
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(title).font(SLFont.headline).foregroundStyle(SLColor.textPrimary).accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: Spacing.sm) { content() }
        }
    }
}

private struct DoneStep: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(SLColor.success)
                .accessibilityHidden(true)
                .padding(.top, Spacing.xl)
            OnboardingTitle(
                title: "You’re all set",
                message: model.role == .creator
                    ? "Your feed is ready. When you’re ready to share a family recipe, tap New recipe in Profile."
                    : "Your feed is ready. Change any of this later in Profile."
            )
        }
    }
}

#Preview {
    OnboardingFlow().environment(AppEnvironment.preview(signedIn: true))
}
