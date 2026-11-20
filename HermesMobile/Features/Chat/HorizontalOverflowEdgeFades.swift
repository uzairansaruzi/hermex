import SwiftUI

struct HorizontalOverflowEdgeFades: Equatable {
    static let scrollEpsilon: CGFloat = 4

    let leading: Bool
    let trailing: Bool

    init(leading: Bool = false, trailing: Bool = false) {
        self.leading = leading
        self.trailing = trailing
    }

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

enum HorizontalOverflowFadeStyle {
    case mask
    case overlay(Color)
}

extension View {
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
