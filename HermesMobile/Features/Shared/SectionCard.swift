import SwiftUI

/// A card container: an optional uppercase title over a glass panel. Shared by
/// Usage and Task Detail, and matched to the Settings card chrome, so the
/// screens read as one app.
///
/// An optional `footer` sits flush against the card's bottom edge, under a
/// full-width divider and outside the content's padding — the shape a row of
/// card actions wants. Passing it here rather than cancelling the padding at
/// the call site keeps the card's insets its own business.
struct SectionCard<Content: View, Footer: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let title: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    /// Set by the initializer rather than inferred from `Footer`, so an empty
    /// footer never leaves a divider hanging under the content.
    private let hasFooter: Bool

    init(
        title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
        self.hasFooter = true
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .textCase(.uppercase)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if hasFooter {
                    Divider()
                    footer
                }
            }
            .background {
                shape.fill(Color(.secondarySystemBackground).opacity(reduceTransparency ? 1 : 0.34))
            }
            .adaptiveGlass(.regular, fallbackMaterial: .regularMaterial, in: shape)
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color.primary.opacity(colorSchemeContrast == .increased ? 0.16 : 0.06), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension SectionCard where Footer == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.footer = EmptyView()
        self.hasFooter = false
    }
}
