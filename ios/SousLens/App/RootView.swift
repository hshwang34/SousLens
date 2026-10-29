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
        .onOpenURL { url in
            environment.open(url: url)
        }
    }
}

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var environment = environment
        @Bindable var cooking = environment.cooking
        tabs
            .overlay(alignment: .top) {
                if cooking.showsBanner {
                    ResumeBanner(store: cooking)
                        .padding(.top, Spacing.xs)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.mise(reduceMotion: reduceMotion), value: cooking.showsBanner)
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
        let cooking = environment.cooking
        return TabView(selection: $environment.selectedTab) {
            ExploreView()
                .resumePillInset(cooking)
                .tabItem { Label("Explore", systemImage: "sparkles.rectangle.stack") }
                .tag(AppEnvironment.Tab.explore)
            SavedView()
                .resumePillInset(cooking)
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .tag(AppEnvironment.Tab.saved)
            PantryView()
                .resumePillInset(cooking)
                .tabItem { Label("Pantry", systemImage: "basket") }
                .tag(AppEnvironment.Tab.pantry)
            ProfileView()
                .resumePillInset(cooking)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppEnvironment.Tab.profile)
        }
        .modifier(MiseTabBar(cooking: cooking))
    }
}

/// iOS 26.1+: the tab bar minimises on scroll and the resume pill is its bottom accessory.
/// iOS 26.0: minimises on scroll; the pill floats (26.0 has no way to hide an empty accessory).
/// iOS 17–25: the standard tab bar; the pill floats (`resumePillInset`).
private struct MiseTabBar: ViewModifier {
    let cooking: CookingSessionStore

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory(isEnabled: cooking.showsPill) {
                    CurrentSessionPill(store: cooking, style: .accessory)
                }
        } else if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }

    /// Whether the pill lives in the tab bar accessory on this OS.
    static var usesAccessory: Bool {
        if #available(iOS 26.1, *) { return true }
        return false
    }
}

private extension View {
    /// The floating resume pill, inset above the tab bar (no fixed offsets: the inset is laid out
    /// inside the tab's safe area, so it sits on the bar at any size and on any OS).
    func resumePillInset(_ cooking: CookingSessionStore) -> some View {
        modifier(ResumePillInset(cooking: cooking))
    }
}

private struct ResumePillInset: ViewModifier {
    let cooking: CookingSessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if !MiseTabBar.usesAccessory, cooking.showsPill {
                CurrentSessionPill(store: cooking, style: .floating)
                    .padding(.bottom, Spacing.sm)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.mise(reduceMotion: reduceMotion), value: cooking.showsPill)
    }
}

#Preview("Signed out") {
    RootView().environment(AppEnvironment.preview(signedIn: false))
}
