import SwiftUI

/// The Card family's shared defaults. `SectionCard` (adaptive-glass grouped content) and Request
/// Card (`requestCardSurface`, used by `ClarificationRequestCard`, `ApprovalRequestOverlay`,
/// and `BotPendingRequestCard`) both wrap their content in exactly this padding on every edge —
/// this is the one place that default lives, instead of each surface repeating the literal.
enum HermexCardMetrics {
    static let contentPadding: CGFloat = HermesSpacing.s16
}

/// Canonical Card surface choices. Any Card described as outlined uses this exact semantic
/// background-and-border treatment rather than reconstructing white fill and grey stroke locally.
enum HermexCardSurface {
    case glass
    case outlined
}

/// The Card family's approved Neutral surface mapping (DSF-07): every Card variant's background
/// resolves to one of these two adaptive pairs instead of a platform color or a hand-typed literal.
/// Border roles live in the shared `HermexSurfaceBorderColors` foundation, which Card and Search both
/// consume instead of each owning their own border mapping.
enum HermexCardColors {
    static let primarySurface = HermesColorRamp.Neutral.adaptive(
        light: HermesColorRamp.Neutral.s50,
        dark: HermesColorRamp.Neutral.s950
    )
    static let secondarySurface = HermesColorRamp.Neutral.adaptive(
        light: HermesColorRamp.Neutral.s100,
        dark: HermesColorRamp.Neutral.s900
    )
}

extension View {
    func hermexCardSurface(
        _ surface: HermexCardSurface,
        cornerRadius: CGFloat = HermesRadius.card
    ) -> some View {
        modifier(HermexCardSurfaceModifier(surface: surface, cornerRadius: cornerRadius))
    }
}

private struct HermexCardSurfaceModifier: ViewModifier {
    let surface: HermexCardSurface
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        switch surface {
        case .glass:
            content
                .background {
                    shape.fill(HermexCardColors.primarySurface.opacity(reduceTransparency ? 1 : 0.34))
                }
                .adaptiveGlass(.regular, fallbackMaterial: .regularMaterial, in: shape)
                .clipShape(shape)
                .overlay {
                    shape
                        .stroke(
                            colorSchemeContrast == .increased ? HermexSurfaceBorderColors.increasedContrast : HermexSurfaceBorderColors.resting,
                            lineWidth: 0.7
                        )
                        .allowsHitTesting(false)
                }
        case .outlined:
            content
                .background(HermexCardColors.primarySurface, in: shape)
                .clipShape(shape)
                .overlay {
                    shape
                        .stroke(
                            colorSchemeContrast == .increased ? HermexSurfaceBorderColors.increasedContrast : HermexSurfaceBorderColors.resting,
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
        }
    }
}

/// Compact Card: the explicit, documented compact-density surface for component compositions —
/// today, the composer and message Attachment file tiles' outer surface. It is not Card's 16-point
/// default; a component owns its own compact geometry, and this only unifies the fill-plus-hairline
/// chrome those tiles each drew by hand into one named, shared treatment.
enum HermexCompactCardMetrics {
    static let borderWidth: CGFloat = 0.5
}

extension View {
    /// Compact Card's opaque surface: a tinted fill plus the hairline border every normal (non-mini)
    /// Attachment tile already drew by hand. `fill` defaults to the shared file-badge tint; pass
    /// `.clear` for a tile whose own image content already covers the surface and only wants the
    /// border. `cornerRadius` defaults to `HermesRadius.card` — the one outer radius every normal
    /// Attachment tile shares with Card — so a call site only overrides it for a deliberately
    /// different (for example mini) surface instead of hand-picking a radius that can drift.
    func compactCardSurface(cornerRadius: CGFloat = HermesRadius.card, fill: Color = HermexCardColors.secondarySurface) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .modifier(HermexCompactCardBorderModifier(cornerRadius: cornerRadius))
    }
}

private struct HermexCompactCardBorderModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        colorSchemeContrast == .increased ? HermexSurfaceBorderColors.increasedContrast : HermexSurfaceBorderColors.resting,
                        lineWidth: HermexCompactCardMetrics.borderWidth
                    )
            )
    }
}

/// Request Card's material: `.opaque` by default, since these cards float over live transcript
/// text and a translucent surface would render the request on top of whatever message happens to
/// sit underneath. `.translucentOverScrim` is the one documented exception — a card that instead
/// sits over its own dimmed scrim, where translucency reads correctly.
enum RequestCardMaterial {
    case opaque
    case translucentOverScrim
}

extension View {
    /// Request Card: the shared approval/clarification surface used by the Sessions clarification
    /// card, the Sessions approval overlay, and the Bot pending-request card. Placement differs per
    /// caller — the Sessions clarification pins above the composer, the Bot card sits in the
    /// transcript, the approval overlay floats over a scrim — but the surface itself does not.
    func requestCardSurface(cornerRadius: CGFloat, material: RequestCardMaterial = .opaque) -> some View {
        modifier(RequestCardSurfaceModifier(cornerRadius: cornerRadius, material: material))
    }
}

private struct RequestCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let material: RequestCardMaterial

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        switch material {
        case .opaque:
            content
                .background(HermexCardColors.primarySurface, in: shape)
                .overlay(shape.stroke(colorSchemeContrast == .increased ? HermexSurfaceBorderColors.increasedContrast : HermexSurfaceBorderColors.resting, lineWidth: 1))
        case .translucentOverScrim:
            content
                .background(.regularMaterial, in: shape)
                .background(HermexCardColors.primarySurface.opacity(0.34), in: shape)
                .overlay(shape.stroke(colorSchemeContrast == .increased ? HermexSurfaceBorderColors.increasedContrast : HermexSurfaceBorderColors.resting, lineWidth: 1))
        }
    }
}
