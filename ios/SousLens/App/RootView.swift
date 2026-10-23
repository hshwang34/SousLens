import SwiftUI

/// Signed-out → sign-in; signed-in → the four P0 tabs (PRD §6).
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            switch environment.auth.state {
            case .restoring:
                ProgressView("Restoring session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SLColor.background)
            case .signedOut:
                SignInView()
            case .signedIn:
                MainTabView()
                    .onAppear { environment.applyPendingDeepLink() }
            }
        }
        .task {
            await environment.auth.restore()
        }
        .onChange(of: environment.auth.isSignedIn) { _, signedIn in
            // Session data is private to the account that was signed in.
            if !signedIn { environment.cooking.reset() }
        }
        .onOpenURL { url in
            environment.open(url: url)
        }
    }
}

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var environment = environment
        @Bindable var cooking = environment.cooking
        tabs
            .overlay(alignment: .top) {
                if cooking.showsBanner {
                    ResumeBanner(store: cooking)
                        .padding(.top, Spacing.xs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if cooking.showsPill {
                    // Above the tab bar.
                    CurrentSessionPill(store: cooking)
                        .padding(.bottom, 60)
                }
            }
            .animation(.default, value: cooking.showsBanner)
            .fullScreenCover(item: $cooking.presented, onDismiss: {
                Task { await environment.cooking.refresh() }
            }) { presentation in
                CookingView(presentation: presentation)
                    .environment(environment)
            }
            .task {
                // Launch: is there a session to resume?
                await environment.cooking.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await environment.cooking.refresh() } }
            }
    }

    private var tabs: some View {
        @Bindable var environment = environment
        return TabView(selection: $environment.selectedTab) {
            ExploreView()
                .tabItem { Label("Explore", systemImage: "sparkles.rectangle.stack") }
                .tag(AppEnvironment.Tab.explore)
            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .tag(AppEnvironment.Tab.saved)
            PantryView()
                .tabItem { Label("Pantry", systemImage: "basket") }
                .tag(AppEnvironment.Tab.pantry)
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppEnvironment.Tab.profile)
        }
    }
}

#Preview("Signed out") {
    RootView().environment(AppEnvironment.preview(signedIn: false))
}
