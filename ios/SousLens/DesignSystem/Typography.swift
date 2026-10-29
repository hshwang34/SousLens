import SwiftUI
import UIKit

/// Type tokens (Mise, brief 006). Every style is relative to a system text style so Dynamic Type
/// scales it; never use fixed point sizes in screens.
/// - New York (`.serif`) for display and titles: the cookbook voice.
/// - SF Pro (`.default`) for body copy, legible at a distance.
/// - SF Rounded (`.rounded`) for quantities, timers and step numbers.
enum SLFont {
    static let display = Font.system(.largeTitle, design: .serif, weight: .bold)
    static let title = Font.system(.title, design: .serif, weight: .bold)
    static let title2 = Font.system(.title2, design: .serif, weight: .bold)
    static let title3 = Font.system(.title3, design: .serif, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body, design: .default)
    static let bodyEmphasis = Font.system(.body, design: .default, weight: .semibold)
    static let callout = Font.system(.callout, design: .default)
    static let subheadline = Font.system(.subheadline, design: .default)
    static let footnote = Font.system(.footnote, design: .default)
    static let caption = Font.system(.caption, design: .default, weight: .medium)
    static let overline = Font.system(.caption2, design: .default, weight: .semibold)
    /// Step numbers in lists: monospaced digits keep columns aligned.
    static let numeral = Font.system(.title3, design: .rounded, weight: .bold).monospacedDigit()
    /// Ingredient quantities ("1½ tsp").
    static let quantity = Font.system(.body, design: .rounded, weight: .semibold).monospacedDigit()
    /// "Step 4 of 6" over the cooking step.
    static let stepCounter = Font.system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit()
    /// The cooking step itself: read from arm's length.
    static let stepText = Font.system(.title, design: .serif, weight: .semibold)
    /// Timer countdowns.
    static let timer = Font.system(.title, design: .rounded, weight: .bold).monospacedDigit()
    /// Big numerals (pantry-fit count).
    static let bigNumeral = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
    /// Decorative glyphs in empty states and placeholders (scales with Dynamic Type).
    static let glyph = Font.system(.largeTitle, design: .default, weight: .light)

    /// UIKit navigation bars: New York for large and inline titles. Called once at launch.
    @MainActor
    static func applyNavigationBarAppearance() {
        func serif(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
            // Start from the default (Large) size and let UIFontMetrics apply the user's setting.
            let base = UIFontDescriptor.preferredFontDescriptor(
                withTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
            let weighted = base.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            let descriptor = weighted.withDesign(.serif) ?? weighted
            return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: 0))
        }
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [
            .font: serif(.largeTitle, weight: .bold),
            .foregroundColor: UIColor(named: "TextPrimary") ?? .label,
        ]
        bar.titleTextAttributes = [
            .font: serif(.headline, weight: .semibold),
            .foregroundColor: UIColor(named: "TextPrimary") ?? .label,
        ]
    }
}
