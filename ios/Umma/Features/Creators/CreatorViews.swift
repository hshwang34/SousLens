import SwiftUI

/// Brief 015: a creator's page. Reached from a recipe's "by …" line or Profile → Following.
struct CreatorProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    let creatorId: UUID
    @State private var model: CreatorProfileViewModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background)
        .navigationTitle(model?.profile?.creator.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = CreatorProfileViewModel(creatorId: creatorId, service: environment.api)
            created.onFollowChanged = { [environment] in environment.noteFollowChanged() }
            model = created
            await created.load()
        }
    }

    @ViewBuilder
    private func content(_ model: CreatorProfileViewModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            EmptyStateView(systemImage: "person.crop.circle.badge.questionmark", title: "Nothing here",
                           message: "This cook hasn’t published any recipes.")
        case .error(let message):
            EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn’t load this cook", message: message,
                           primary: EmptyStateView.Action("Try again") { Task { await model.load() } })
        case .loaded:
            if let profile = model.profile {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        header(profile.creator, model: model)
                        Text("Recipes")
                            .font(SLFont.title3)
                            .foregroundStyle(SLColor.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(profile.recipes) { card in
                            NavigationLink(value: RecipeRoute.card(card)) {
                                RecipeCardView(card: card)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Spacing.screen)
                    .padding(.vertical, Spacing.md)
                }
                .refreshable { await model.load() }
            }
        }
    }

    private func header(_ creator: CreatorSummary, model: CreatorProfileViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                MonogramAvatar(initials: creator.initials, size: 72)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(creator.displayName)
                        .font(SLFont.brandHeadline)
                        .foregroundStyle(SLColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(creator.recipeCount) recipe\(creator.recipeCount == 1 ? "" : "s") · \(creator.followerCount) follower\(creator.followerCount == 1 ? "" : "s")")
                        .font(SLFont.subheadline)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            if let bio = creator.bio {
                Text(bio).font(SLFont.body).foregroundStyle(SLColor.textPrimary)
            }
            if environment.auth.user?.id != creator.id {
                FollowButton(isFollowing: creator.isFollowing, isBusy: model.isTogglingFollow) {
                    Task { await model.toggleFollow() }
                }
                .accessibilityIdentifier("creator.follow")
            }
            if let error = model.followError {
                Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
            }
        }
        .padding(.bottom, Spacing.sm)
    }
}

/// Profile → Following.
struct FollowingListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: FollowingListViewModel?

    var body: some View {
        Group {
            if let model {
                switch model.phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error(let message):
                    EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn’t load who you follow", message: message,
                                   primary: EmptyStateView.Action("Try again") { Task { await model.load() } })
                case .loaded where model.creators.isEmpty:
                    EmptyStateView(systemImage: "person.2", title: "Not following anyone yet",
                                   message: "Open a recipe and tap the cook’s name to see their page and follow them.")
                case .loaded:
                    list(model)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background)
        .navigationTitle("Following")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let created = FollowingListViewModel(service: environment.api)
                created.onFollowChanged = { [environment] in environment.noteFollowChanged() }
                model = created
            }
            await model?.load()
        }
    }

    private func list(_ model: FollowingListViewModel) -> some View {
        List {
            if let error = model.actionError {
                Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
            }
            ForEach(model.creators) { creator in
                NavigationLink(value: RecipeRoute.creator(id: creator.id)) {
                    HStack(spacing: Spacing.md) {
                        MonogramAvatar(initials: creator.initials, size: 40)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(creator.displayName).font(SLFont.headline)
                            Text("\(creator.recipeCount) recipe\(creator.recipeCount == 1 ? "" : "s")")
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textSecondary)
                        }
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                }
                .swipeActions {
                    Button("Unfollow", role: .destructive) { Task { await model.unfollow(creator.id) } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }
}

/// Profile → "Diets, cuisines & skill" (brief 015 taste profile).
struct TastePreferencesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: TastePreferencesViewModel?

    var body: some View {
        Group {
            if let model {
                switch model.phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error(let message):
                    EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn’t load your taste", message: message,
                                   primary: EmptyStateView.Action("Try again") { Task { await model.load() } })
                case .loaded:
                    form(model)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SLColor.background)
        .navigationTitle("Diets, cuisines & skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { _ = await model?.save() } }
                    .disabled(!(model?.hasChanges ?? false) || (model?.isSaving ?? true))
            }
        }
        .task {
            guard model == nil else { return }
            let created = TastePreferencesViewModel(preferences: environment.api, onboarding: environment.api)
            model = created
            await created.load()
        }
    }

    private func form(_ model: TastePreferencesViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                group("Diets") {
                    ForEach(TasteOptions.diets) { o in
                        SelectableChip(title: o.label, isSelected: model.diets.contains(o.id)) { model.toggleDiet(o.id) }
                    }
                }
                group("Cuisines you love") {
                    ForEach(TasteOptions.cuisines) { o in
                        SelectableChip(title: o.label, isSelected: model.cuisines.contains(o.id)) { model.toggleCuisine(o.id) }
                    }
                }
                group("Cooking skill") {
                    ForEach(TasteOptions.skillLevels) { o in
                        SelectableChip(title: o.label, isSelected: model.skillLevel == o.id) {
                            model.skillLevel = model.skillLevel == o.id ? nil : o.id
                        }
                    }
                }
                Text("Used to rank For You and suggest cooks. It never hides a recipe; allergies live under Allergies & foods to avoid.")
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
                if let error = model.saveError {
                    Text(error).font(SLFont.footnote).foregroundStyle(SLColor.danger)
                }
            }
            .padding(Spacing.screen)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(title).font(SLFont.headline).accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: Spacing.sm) { content() }
        }
    }
}
