import SwiftUI

/// Shared radio metrics, mirroring `HermexCheckboxMetrics`: a compact visual control inside the
/// platform minimum hit target.
enum HermexRadioMetrics {
    static let circleSize: CGFloat = HermexCheckboxMetrics.boxSize
    static let innerDotSize: CGFloat = 10
    static let borderWidth: CGFloat = HermexCheckboxMetrics.borderWidth
    static let minimumHitTarget: CGFloat = HermexCheckboxMetrics.minimumHitTarget
}

/// A reusable one-of-many selection control — the circular counterpart to `HermexCheckbox`'s
/// boolean square. Pass an `action` when the radio owns interaction; a containing row that owns the
/// tap instead gets the same visual as an accessibility-hidden indicator.
struct HermexRadio: View {
    let isSelected: Bool
    var isEnabled = true
    var label: String?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                content
                    .frame(minWidth: HermexRadioMetrics.minimumHitTarget, minHeight: HermexRadioMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hermexPressOnly(.icon))
            .disabled(!isEnabled)
            .accessibilityLabel(label ?? String(localized: "Option"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
                .accessibilityHidden(true)
        }
    }

    private var content: some View {
        HStack(spacing: HermesSpacing.s8) {
            ZStack {
                Circle()
                    .stroke(
                        isSelected ? HermexSelectionControlColors.selected : HermexSelectionControlColors.unselectedBorder,
                        lineWidth: HermexRadioMetrics.borderWidth
                    )

                if isSelected {
                    Circle()
                        .fill(HermexSelectionControlColors.selected)
                        .frame(width: HermexRadioMetrics.innerDotSize, height: HermexRadioMetrics.innerDotSize)
                }
            }
            .frame(width: HermexRadioMetrics.circleSize, height: HermexRadioMetrics.circleSize)

            if let label {
                Text(label)
                    .appFont(.body)
                    .foregroundStyle(.primary)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}
