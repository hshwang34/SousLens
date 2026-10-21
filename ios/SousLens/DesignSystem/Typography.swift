import SwiftUI

/// Type tokens. Every style is relative to a system text style so Dynamic Type scales it;
/// never use fixed point sizes in screens. Titles use the serif design for an editorial,
/// cookbook feel; body copy stays in the system sans for legibility at a distance.
enum SLFont {
    static let display = Font.system(.largeTitle, design: .serif, weight: .bold)
    static let title = Font.system(.title, design: .serif, weight: .bold)
    static let title2 = Font.system(.title2, design: .serif, weight: .semibold)
    static let title3 = Font.system(.title3, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body, design: .default)
    static let bodyEmphasis = Font.system(.body, design: .default, weight: .semibold)
    static let callout = Font.system(.callout, design: .default)
    static let subheadline = Font.system(.subheadline, design: .default)
    static let footnote = Font.system(.footnote, design: .default)
    static let caption = Font.system(.caption, design: .default, weight: .medium)
    static let overline = Font.system(.caption2, design: .default, weight: .semibold)
    /// Step numbers and quantities: monospaced digits keep columns aligned.
    static let numeral = Font.system(.title3, design: .rounded, weight: .bold).monospacedDigit()
}
