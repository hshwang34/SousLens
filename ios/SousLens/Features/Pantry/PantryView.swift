import SwiftUI

struct PantryView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            EmptyStateView(
                systemImage: "basket",
                title: "Your pantry is empty",
                message: "Add what you have and SousLens will tell you which recipes you can cook tonight.",
                primary: EmptyStateView.Action("Add pantry item", isEnabled: false, hint: "Coming in a later build"),
                secondary: EmptyStateView.Action("Try the demo recipe") {
                    environment.selectedTab = .explore
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SLColor.background)
            .navigationTitle("Pantry")
        }
    }
}
