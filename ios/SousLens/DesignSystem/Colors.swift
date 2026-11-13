import SwiftUI

/// Color tokens (Umma "Persimmon", brief 013 / DECISIONS #23). Values live in
/// `Resources/Assets.xcassets` with light, dark and Increase Contrast variants; `BrandPalette`
/// mirrors them so a unit test can check every text / background pair for WCAG AA and that the
/// asset catalog hasn't drifted. This file is the only place that knows the asset names, so
/// screens never reference raw colors or asset strings.
///
/// Roles, in one line each:
/// - `brand` (Persimmon) is a **fill** colour: the primary button, icons, illustration. It is
///   2.5:1 on Flesh, so it is never text on a light background. Label it with `onBrand` (Seed).
/// - `accent` (Leaf) is the colour for **text and interactive tint**: links, chips, toggles.
/// - `success`, `warning`, `danger` are semantic and deliberately not brand hues, so a safety or
///   allergy notice never reads as decoration.
enum SLColor {
    /// Flesh: the persimmon's inside.
    static let background = Color("Background")
    static let surface = Color("Surface")
    static let surfaceRaised = Color("SurfaceRaised")
    /// Seed.
    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")
    /// Leaf: text-safe brand colour, the app tint, chips, links.
    static let accent = Color("Accent")
    static let accentSoft = Color("AccentSoft")
    /// Text and icons on a solid `accent` fill.
    static let onAccent = Color("OnAccent")
    /// Persimmon: fills only (primary button, icons, illustration). Never body text on light.
    static let brand = Color("Brand")
    /// A pale persimmon wash behind brand icons and empty-state glyphs.
    static let brandSoft = Color("BrandSoft")
    /// Text and icons on a solid `brand` fill (Seed, because white on Persimmon is 2.8:1).
    static let onBrand = Color("OnBrand")
    /// Deep persimmon: small emphasis text that isn't a warning (AA on Background and Surface).
    static let tomato = Color("Tomato")
    /// A teal green, kept apart from Leaf so "done" never looks like a tappable accent.
    static let success = Color("Success")
    static let warning = Color("Warning")
    /// Solid backing for warning / food-safety notices (never glass).
    static let warningSurface = Color("WarningSurface")
    /// Allergy and destructive: a crimson kept clearly redder than Persimmon.
    static let danger = Color("Danger")
    /// Solid backing for allergy notices (never glass).
    static let dangerSurface = Color("DangerSurface")
    /// Text and icons on a solid `danger` fill.
    static let onDanger = Color("OnDanger")
    static let separator = Color("Separator")
}

/// The Umma token table: the same hex values as the asset catalog, per appearance.
/// `SousLensTests/BrandTokenTests` checks every pair in `textPairs` is ≥ 4.5:1 (≥ 7:1 under
/// Increase Contrast), and that each asset resolves to the value here.
///
/// Dark mode is designed, not inverted: the backgrounds are warm Seed browns rather than grey,
/// Persimmon brightens slightly so the fill keeps its glow, and Leaf lifts to a soft sage so it
/// still reads as the same green at text sizes.
enum BrandPalette {
    struct Token: Sendable {
        let name: String
        let light: UInt32
        let dark: UInt32
        let lightHighContrast: UInt32
        let darkHighContrast: UInt32

        init(_ name: String, light: UInt32, dark: UInt32, lightHighContrast: UInt32, darkHighContrast: UInt32) {
            self.name = name
            self.light = light
            self.dark = dark
            self.lightHighContrast = lightHighContrast
            self.darkHighContrast = darkHighContrast
        }
    }

    enum Appearance: CaseIterable, Sendable {
        case light, dark, lightHighContrast, darkHighContrast
    }

    /// The four brand colours, as named in `docs/brand/README.md`.
    static let persimmon: UInt32 = 0xF2782A
    static let leaf: UInt32 = 0x2F6B3A
    static let flesh: UInt32 = 0xFFF1E6
    static let seed: UInt32 = 0x2A1C14

    static let tokens: [Token] = [
        Token("Background", light: 0xFFF1E6, dark: 0x1B130E, lightHighContrast: 0xFFF1E6, darkHighContrast: 0x0F0A07),
        Token("Surface", light: 0xFFFFFF, dark: 0x261B14, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x1C140F),
        Token("SurfaceRaised", light: 0xFFE4D0, dark: 0x33251C, lightHighContrast: 0xFFDFC7, darkHighContrast: 0x2B1F17),
        Token("TextPrimary", light: 0x2A1C14, dark: 0xFBEDE2, lightHighContrast: 0x1A100A, darkHighContrast: 0xFFFFFF),
        Token("TextSecondary", light: 0x6B5244, dark: 0xC9AE9C, lightHighContrast: 0x4A372C, darkHighContrast: 0xE8D6C8),
        Token("Accent", light: 0x2F6B3A, dark: 0x8ED39A, lightHighContrast: 0x1F5229, darkHighContrast: 0xB3E8BB),
        Token("AccentSoft", light: 0xE3EFDF, dark: 0x203626, lightHighContrast: 0xD4E7CF, darkHighContrast: 0x1A3021),
        Token("OnAccent", light: 0xFFFFFF, dark: 0x0E2413, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x06140A),
        Token("Brand", light: 0xF2782A, dark: 0xFF8A3D, lightHighContrast: 0xF2782A, darkHighContrast: 0xFF9C57),
        Token("BrandSoft", light: 0xFFDCC2, dark: 0x4A2814, lightHighContrast: 0xFFD3B3, darkHighContrast: 0x4A2814),
        Token("OnBrand", light: 0x2A1C14, dark: 0x2A1C14, lightHighContrast: 0x000000, darkHighContrast: 0x000000),
        Token("Tomato", light: 0xB04A12, dark: 0xFF9A5C, lightHighContrast: 0x8A3708, darkHighContrast: 0xFFB989),
        Token("Success", light: 0x00695C, dark: 0x5ED3C0, lightHighContrast: 0x004D43, darkHighContrast: 0x8FE6D8),
        Token("Warning", light: 0x6B5500, dark: 0xF0D04E, lightHighContrast: 0x4F3F00, darkHighContrast: 0xFFE07A),
        Token("WarningSurface", light: 0xFFF2B8, dark: 0x3A2F0A, lightHighContrast: 0xFFEEA6, darkHighContrast: 0x332908),
        Token("Danger", light: 0xB0122E, dark: 0xFF7A85, lightHighContrast: 0x86091F, darkHighContrast: 0xFFA3AA),
        Token("DangerSurface", light: 0xFFE0E3, dark: 0x42161D, lightHighContrast: 0xFFD5DA, darkHighContrast: 0x3D1219),
        Token("OnDanger", light: 0xFFFFFF, dark: 0x2A0A0F, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x1E0509),
        Token("Separator", light: 0xF0CDB4, dark: 0x45342A, lightHighContrast: 0x9A7A66, darkHighContrast: 0x9A8475),
    ]

    /// Fill colours that must never carry text on a light background (they fail 4.5:1).
    static let fillOnly: Set<String> = ["Brand", "BrandSoft"]

    /// Every foreground / background combination a screen may draw text in.
    static let textPairs: [(foreground: String, background: String)] = {
        var pairs: [(String, String)] = []
        for text in ["TextPrimary", "TextSecondary"] {
            for surface in ["Background", "Surface", "SurfaceRaised", "WarningSurface", "DangerSurface", "AccentSoft",
                            "BrandSoft"] {
                pairs.append((text, surface))
            }
        }
        for surface in ["Background", "Surface", "SurfaceRaised", "AccentSoft"] { pairs.append(("Accent", surface)) }
        for surface in ["Background", "Surface", "SurfaceRaised"] { pairs.append(("Success", surface)) }
        for surface in ["Background", "Surface", "SurfaceRaised", "WarningSurface"] { pairs.append(("Warning", surface)) }
        for surface in ["Background", "Surface", "SurfaceRaised", "DangerSurface", "WarningSurface"] {
            pairs.append(("Danger", surface))
        }
        for surface in ["Background", "Surface"] { pairs.append(("Tomato", surface)) }
        pairs.append(("OnAccent", "Accent"))
        pairs.append(("OnDanger", "Danger"))
        pairs.append(("OnBrand", "Brand"))
        return pairs
    }()

    static func token(_ name: String) -> Token? { tokens.first { $0.name == name } }

    static func hex(_ token: Token, _ appearance: Appearance) -> UInt32 {
        switch appearance {
        case .light: token.light
        case .dark: token.dark
        case .lightHighContrast: token.lightHighContrast
        case .darkHighContrast: token.darkHighContrast
        }
    }

    /// WCAG 2.x relative luminance of an sRGB hex colour.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
