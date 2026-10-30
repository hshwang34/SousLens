import SwiftUI

@main
struct SousLensApp: App {
    @State private var environment = AppEnvironment.live()

    init() {
        SLFont.applyNavigationBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(SLColor.accent)
        }
    }
}
