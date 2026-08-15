import SwiftUI

struct ChatActiveRunStatusView: View {
    let presentation: ChatActiveRunStatusPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            progressIndicator

            Text(presentation.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.88)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            ChatPalette.appChrome(colorScheme: colorScheme).surface.opacity(colorScheme == .dark ? 0.28 : 0.48),
            in: Capsule(style: .continuous)
        )
        .adaptiveGlass(
            .regular,
            isInteractive: false,
            fallbackMaterial: .regularMaterial,
            in: Capsule(style: .continuous)
        )
        .clipShape(Capsule(style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if reduceMotion {
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        }
    }
}

#Preview("Active Run Status") {
    VStack(spacing: 12) {
        ChatActiveRunStatusView(
            presentation: ChatActiveRunStatusPresentation(kind: .active)
        )

        ChatActiveRunStatusView(
            presentation: ChatActiveRunStatusPresentation(kind: .reconnecting)
        )
    }
    .padding()
    .appSurfaceBackground(.canvas)
}
