import SwiftUI

/// Shared checkbox metrics. The visual control stays compact while the interactive
/// wrapper expands to the platform minimum hit target.
enum HermexCheckboxMetrics {
    static let boxSize: CGFloat = 20
    static let borderWidth: CGFloat = 2
    static let minimumHitTarget: CGFloat = 44
}

/// The shared Neutral color mapping for both selection controls (DSF-08/DSF-09): `HermexCheckbox`'s
/// checked fill/border/checkmark and `HermexRadio`'s selected ring/dot both resolve to these three
/// adaptive pairs instead of `Color.primary` or the inverse system background.
enum HermexSelectionControlColors {
    static let selected = HermesColorRamp.Neutral.adaptive(
        light: HermesColorRamp.Neutral.s950,
        dark: HermesColorRamp.Neutral.s50
    )
    static let selectedForeground = HermesColorRamp.Neutral.adaptive(
        light: HermesColorRamp.Neutral.s50,
        dark: HermesColorRamp.Neutral.s950
    )
    static let unselectedBorder = HermesColorRamp.Neutral.adaptive(
        light: HermesColorRamp.Neutral.s500,
        dark: HermesColorRamp.Neutral.s600
    )
}

/// A reusable square multi-selection control.
///
/// Pass an `action` when the checkbox owns interaction. When a containing row
/// owns the tap, omit `action`; the same visual is rendered as an
/// accessibility-hidden indicator so controls are never nested.
struct HermexCheckbox: View {
    let isChecked: Bool
    var isEnabled = true
    var label: String?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                content
                    .frame(minWidth: HermexCheckboxMetrics.minimumHitTarget, minHeight: HermexCheckboxMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hermexPressOnly(.icon))
            .disabled(!isEnabled)
            .accessibilityRepresentation {
                Toggle(
                    label ?? String(localized: "Checkbox"),
                    isOn: Binding(
                        get: { isChecked },
                        set: { _ in action() }
                    )
                )
                .disabled(!isEnabled)
            }
        } else {
            content
                .accessibilityHidden(true)
        }
    }

    private var content: some View {
        HStack(spacing: HermesSpacing.s8) {
            ZStack {
                RoundedRectangle(cornerRadius: HermesRadius.r4, style: .continuous)
                    .fill(isChecked ? HermexSelectionControlColors.selected : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: HermesRadius.r4, style: .continuous)
                            .stroke(
                                isChecked ? HermexSelectionControlColors.selected : HermexSelectionControlColors.unselectedBorder,
                                lineWidth: HermexCheckboxMetrics.borderWidth
                            )
                    }

                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: HermesIconSize.xs, weight: .bold))
                        .foregroundStyle(HermexSelectionControlColors.selectedForeground)
                }
            }
            .frame(width: HermexCheckboxMetrics.boxSize, height: HermexCheckboxMetrics.boxSize)

            if let label {
                Text(label)
                    .appFont(.body)
                    .foregroundStyle(.primary)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}
