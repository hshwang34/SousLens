import SwiftUI
import UIKit

/// Type tokens (Umma, brief 013 / DECISIONS #23). Every style is relative to a system text style
/// so Dynamic Type scales it; never use fixed point sizes in screens.
/// - Bagel Fat One for the wordmark and large display titles only: the brand moment. It covers
///   Hangul, so Korean recipe titles set in it too. Bundled under `Resources/Fonts` (OFL 1.1).
/// - SF Pro (`.default`) for everything else: titles, body, controls.
/// - SF Rounded (`.rounded`) for quantities, timers and step numbers.
enum SLFont {
    /// PostScript name of the bundled display face (registered via `UIAppFonts` in project.yml).
    static let brandFontName = "BagelFatOne-Regular"

    /// Large display titles: recipe title, sign-in. Scales with Dynamic Type from 34 pt.
    static let display = Font.custom(brandFontName, size: 34, relativeTo: .largeTitle)
    /// Empty-state and onboarding headlines.
    static let brandHeadline = Font.custom(brandFontName, size: 24, relativeTo: .title2)
    /// The "umma" wordmark set live (the sign-in header). Logos aren't held to text contrast,
    /// but it still scales so it never crowds the copy under it at large sizes.
    static let wordmark = Font.custom(brandFontName, size: 44, relativeTo: .largeTitle)
    static let title = Font.system(.title, design: .default, weight: .bold)
    static let title2 = Font.system(.title2, design: .default, weight: .bold)
    static let title3 = Font.system(.title3, design: .default, weight: .semibold)
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
    static let stepText = Font.system(.title, design: .default, weight: .semibold)
    /// Timer countdowns.
    static let timer = Font.system(.title, design: .rounded, weight: .bold).monospacedDigit()
    /// Big numerals (pantry-fit count).
    static let bigNumeral = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
    /// Decorative glyphs in empty states and placeholders (scales with Dynamic Type).
    static let glyph = Font.system(.largeTitle, design: .default, weight: .light)

    /// UIKit navigation bars: Bagel Fat One for large titles (Explore, Saved, Pantry, Profile),
    /// SF Pro semibold for inline titles. Called once at launch.
    @MainActor
    static func applyNavigationBarAppearance() {
        let bar = UINavigationBar.appearance()
        let text = UIColor(named: "TextPrimary") ?? .label
        bar.largeTitleTextAttributes = [.font: brandUIFont(.largeTitle, size: 34), .foregroundColor: text]
        bar.titleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold)),
            .foregroundColor: text,
        ]
    }

    /// Bagel Fat One at `size` (the Large content-size default), scaled for `style` by
    /// UIFontMetrics. Falls back to the bold system font if the bundle font failed to register.
    static func brandUIFont(_ style: UIFont.TextStyle, size: CGFloat) -> UIFont {
        let base = UIFont(name: brandFontName, size: size) ?? .systemFont(ofSize: size, weight: .bold)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
}
