import SwiftUI

/// "Continue cooking <title> — step N" after launch / foreground (COOK-07).
struct ResumeBanner: View {
    let store: CookingSessionStore

    var body: some View {
        if let title = store.resumeTitle {
            HStack(spacing: Spacing.md) {
                Image(systemName: "flame.fill")
                    .font(.title2)
                    .foregroundStyle(SLColor.accent)
                    .accessibilityHidden(true)
                Button {
                    store.resume()
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(title)
                            .font(SLFont.headline)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(2)
                        Text(subtitle)
                            .font(SLFont.subheadline)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) — \(store.resumeStepText ?? "")")
                .accessibilityHint("Opens the cooking screen at the step the server has")
                .accessibilityIdentifier("resume.banner")
                Button {
                    store.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                }
                .accessibilityLabel("Not now")
                .accessibilityIdentifier("resume.dismiss")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .foregroundStyle(SLColor.textPrimary)
            // Controls layer: a resume prompt, not content.
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous), interactive: true)
            .padding(.horizontal, Spacing.md)
        }
    }

    private var subtitle: String {
        var text = store.resumeStepText ?? ""
        if store.activeIsFromCache { text += " · offline" }
        return text
    }
}

/// Current-session entry while browsing (PRD §6): the tab bar's bottom accessory on iOS 26.1+
/// (the system draws the glass), its own floating glass pill elsewhere.
struct CurrentSessionPill: View {
    enum Style { case floating, accessory }

    let store: CookingSessionStore
    var style: Style = .floating

    var body: some View {
        if let active = store.active {
            Button {
                store.resume()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(SLColor.tomato)
                        .accessibilityHidden(true)
                    Text(active.title).lineLimit(1)
                    Text("· \(store.resumeStepText ?? "")")
                        .font(SLFont.stepCounter)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(1)
                }
                .font(SLFont.callout.weight(.semibold))
                .foregroundStyle(SLColor.textPrimary)
                .padding(.horizontal, Spacing.lg)
                .frame(minHeight: Metrics.minTapTarget)
                .frame(maxWidth: style == .accessory ? .infinity : nil)
                .contentShape(Capsule())
                .modifier(PillBackground(style: style))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue cooking \(active.title), \(store.resumeStepText ?? "")")
            .accessibilityIdentifier("resume.pill")
        }
    }

    private struct PillBackground: ViewModifier {
        let style: Style

        func body(content: Content) -> some View {
            switch style {
            case .floating: content.adaptiveGlass(interactive: true)
            case .accessory: content
            }
        }
    }
}
