import SwiftUI

enum AdaptiveReadableContentWidth {
    static let secondaryDestination: CGFloat = 800
    static let workspace: CGFloat = 1_000
}

private struct AdaptiveReadableContentModifier: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

private struct AdaptiveReadableScrollContentModifier: ViewModifier {
    let maxWidth: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            width = newWidth
                        }
                }
            }
            .contentMargins(
                .horizontal,
                max((width - maxWidth) / 2, 0),
                for: .scrollContent
            )
    }
}

extension View {
    func adaptiveReadableContent(maxWidth: CGFloat) -> some View {
        modifier(AdaptiveReadableContentModifier(maxWidth: maxWidth))
    }

    func adaptiveReadableScrollContent(maxWidth: CGFloat) -> some View {
        modifier(AdaptiveReadableScrollContentModifier(maxWidth: maxWidth))
    }

    func adaptiveSecondaryNavigationTitle() -> some View {
        modifier(AdaptiveSecondaryNavigationTitleModifier())
    }
}

private struct AdaptiveSecondaryNavigationTitleModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .automatic)
    }
}

enum GlassPreference {
    static let isEnabledKey = "adaptiveGlass.isEnabled"
    static let defaultIsEnabled = true

    static var isLiquidGlassSupported: Bool {
        if #available(iOS 26, *) {
            return true
        }

        return false
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: isEnabledKey) != nil else {
            return defaultIsEnabled
        }

        return defaults.bool(forKey: isEnabledKey)
    }
}

enum AdaptiveGlassStyle: Equatable {
    case regular
}

enum AdaptiveGlassSurface: Equatable {
    case liquidGlass
    case material
    case opaque

    static func resolve(
        liquidGlassAvailable: Bool,
        isGlassEnabled: Bool,
        reduceTransparency: Bool
    ) -> AdaptiveGlassSurface {
        if reduceTransparency {
            return .opaque
        }

        guard liquidGlassAvailable, isGlassEnabled else {
            return .material
        }

        return .liquidGlass
    }
}

enum AdaptiveScrollEdgeTreatment: Equatable {
    case soft
    case disabled

    static func resolve(
        softScrollEdgesAvailable: Bool,
        reduceTransparency: Bool
    ) -> AdaptiveScrollEdgeTreatment {
        guard softScrollEdgesAvailable, !reduceTransparency else {
            return .disabled
        }

        return .soft
    }
}

private struct AdaptiveGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(GlassPreference.isEnabledKey) private var isGlassEnabled = GlassPreference.defaultIsEnabled

    let style: AdaptiveGlassStyle
    let isInteractive: Bool
    let tint: Color?
    let fallbackMaterial: Material
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        switch resolvedSurface {
        case .liquidGlass:
            if #available(iOS 26, *) {
                liquidGlassContent(content)
            } else {
                materialContent(content)
            }
        case .material:
            materialContent(content)
        case .opaque:
            opaqueContent(content)
        }
    }

    private var resolvedSurface: AdaptiveGlassSurface {
        AdaptiveGlassSurface.resolve(
            liquidGlassAvailable: GlassPreference.isLiquidGlassSupported,
            isGlassEnabled: isGlassEnabled,
            reduceTransparency: reduceTransparency
        )
    }

    private var showsContrastStroke: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }

    private var contrastStrokeOpacity: Double {
        colorSchemeContrast == .increased ? 0.22 : 0.14
    }

    @available(iOS 26, *)
    private var resolvedGlass: Glass {
        switch style {
        case .regular:
            var glass = Glass.regular
            if let tint {
                glass = glass.tint(tint)
            }
            if isInteractive {
                glass = glass.interactive()
            }
            return glass
        }
    }

    @available(iOS 26, *)
    private func liquidGlassContent(_ content: Content) -> some View {
        content
            .glassEffect(resolvedGlass, in: shape)
            .adaptiveGlassAccessibilityStroke(
                shape: shape,
                isVisible: showsContrastStroke,
                opacity: contrastStrokeOpacity
            )
    }

    private func materialContent(_ content: Content) -> some View {
        content
            .background(fallbackMaterial, in: shape)
            .adaptiveGlassAccessibilityStroke(
                shape: shape,
                isVisible: showsContrastStroke,
                opacity: contrastStrokeOpacity
            )
    }

    private func opaqueContent(_ content: Content) -> some View {
        content
            .background(Color(.secondarySystemBackground), in: shape)
            .adaptiveGlassAccessibilityStroke(
                shape: shape,
                isVisible: true,
                opacity: contrastStrokeOpacity
            )
    }
}

private struct AdaptiveSoftScrollEdgeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let edges: Edge.Set

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *),
           AdaptiveScrollEdgeTreatment.resolve(
               softScrollEdgesAvailable: true,
               reduceTransparency: reduceTransparency
           ) == .soft {
            content.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            content
        }
    }
}

struct AdaptiveGlassContainer<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(GlassPreference.isEnabledKey) private var isGlassEnabled = GlassPreference.defaultIsEnabled

    let spacing: CGFloat
    private let content: () -> Content

    init(spacing: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26, *), isGlassEnabled, !reduceTransparency {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

private extension View {
    @ViewBuilder
    func adaptiveGlassAccessibilityStroke<S: Shape>(
        shape: S,
        isVisible: Bool,
        opacity: Double
    ) -> some View {
        if isVisible {
            overlay(
                shape
                    .stroke(Color.primary.opacity(opacity), lineWidth: 1)
                    .allowsHitTesting(false)
            )
        } else {
            self
        }
    }
}

extension View {
    func adaptiveGlass(
        _ style: AdaptiveGlassStyle = .regular,
        isInteractive: Bool = false,
        tint: Color? = nil,
        fallbackMaterial: Material = .regularMaterial,
        in shape: some Shape
    ) -> some View {
        modifier(AdaptiveGlassModifier(
            style: style,
            isInteractive: isInteractive,
            tint: tint,
            fallbackMaterial: fallbackMaterial,
            shape: shape
        ))
    }

    func adaptiveSoftScrollEdges(_ edges: Edge.Set = [.top, .bottom]) -> some View {
        modifier(AdaptiveSoftScrollEdgeModifier(edges: edges))
    }
}
