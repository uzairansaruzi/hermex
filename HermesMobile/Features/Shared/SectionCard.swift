import SwiftUI

struct SectionCard<Content: View, Footer: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let title: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
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
                    .foregroundStyle(.appSecondary)
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
                shape.fill(Color(.appSurface).opacity(reduceTransparency ? 1 : 0.34))
            }
            .adaptiveGlass(.regular, fallbackMaterial: .regularMaterial, in: shape)
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color(.appText).opacity(colorSchemeContrast == .increased ? 0.16 : 0.06), lineWidth: 0.7)
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
