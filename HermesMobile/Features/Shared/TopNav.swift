import SwiftUI

/// The button style `TopNav` applies to a non-empty slot's content, chosen by the composing caller
/// rather than inferred. `ToolbarContent` is not `View`, so this cannot be applied outside a
/// `TopNav(...)` call — `apply(to:)` applies it inside each slot's own `ToolbarItemGroup`, after
/// that slot's `slotIsEmpty` check has already decided whether the group exists at all.
enum TopNavActionStyle: Equatable {
    /// No style is applied; the slot's content renders exactly as the caller supplied it.
    case native
    /// The compact XS neutral adaptive-glass button style Bottom Sheet opts into.
    case compactAdaptiveGlass

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
        switch self {
        case .native:
            content
        case .compactAdaptiveGlass:
            content
                .buttonStyle(.hermex(.extraSmall, emphasis: .neutral, isGlass: true))
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// A shared foundation for top-navigation toolbars: native `ToolbarContent`, not an in-content fake
/// nav bar, assembling leading/center/trailing `ToolbarItem`/`ToolbarItemGroup` placements for
/// standard push/pop screens and modal sheets/editors with Cancel/Save semantics. `HermexBottomSheet`
/// composes it today; normal production screens still hand-assemble their own raw
/// `ToolbarItem`/`ToolbarItemGroup` placements and have not migrated onto this component.
///
/// Five slots: `leadingPrimary` and `leadingSecondary` share `leadingPlacement`; `trailingPrimary`
/// and `trailingSecondary` share `trailingPlacement`. Each slot is a `ViewBuilder` that itself can
/// hold more than one child (SwiftUI's `ToolbarItemGroup` renders a tuple of children as one
/// grouped cluster) — two named positions per edge is the guaranteed floor, not a hard ceiling.
///
/// `leadingPlacement`/`trailingPlacement` default to `.topBarLeading`/`.topBarTrailing` for
/// standard navigation, and take any `ToolbarItemPlacement` — `.cancellationAction`,
/// `.confirmationAction`, `.primaryAction`, or a caller-supplied dynamic placement — for modal and
/// editor semantics. The placement value itself, not which named slot authored it, decides where
/// the system renders it and whether it keeps native back/cancel/confirm behavior.
///
/// `center` wraps a single `.principal` item for a custom header (Chat's title label, Kanban's
/// board picker). A screen that only needs `.navigationTitle` leaves `center` at its default and
/// gets no interfering empty principal item.
///
/// `trailingSpacer` inserts a `ToolbarSpacer` (iOS 26+) between `trailingPrimary` and
/// `trailingSecondary`, for the one real case that needs two visually separated trailing clusters
/// instead of one group (`ToolbarSpacer` is `ToolbarContent`, not `View`, so it cannot live inside
/// a `ViewBuilder` slot itself).
struct TopNav<
    LeadingPrimary: View,
    LeadingSecondary: View,
    Center: View,
    TrailingPrimary: View,
    TrailingSecondary: View
>: ToolbarContent {
    var leadingPlacement: ToolbarItemPlacement = .topBarLeading
    var trailingPlacement: ToolbarItemPlacement = .topBarTrailing
    var trailingSpacer: Bool = false
    var actionStyle: TopNavActionStyle = .native
    @ViewBuilder var leadingPrimary: () -> LeadingPrimary
    @ViewBuilder var leadingSecondary: () -> LeadingSecondary
    @ViewBuilder var center: () -> Center
    @ViewBuilder var trailingPrimary: () -> TrailingPrimary
    @ViewBuilder var trailingSecondary: () -> TrailingSecondary

    init(
        leadingPlacement: ToolbarItemPlacement = .topBarLeading,
        trailingPlacement: ToolbarItemPlacement = .topBarTrailing,
        trailingSpacer: Bool = false,
        actionStyle: TopNavActionStyle = .native,
        @ViewBuilder leadingPrimary: @escaping () -> LeadingPrimary = { EmptyView() },
        @ViewBuilder leadingSecondary: @escaping () -> LeadingSecondary = { EmptyView() },
        @ViewBuilder center: @escaping () -> Center = { EmptyView() },
        @ViewBuilder trailingPrimary: @escaping () -> TrailingPrimary = { EmptyView() },
        @ViewBuilder trailingSecondary: @escaping () -> TrailingSecondary = { EmptyView() }
    ) {
        self.leadingPlacement = leadingPlacement
        self.trailingPlacement = trailingPlacement
        self.trailingSpacer = trailingSpacer
        self.actionStyle = actionStyle
        self.leadingPrimary = leadingPrimary
        self.leadingSecondary = leadingSecondary
        self.center = center
        self.trailingPrimary = trailingPrimary
        self.trailingSecondary = trailingSecondary
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if !Self.slotIsEmpty(LeadingPrimary.self) {
            ToolbarItemGroup(placement: leadingPlacement) { actionStyle.apply(to: leadingPrimary()) }
        }
        if !Self.slotIsEmpty(LeadingSecondary.self) {
            ToolbarItemGroup(placement: leadingPlacement) { actionStyle.apply(to: leadingSecondary()) }
        }
        if !Self.slotIsEmpty(Center.self) {
            ToolbarItem(placement: .principal) { center() }
        }
        if !Self.slotIsEmpty(TrailingPrimary.self) {
            ToolbarItemGroup(placement: trailingPlacement) { actionStyle.apply(to: trailingPrimary()) }
        }
        if trailingSpacer, !Self.slotIsEmpty(TrailingSecondary.self), #available(iOS 26, *) {
            ToolbarSpacer(.fixed, placement: trailingPlacement)
        }
        if !Self.slotIsEmpty(TrailingSecondary.self) {
            ToolbarItemGroup(placement: trailingPlacement) { actionStyle.apply(to: trailingSecondary()) }
        }
    }

    /// A slot left at its `EmptyView` default never reaches the toolbar at all, rather than
    /// mounting a zero-content `ToolbarItemGroup` that could still claim bar space.
    private static func slotIsEmpty<V>(_ type: V.Type) -> Bool {
        ObjectIdentifier(type) == ObjectIdentifier(EmptyView.self)
    }
}
