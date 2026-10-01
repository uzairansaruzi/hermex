import SwiftUI

/// Anchored explanatory content behind an explicit tap trigger, using the native `.popover`
/// presentation path (the same one `ContextWindowIndicatorView` and `GitBranchPickerView` already
/// use) — never a hover-only affordance. Dismissal is the popover's own native recovery path: tap
/// outside, or the hardware-keyboard Escape key.
struct HermexTooltip<Trigger: View, Content: View>: View {
    @State private var isPresented = false
    let accessibilityLabel: String
    let trigger: () -> Trigger
    let content: () -> Content

    init(
        accessibilityLabel: String = String(localized: "More information"),
        @ViewBuilder trigger: @escaping () -> Trigger,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.trigger = trigger
        self.content = content
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            trigger()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            content()
                .appFont(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(HermesSpacing.s12)
                .frame(maxWidth: 280)
                .presentationCompactAdaptation(.none)
        }
    }
}

/// The common trigger: a small "info" glyph sized to the accepted icon scale.
struct HermexTooltipInfoTrigger: View {
    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: HermesIconSize.small))
            .foregroundStyle(.secondary)
    }
}

extension HermexTooltip where Trigger == HermexTooltipInfoTrigger {
    /// The common case: an "info" glyph trigger, so a caller doesn't have to spell one out.
    static func info(
        accessibilityLabel: String = String(localized: "More information"),
        @ViewBuilder content: @escaping () -> Content
    ) -> HermexTooltip {
        HermexTooltip(accessibilityLabel: accessibilityLabel, trigger: { HermexTooltipInfoTrigger() }, content: content)
    }
}
