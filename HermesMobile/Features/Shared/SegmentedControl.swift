import SwiftUI

/// Shared mutually-exclusive selection control. Both variants use Hermex-owned presentation and
/// native Button semantics: fixed divides the available width equally, while scrolling preserves
/// each option's intrinsic width when the set no longer fits.
enum SegmentedControlStyle {
    case fixed
    case scrolling
}

private enum SegmentedControlMetrics {
    static let minimumTouchHeight: CGFloat = 44
    static let trackInset: CGFloat = HermesSpacing.s2
    /// Vertical padding step above and below the selected pill that defines the fixed variant's
    /// recessed visual-track background, distinct from the 44pt interactive row it sits inside.
    /// Insets from the text-bearing row rather than fixing a height, so the track grows with
    /// accessibility-sized labels: 40pt at the 44pt minimum row height.
    static let fixedTrackVisualPadding: CGFloat = HermesSpacing.s2
    /// Vertical inset between the fixed variant's selected pill and its text-bearing row. Insets
    /// rather than fixing a height, so the pill grows with wrapped or scaled labels: 36pt at the
    /// 44pt minimum row height.
    static let selectedVisualInset: CGFloat = HermesSpacing.s4
    /// The scrolling variant's selected pill keeps its prior fixed visual height instead of growing
    /// with accessibility text, unlike the fixed variant's dynamically inset pill.
    static let scrollingSelectedPillHeight: CGFloat = 36
}

struct SegmentedControlOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var count: Int?
    var tint: Color?

    var id: Value { value }
}

struct SegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SegmentedControlOption<Value>]
    var style: SegmentedControlStyle = .fixed

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    init(
        _ title: String,
        selection: Binding<Value>,
        options: [SegmentedControlOption<Value>],
        style: SegmentedControlStyle = .fixed
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.style = style
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .fixed:
            HStack(spacing: HermesSpacing.s4) {
                ForEach(options) { option in
                    optionButton(option, expandsToFill: true)
                }
            }
            .frame(minHeight: SegmentedControlMetrics.minimumTouchHeight)
            .padding(.horizontal, SegmentedControlMetrics.trackInset)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .padding(.vertical, SegmentedControlMetrics.fixedTrackVisualPadding)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title))
        case .scrolling:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HermesSpacing.s8) {
                    ForEach(options) { option in
                        optionButton(option, expandsToFill: false)
                    }
                }
                .padding(.horizontal, HermesSpacing.screenHorizontal)
                .padding(.vertical, HermesSpacing.s4)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title))
        }
    }

    private func optionButton(
        _ option: SegmentedControlOption<Value>,
        expandsToFill: Bool
    ) -> some View {
        let isSelected = selection == option.value

        return Button {
            withAnimation(selectionAnimation) {
                selection = option.value
            }
        } label: {
            optionLabel(option, isSelected: isSelected, expandsToFill: expandsToFill)
                .padding(.horizontal, HermesSpacing.s12)
                .frame(
                    maxWidth: expandsToFill ? .infinity : nil,
                    minHeight: SegmentedControlMetrics.minimumTouchHeight
                )
                .background {
                    // The selected pill is bound to this text-bearing row's own resolved size via
                    // `.background` — never a ZStack sibling — so a greedy, unconstrained `Capsule`
                    // can never adopt an ambient parent proposal instead of tracking the row it sits
                    // behind.
                    if isSelected {
                        if expandsToFill {
                            Capsule(style: .continuous)
                                .fill(Color(.systemBackground))
                                .hermesShadow(.controlElevatedResting)
                                .matchedGeometryEffect(id: "segmented-control-selection", in: selectionNamespace)
                                .padding(.vertical, SegmentedControlMetrics.selectedVisualInset)
                                .allowsHitTesting(false)
                        } else {
                            Capsule(style: .continuous)
                                .fill(Color(.systemBackground))
                                .hermesShadow(.controlElevatedResting)
                                .matchedGeometryEffect(id: "segmented-control-selection", in: selectionNamespace)
                                .frame(height: SegmentedControlMetrics.scrollingSelectedPillHeight)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.hermexPressOnly(.capsule))
        .accessibilityLabel(accessibilityLabel(for: option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func optionLabel(
        _ option: SegmentedControlOption<Value>,
        isSelected: Bool,
        expandsToFill: Bool
    ) -> some View {
        HStack(spacing: HermesSpacing.s8) {
            if let tint = option.tint {
                Circle()
                    .fill(tint)
                    .frame(width: HermesIconSize.xs, height: HermesIconSize.xs)
                    .accessibilityHidden(true)
            }

            Text(option.title)
                .appFont(isSelected ? .subheadlineSemibold : .subheadline)
                .lineLimit(expandsToFill ? 2 : nil)
                .multilineTextAlignment(.center)

            if let count = option.count {
                Text(verbatim: "\(count)")
                    .appFont(.mono12)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
    }

    private var selectionAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return HermesMotion.animation(for: HermesMotion.Bundle.contentReposition)
    }

    private func accessibilityLabel(for option: SegmentedControlOption<Value>) -> Text {
        if let count = option.count {
            return Text("\(option.title), \(count)")
        }
        return Text(option.title)
    }
}
