import SwiftUI

/// `AccordionList`'s mandatory visual surface: every caller picks explicitly, so a new collection of
/// expandable `ListItem` groups never silently inherits an unintended default.
enum AccordionListAppearance: Equatable {
    case card
    case cardless
}

/// `AccordionList`'s mandatory separator policy. `showsOuterDividers`/`showsInternalDividers` are
/// the two boundary axes the rendering algorithm composes from, rather than switching on the case
/// directly at every call site.
enum AccordionListSeparatorStyle: Equatable {
    case none
    case betweenRows
    case topAndBottom
    case all

    var showsInternalDividers: Bool {
        self == .betweenRows || self == .all
    }

    var showsOuterDividers: Bool {
        self == .topAndBottom || self == .all
    }
}

/// Expansion state ownership: controlled forms carry a caller binding, local forms are owned by the
/// component itself and seeded from an explicit initial value. Neither form persists automatically.
enum AccordionListExpansion<ID: Hashable> {
    case single(Binding<ID?>)
    case multiple(Binding<Set<ID>>)
    case localSingle(initiallyExpanded: ID?)
    case localMultiple(initiallyExpanded: Set<ID>)
}

/// Pure expansion-state transitions, free of SwiftUI state so they can be tested directly.
enum AccordionListExpansionResolver {
    static func toggledSingle<ID: Equatable>(current: ID?, id: ID) -> ID? {
        current == id ? nil : id
    }

    static func toggledMultiple<ID: Hashable>(current: Set<ID>, id: ID) -> Set<ID> {
        var result = current
        if result.contains(id) {
            result.remove(id)
        } else {
            result.insert(id)
        }
        return result
    }

    static func prunedSingle<ID: Hashable>(current: ID?, validIDs: Set<ID>) -> ID? {
        guard let current, validIDs.contains(current) else { return nil }
        return current
    }

    static func prunedMultiple<ID: Hashable>(current: Set<ID>, validIDs: Set<ID>) -> Set<ID> {
        current.intersection(validIDs)
    }
}

private enum AccordionListMetrics {
    static let groupSpacing = HermesSpacing.s8
    /// The header row's own text-column start (avatar width plus the header/body gap) — the one
    /// named source both a body row's leading alignment and the internal body-row divider's leading
    /// alignment derive from, rather than each reconstructing its own inset.
    static let headerTextLeadingInset = HermesAvatarSize.small.rawValue + HermesSpacing.s12
}

/// Marks a view as valid `AccordionList` header/body row content: the shared `ListItem` anatomy,
/// optionally wrapped in caller-owned row-level modifiers (swipe actions, context menus,
/// transitions) via `ModifiedContent`, but never an arbitrary free-form view.
protocol AccordionListRowContent: View {}

extension ListItem: AccordionListRowContent {}
extension ModifiedContent: AccordionListRowContent where Content: AccordionListRowContent, Modifier: ViewModifier {}

/// A collection-level, data-agnostic composition of expandable `ListItem` groups: one explicit
/// appearance, one explicit separator policy, single-or-multiple expansion in controlled or local
/// form, and header/body rows rooted in `ListItem`. The whole header toggles expansion; the chevron
/// is a decorative in-row indicator, never an independent control. Grows naturally inside whatever
/// container the caller already scrolls with, never introducing a scrolling container of its own,
/// and understands nothing about the data its rows represent.
struct AccordionList<
    Item: Identifiable,
    BodyItem: Identifiable,
    HeaderLeading: View,
    HeaderTitleAccessory: View,
    BodyRow: AccordionListRowContent
>: View where Item.ID: Hashable {
    let items: [Item]
    let appearance: AccordionListAppearance
    let separatorStyle: AccordionListSeparatorStyle
    let expansion: AccordionListExpansion<Item.ID>
    let bodyItems: (Item) -> [BodyItem]
    let headerTitle: (Item) -> Text
    let headerSubtitle: (Item) -> Text?
    let headerAccessibilityLabel: (Item) -> Text?
    let headerIsDisabled: (Item) -> Bool
    @ViewBuilder let headerLeading: (Item) -> HeaderLeading
    @ViewBuilder let headerTitleAccessory: (Item) -> HeaderTitleAccessory
    @ViewBuilder let bodyItem: (Item, BodyItem) -> BodyRow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localSingleID: Item.ID?
    @State private var localMultipleIDs: Set<Item.ID>

    /// The one leading-presence rule: `HeaderLeading` is `EmptyView` only for the no-leading
    /// initializer path, so this is the single source both header rendering and body-row/divider
    /// geometry read to decide whether a leading column exists.
    private var hasHeaderLeading: Bool {
        ObjectIdentifier(HeaderLeading.self) != ObjectIdentifier(EmptyView.self)
    }

    init(
        items: [Item],
        appearance: AccordionListAppearance,
        separatorStyle: AccordionListSeparatorStyle,
        expansion: AccordionListExpansion<Item.ID>,
        bodyItems: @escaping (Item) -> [BodyItem],
        headerTitle: @escaping (Item) -> Text,
        headerSubtitle: @escaping (Item) -> Text?,
        headerAccessibilityLabel: @escaping (Item) -> Text?,
        headerIsDisabled: @escaping (Item) -> Bool,
        @ViewBuilder headerLeading: @escaping (Item) -> HeaderLeading,
        @ViewBuilder headerTitleAccessory: @escaping (Item) -> HeaderTitleAccessory,
        @ViewBuilder bodyItem: @escaping (Item, BodyItem) -> BodyRow
    ) {
        self.items = items
        self.appearance = appearance
        self.separatorStyle = separatorStyle
        self.expansion = expansion
        self.bodyItems = bodyItems
        self.headerTitle = headerTitle
        self.headerSubtitle = headerSubtitle
        self.headerAccessibilityLabel = headerAccessibilityLabel
        self.headerIsDisabled = headerIsDisabled
        self.headerLeading = headerLeading
        self.headerTitleAccessory = headerTitleAccessory
        self.bodyItem = bodyItem

        switch expansion {
        case .localSingle(let initiallyExpanded):
            _localSingleID = State(initialValue: initiallyExpanded)
            _localMultipleIDs = State(initialValue: [])
        case .localMultiple(let initiallyExpanded):
            _localSingleID = State(initialValue: nil)
            _localMultipleIDs = State(initialValue: initiallyExpanded)
        case .single, .multiple:
            _localSingleID = State(initialValue: nil)
            _localMultipleIDs = State(initialValue: [])
        }
    }

    var body: some View {
        Group {
            switch appearance {
            case .card:
                VStack(spacing: AccordionListMetrics.groupSpacing) {
                    ForEach(items) { item in
                        cardGroup(item)
                    }
                }
            case .cardless:
                VStack(spacing: HermesSpacing.s0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        cardlessGroup(item, index: index)
                    }
                }
            }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            pruneLocalExpansion(validIDs: Set(ids))
        }
    }

    // MARK: - Expansion state

    private func isExpanded(_ id: Item.ID) -> Bool {
        switch expansion {
        case .single(let binding):
            return binding.wrappedValue == id
        case .multiple(let binding):
            return binding.wrappedValue.contains(id)
        case .localSingle:
            return localSingleID == id
        case .localMultiple:
            return localMultipleIDs.contains(id)
        }
    }

    private func toggle(_ item: Item) {
        guard !headerIsDisabled(item) else { return }
        let id = item.id
        let animation = reduceMotion ? nil : HermesMotion.animation(for: HermesMotion.Bundle.contentReposition)
        withAnimation(animation) {
            switch expansion {
            case .single(let binding):
                binding.wrappedValue = AccordionListExpansionResolver.toggledSingle(
                    current: binding.wrappedValue,
                    id: id
                )
            case .multiple(let binding):
                binding.wrappedValue = AccordionListExpansionResolver.toggledMultiple(
                    current: binding.wrappedValue,
                    id: id
                )
            case .localSingle:
                localSingleID = AccordionListExpansionResolver.toggledSingle(current: localSingleID, id: id)
            case .localMultiple:
                localMultipleIDs = AccordionListExpansionResolver.toggledMultiple(current: localMultipleIDs, id: id)
            }
        }
    }

    private func pruneLocalExpansion(validIDs: Set<Item.ID>) {
        switch expansion {
        case .localSingle:
            localSingleID = AccordionListExpansionResolver.prunedSingle(
                current: localSingleID,
                validIDs: validIDs
            )
        case .localMultiple:
            localMultipleIDs = AccordionListExpansionResolver.prunedMultiple(
                current: localMultipleIDs,
                validIDs: validIDs
            )
        case .single, .multiple:
            break
        }
    }

    // MARK: - Rendering

    @ViewBuilder
    private func cardGroup(_ item: Item) -> some View {
        VStack(spacing: HermesSpacing.s0) {
            if separatorStyle.showsOuterDividers {
                HermexDivider()
            }
            groupRows(item)
            if separatorStyle.showsOuterDividers {
                HermexDivider()
            }
        }
        .padding(.horizontal, HermexCardMetrics.contentPadding)
        .hermexCardSurface(.outlined, cornerRadius: HermesRadius.card)
    }

    @ViewBuilder
    private func cardlessGroup(_ item: Item, index: Int) -> some View {
        if separatorStyle.showsOuterDividers, index == items.startIndex {
            HermexDivider()
        }

        groupRows(item)

        if separatorStyle.showsOuterDividers
            || (separatorStyle == .betweenRows && index < items.index(before: items.endIndex)) {
            HermexDivider()
        }
    }

    @ViewBuilder
    private func groupRows(_ item: Item) -> some View {
        let expanded = isExpanded(item.id)
        let rows = bodyItems(item)
        let bodyLeadingInset = hasHeaderLeading ? AccordionListMetrics.headerTextLeadingInset : HermesSpacing.s0
        let bodyDividerLeadingInset = bodyLeadingInset + HermesSpacing.s12

        header(for: item, expanded: expanded)

        if expanded {
            if separatorStyle.showsInternalDividers, !rows.isEmpty {
                HermexDivider()
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                bodyItem(item, row)
                    .padding(.leading, bodyLeadingInset)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .asymmetric(
                                insertion: .opacity.combined(
                                    with: .offset(y: HermesMotion.Properties.distanceShort)
                                ),
                                removal: .opacity.combined(
                                    with: .offset(y: -HermesMotion.Properties.distanceShort)
                                )
                            )
                    )

                if separatorStyle.showsInternalDividers, index < rows.index(before: rows.endIndex) {
                    HermexDivider(leadingInset: bodyDividerLeadingInset)
                }
            }
        }
    }

    private func header(for item: Item, expanded: Bool) -> some View {
        ListItem(
            title: headerTitle(item),
            subtitle: headerSubtitle(item),
            accessibilityLabel: headerAccessibilityLabel(item),
            accessibilityValue: expanded ? Text("Expanded") : Text("Collapsed"),
            state: ListItemState(isDisabled: headerIsDisabled(item)),
            titleRole: .label,
            rowIndicatorSystemImage: expanded ? "chevron.up" : "chevron.down",
            rowIndicatorSize: HermesIconSize.medium,
            action: { toggle(item) },
            leading: {
                if hasHeaderLeading {
                    headerLeading(item)
                        .frame(
                            width: HermesAvatarSize.small.rawValue,
                            height: HermesAvatarSize.small.rawValue
                        )
                }
            },
            titleAccessory: { headerTitleAccessory(item) }
        )
    }
}

/// Compile-safe initializer path for callers with no header leading content: forwards an
/// `EmptyView` `headerLeading` closure to the designated initializer rather than requiring every
/// no-leading caller to pass an empty placeholder frame manually.
extension AccordionList where HeaderLeading == EmptyView {
    init(
        items: [Item],
        appearance: AccordionListAppearance,
        separatorStyle: AccordionListSeparatorStyle,
        expansion: AccordionListExpansion<Item.ID>,
        bodyItems: @escaping (Item) -> [BodyItem],
        headerTitle: @escaping (Item) -> Text,
        headerSubtitle: @escaping (Item) -> Text?,
        headerAccessibilityLabel: @escaping (Item) -> Text?,
        headerIsDisabled: @escaping (Item) -> Bool,
        @ViewBuilder headerTitleAccessory: @escaping (Item) -> HeaderTitleAccessory,
        @ViewBuilder bodyItem: @escaping (Item, BodyItem) -> BodyRow
    ) {
        self.init(
            items: items,
            appearance: appearance,
            separatorStyle: separatorStyle,
            expansion: expansion,
            bodyItems: bodyItems,
            headerTitle: headerTitle,
            headerSubtitle: headerSubtitle,
            headerAccessibilityLabel: headerAccessibilityLabel,
            headerIsDisabled: headerIsDisabled,
            headerLeading: { _ in EmptyView() },
            headerTitleAccessory: headerTitleAccessory,
            bodyItem: bodyItem
        )
    }
}
