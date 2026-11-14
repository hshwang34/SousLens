import SwiftUI

/// A toggle chip for multi- and single-select lists (brief 015 onboarding, Preferences):
/// glass when idle, solid accent with a checkmark when selected.
struct SelectableChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(SLFont.caption.weight(.bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(SLFont.subheadline.weight(.semibold))
            }
            .padding(.horizontal, Spacing.lg)
            .frame(minHeight: Metrics.minTapTarget)
            .foregroundStyle(isSelected ? SLColor.onAccent : SLColor.textPrimary)
            .modifier(Background(isSelected: isSelected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private struct Background: ViewModifier {
        let isSelected: Bool

        func body(content: Content) -> some View {
            if isSelected {
                content.background(SLColor.accent, in: Capsule())
            } else {
                content.adaptiveGlass(interactive: true)
            }
        }
    }
}

/// A circular monogram avatar for creators without a picture (brief 015 seeded personas).
struct MonogramAvatar: View {
    let initials: String
    var size: CGFloat = 48

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(SLColor.onAccent)
            .frame(width: size, height: size)
            .background(SLColor.accent, in: Circle())
            .accessibilityHidden(true)
    }
}
