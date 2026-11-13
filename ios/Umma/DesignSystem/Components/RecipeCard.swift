import SwiftUI

/// Explore / Saved card (brief 006): a full-bleed cover with an optional glass pantry-fit chip,
/// then the title in New York and one quiet metadata line. The card itself is content (solid);
/// only the fit chip sits on glass, over a scrim so it stays legible on any photo.
struct RecipeCardView: View {
    let card: RecipeCard
    var fit: CardFitSummary? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RecipeCoverArt(url: card.coverImageURL, seed: card.recipeId)
                    .aspectRatio(Metrics.cardAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
                if let chip = fit?.chipText {
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                        .accessibilityHidden(true)
                    FitChip(text: chip, complete: fit?.hasEverything == true)
                        .padding(Spacing.md)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(card.title)
                    .font(SLFont.title3)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(metadataLine)
                    .font(SLFont.subheadline)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SLColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the recipe")
    }

    /// "by Min-ji Park · 40 min · Serves 4"
    private var metadataLine: String {
        var parts = ["by \(card.creator.displayName)"]
        if let time = RecipeFormatting.totalTime(prep: card.prepMinutes, cook: card.cookMinutes) { parts.append(time) }
        parts.append("Serves \(card.servings)")
        return parts.joined(separator: " · ")
    }
}

/// "You have 9 of 10" on a card cover. Glass (controls layer), over the card's scrim.
struct FitChip: View {
    let text: String
    var complete = false

    var body: some View {
        Label(text, systemImage: complete ? "checkmark.circle.fill" : "basket")
            .font(SLFont.caption.weight(.semibold))
            .foregroundStyle(SLColor.textPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .adaptiveGlass()
    }
}

/// A recipe's cover photo, or a warm Mise gradient (picked from the recipe id) until it has one.
struct RecipeCoverArt: View {
    let url: URL?
    let seed: UUID

    var body: some View {
        ZStack {
            MiseArt.gradient(for: seed)
            Image(systemName: "fork.knife")
                .font(SLFont.glyph)
                .foregroundStyle(.white.opacity(0.75))
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
    }
}

/// Decorative art. Not tokens: never used for text or backgrounds behind text.
enum MiseArt {
    private static let palettes: [[UInt32]] = [
        [0xC9572B, 0xE8A04A, 0x6E8B3D],
        [0x8B3A1E, 0xD27A3A],
        [0x2F6B3A, 0x8DAA5B],
        [0xB3401E, 0xE8A04A],
        [0x6E8B3D, 0xC9A24A],
    ]

    static func gradient(for seed: UUID) -> LinearGradient {
        let index = Int(seed.uuid.0) % palettes.count
        return LinearGradient(colors: palettes[index].map(color), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Loading placeholder with the card's shape. Breathes gently; still under Reduce Motion.
struct RecipeCardSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(SLColor.surfaceRaised)
                .aspectRatio(Metrics.cardAspect, contentMode: .fit)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Capsule().fill(SLColor.surfaceRaised).frame(width: 200, height: 14)
                Capsule().fill(SLColor.surfaceRaised).frame(width: 140, height: 10)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
        }
        .background(SLColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .opacity(dim ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityHidden(true)
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
