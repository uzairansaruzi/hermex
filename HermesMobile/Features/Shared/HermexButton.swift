import SwiftUI

enum HermexButtonSize: CaseIterable {
    case extraSmall, small, medium, large

    var font: AppFont.Role {
        switch self {
        case .extraSmall: .captionSemibold
        case .small: .captionSemibold
        case .medium: .subheadlineSemibold
        case .large: .label
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .extraSmall: HermesSpacing.s8
        case .small: HermesSpacing.s12
        case .medium: HermesSpacing.s16
        case .large: HermesSpacing.s20
        }
    }

    var minHeight: CGFloat {
        switch self {
        case .extraSmall: 24
        case .small: 32
        case .medium: 40
        case .large: 48
        }
    }

    var iconSpacing: CGFloat { HermesSpacing.s8 }
}

enum HermexButtonEmphasis: CaseIterable {
    case neutral, brandPrimary, primary, secondary, destructive
}

/// Press Feedback: `.standard` is Hermex Buttons' default — a slight scale and opacity response,
/// Reduce-Motion-safe. `.emphasized` is a stronger version for a button that wants extra weight
/// (a primary composer/send action, for instance); `.none` opts a button out entirely. Physical
/// haptics are a separate, opt-in concern (`HermexButton.haptic`), not part of Press Feedback.
enum HermexButtonPressFeedback: CaseIterable {
    case standard, emphasized, none

    var scale: CGFloat {
        switch self {
        case .standard: HermesMotion.Properties.scalePress
        case .emphasized: 0.95
        case .none: 1
        }
    }

    var opacity: Double {
        switch self {
        case .standard: 0.92
        case .emphasized: 0.85
        case .none: 1
        }
    }

    var duration: TimeInterval {
        switch self {
        case .standard: HermesMotion.Bundle.feedbackPress.duration
        case .emphasized: HermesMotion.Duration.d150
        case .none: HermesMotion.Duration.d0
        }
    }
}

/// The one place Hermex Buttons apply press feedback: scale, opacity, and a matching animation,
/// live only while pressed and enabled, skipped entirely under Reduce Motion. `HermexButtonStyle`
/// (full chrome) and `HermexButtonPressOnlyStyle` (caller-owned chrome) both call this instead of
/// each hand-rolling their own scale/opacity/animation chain.
extension View {
    func applyingHermexButtonPressFeedback(
        isPressed: Bool,
        isEnabled: Bool,
        scale: CGFloat,
        opacity: Double,
        disabledOpacity: Double,
        anchor: UnitPoint = .center,
        reduceMotion: Bool,
        animation: Animation?
    ) -> some View {
        self
            .scaleEffect(reduceMotion ? 1 : (isPressed ? scale : 1), anchor: anchor)
            .opacity(isEnabled ? (isPressed ? opacity : 1) : disabledOpacity)
            .animation(reduceMotion ? nil : animation, value: isPressed)
    }
}

/// Hermex's shared Button chrome: sizing, emphasis, and Press Feedback, standard by default and
/// Reduce-Motion-safe. Composes Adaptive Glass for `isGlass` rather than duplicating its fallback
/// logic. Applies to a native `Button`; it never replaces native Button semantics.
struct HermexButtonStyle: ButtonStyle {
    var size: HermexButtonSize = .medium
    var emphasis: HermexButtonEmphasis = .neutral
    var pressFeedback: HermexButtonPressFeedback = .standard
    var isGlass = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed
        let shape = Capsule()

        configuration.label
            .appFont(size.font)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.minHeight)
            .foregroundStyle(foregroundColor)
            .background {
                if isGlass {
                    Color.clear.adaptiveGlass(.regular, tint: tint, in: shape)
                } else {
                    shape.fill(backgroundColor(isPressed: isPressed))
                }
            }
            .overlay(shape.stroke(borderColor, lineWidth: emphasis == .secondary ? 1 : 0))
            .contentShape(shape)
            .applyingHermexButtonPressFeedback(
                isPressed: isPressed,
                isEnabled: isEnabled,
                scale: pressFeedback.scale,
                opacity: pressFeedback.opacity,
                disabledOpacity: 0.5,
                reduceMotion: reduceMotion,
                animation: pressAnimation
            )
    }

    private var pressAnimation: Animation? {
        guard !reduceMotion, pressFeedback != .none else { return nil }
        return .easeInOut(duration: pressFeedback.duration)
    }

    private var tint: Color? {
        switch emphasis {
        case .neutral, .secondary: nil
        case .brandPrimary: HermesColorRamp.Gold.s500.color
        case .primary: .accentColor
        case .destructive: .red
        }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return Color(.secondaryLabel) }

        switch emphasis {
        case .neutral, .secondary: return .primary
        case .brandPrimary: return .black
        case .primary: return colorScheme == .dark ? .black : .white
        case .destructive: return .red
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else {
            return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
        }

        switch emphasis {
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(isPressed ? 0.14 : 0.10) : Color.black.opacity(isPressed ? 0.08 : 0.05)
        case .brandPrimary:
            return isPressed ? HermesColorRamp.Gold.s600.color : HermesColorRamp.Gold.s500.color
        case .primary:
            return colorScheme == .dark ? .white : .black
        case .secondary:
            return colorScheme == .dark ? Color.white.opacity(isPressed ? 0.12 : 0.08) : Color.black.opacity(isPressed ? 0.07 : 0.045)
        case .destructive:
            return Color.red.opacity(isPressed ? 0.16 : 0.10)
        }
    }

    private var borderColor: Color {
        emphasis == .secondary ? Color(.separator).opacity(colorScheme == .dark ? 0.36 : 0.24) : .clear
    }
}

extension ButtonStyle where Self == HermexButtonStyle {
    static func hermex(
        _ size: HermexButtonSize = .medium,
        emphasis: HermexButtonEmphasis = .neutral,
        pressFeedback: HermexButtonPressFeedback = .standard,
        isGlass: Bool = false
    ) -> HermexButtonStyle {
        HermexButtonStyle(size: size, emphasis: emphasis, pressFeedback: pressFeedback, isGlass: isGlass)
    }
}

/// A Hermex Button's content configuration: a label, an icon, or both in either order. `HermexButton`
/// composes this with `HermexButtonStyle` and a pending state; `isPending` swaps the content for a
/// spinner and disables the button rather than adding a fifth content shape.
enum HermexButtonContent: Equatable {
    case label(String)
    /// A bare system image name announces nothing to VoiceOver on its own, so an icon-only button
    /// must name its action directly in the content contract rather than leaving it to an external,
    /// easy-to-forget `.accessibilityLabel` modifier at the call site.
    case icon(String, accessibilityLabel: String)
    case iconLeading(icon: String, label: String)
    case iconTrailing(icon: String, label: String)
}

struct HermexButton: View {
    let content: HermexButtonContent
    var size: HermexButtonSize = .medium
    var emphasis: HermexButtonEmphasis = .neutral
    var pressFeedback: HermexButtonPressFeedback = .standard
    var isGlass = false
    var isPending = false
    /// Optional, semantic haptic fired alongside `action` — never implied by Press Feedback.
    var haptic: (() -> Void)?
    let action: () -> Void

    var body: some View {
        Button {
            haptic?()
            action()
        } label: {
            if isPending {
                ProgressView()
                    .controlSize(.small)
            } else {
                contentLabel
            }
        }
        .buttonStyle(.hermex(size, emphasis: emphasis, pressFeedback: pressFeedback, isGlass: isGlass))
        .disabled(isPending)
    }

    @ViewBuilder
    private var contentLabel: some View {
        switch content {
        case .label(let title):
            Text(title)
        case .icon(let systemImage, let accessibilityLabel):
            Image(systemName: systemImage)
                .accessibilityLabel(Text(accessibilityLabel))
        case .iconLeading(let icon, let title):
            Label(title, systemImage: icon)
        case .iconTrailing(let icon, let title):
            HStack(spacing: size.iconSpacing) {
                Text(title)
                Image(systemName: icon)
            }
        }
    }
}

/// The other Hermex Button: press-only. A control whose shape, fill, and shadow stay
/// caller-owned — an icon, a compact control, a capsule, a card, a thumbnail — still needs
/// Reduce-Motion-safe Press Feedback, so it gets this rather than inventing a separate family.
/// It applies press feedback through the same `applyingHermexButtonPressFeedback` `HermexButtonStyle`
/// uses; only the per-chrome amount and the optional shadow pair are its own.
struct HermexButtonPressOnlyStyle: ButtonStyle {
    enum Chrome {
        case icon
        case compactControl
        case capsule
        case card
        case thumbnail

        var pressedScale: CGFloat {
            switch self {
            case .icon:
                0.945
            case .compactControl:
                1
            case .capsule:
                0.975
            case .card:
                0.985
            case .thumbnail:
                0.98
            }
        }

        var pressedOpacity: Double {
            switch self {
            case .icon, .compactControl:
                0.94
            case .capsule, .card, .thumbnail:
                0.96
            }
        }

        var duration: TimeInterval {
            switch self {
            case .icon, .compactControl:
                HermesMotion.Duration.d150
            case .capsule, .card, .thumbnail:
                HermesMotion.Duration.d200
            }
        }

        var scaleAnchor: UnitPoint {
            switch self {
            case .compactControl:
                .leading
            case .icon, .capsule, .card, .thumbnail:
                .center
            }
        }
    }

    struct Shadow {
        let resting: HermesShadow
        let pressed: HermesShadow
    }

    let chrome: Chrome
    let shadow: Shadow?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed
        let shadow = shadow ?? Shadow(resting: .none, pressed: .none)

        configuration.label
            .applyingHermexButtonPressFeedback(
                isPressed: isPressed,
                isEnabled: isEnabled,
                scale: chrome.pressedScale,
                opacity: chrome.pressedOpacity,
                disabledOpacity: 0.62,
                anchor: chrome.scaleAnchor,
                reduceMotion: reduceMotion,
                animation: ChatMotion.press(duration: chrome.duration, reduceMotion: reduceMotion)
            )
            .hermesShadow(isPressed ? shadow.pressed : shadow.resting)
    }
}

extension ButtonStyle where Self == HermexButtonPressOnlyStyle {
    static func hermexPressOnly(
        _ chrome: HermexButtonPressOnlyStyle.Chrome,
        shadow: HermexButtonPressOnlyStyle.Shadow? = nil
    ) -> HermexButtonPressOnlyStyle {
        HermexButtonPressOnlyStyle(chrome: chrome, shadow: shadow)
    }
}
