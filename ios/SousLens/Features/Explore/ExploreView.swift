import SwiftUI

struct ExploreView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: ExploreViewModel?
    @State private var fits: ExploreFitLoader?
    /// Card → recipe zoom (iOS 18+).
    @Namespace private var zoom

    var body: some View {
        @Bindable var environment = environment
        NavigationStack(path: $environment.exploreRoutes) {
            Group {
                if let model, let fits {
                    ExploreContent(model: model, fits: fits, zoom: zoom)
                } else {
                    ExploreSkeleton()
                }
            }
            .background(SLColor.background)
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: RecipeRoute.self) { route in
                switch route {
                case .recipe(let id, let card):
                    RecipeDetailView(recipeId: id, card: card)
                        .zoomTransition(sourceID: card == nil ? nil : id, in: zoom, enabled: !reduceMotion)
                }
            }
        }
        .task {
            if model == nil {
                let created = ExploreViewModel(service: environment.api, cache: environment.recipeCache)
                let api = environment.api
                fits = ExploreFitLoader(fit: { try await api.fit(recipeVersionId: $0) })
                model = created
                await created.load()
            }
        }
    }
}

private struct ExploreContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: ExploreViewModel
    let fits: ExploreFitLoader
    let zoom: Namespace.ID
    @State private var filter: ExploreFilter = .all

    private var visibleCards: [RecipeCard] { filter.apply(to: model.cards, fits: fits.fits) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                if let notice = model.offlineNotice {
                    cachedBanner(notice)
                }
                switch model.phase {
                case .idle, .loading:
                    ExploreSkeleton.cards
                case .loaded:
                    filterChips
                    if visibleCards.isEmpty {
                        filteredEmptyState
                    }
                    ForEach(visibleCards) { card in
                        NavigationLink(value: RecipeRoute.card(card)) {
                            RecipeCardView(card: card, fit: fits.fits[card.recipeVersionId])
                                .zoomSource(id: card.recipeId, in: zoom)
                        }
                        .buttonStyle(.plain)
                    }
                case .empty:
                    emptyState
                case .error(let message, let retryable):
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "Recipes didn’t load",
                        message: message,
                        primary: retryable
                            ? EmptyStateView.Action("Try again") { Task { await model.refresh() } }
                            : nil
                    )
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.sm)
            .animation(.mise(reduceMotion: reduceMotion), value: filter)
        }
        .refreshable {
            await model.refresh()
        }
        .searchable(text: $model.searchText, prompt: "Search recipes or ingredients")
        .onSubmit(of: .search) {
            Task { await model.submitSearchNow() }
        }
        .task(id: FitKey(versions: model.cards.map(\.recipeVersionId), pantry: environment.pantryRevision)) {
            await fits.load(versionIds: model.cards.map(\.recipeVersionId), pantryRevision: environment.pantryRevision)
        }
    }

    private struct FitKey: Hashable {
        let versions: [UUID]
        let pantry: Int
    }

    // MARK: Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            AdaptiveGlassContainer(spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    ForEach(ExploreFilter.chips(for: model.cards), id: \.self) { chip in
                        FilterChipButton(title: chip.title, isSelected: filter == chip) {
                            filter = (filter == chip && chip != .all) ? .all : chip
                        }
                        .accessibilityIdentifier(chip.identifier)
                    }
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    // MARK: Empty and banner states

    private var filteredEmptyState: some View {
        EmptyStateView(
            systemImage: filter == .canMakeNow ? "basket" : "line.3.horizontal.decrease.circle",
            title: filter == .canMakeNow ? "Nothing you can make yet" : "No \(filter.title.lowercased()) recipes",
            message: filter == .canMakeNow
                ? "Add what’s on the shelf in Pantry and we’ll show what fits."
                : "Try another filter, or see everything.",
            primary: EmptyStateView.Action("Show all recipes") { filter = .all }
        )
    }

    private var emptyState: some View {
        let searching = !model.query.isEmpty
        return EmptyStateView(
            systemImage: searching ? "magnifyingglass" : "leaf",
            title: searching ? "No recipes match" : "The kitchen’s quiet",
            message: searching
                ? "Nothing matched “\(model.query)”. Try an ingredient you have."
                : "No recipes are published yet. Pull down to check again.",
            primary: searching
                ? EmptyStateView.Action("Clear search") { model.searchText = "" }
                : EmptyStateView.Action("Refresh") { Task { await model.refresh() } }
        )
    }

    /// Solid (content layer): an offline notice is never on glass.
    private func cachedBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Showing cached recipes")
                    .font(SLFont.headline)
                Text(notice)
                    .font(SLFont.footnote)
                if let at = model.cachedAt {
                    Text("Saved \(at, style: .relative) ago")
                        .font(SLFont.caption)
                }
            }
        }
        .foregroundStyle(SLColor.warning)
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.warningSurface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A filter chip: glass when idle, solid herb green when selected.
private struct FilterChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SLFont.subheadline.weight(.semibold))
                .padding(.horizontal, Spacing.lg)
                .frame(minHeight: Metrics.minTapTarget)
                .foregroundStyle(isSelected ? SLColor.onAccent : SLColor.textPrimary)
                .modifier(ChipBackground(isSelected: isSelected))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private struct ChipBackground: ViewModifier {
        let isSelected: Bool

        func body(content: Content) -> some View {
            if isSelected {
                content.background(SLColor.accent, in: Capsule())
            } else {
                content.adaptiveGlass(interactive: true)
            }
        }
    }
}

/// Skeleton loading: card-shaped placeholders instead of a spinner.
private struct ExploreSkeleton: View {
    var body: some View {
        ScrollView {
            Self.cards
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.sm)
        }
        .scrollDisabled(true)
    }

    static var cards: some View {
        VStack(spacing: Spacing.lg) {
            ForEach(0..<3, id: \.self) { _ in RecipeCardSkeleton() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading recipes")
    }
}

// MARK: - Card → recipe zoom (iOS 18+; a standard push before that and under Reduce Motion)

extension View {
    @ViewBuilder
    func zoomSource(id: UUID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomTransition(sourceID: UUID?, in namespace: Namespace.ID, enabled: Bool) -> some View {
        if #available(iOS 18.0, *), enabled, let sourceID {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}

#Preview {
    ExploreView().environment(AppEnvironment.preview())
}
