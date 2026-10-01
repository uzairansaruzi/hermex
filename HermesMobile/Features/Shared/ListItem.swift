import SwiftUI

/// Row geometry and selection chrome shared by every picker row in Settings and the Task editor, so
/// Default Model, Default Profile, and the Task editor's Model/Profile/Skills pickers stay visually
/// identical. Replaces the standalone "Picker Row" component: every caller below composes `ListItem`
/// directly instead of hand-rolling this HStack/frame/pill scaffolding.
enum ListItemMetrics {
    static let minHeight: CGFloat = 48
    static let cornerRadius: CGFloat = HermesRadius.field
}

/// `ListItem`'s selected/pending/disabled state. A free-standing type rather than a nested one, so a
/// caller can build a `ListItemState` without first spelling out `ListItem`'s three content generic
/// parameters.
struct ListItemState: Equatable {
    var isSelected = false
    var isPending = false
    var isDisabled = false
}

/// `ListItem`'s selected-row visual chrome. `.standard` is the original, still-default behavior:
/// the filled selection pill plus the built-in trailing checkmark. `.indicatorOnly` is additive —
/// Selection Sheet opts into it so a row-owned Radio/Checkbox visual is the row's only selection
/// mark, while `state.isSelected`'s accessibility trait stays identical under both modes.
enum ListItemSelectionChrome {
    case standard
    case indicatorOnly
}

/// `ListItem`'s content padding. `.standard` is the original, still-default behavior: the row and
/// its selection pill keep their existing 12pt horizontal inset. `.none` is additive — a caller that
/// already owns its own surrounding padding (`HermexPopoverMenu`'s shell padding, for instance)
/// opts into it so the row's content never doubles that padding.
enum ListItemContentInset: Equatable {
    case standard
    case none

    var horizontalPadding: CGFloat {
        switch self {
        case .standard: return HermesSpacing.s12
        case .none: return HermesSpacing.s0
        }
    }
}

extension View {
    /// The selected-row treatment shared by every `ListItem`: a filled `Color.primary` pill with the
    /// inverted foreground that fill needs. The caller owns the row's frame, because the pill can
    /// wrap content that sits outside the row's own button — a trailing accessory does. The pill's
    /// horizontal inset comes from the `contentInset` the caller forwards, so a `.none` row (a
    /// `HermexPopoverMenu` action, for instance) collapses it to zero.
    func listItemSelectionPill(isSelected: Bool, contentInset: ListItemContentInset) -> some View {
        modifier(ListItemSelectionPillModifier(isSelected: isSelected, contentInset: contentInset))
    }
}

private struct ListItemSelectionPillModifier: ViewModifier {
    let isSelected: Bool
    let contentInset: ListItemContentInset

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
            .padding(.horizontal, contentInset.horizontalPadding)
            .background(
                isSelected ? Color.primary : Color.clear,
                in: RoundedRectangle(cornerRadius: ListItemMetrics.cornerRadius, style: .continuous)
            )
    }
}

/// The row button's pressed-surface treatment: a color/opacity change only, using
/// `HermesMotion.Bundle.stateChange` — no scale feedback, unlike `HermesMotion.Bundle.feedbackPress`'s
/// tactile pattern used elsewhere in the app. A standard selected row keeps its filled selection pill
/// and gets a contrast-safe opacity adjustment while pressed; every other row (unselected, or an
/// indicator-only selected row with no filled pill of its own) gets a subtle adaptive Neutral surface
/// instead. Respects `Environment(\.isEnabled)` so a disabled or pending row shows no pressed feedback.
struct ListItemButtonStyle: ButtonStyle {
    let isSelected: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed
        configuration.label
            .background(
                isSelected ? Color.clear : (isPressed ? ListItemButtonStyleColors.pressedSurface : Color.clear),
                in: RoundedRectangle(cornerRadius: ListItemMetrics.cornerRadius, style: .continuous)
            )
            .opacity(isSelected && isPressed ? ListItemButtonStyleColors.selectedPressedOpacity : 1)
            .animation(HermesMotion.animation(for: HermesMotion.Bundle.stateChange), value: isPressed)
    }
}

private enum ListItemButtonStyleColors {
    static let pressedSurface = HermesColorRamp.Neutral.adaptive(
        light: HermesColorRamp.Neutral.s100,
        dark: HermesColorRamp.Neutral.s800
    )
    static let selectedPressedOpacity: Double = 0.85
}

/// A reusable list row: optional leading content, a title with an optional title-adjacent accessory
/// (a Tag, for instance), an optional subtitle, and a trailing zone that shows a pending spinner, a
/// selected checkmark, or nothing. `trailingAccessory` sits beside — not inside — the row's own tap
/// target, so it stays independently interactive (a favorite star, for instance) while the whole row
/// still shares one selection pill.
///
/// Navigation, swipe actions, context menus, and the decision to wrap a whole row in another control
/// stay caller-owned; `ListItem` only owns this shared anatomy and its selected/pending/disabled
/// states.
struct ListItem<Leading: View, TitleAccessory: View, Trailing: View>: View {
    var title: Text
    var titleLineLimit: Int = 1
    var subtitle: Text?
    var subtitleLineLimit: Int = 1
    var accessibilityLabel: Text?
    var accessibilityValue: Text?
    var state = ListItemState()
    var selectionChrome: ListItemSelectionChrome = .standard
    var contentInset: ListItemContentInset = .standard
    /// Omit for a plain native `Button`. Set it when a caller needs an explicit tap haptic while
    /// retaining `ListItem`'s shared row anatomy.
    var hapticFeedbackStyle: HapticButtonFeedbackStyle?
    /// The title's semantic weight. Defaults to `.body`; an accordion header requests `.label` to
    /// read stronger than the body rows it discloses.
    var titleRole: AppFont.Role = .body
    /// A decorative, accessibility-hidden system image shown in the trailing indicator slot once
    /// pending/selected precedence is resolved — an accordion header's chevron, for instance.
    var rowIndicatorSystemImage: String? = nil
    /// `rowIndicatorSystemImage`'s rendered size. Defaults to the existing `HermesIconSize.small`
    /// ListItem indicator size; an accordion header opts into `HermesIconSize.medium`.
    var rowIndicatorSize: CGFloat = HermesIconSize.small
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var titleAccessory: () -> TitleAccessory
    @ViewBuilder var trailingAccessory: () -> Trailing

    var body: some View {
        HStack(spacing: HermesSpacing.s12) {
            rowButton
                .buttonStyle(ListItemButtonStyle(isSelected: state.isSelected && selectionChrome == .standard))
                .disabled(state.isDisabled || state.isPending)
                .accessibilityLabel(accessibilityLabel ?? title)
                .modifier(OptionalAccessibilityValue(value: accessibilityValue))
                .accessibilityAddTraits(state.isSelected ? .isSelected : [])

            trailingAccessory()
        }
        .listItemSelectionPill(isSelected: state.isSelected && selectionChrome == .standard, contentInset: contentInset)
    }

    @ViewBuilder
    private var rowButton: some View {
        if let hapticFeedbackStyle {
            HapticButton(feedbackStyle: hapticFeedbackStyle, action: action) { rowContent }
        } else {
            Button(action: action) { rowContent }
        }
    }

    private var rowContent: some View {
        HStack(spacing: HermesSpacing.s12) {
            leading()

            VStack(alignment: .leading, spacing: HermesSpacing.s4) {
                HStack(spacing: HermesSpacing.s8) {
                    title
                        .appFont(titleRole)
                        .lineLimit(titleLineLimit)

                    titleAccessory()
                }

                if let subtitle {
                    subtitle
                        .appFont(.caption)
                        .foregroundStyle(subtitleForeground)
                        .lineLimit(subtitleLineLimit)
                }
            }

            Spacer(minLength: 0)

            trailingIndicator
        }
        .frame(maxWidth: .infinity, minHeight: ListItemMetrics.minHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if state.isPending {
            ProgressView()
                .controlSize(.small)
                .tint(state.isSelected ? Color(.systemBackground) : Color.primary)
        } else if state.isSelected && selectionChrome == .standard {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
        } else if let rowIndicatorSystemImage {
            Image(systemName: rowIndicatorSystemImage)
                .font(.system(size: rowIndicatorSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: HermesIconSize.large, height: HermesIconSize.large)
                .accessibilityHidden(true)
        }
    }

    private var subtitleForeground: Color {
        state.isSelected && selectionChrome == .standard ? Color(.systemBackground).opacity(0.7) : Color.secondary
    }
}

extension ListItem where Leading == EmptyView {
    init(
        title: Text,
        titleLineLimit: Int = 1,
        subtitle: Text? = nil,
        subtitleLineLimit: Int = 1,
        accessibilityLabel: Text? = nil,
        accessibilityValue: Text? = nil,
        state: ListItemState = ListItemState(),
        selectionChrome: ListItemSelectionChrome = .standard,
        contentInset: ListItemContentInset = .standard,
        titleRole: AppFont.Role = .body,
        rowIndicatorSystemImage: String? = nil,
        rowIndicatorSize: CGFloat = HermesIconSize.small,
        action: @escaping () -> Void,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory,
        @ViewBuilder trailingAccessory: @escaping () -> Trailing
    ) {
        self.init(
            title: title,
            titleLineLimit: titleLineLimit,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            state: state,
            selectionChrome: selectionChrome,
            contentInset: contentInset,
            titleRole: titleRole,
            rowIndicatorSystemImage: rowIndicatorSystemImage,
            rowIndicatorSize: rowIndicatorSize,
            action: action,
            leading: { EmptyView() },
            titleAccessory: titleAccessory,
            trailingAccessory: trailingAccessory
        )
    }
}

extension ListItem where Leading == EmptyView, TitleAccessory == EmptyView {
    init(
        title: Text,
        titleLineLimit: Int = 1,
        subtitle: Text? = nil,
        subtitleLineLimit: Int = 1,
        accessibilityLabel: Text? = nil,
        accessibilityValue: Text? = nil,
        state: ListItemState = ListItemState(),
        selectionChrome: ListItemSelectionChrome = .standard,
        contentInset: ListItemContentInset = .standard,
        titleRole: AppFont.Role = .body,
        rowIndicatorSystemImage: String? = nil,
        rowIndicatorSize: CGFloat = HermesIconSize.small,
        action: @escaping () -> Void,
        @ViewBuilder trailingAccessory: @escaping () -> Trailing
    ) {
        self.init(
            title: title,
            titleLineLimit: titleLineLimit,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            state: state,
            selectionChrome: selectionChrome,
            contentInset: contentInset,
            titleRole: titleRole,
            rowIndicatorSystemImage: rowIndicatorSystemImage,
            rowIndicatorSize: rowIndicatorSize,
            action: action,
            leading: { EmptyView() },
            titleAccessory: { EmptyView() },
            trailingAccessory: trailingAccessory
        )
    }
}

extension ListItem where Leading == EmptyView, TitleAccessory == EmptyView, Trailing == EmptyView {
    init(
        title: Text,
        titleLineLimit: Int = 1,
        subtitle: Text? = nil,
        subtitleLineLimit: Int = 1,
        accessibilityLabel: Text? = nil,
        accessibilityValue: Text? = nil,
        state: ListItemState = ListItemState(),
        selectionChrome: ListItemSelectionChrome = .standard,
        contentInset: ListItemContentInset = .standard,
        titleRole: AppFont.Role = .body,
        rowIndicatorSystemImage: String? = nil,
        rowIndicatorSize: CGFloat = HermesIconSize.small,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            titleLineLimit: titleLineLimit,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            state: state,
            selectionChrome: selectionChrome,
            contentInset: contentInset,
            titleRole: titleRole,
            rowIndicatorSystemImage: rowIndicatorSystemImage,
            rowIndicatorSize: rowIndicatorSize,
            action: action,
            leading: { EmptyView() },
            titleAccessory: { EmptyView() },
            trailingAccessory: { EmptyView() }
        )
    }
}

extension ListItem where TitleAccessory == EmptyView, Trailing == EmptyView {
    init(
        title: Text,
        titleLineLimit: Int = 1,
        subtitle: Text? = nil,
        subtitleLineLimit: Int = 1,
        accessibilityLabel: Text? = nil,
        accessibilityValue: Text? = nil,
        state: ListItemState = ListItemState(),
        selectionChrome: ListItemSelectionChrome = .standard,
        contentInset: ListItemContentInset = .standard,
        hapticFeedbackStyle: HapticButtonFeedbackStyle? = nil,
        titleRole: AppFont.Role = .body,
        rowIndicatorSystemImage: String? = nil,
        rowIndicatorSize: CGFloat = HermesIconSize.small,
        action: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.init(
            title: title,
            titleLineLimit: titleLineLimit,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            state: state,
            selectionChrome: selectionChrome,
            contentInset: contentInset,
            hapticFeedbackStyle: hapticFeedbackStyle,
            titleRole: titleRole,
            rowIndicatorSystemImage: rowIndicatorSystemImage,
            rowIndicatorSize: rowIndicatorSize,
            action: action,
            leading: leading,
            titleAccessory: { EmptyView() },
            trailingAccessory: { EmptyView() }
        )
    }
}

extension ListItem where Trailing == EmptyView {
    init(
        title: Text,
        titleLineLimit: Int = 1,
        subtitle: Text? = nil,
        subtitleLineLimit: Int = 1,
        accessibilityLabel: Text? = nil,
        accessibilityValue: Text? = nil,
        state: ListItemState = ListItemState(),
        selectionChrome: ListItemSelectionChrome = .standard,
        contentInset: ListItemContentInset = .standard,
        titleRole: AppFont.Role = .body,
        rowIndicatorSystemImage: String? = nil,
        rowIndicatorSize: CGFloat = HermesIconSize.small,
        action: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder titleAccessory: @escaping () -> TitleAccessory
    ) {
        self.init(
            title: title,
            titleLineLimit: titleLineLimit,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            state: state,
            selectionChrome: selectionChrome,
            contentInset: contentInset,
            titleRole: titleRole,
            rowIndicatorSystemImage: rowIndicatorSystemImage,
            rowIndicatorSize: rowIndicatorSize,
            action: action,
            leading: leading,
            titleAccessory: titleAccessory,
            trailingAccessory: { EmptyView() }
        )
    }
}

/// `.accessibilityValue` has no "only if present" overload, so a nil value must skip the modifier
/// entirely rather than pass it an empty `Text`, which would announce a blank value.
private struct OptionalAccessibilityValue: ViewModifier {
    let value: Text?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(value)
        } else {
            content
        }
    }
}
