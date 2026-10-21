import SwiftUI

/// Explore list card. Shows title, creator, total time, and tags.
struct RecipeCardView: View {
    let card: RecipeCard

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            cover
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(card.title)
                    .font(SLFont.title3)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.leading)
                Text("by \(card.creator.displayName)")
                    .font(SLFont.subheadline)
                    .foregroundStyle(SLColor.textSecondary)
            }
            HStack(spacing: Spacing.sm) {
                if let time = RecipeFormatting.totalTime(prep: card.prepMinutes, cook: card.cookMinutes) {
                    MetadataPill(text: time, systemImage: "clock", accessibilityLabel: "Total time \(time)")
                }
                MetadataPill(text: "Serves \(card.servings)", systemImage: "person.2")
            }
            if !card.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(card.tags, id: \.self) { tag in
                            MetadataPill(text: tag, style: .accent)
                        }
                    }
                }
                .accessibilityLabel("Tags: \(card.tags.joined(separator: ", "))")
            }
        }
        .padding(Spacing.lg)
        .background(SLColor.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(SLColor.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the recipe")
    }

    @ViewBuilder
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(SLColor.accentSoft)
            if let url = card.coverImageURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholderGlyph
                    }
                }
            } else {
                placeholderGlyph
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholderGlyph: some View {
        Image(systemName: "fork.knife")
            .font(.system(size: 36, weight: .light))
            .foregroundStyle(SLColor.accent)
    }
}

/// Shared formatting helpers for recipe metadata.
enum RecipeFormatting {
    static func totalTime(prep: Int?, cook: Int?) -> String? {
        let total = (prep ?? 0) + (cook ?? 0)
        guard total > 0 else { return nil }
        return minutes(total)
    }

    static func minutes(_ value: Int) -> String {
        if value >= 60 {
            let hours = value / 60
            let mins = value % 60
            return mins == 0 ? "\(hours) hr" : "\(hours) hr \(mins) min"
        }
        return "\(value) min"
    }

    /// "3 lb", "1½ tsp", "2 cloves" — quantity and unit joined for display.
    static func quantity(_ quantity: Double?, unit: String?) -> String? {
        var parts: [String] = []
        if let quantity {
            parts.append(number(quantity))
        }
        if let unit, !unit.isEmpty {
            parts.append(unit)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func number(_ value: Double) -> String {
        let whole = value.rounded(.down)
        let fraction = value - whole
        let fractionGlyph: String? = {
            switch fraction {
            case 0.24...0.26: return "¼"
            case 0.32...0.34: return "⅓"
            case 0.49...0.51: return "½"
            case 0.66...0.67: return "⅔"
            case 0.74...0.76: return "¾"
            default: return nil
            }
        }()
        if let fractionGlyph {
            return whole == 0 ? fractionGlyph : "\(Int(whole))\(fractionGlyph)"
        }
        if fraction == 0 {
            return String(Int(whole))
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
