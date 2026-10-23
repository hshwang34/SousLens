import SwiftUI

/// Saved tab: `GET /v1/me/saved`, newest first. Reloads whenever the tab appears so a save made
/// on a detail screen shows up without a manual refresh.
struct SavedView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: SavedViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    SavedContent(model: model)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SLColor.background)
            .navigationTitle("Saved")
            .navigationDestination(for: RecipeRoute.self) { route in
                switch route {
                case .recipe(let id, let card):
                    RecipeDetailView(recipeId: id, card: card)
                }
            }
        }
        .task {
            if model == nil {
                let created = SavedViewModel(service: environment.api)
                model = created
                await created.load()
            } else {
                await model?.refresh()
            }
        }
    }
}

private struct SavedContent: View {
    @Environment(AppEnvironment.self) private var environment
    let model: SavedViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                switch model.phase {
                case .idle, .loading:
                    VStack(spacing: Spacing.md) {
                        ProgressView()
                        Text("Loading saved recipes…")
                            .font(SLFont.subheadline)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.xxl)
                    .accessibilityElement(children: .combine)
                case .loaded:
                    ForEach(model.cards) { card in
                        NavigationLink(value: RecipeRoute.card(card)) {
                            RecipeCardView(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                case .empty:
                    EmptyStateView(
                        systemImage: "bookmark",
                        title: "No saved recipes",
                        message: "Recipes you save will live here so you can cook them again.",
                        primary: EmptyStateView.Action("Try the demo recipe") {
                            environment.selectedTab = .explore
                        }
                    )
                case .error(let message, let retryable):
                    EmptyStateView(
                        systemImage: "wifi.exclamationmark",
                        title: "Couldn’t load saved recipes",
                        message: message,
                        primary: retryable ? EmptyStateView.Action("Try again") { Task { await model.refresh() } } : nil
                    )
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.lg)
        }
        .refreshable { await model.refresh() }
        .onAppear { Task { await model.refresh() } }
    }
}

#Preview {
    SavedView().environment(AppEnvironment.preview())
}
