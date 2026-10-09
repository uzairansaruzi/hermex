import SwiftUI

/// Hermex's Bottom Sheet content scaffold: content supplied to native SwiftUI `.sheet`, never a
/// replacement for the presentation modifier itself. The caller keeps `.sheet` — detents, the drag
/// indicator, compact adaptation, interactive-dismiss policy, focus state, validation, loading
/// state, and dismissal callbacks all stay caller-owned, and native `.sheet` alone owns presentation
/// motion and Reduce Motion.
///
/// This scaffold owns three things: a `NavigationStack` with an inline native navigation title, this
/// file's own `TopNav` composed through native `.toolbar` at modal-appropriate placements
/// (`.cancellationAction`/`.confirmationAction`) rather than a hand-rolled in-content bar, and an
/// optional footer pinned with native `.safeAreaInset(edge: .bottom)` rather than a hard-coded
/// height.
///
/// `content` is an unconstrained `@ViewBuilder` body slot: it accepts a native `List` or arbitrary
/// content without imposing a card, scroll view, padding, or background of its own — either context
/// keeps its own native scroll/layout behavior.
struct HermexBottomSheet<
    Content: View,
    LeadingPrimary: View,
    LeadingSecondary: View,
    TrailingPrimary: View,
    TrailingSecondary: View,
    Footer: View
>: View {
    /// Direct footer children arrange horizontally (side-by-side actions) or vertically (a stacked
    /// primary-over-secondary confirmation), selected by the caller — never inferred automatically.
    enum FooterAxis {
        case horizontal
        case vertical
    }

    let title: LocalizedStringKey
    var footerAxis: FooterAxis = .horizontal
    @ViewBuilder var content: () -> Content
    @ViewBuilder var leadingPrimary: () -> LeadingPrimary
    @ViewBuilder var leadingSecondary: () -> LeadingSecondary
    @ViewBuilder var trailingPrimary: () -> TrailingPrimary
    @ViewBuilder var trailingSecondary: () -> TrailingSecondary
    @ViewBuilder var footer: () -> Footer

    init(
        _ title: LocalizedStringKey,
        footerAxis: FooterAxis = .horizontal,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder leadingPrimary: @escaping () -> LeadingPrimary = { EmptyView() },
        @ViewBuilder leadingSecondary: @escaping () -> LeadingSecondary = { EmptyView() },
        @ViewBuilder trailingPrimary: @escaping () -> TrailingPrimary = { EmptyView() },
        @ViewBuilder trailingSecondary: @escaping () -> TrailingSecondary = { EmptyView() },
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.footerAxis = footerAxis
        self.content = content
        self.leadingPrimary = leadingPrimary
        self.leadingSecondary = leadingSecondary
        self.trailingPrimary = trailingPrimary
        self.trailingSecondary = trailingSecondary
        self.footer = footer
    }

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    TopNav(
                        leadingPlacement: .cancellationAction,
                        trailingPlacement: .confirmationAction,
                        actionStyle: .compactAdaptiveGlass,
                        leadingPrimary: leadingPrimary,
                        leadingSecondary: leadingSecondary,
                        trailingPrimary: trailingPrimary,
                        trailingSecondary: trailingSecondary
                    )
                }
                .safeAreaInset(edge: .bottom) {
                    footerContent
                }
        }
    }

    @ViewBuilder
    private var footerContent: some View {
        if Self.slotIsEmpty(Footer.self) {
            EmptyView()
        } else {
            Group {
                switch footerAxis {
                case .horizontal:
                    HStack(spacing: HermesSpacing.s12) { footer() }
                case .vertical:
                    VStack(spacing: HermesSpacing.s12) { footer() }
                }
            }
            .padding(.horizontal, HermesSpacing.screenHorizontal)
            .padding(.vertical, HermesSpacing.s12)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    /// Same convention as `TopNav.slotIsEmpty`: a footer left at its `EmptyView` default contributes
    /// no size to `.safeAreaInset`, so a caller with no footer never reserves bottom space for one.
    private static func slotIsEmpty<V>(_ type: V.Type) -> Bool {
        ObjectIdentifier(type) == ObjectIdentifier(EmptyView.self)
    }
}
