import SwiftUI

// Brief 015 onboarding steps 5–7: follow creators, pantry, done.

struct FollowStep: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            OnboardingTitle(
                title: "Follow cooks you’ll love",
                message: model.cuisines.isEmpty
                    ? "Their recipes show up in your Following feed. Follow as many as you like."
                    : "Picked for the cuisines you chose. Their recipes show up in your Following feed."
            )
            switch model.suggestionsPhase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, Spacing.xl)
            case .error(let message):
                EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn’t load cooks", message: message,
                               primary: EmptyStateView.Action("Try again") { Task { await model.loadSuggestions() } })
            case .loaded where model.suggestions.isEmpty:
                Text("No cooks to suggest yet. You can follow people later from any recipe.")
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textSecondary)
            case .loaded:
                VStack(spacing: Spacing.md) {
                    ForEach(model.suggestions) { creator in
                        CreatorSuggestionRow(creator: creator, isBusy: model.followBusy.contains(creator.id)) {
                            Task { await model.toggleFollow(creator.id) }
                        }
                    }
                }
            }
        }
        .task(id: model.cuisines) { await model.loadSuggestions() }
    }
}

/// Avatar, name, bio, two recipe titles and a Follow toggle. Reused on the creator profile list.
struct CreatorSuggestionRow: View {
    let creator: CreatorSummary
    let isBusy: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            MonogramAvatar(initials: creator.initials)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(creator.displayName).font(SLFont.headline).foregroundStyle(SLColor.textPrimary)
                if let bio = creator.bio {
                    Text(bio).font(SLFont.subheadline).foregroundStyle(SLColor.textSecondary).lineLimit(2)
                }
                if !creator.sampleRecipeTitles.isEmpty {
                    Text(creator.sampleRecipeTitles.joined(separator: " · "))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            FollowButton(isFollowing: creator.isFollowing, isBusy: isBusy, action: onToggle)
        }
        .padding(Spacing.md)
        .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.creator.\(creator.displayName)")
    }
}

struct FollowButton: View {
    let isFollowing: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isFollowing ? "Following" : "Follow")
                .font(SLFont.subheadline.weight(.semibold))
                .padding(.horizontal, Spacing.md)
                .frame(minHeight: Metrics.minTapTarget)
                .foregroundStyle(isFollowing ? SLColor.textPrimary : SLColor.onAccent)
                .background(isFollowing ? SLColor.accentSoft : SLColor.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityAddTraits(isFollowing ? .isSelected : [])
    }
}

struct PantryStep: View {
    @Environment(AppEnvironment.self) private var environment
    let model: OnboardingViewModel
    @State private var capture: PantryCaptureKind?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            OnboardingTitle(
                title: "What’s in your kitchen?",
                message: "Snap your fridge or shelf, or just say what you have. You check every item before it’s added, and photos aren’t kept."
            )
            if model.pantryItemsAdded > 0 {
                Label("Added \(model.pantryItemsAdded) item\(model.pantryItemsAdded == 1 ? "" : "s") to your pantry",
                      systemImage: "checkmark.circle.fill")
                    .font(SLFont.headline)
                    .foregroundStyle(SLColor.success)
                    .accessibilityIdentifier("onboarding.pantry.added")
            }
            choice("camera.fill", "Scan my pantry", "One photo of a shelf or the fridge.") { capture = .scan }
                .accessibilityIdentifier("onboarding.pantry.scan")
            choice("mic.fill", "Say what I have", "Talk or type a list, like “eggs, rice, kimchi”.") { capture = .speak }
                .accessibilityIdentifier("onboarding.pantry.speak")
            Text("Not now? Tap Skip. You can scan any time from the Pantry tab.")
                .font(SLFont.footnote)
                .foregroundStyle(SLColor.textSecondary)
        }
        .sheet(item: $capture) { kind in
            PantryCaptureSheet(kind: kind, existingItems: []) { added in
                model.pantryAdded(added.count)
                environment.notePantryChanged()
            }
        }
    }

    private func choice(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: symbol)
                    .font(SLFont.title3)
                    .foregroundStyle(SLColor.accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title).font(SLFont.headline).foregroundStyle(SLColor.textPrimary)
                    Text(detail).font(SLFont.subheadline).foregroundStyle(SLColor.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(SLColor.textSecondary).accessibilityHidden(true)
            }
            .padding(Spacing.lg)
            .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct DoneStep: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(SLColor.success)
                .accessibilityHidden(true)
                .padding(.top, Spacing.xl)
            OnboardingTitle(title: "You’re all set", message: summary)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if model.followingCount > 0 {
            parts.append("Following \(model.followingCount) cook\(model.followingCount == 1 ? "" : "s").")
        }
        if model.pantryItemsAdded > 0 {
            parts.append("For You is ranked by what’s in your pantry.")
        } else {
            parts.append("Scan your pantry any time to see what you can make tonight.")
        }
        if model.role == .creator {
            parts.append("Ready to share a family recipe? Start it now or later from Profile.")
        }
        return parts.joined(separator: " ")
    }
}
