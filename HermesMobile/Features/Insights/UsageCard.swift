import SwiftUI

/// The Usage screen's card container: an optional uppercase title over a glass
/// panel. Matches the Settings card chrome so the two screens read as one app.
struct UsageCard<Content: View>: View {
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

/// Formats a server-reported 0–100 percentage (e.g. `cache_hit_percent`) with a
/// localized percent symbol and at most one fraction digit ("87.5%", "12%").
func insightsFormattedPercent(_ value: Double, locale: Locale = .current) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
}
