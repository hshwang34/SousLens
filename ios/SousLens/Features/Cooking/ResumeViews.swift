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
            .background(SLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, Spacing.md)
        }
    }

    private var subtitle: String {
        var text = store.resumeStepText ?? ""
        if store.activeIsFromCache { text += " · offline" }
        return text
    }
}

/// Floating current-session entry while browsing (PRD §6).
struct CurrentSessionPill: View {
    let store: CookingSessionStore

    var body: some View {
        if let active = store.active {
            Button {
                store.resume()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "flame.fill").accessibilityHidden(true)
                    Text(active.title).lineLimit(1)
                    Text("· \(store.resumeStepText ?? "")").monospacedDigit()
                }
                .font(SLFont.callout.weight(.semibold))
                .padding(.horizontal, Spacing.lg)
                .frame(minHeight: Metrics.minTapTarget)
                .foregroundStyle(Color.white)
                .background(SLColor.accent, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue cooking \(active.title), \(store.resumeStepText ?? "")")
            .accessibilityIdentifier("resume.pill")
        }
    }
}
