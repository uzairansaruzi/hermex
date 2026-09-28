import SwiftUI

/// Which edges of the composer toolbar scroller currently hide content.
/// A fade is only ever shown on an edge with something behind it, so a fade
/// never reads as a disabled control. Pure so the rule is unit-testable.
struct ComposerToolbarEdgeFades: Equatable {
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

/// Horizontal scroller for the composer toolbar row (add, model, reasoning,
/// workspace, profile, git branch, mic, context meter). The Stop/Send circle
/// stays outside it, pinned to the row's trailing edge.
struct ComposerToolbarScroller<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private let content: Content

    @State private var fades = ComposerToolbarEdgeFades()

    private let fadeWidth: CGFloat = 18
    private let itemSpacing: CGFloat = 8
    private let minimumRowHeight: CGFloat = 44

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: itemSpacing) {
                content
            }
            .frame(minHeight: minimumRowHeight, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        // Horizontal only, and inert when everything fits, so the row never
        // feels draggable for no reason.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // Taps on toolbar controls must never dismiss the keyboard first.
        .scrollDismissesKeyboard(.never)
        .onScrollGeometryChange(for: ComposerToolbarEdgeFades.self) { geometry in
            ComposerToolbarEdgeFades(
                offset: geometry.contentOffset.x,
                contentWidth: geometry.contentSize.width,
                viewportWidth: geometry.containerSize.width,
                layoutDirection: layoutDirection
            )
        } action: { _, newFades in
            fades = newFades
        }
        .mask { fadeMask }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: fades)
    }

    /// Alpha mask: opaque everywhere except an edge that hides content, which
    /// fades over `fadeWidth` so the glass surface shows through.
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
}
