import SwiftUI

private struct ChatTimelineAccessorySurfaceModifier<SurfaceShape: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let fallbackMaterial: Material
    let shape: SurfaceShape

    func body(content: Content) -> some View {
        content
            .background(
                Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.28 : 0.48),
                in: shape
            )
            .adaptiveGlass(
                .regular,
                isInteractive: false,
                fallbackMaterial: fallbackMaterial,
                in: shape
            )
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color(.separator).opacity(colorScheme == .dark ? 0.42 : 0.28), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

private struct ChatTimelineAccessoryInsetSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var backgroundColor: Color {
        if reduceTransparency {
            return Color(.secondarySystemGroupedBackground)
        }

        return Color(.secondarySystemFill).opacity(0.72)
    }

    func body(content: Content) -> some View {
        content
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(.separator).opacity(colorScheme == .dark ? 0.36 : 0.22), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func chatTimelineAccessorySurface(
        fallbackMaterial: Material,
        cornerRadius: CGFloat
    ) -> some View {
        chatTimelineAccessorySurface(
            fallbackMaterial: fallbackMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// Shape-based entry point for accessories that are not a rounded rectangle,
    /// such as the one-line run-status capsule.
    func chatTimelineAccessorySurface(
        fallbackMaterial: Material,
        in shape: some Shape
    ) -> some View {
        modifier(ChatTimelineAccessorySurfaceModifier(
            fallbackMaterial: fallbackMaterial,
            shape: shape
        ))
    }

    func chatTimelineAccessoryInsetSurface() -> some View {
        modifier(ChatTimelineAccessoryInsetSurfaceModifier())
    }
}
