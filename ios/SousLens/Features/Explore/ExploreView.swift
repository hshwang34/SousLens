import SwiftUI

struct ExploreView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: ExploreViewModel?

    var body: some View {
        @Bindable var environment = environment
        NavigationStack(path: $environment.exploreRoutes) {
            Group {
                if let model {
                    ExploreContent(model: model)
                } else {
                    ProgressView()
                }
            }
            .background(SLColor.background)
            .navigationTitle("Explore")
            .navigationDestination(for: RecipeRoute.self) { route in
                switch route {
                case .recipe(let id, let card):
                    RecipeDetailView(recipeId: id, card: card)
                }
            }
        }
        .task {
            if model == nil {
                let created = ExploreViewModel(service: environment.api, cache: environment.recipeCache)
                model = created
                await created.load()
            }
        }
    }
}

private struct ExploreContent: View {
    @Bindable var model: ExploreViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                if let notice = model.offlineNotice {
                    cachedBanner(notice)
                }
                switch model.phase {
                case .idle, .loading:
                    loadingState
                case .loaded:
                    ForEach(model.cards) { card in
                        NavigationLink(value: RecipeRoute.card(card)) {
                            RecipeCardView(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                case .empty:
                    emptyState
                case .error(let message, let retryable):
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "Couldn’t load recipes",
                        message: message,
                        primary: retryable
                            ? EmptyStateView.Action("Try again") { Task { await model.refresh() } }
                            : nil
                    )
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.lg)
        }
        .refreshable {
            await model.refresh()
        }
        .searchable(text: $model.searchText, prompt: "Search recipes or ingredients")
        .onSubmit(of: .search) {
            Task { await model.submitSearchNow() }
        }
    }

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text("Loading recipes…")
                .font(SLFont.subheadline)
                .foregroundStyle(SLColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        let searching = !model.query.isEmpty
        return EmptyStateView(
            systemImage: searching ? "magnifyingglass" : "frying.pan",
            title: searching ? "No recipes match" : "Nothing here yet",
            message: searching
                ? "Nothing matched “\(model.query)”."
                : "Try the demo recipe — seed the backend with `make seed`, then pull to refresh.",
            primary: searching
                ? EmptyStateView.Action("Clear search") { model.searchText = "" }
                : EmptyStateView.Action("Refresh") { Task { await model.refresh() } }
        )
    }

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
        .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ExploreView().environment(AppEnvironment.preview())
}
