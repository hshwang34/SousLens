import SwiftUI

/// The one way to put a control on glass (brief 006).
///
/// - iOS 26: Liquid Glass (`glassEffect`), merged by `AdaptiveGlassContainer`.
/// - iOS 17–25: a frosted material with a hairline edge.
/// - Reduce Transparency: a solid raised surface, every OS.
/// - Increase Contrast: a visible border on top, every OS.
///
/// Glass is for the **controls layer only**: the tab bar accessory, chips, the cooking tool
/// cluster and Back/Next. Recipe text, ingredients, step text, allergy and safety notices,
/// errors and dialogs are always drawn on a solid `SLColor` surface, never through this.
extension View {
    func adaptiveGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(AdaptiveGlassModifier(shape: shape, interactive: interactive))
    }

    func adaptiveGlass(interactive: Bool = false) -> some View {
        modifier(AdaptiveGlassModifier(shape: Capsule(), interactive: interactive))
    }
}

private struct AdaptiveGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(SLColor.surfaceRaised, in: shape)
            } else if #available(iOS 26.0, *) {
                content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5).blendMode(.overlay))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
        }
        .overlay {
            if contrast == .increased || reduceTransparency {
                shape.strokeBorder(contrast == .increased ? SLColor.textSecondary : SLColor.separator, lineWidth: 1)
            }
        }
    }
}

/// Groups glass controls so they blend and morph together on iOS 26; a plain stack elsewhere.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat = Spacing.sm
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Motion

extension Animation {
    /// Mise motion: gentle springs and unhurried reveals. Under Reduce Motion, a short crossfade.
    static func mise(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)
    }
}

extension AnyTransition {
    /// Slides in from `edge`; under Reduce Motion, crossfades only.
    static func misePush(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .push(from: edge)
    }
}
