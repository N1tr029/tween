import SwiftUI
import UIKit

/// Tween's single source of truth for design values. New UI code must read from this
/// namespace — never inline. See `.agents/skills/tween-design/SKILL.md` for the rules.
enum Tokens {

    enum Palette {
        // Surface — adapt to dark mode via the asset catalog-free system semantics.
        static let background = Color(uiColor: .systemBackground)
        static let surface = Color(uiColor: .secondarySystemBackground)
        static let onSurface = Color.primary
        static let onSurfaceMuted = Color.secondary

        // Brand — Tween identity. Tuneable; never reference these colors raw at call sites.
        static let brand = Color(red: 0.13, green: 0.55, blue: 0.55)        // deep teal
        static let brandMuted = Color(red: 0.13, green: 0.55, blue: 0.55).opacity(0.16)
        static let accent = Color.accentColor

        // Semantic
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red

        // Pins — visual continuity with prior versions. Midpoint is brand, not status,
        // because the fair midpoint is a *Tween* concept.
        static let pinSelf = Color.blue
        static let pinFriend = Color.orange
        static let pinMidpoint = brand

        // Glass
        static let glassStroke = Color.primary.opacity(0.08)
        static let glassShadow = Color.black.opacity(0.18)

        /// UIColor mirrors of the brand palette, for code paths that draw with UIKit
        /// (UIBezierPath / UIGraphicsImageRenderer / NSAttributedString). Keep these in
        /// sync with the SwiftUI Color values above.
        enum UIKit {
            static let brand = UIColor(red: 0.13, green: 0.55, blue: 0.55, alpha: 1)
            static let pinSelf = UIColor.systemBlue
            static let pinFriend = UIColor.systemOrange
            static let pinMidpoint = brand
            static let onSurface = UIColor.label
            static let onSurfaceMuted = UIColor.secondaryLabel
            static let surface = UIColor.secondarySystemBackground
        }
    }

    /// 4-pt grid. Pick the smallest token that holds — the tightness is usually right.
    enum Space {
        static let s0: CGFloat = 0
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s7: CGFloat = 32
        static let s8: CGFloat = 40
        static let s9: CGFloat = 56
    }

    enum Radius {
        static let chip: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 24
        static let pin: CGFloat = 22
        static let pill: CGFloat = .infinity
    }

    /// Semantic typography — built from Dynamic Type so accessibility scales for free.
    enum Typography {
        static let display = Font.largeTitle.weight(.bold)
        static let title = Font.title2.weight(.bold)
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.subheadline
        static let caption = Font.caption
        static let captionEmphasized = Font.caption.weight(.semibold)
        static let mono = Font.system(.caption, design: .monospaced)
        /// Small SF Symbol inside a ≤24pt circle — used for badge stars, plus-buttons, etc.
        static let iconBadge = Font.system(size: 10, weight: .bold)
    }

    enum Duration {
        static let fast: Double = 0.40
        static let standard: Double = 0.48
        static let slow: Double = 0.66
    }

    /// Pre-built animations. Prefer these over ad-hoc `.spring(response:dampingFraction:)`.
    enum Motion {
        static let snappy: Animation = .smooth(duration: Duration.fast)
        static let spring: Animation = .spring(response: Duration.standard, dampingFraction: 0.88)
        static let gentle: Animation = .easeInOut(duration: Duration.slow)
        /// The scale factor used by `View.tweenPressFeedback()`.
        static let pressScale: CGFloat = 0.97
    }

    enum Elevation {
        static let floating = Shadow(color: Palette.glassShadow.opacity(0.6), radius: 12, x: 0, y: 6)
        static let sheet = Shadow(color: Palette.glassShadow, radius: 18, x: 0, y: -4)
        static let pin = Shadow(color: Palette.glassShadow.opacity(0.7), radius: 4, x: 0, y: 2)

        struct Shadow {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }
}

// MARK: - View extensions

extension View {
    /// The tokened glass surface. On iOS 26+ uses native Liquid Glass via
    /// `.glassEffect`; on older systems falls back to `.regularMaterial` with
    /// a soft border stroke.
    @ViewBuilder
    func tweenGlass(cornerRadius: CGFloat = Tokens.Radius.sheet) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Tokens.Palette.glassStroke, lineWidth: 0.5)
                    }
            }
        }
    }

    /// Apply a tokened shadow.
    func tweenElevation(_ shadow: Tokens.Elevation.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    /// Standard press feedback — scale down on touch, animate back on release.
    func tweenPressFeedback(_ isPressed: Bool) -> some View {
        scaleEffect(isPressed ? Tokens.Motion.pressScale : 1)
            .animation(Tokens.Motion.snappy, value: isPressed)
    }
}

// MARK: - Button style

/// The only primary CTA style in Tween. On iOS 26+ the `prominent` variant
/// uses `.glassProminent` for a native Liquid Glass look; older systems keep
/// the solid brand fill.
struct TweenPrimaryButtonStyle: ButtonStyle {
    enum Emphasis { case prominent, subtle }

    let emphasis: Emphasis

    init(_ emphasis: Emphasis = .prominent) {
        self.emphasis = emphasis
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            configuration.label
                .font(Tokens.Typography.headline)
                .foregroundStyle(foreground)
                .padding(.horizontal, Tokens.Space.s4)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .glassEffect(
                    emphasis == .prominent ? .regular.interactive : .regular,
                    in: .rect(cornerRadius: Tokens.Radius.card)
                )
                .tweenPressFeedback(configuration.isPressed)
        } else {
            configuration.label
                .font(Tokens.Typography.headline)
                .foregroundStyle(foreground)
                .padding(.horizontal, Tokens.Space.s4)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(background)
                }
                .tweenPressFeedback(configuration.isPressed)
        }
    }

    private var foreground: Color {
        switch emphasis {
        case .prominent: return .white
        case .subtle: return Tokens.Palette.brand
        }
    }

    private var background: Color {
        switch emphasis {
        case .prominent: return Tokens.Palette.brand
        case .subtle: return Tokens.Palette.brandMuted
        }
    }
}

extension ButtonStyle where Self == TweenPrimaryButtonStyle {
    static var tweenPrimary: TweenPrimaryButtonStyle { TweenPrimaryButtonStyle(.prominent) }
    static var tweenSubtle: TweenPrimaryButtonStyle { TweenPrimaryButtonStyle(.subtle) }
}
