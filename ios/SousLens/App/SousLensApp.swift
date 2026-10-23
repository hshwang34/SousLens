import SwiftUI

@main
struct SousLensApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(SLColor.accent)
        }
    }
}
