import SwiftUI

/// Which edges of a horizontal scroller currently hide content. A fade is
/// only ever shown on an edge with something behind it, so a fade never reads
/// as a disabled control. Pure so the rule is unit-testable.
struct HorizontalOverflowEdgeFades: Equatable {
    /// Offsets this close to an edge count as sitting on it.
    static let scrollEpsilon: CGFloat = 4

    let leading: Bool
    let trailing: Bool

    init(leading: Bool = false, trailing: Bool = false) {
        self.leading = leading
        self.trailing = trailing
    }

    /// - Parameters:
    ///   - offset: horizontal content offset as the scroll view reports it, measured
    ///     from the left edge regardless of layout direction.
    ///   - layoutDirection: in right-to-left layouts the visual start of the content
    ///     is at the right, so the raw offset is flipped before comparing.
    init(
        offset: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        layoutDirection: LayoutDirection = .leftToRight
    ) {
        let maxOffset = max(0, contentWidth - viewportWidth)
        let logicalOffset = layoutDirection == .rightToLeft ? maxOffset - offset : offset
        leading = logicalOffset > Self.scrollEpsilon
        trailing = logicalOffset < maxOffset - Self.scrollEpsilon
    }
}

/// How `horizontalOverflowFades(_:)` draws an edge that hides content.
enum HorizontalOverflowFadeStyle {
    /// Alpha mask: the content itself fades, so any surface behind it (glass)
    /// shows through. Costs an offscreen pass, so keep it to fixed chrome.
    case mask
    /// A gradient from clear to the host's background colour drawn over the
    /// edge. No offscreen pass, so it suits views in a scrolling transcript.
    case overlay(Color)
}

extension View {
    /// Fades the edges of a `ScrollView(.horizontal)` while they hide content.
    /// Apply it to the scroll view itself.
    func horizontalOverflowFades(_ style: HorizontalOverflowFadeStyle) -> some View {
        modifier(HorizontalOverflowFadesModifier(style: style))
    }
}

private struct HorizontalOverflowFadesModifier: ViewModifier {
    let style: HorizontalOverflowFadeStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var fades = HorizontalOverflowEdgeFades()

    private let fadeWidth: CGFloat = 18

    func body(content: Content) -> some View {
        styled(
            content.onScrollGeometryChange(for: HorizontalOverflowEdgeFades.self) { geometry in
                HorizontalOverflowEdgeFades(
                    offset: geometry.contentOffset.x,
                    contentWidth: geometry.contentSize.width,
                    viewportWidth: geometry.containerSize.width,
                    layoutDirection: layoutDirection
                )
            } action: { _, newFades in
                fades = newFades
            }
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: fades)
    }

    @ViewBuilder
    private func styled(_ scroller: some View) -> some View {
        switch style {
        case .mask:
            scroller.mask { fadeMask }
        case .overlay(let color):
            scroller.overlay { fadeOverlay(color) }
        }
    }

    /// Opaque everywhere except an edge that hides content, which fades over
    /// `fadeWidth` so the surface behind shows through.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [fades.leading ? .clear : .black, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)

            Color.black

            LinearGradient(
                colors: [.black, fades.trailing ? .clear : .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
        }
    }

    /// Clear everywhere except an edge that hides content, which blends into
    /// `color` over `fadeWidth`. Never takes touches.
    private func fadeOverlay(_ color: Color) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [color, color.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeWidth)
                .opacity(fades.leading ? 1 : 0)

            Spacer(minLength: 0)

            LinearGradient(colors: [color.opacity(0), color], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeWidth)
                .opacity(fades.trailing ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
