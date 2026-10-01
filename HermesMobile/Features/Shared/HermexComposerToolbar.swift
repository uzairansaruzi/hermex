import SwiftUI

/// Appearance for `HermexComposerToolbar`. `.elevated` draws its own adaptive
/// surface, radius, and shadow; `.transparent` leaves the surface to the caller.
enum HermexComposerToolbarAppearance {
    case elevated
    case transparent
}

/// Shared horizontal composer-toolbar row: one ordered, zero-or-more arbitrary-content slot —
/// a generic `@ViewBuilder content` closure, never a typed toolbar-item model or named
/// leading/trailing slots — laid out in one `ScrollView(.horizontal)` containing one content
/// `HStack`, with edge fades that reveal only where content is hidden behind that edge. The
/// toolbar owns horizontal ordering, spacing, scrolling, fades, and its own optional surface;
/// each child owns its own semantics, interaction, and minimum hit target. Accepted content
/// includes any generic SwiftUI View, a control (e.g. `Button`), and display-only content (e.g.
/// a `Tag`) — mixed freely in the same row. Catalog foundation for future adoption; current
/// Chat/Bots feature-local scrollers (`ComposerToolbarScroller`) are unchanged by this type.
struct HermexComposerToolbar<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private let appearance: HermexComposerToolbarAppearance
    private let content: Content

    @State private var fades = HermexComposerToolbarEdgeFades()

    private let fadeWidth: CGFloat = 18
    private let itemSpacing: CGFloat = HermesSpacing.s8
    private let minimumRowHeight: CGFloat = 44

    init(
        appearance: HermexComposerToolbarAppearance = .elevated,
        @ViewBuilder content: () -> Content
    ) {
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: itemSpacing) {
                content
            }
            .padding(HermesSpacing.s8)
            .frame(minHeight: minimumRowHeight, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        // Horizontal only, and inert when everything fits, so the row never
        // feels draggable for no reason.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // Taps on toolbar controls must never dismiss the keyboard first.
        .scrollDismissesKeyboard(.never)
        .onScrollGeometryChange(for: HermexComposerToolbarEdgeFades.self) { geometry in
            HermexComposerToolbarEdgeFades(
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
        .background {
            if appearance == .elevated {
                RoundedRectangle(cornerRadius: HermesRadius.r24, style: .continuous)
                    .fill(Color(.systemBackground))
                    .hermesShadow(.controlElevatedResting)
            }
        }
    }

    /// Alpha mask: opaque everywhere except an edge that hides content, fading
    /// over `fadeWidth`. Laid out as non-overlapping `ZStack` regions, not a
    /// second content row, so the toolbar keeps exactly one row of items.
    private var fadeMask: some View {
        ZStack {
            Color.black
                .padding(.horizontal, fadeWidth)

            LinearGradient(
                colors: [fades.leading ? .clear : .black, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .frame(maxWidth: .infinity, alignment: .leading)

            LinearGradient(
                colors: [.black, fades.trailing ? .clear : .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Which edges of the composer toolbar currently hide content. A fade only ever
/// shows on an edge with something behind it, so a fade never reads as a
/// disabled control. Pure so the rule is unit-testable.
struct HermexComposerToolbarEdgeFades: Equatable {
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

typealias ComposerToolbarEdgeFades = HermexComposerToolbarEdgeFades

/// Explicit caller-inserted vertical divider between logical control groups in a
/// `HermexComposerToolbar`. Never inserted automatically, so a caller with two adjacent controls
/// that belong to the same logical group never sees an unwanted separator.
struct HermexComposerToolbarDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1 / displayScale, height: HermesSpacing.s24)
            .accessibilityHidden(true)
    }
}
