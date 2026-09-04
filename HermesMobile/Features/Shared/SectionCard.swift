import SwiftUI

/// A card container: an optional uppercase title over a glass panel. Shared by
/// Usage and Task Detail, and matched to the Settings card chrome, so the
/// screens read as one app.
struct SectionCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
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

            content
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape.fill(Color(.secondarySystemBackground).opacity(reduceTransparency ? 1 : 0.34))
                }
                .adaptiveGlass(.regular, fallbackMaterial: .regularMaterial, in: shape)
                .overlay {
                    shape
                        .stroke(Color.primary.opacity(colorSchemeContrast == .increased ? 0.16 : 0.06), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
        }
    }
}
