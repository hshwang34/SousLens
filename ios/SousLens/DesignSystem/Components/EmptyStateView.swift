import SwiftUI

/// Empty / error state with an illustration glyph, copy, and up to two actions.
struct EmptyStateView: View {
    struct Action {
        let title: String
        let isEnabled: Bool
        let hint: String?
        let handler: () -> Void

        init(_ title: String, isEnabled: Bool = true, hint: String? = nil, handler: @escaping () -> Void = {}) {
            self.title = title
            self.isEnabled = isEnabled
            self.hint = hint
            self.handler = handler
        }
    }

    let systemImage: String
    let title: String
    let message: String
    var primary: Action? = nil
    var secondary: Action? = nil

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: systemImage)
                .font(SLFont.glyph)
                .foregroundStyle(SLColor.accent)
                .padding(Spacing.xl)
                .background(SLColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: Spacing.sm) {
                Text(title)
                    .font(SLFont.title2)
                    .foregroundStyle(SLColor.textPrimary)
                Text(message)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            if let primary {
                actionButton(primary, prominent: true)
            }
            if let secondary {
                actionButton(secondary, prominent: false)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func actionButton(_ action: Action, prominent: Bool) -> some View {
        VStack(spacing: Spacing.xs) {
            Button(action.title, action: action.handler)
                .buttonStyle(SLButtonStyle(prominent: prominent))
                .disabled(!action.isEnabled)
            if let hint = action.hint {
                Text(hint)
                    .font(SLFont.footnote)
                    .foregroundStyle(SLColor.textSecondary)
            }
        }
    }
}

/// Primary / secondary button: a solid capsule (content layer, never glass). Always ≥44pt tall.
struct SLButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SLFont.bodyEmphasis)
            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
            .padding(.horizontal, Spacing.lg)
            .foregroundStyle(prominent ? SLColor.onAccent : SLColor.accent)
            .background(prominent ? SLColor.accent : SLColor.accentSoft, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension View {
    /// Dims disabled controls uniformly.
    func slDisabledAppearance(_ disabled: Bool) -> some View {
        opacity(disabled ? 0.45 : 1)
    }
}
