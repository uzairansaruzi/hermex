import SwiftUI

#if DEBUG
private enum AdaptiveGlassPreviewDefaults {
    static let glassEnabled = configuredDefaults(
        suiteName: "AdaptiveGlassPreviewDefaults.glassEnabled",
        isEnabled: true
    )

    static let materialFallback = configuredDefaults(
        suiteName: "AdaptiveGlassPreviewDefaults.materialFallback",
        isEnabled: false
    )

    private static func configuredDefaults(suiteName: String, isEnabled: Bool) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }

        defaults.set(isEnabled, forKey: GlassPreference.isEnabledKey)
        return defaults
    }
}

private struct AdaptiveGlassDebugFixture: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: "Adaptive surfaces")
                .font(.headline)

            HStack(spacing: 14) {
                AdaptiveGlassContainer(spacing: 14) {
                    sampleCard(
                        title: "Glass",
                        subtitle: "iOS 26 path",
                        systemImage: "sparkles",
                        tint: .accentColor
                    )
                }
                .defaultAppStorage(AdaptiveGlassPreviewDefaults.glassEnabled)

                sampleCard(
                    title: "Material",
                    subtitle: "Fallback path",
                    systemImage: "square.on.circle",
                    tint: nil
                )
                .defaultAppStorage(AdaptiveGlassPreviewDefaults.materialFallback)
            }

            Button {
            } label: {
                Label { Text(verbatim: "Interactive") } icon: { Image(systemName: "hand.tap") }
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .adaptiveGlass(
                isInteractive: true,
                tint: .accentColor,
                fallbackMaterial: .thinMaterial,
                in: Capsule(style: .continuous)
            )
            .defaultAppStorage(AdaptiveGlassPreviewDefaults.glassEnabled)
        }
        .padding(24)
        .frame(maxWidth: 390)
        .background(Color(.systemGroupedBackground))
    }

    private func sampleCard(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint ?? .secondary)
                .scaleEffect(reduceMotion ? 1 : 1.04)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(16)
        .adaptiveGlass(
            tint: tint,
            fallbackMaterial: .regularMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title) adaptive surface"))
    }
}

#Preview("Adaptive Glass") {
    AdaptiveGlassDebugFixture()
}

#Preview("Adaptive Glass Dark") {
    AdaptiveGlassDebugFixture()
        .preferredColorScheme(.dark)
}

// SwiftUI does not expose public writable preview keys for these states.
// Keep the underscored overrides isolated to this DEBUG-only fixture.
#Preview("Adaptive Glass Increased Contrast") {
    AdaptiveGlassDebugFixture()
        .environment(\._colorSchemeContrast, ColorSchemeContrast.increased)
}

#Preview("Adaptive Glass Reduce Transparency") {
    AdaptiveGlassDebugFixture()
        .environment(\._accessibilityReduceTransparency, true)
}

#Preview("Adaptive Glass Reduce Motion") {
    AdaptiveGlassDebugFixture()
        .environment(\._accessibilityReduceMotion, true)
}
#endif
