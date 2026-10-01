import SwiftUI

/// Row-container metrics for `HermexList.Style.compactOverlay`. Kept top-level rather than nested
/// inside the generic `HermexList<Content>` — Swift disallows stored `static` properties inside a
/// generic type — so `HermexPopoverMenu` can size its preferred content against the exact same
/// numbers `HermexList` renders with, instead of re-deriving them.
enum HermexListCompactOverlayMetrics {
    static let rowVerticalInset: CGFloat = HermesSpacing.s4
    /// `HermexPopoverMenu` now owns the shell padding this used to provide (see
    /// `HermexPopoverMenuMetrics.contentPadding`), so the row itself adds none of its own.
    static let rowHorizontalInset: CGFloat = HermesSpacing.s0
    /// The minimum accessible row height `.compactOverlay` guarantees. This is a List-level floor,
    /// independent of `ListItemMetrics.minHeight` (48pt) — a caller's row content can be taller,
    /// never shorter.
    static let minimumRowHeight: CGFloat = 44
    /// `HermexPopoverMenu` now owns the shell padding this used to provide (see
    /// `HermexPopoverMenuMetrics.contentPadding`), so the scroll content itself adds none of its own.
    static let scrollContentMargin: CGFloat = HermesSpacing.s0
}

/// The shared native List container. It deliberately keeps SwiftUI List semantics—navigation,
/// swipe actions, refresh, editing, keyboard support, and platform accessibility—while giving
/// production screens one reusable entry point for list-level defaults.
struct HermexList<Content: View>: View {
    /// `.standard` is the original, still-default behavior: native List chrome plus a 12pt
    /// vertical scroll-content margin. `.compactOverlay` is the plain, transparent, separator-free
    /// variant an overlay-hosted list composes (`HermexPopoverMenu`) — it owns only row-container
    /// policy, never the outer overlay's material, shadow, anchoring, or dismissal.
    enum Style {
        case standard
        case compactOverlay
    }

    private let style: Style
    @ViewBuilder private let content: () -> Content

    init(style: Style = .standard, @ViewBuilder content: @escaping () -> Content) {
        self.style = style
        self.content = content
    }

    var body: some View {
        switch style {
        case .standard:
            List {
                content()
            }
            .contentMargins(.vertical, HermesSpacing.s12, for: .scrollContent)
        case .compactOverlay:
            // `.listRowSeparator`/`.listRowInsets` are row traits: applied to the List itself they
            // have no effect on the rendered rows (separators and native insets stay put). They
            // must be attached to the row content inside the List builder instead, the same way a
            // `ForEach` carries them to every row it produces.
            List {
                content()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(
                        top: HermexListCompactOverlayMetrics.rowVerticalInset,
                        leading: HermexListCompactOverlayMetrics.rowHorizontalInset,
                        bottom: HermexListCompactOverlayMetrics.rowVerticalInset,
                        trailing: HermexListCompactOverlayMetrics.rowHorizontalInset
                    ))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, HermexListCompactOverlayMetrics.scrollContentMargin, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, HermexListCompactOverlayMetrics.minimumRowHeight)
        }
    }
}
