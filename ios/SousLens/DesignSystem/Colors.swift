import SwiftUI

/// Color tokens (Mise, brief 006). Values live in `Resources/Assets.xcassets` with light, dark and
/// Increase Contrast variants; `MisePalette` mirrors them so a unit test can check every text /
/// background pair for WCAG AA and that the asset catalog hasn't drifted. This file is the only
/// place that knows the asset names, so screens never reference raw colors or asset strings.
enum SLColor {
    /// Warm paper.
    static let background = Color("Background")
    static let surface = Color("Surface")
    static let surfaceRaised = Color("SurfaceRaised")
    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")
    /// Herb green.
    static let accent = Color("Accent")
    static let accentSoft = Color("AccentSoft")
    /// Text and icons on a solid `accent` fill.
    static let onAccent = Color("OnAccent")
    /// Tomato: the secondary brand colour, for emphasis that isn't a warning.
    static let tomato = Color("Tomato")
    static let success = Color("Success")
    static let warning = Color("Warning")
    /// Solid backing for warning / food-safety notices (never glass).
    static let warningSurface = Color("WarningSurface")
    /// Allergy and destructive.
    static let danger = Color("Danger")
    /// Solid backing for allergy notices (never glass).
    static let dangerSurface = Color("DangerSurface")
    /// Text and icons on a solid `danger` fill.
    static let onDanger = Color("OnDanger")
    static let separator = Color("Separator")
}

/// The Mise token table: the same hex values as the asset catalog, per appearance.
/// `SousLensTests/BrandTokenTests` checks every pair in `textPairs` is ≥ 4.5:1 in all four
/// appearances, and that each asset resolves to the value here.
enum MisePalette {
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

    static let tokens: [Token] = [
        Token("Background", light: 0xFBF6EE, dark: 0x16130F, lightHighContrast: 0xFBF6EE, darkHighContrast: 0x0D0B08),
        Token("Surface", light: 0xFFFFFF, dark: 0x221E19, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x1A1713),
        Token("SurfaceRaised", light: 0xF3ECE1, dark: 0x2D2822, lightHighContrast: 0xEFE6D8, darkHighContrast: 0x26211B),
        Token("TextPrimary", light: 0x2A2118, dark: 0xF5EEE3, lightHighContrast: 0x1A140E, darkHighContrast: 0xFFFFFF),
        Token("TextSecondary", light: 0x6A5D4F, dark: 0xB8AD9E, lightHighContrast: 0x4A3F33, darkHighContrast: 0xDDD3C4),
        Token("Accent", light: 0x2F6B3A, dark: 0x7FCB8C, lightHighContrast: 0x1F5229, darkHighContrast: 0xA6E3B0),
        Token("AccentSoft", light: 0xE4EEE2, dark: 0x22382A, lightHighContrast: 0xD6E6D3, darkHighContrast: 0x1C3323),
        Token("OnAccent", light: 0xFFFFFF, dark: 0x10230F, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x06140A),
        Token("Tomato", light: 0xB3401E, dark: 0xFF8F6B, lightHighContrast: 0x8E2F13, darkHighContrast: 0xFFB096),
        Token("Success", light: 0x2F6B3A, dark: 0x7FCB8C, lightHighContrast: 0x1F5229, darkHighContrast: 0xA6E3B0),
        Token("Warning", light: 0x8A5300, dark: 0xF2B24B, lightHighContrast: 0x6A3F00, darkHighContrast: 0xFFCB73),
        Token("WarningSurface", light: 0xFFF4D6, dark: 0x3A2A0E, lightHighContrast: 0xFFF0C7, darkHighContrast: 0x33240A),
        Token("Danger", light: 0xA4161A, dark: 0xFF7B72, lightHighContrast: 0x7F0F12, darkHighContrast: 0xFFA39C),
        Token("DangerSurface", light: 0xFCE9E6, dark: 0x3D1C19, lightHighContrast: 0xFADBD6, darkHighContrast: 0x3A1715),
        Token("OnDanger", light: 0xFFFFFF, dark: 0x2A0A08, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x1E0605),
        Token("Separator", light: 0xE6DCCD, dark: 0x3A332B, lightHighContrast: 0x8C7D6A, darkHighContrast: 0x8A7F70),
    ]

    /// Every foreground / background combination a screen may draw text in.
    static let textPairs: [(foreground: String, background: String)] = {
        var pairs: [(String, String)] = []
        for text in ["TextPrimary", "TextSecondary"] {
            for surface in ["Background", "Surface", "SurfaceRaised", "WarningSurface", "DangerSurface", "AccentSoft"] {
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
