import SwiftUI

/// One option in a `HermexSelectionSheet`. Intentionally small — a caller needing richer
/// provider-specific row content should first establish that requirement against a real
/// production flow rather than widening this foundation speculatively.
struct HermexSelectionSheetOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: LocalizedStringKey
    let isEnabled: Bool
    var id: Value { value }

    init(value: Value, title: LocalizedStringKey, isEnabled: Bool = true) {
        self.value = value
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// Optional caller-controlled Search configuration. When present, Selection Sheet renders the
/// real `HermexSearchField` above the option list; it never matches, debounces, loads, or errors
/// on its own — the caller edits `text` and supplies the currently visible `options` array.
struct HermexSelectionSheetSearch {
    let title: LocalizedStringKey
    let text: Binding<String>
    let prompt: Text?
    let isEnabled: Bool

    init(title: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil, isEnabled: Bool = true) {
        self.title = title
        self.text = text
        self.prompt = prompt
        self.isEnabled = isEnabled
    }
}

/// Pure staged multi-selection state: `baseline` is the caller's set snapshotted at open time,
/// `values` is the locally-edited draft row taps toggle. Done writes `values` to the caller
/// binding once; Cancel/dismissal discard both without ever reading them again. Never intersected
/// against a caller's currently-visible option array, so a value temporarily hidden by Search
/// filtering stays selected.
struct HermexSelectionSheetDraft<Value: Hashable>: Equatable {
    private(set) var baseline: Set<Value>
    private(set) var values: Set<Value>

    init(baseline: Set<Value>) {
        self.baseline = baseline
        self.values = baseline
    }

    var isDirty: Bool { values != baseline }

    mutating func toggle(_ value: Value) {
        if values.contains(value) {
            values.remove(value)
        } else {
            values.insert(value)
        }
    }
}

/// One private mode per explicit public initializer — never inferred from option count.
private enum HermexSelectionSheetMode<Value: Hashable> {
    case single(Binding<Value?>)
    case multi(Binding<Set<Value>>)
}

/// How the multi-selection footer's Cancel/Done actions arrange: side-by-side or stacked. Maps
/// onto the existing `HermexBottomSheet.FooterAxis` at the call site rather than changing Bottom
/// Sheet itself. The single-selection composition renders no footer, so this only ever affects
/// multi-selection.
enum HermexSelectionSheetFooterAxis: Equatable {
    case horizontal
    case vertical
}

/// Caller-selected outer horizontal inset applied once to the shared Search/list/empty-state
/// container. Not an arbitrary CGFloat — a closed, semantic choice between the standard screen
/// margin and no inset at all.
enum HermexSelectionSheetContentInset: Equatable {
    case standard
    case none

    var horizontalPadding: CGFloat {
        switch self {
        case .standard: HermesSpacing.s16
        case .none: HermesSpacing.s0
        }
    }
}

/// The caller-presented content that replaces the retired `HermexDropdown`'s intended
/// fixed-option-selection role: immediate single selection or staged multi-selection over a
/// scrolling option list, composed entirely from existing foundations — `HermexBottomSheet`,
/// `TopNav`, `HermexList`/`ListItem`, row-owned `HermexRadio`/`HermexCheckbox` indicators, and an
/// optional `HermexSearchField`. The caller owns native `.sheet` presentation, detents, option
/// data, and any query/filtering; this view owns only the presented content and local selection
/// lifecycle, dismissing through the environment dismiss action rather than a second overlay
/// mechanism.
struct HermexSelectionSheet<Value: Hashable>: View {
    private let title: LocalizedStringKey
    private let mode: HermexSelectionSheetMode<Value>
    private let options: [HermexSelectionSheetOption<Value>]
    private let search: HermexSelectionSheetSearch?
    private let contentInset: HermexSelectionSheetContentInset
    private let footerAxis: HermexSelectionSheetFooterAxis

    @Environment(\.dismiss) private var dismiss
    @State private var draft: HermexSelectionSheetDraft<Value>?
    @AccessibilityFocusState private var focusedOptionValue: Value?

    /// Immediate single selection: an enabled row commits the caller's binding once and dismisses.
    init(
        _ title: LocalizedStringKey,
        selection: Binding<Value?>,
        options: [HermexSelectionSheetOption<Value>],
        search: HermexSelectionSheetSearch? = nil,
        contentInset: HermexSelectionSheetContentInset = .standard
    ) {
        self.title = title
        self.mode = .single(selection)
        self.options = options
        self.search = search
        self.contentInset = contentInset
        self.footerAxis = .horizontal
        self._draft = State(initialValue: nil)
    }

    /// Staged multi-selection: row taps edit a local draft only; Done commits it once.
    init(
        _ title: LocalizedStringKey,
        selections: Binding<Set<Value>>,
        options: [HermexSelectionSheetOption<Value>],
        search: HermexSelectionSheetSearch? = nil,
        contentInset: HermexSelectionSheetContentInset = .standard,
        footerAxis: HermexSelectionSheetFooterAxis = .horizontal
    ) {
        self.title = title
        self.mode = .multi(selections)
        self.options = options
        self.search = search
        self.contentInset = contentInset
        self.footerAxis = footerAxis
        self._draft = State(initialValue: HermexSelectionSheetDraft(baseline: selections.wrappedValue))
    }

    @ViewBuilder
    var body: some View {
        switch mode {
        case .single:
            singleSelectionSheet
        case .multi(let selections):
            multiSelectionSheet(selections: selections)
        }
    }

    private var singleSelectionSheet: some View {
        HermexBottomSheet(title) {
            sheetContent
        } leadingPrimary: {
            Button("Cancel") { dismiss() }
                .accessibilityIdentifier("hermex-selection-sheet-cancel")
        }
    }

    private func multiSelectionSheet(selections: Binding<Set<Value>>) -> some View {
        HermexBottomSheet(
            title,
            footerAxis: footerAxis == .horizontal ? .horizontal : .vertical
        ) {
            sheetContent
        } footer: {
            multiFooter(selections: selections)
        }
        // The initializer's synchronous `_draft = State(initialValue:)` seeding only ever runs for a
        // genuinely new `draft` storage instance — it cannot reset a value SwiftUI has already
        // decided to keep across this sheet content's own present/dismiss cycle. A cancelled draft
        // from a prior presentation must never leak into the next one, so every presentation also
        // resets it here, from the caller's current binding, against `.onAppear` rather than init.
        .onAppear {
            draft = HermexSelectionSheetDraft(baseline: selections.wrappedValue)
        }
    }

    @ViewBuilder
    private func multiFooter(selections: Binding<Set<Value>>) -> some View {
        switch footerAxis {
        case .horizontal:
            Button("Cancel") { dismiss() }
                .buttonStyle(.hermex(.medium, emphasis: .secondary))
                .accessibilityIdentifier("hermex-selection-sheet-cancel")
            Button("Done") { commitMultiSelection(selections: selections) }
                .buttonStyle(.hermex(.medium, emphasis: .primary))
                .accessibilityIdentifier("hermex-selection-sheet-done")
        case .vertical:
            Button { commitMultiSelection(selections: selections) } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.hermex(.medium, emphasis: .primary))
                .accessibilityIdentifier("hermex-selection-sheet-done")
            Button { dismiss() } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.hermex(.medium, emphasis: .secondary))
                .accessibilityIdentifier("hermex-selection-sheet-cancel")
        }
    }

    private var sheetContent: some View {
        VStack(spacing: 0) {
            if let search {
                HermexSearchField(
                    search.title,
                    text: search.text,
                    prompt: search.prompt,
                    isEnabled: search.isEnabled
                )
                .padding(.top, HermesSpacing.s12)
            }

            if options.isEmpty {
                emptyState
            } else {
                HermexList {
                    ForEach(options) { option in
                        row(for: option)
                    }
                }
            }
        }
        .padding(.horizontal, contentInset.horizontalPadding)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedOptionValue = initialFocusOptionValue
        }
    }

    private var emptyState: some View {
        let hasQuery = !(search?.text.wrappedValue.isEmpty ?? true)
        return HermexContentUnavailable(
            variant: hasQuery ? .noResults : .empty,
            title: hasQuery ? String(localized: "No results") : String(localized: "No options available")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(for option: HermexSelectionSheetOption<Value>) -> some View {
        switch mode {
        case .single(let selection):
            singleRow(for: option, selection: selection)
        case .multi(let selections):
            multiRow(for: option, selections: selections)
        }
    }

    private func singleRow(for option: HermexSelectionSheetOption<Value>, selection: Binding<Value?>) -> some View {
        let isSelected = selection.wrappedValue == option.value
        return ListItem(
            title: Text(option.title),
            titleLineLimit: 3,
            state: ListItemState(isSelected: isSelected, isDisabled: !option.isEnabled),
            selectionChrome: .indicatorOnly,
            action: { activateSingle(option, selection: selection) },
            leading: { HermexRadio(isSelected: isSelected, isEnabled: option.isEnabled, action: nil) }
        )
        .accessibilityFocused($focusedOptionValue, equals: option.value)
        .accessibilityIdentifier("hermex-selection-sheet-option-\(String(describing: option.value))")
    }

    private func multiRow(for option: HermexSelectionSheetOption<Value>, selections: Binding<Set<Value>>) -> some View {
        let isSelected = draft?.values.contains(option.value) ?? selections.wrappedValue.contains(option.value)
        return ListItem(
            title: Text(option.title),
            titleLineLimit: 3,
            state: ListItemState(isSelected: isSelected, isDisabled: !option.isEnabled),
            selectionChrome: .indicatorOnly,
            action: { toggleMulti(option) },
            leading: { HermexCheckbox(isChecked: isSelected, isEnabled: option.isEnabled, action: nil) }
        )
        .accessibilityFocused($focusedOptionValue, equals: option.value)
        .accessibilityIdentifier("hermex-selection-sheet-option-\(String(describing: option.value))")
    }

    private func activateSingle(_ option: HermexSelectionSheetOption<Value>, selection: Binding<Value?>) {
        guard option.isEnabled else { return }
        if selection.wrappedValue != option.value {
            selection.wrappedValue = option.value
        }
        dismiss()
    }

    private func toggleMulti(_ option: HermexSelectionSheetOption<Value>) {
        guard option.isEnabled else { return }
        draft?.toggle(option.value)
    }

    private func commitMultiSelection(selections: Binding<Set<Value>>) {
        guard let draft else { return }
        selections.wrappedValue = draft.values
        dismiss()
    }

    /// The current selected enabled visible option, else the first enabled visible option.
    private var initialFocusOptionValue: Value? {
        let selectedValues = currentSelectedValues
        if let selected = options.first(where: { $0.isEnabled && selectedValues.contains($0.value) }) {
            return selected.value
        }
        return options.first(where: { $0.isEnabled })?.value
    }

    private var currentSelectedValues: Set<Value> {
        switch mode {
        case .single(let selection):
            return selection.wrappedValue.map { Set([$0]) } ?? []
        case .multi:
            return draft?.values ?? []
        }
    }
}
