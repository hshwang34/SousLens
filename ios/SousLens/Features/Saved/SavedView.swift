import SwiftUI

struct SavedView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            EmptyStateView(
                systemImage: "bookmark",
                title: "No saved recipes",
                message: "Recipes you save will live here so you can cook them again.",
                primary: EmptyStateView.Action("Try the demo recipe") {
                    environment.selectedTab = .explore
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SLColor.background)
            .navigationTitle("Saved")
        }
    }
}
