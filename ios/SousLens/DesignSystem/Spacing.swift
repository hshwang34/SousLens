import SwiftUI

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let screen: CGFloat = 20
    static let section: CGFloat = 28
}

enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 18
    static let card: CGFloat = 22
    static let pill: CGFloat = 999
}

enum Metrics {
    /// PRD §14: minimum tap target.
    static let minTapTarget: CGFloat = 44
    static let heroAspect: CGFloat = 4.0 / 3.0
    static let cardAspect: CGFloat = 16.0 / 10.0
    /// Cooking Back / Next height (PRD §6.1: the phone may be propped at a distance).
    static let cookingControl: CGFloat = 64
}
