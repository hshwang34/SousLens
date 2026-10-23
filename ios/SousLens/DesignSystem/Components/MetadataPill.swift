import SwiftUI

/// Small labelled capsule for recipe metadata (prep time, servings, tags).
struct MetadataPill: View {
    enum Style { case neutral, accent }

    let text: String
    var systemImage: String? = nil
    var style: Style = .neutral
    var accessibilityLabel: String? = nil

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(SLFont.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.sm + 2)
        .padding(.vertical, Spacing.xs + 1)
        .foregroundStyle(style == .accent ? SLColor.accent : SLColor.textSecondary)
        .background(style == .accent ? SLColor.accentSoft : SLColor.surfaceRaised, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? text)
    }
}

#Preview {
    HStack {
        MetadataPill(text: "40 min", systemImage: "clock")
        MetadataPill(text: "Serves 4", systemImage: "person.2")
        MetadataPill(text: "korean", style: .accent)
    }
    .padding()
    .background(SLColor.background)
}
