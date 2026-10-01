import SwiftUI

/// Background-agnostic divider that derives contrast from the current foreground instead of
/// assuming a particular surface color.
struct HermexDivider: View {
    @Environment(\.displayScale) private var displayScale

    var leadingInset: CGFloat = HermesSpacing.s0

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1 / displayScale)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}
