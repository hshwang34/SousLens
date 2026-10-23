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
            }
        }
        .task {
            await environment.auth.restore()
        }
    }
}

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var environment = environment
        TabView(selection: $environment.selectedTab) {
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
