import SwiftUI

/// Color tokens. Values live in `Resources/Assets.xcassets` (light + dark variants); this file is
/// the only place that knows the asset names, so screens never reference raw colors or asset strings.
enum SLColor {
    static let background = Color("Background")
    static let surface = Color("Surface")
    static let surfaceRaised = Color("SurfaceRaised")
    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")
    static let accent = Color("Accent")
    static let accentSoft = Color("AccentSoft")
    static let success = Color("Success")
    static let warning = Color("Warning")
    static let danger = Color("Danger")
    static let separator = Color("Separator")
}
