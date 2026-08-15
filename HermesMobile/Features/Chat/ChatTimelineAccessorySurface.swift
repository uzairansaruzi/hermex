import SwiftUI

private struct ChatTimelineAccessorySurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue

    let fallbackMaterial: Material
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                palette.surface.opacity(colorScheme == .dark ? 0.52 : 0.72),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .adaptiveGlass(
                .regular,
                isInteractive: false,
                fallbackMaterial: fallbackMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }
}

private struct ChatTimelineAccessoryInsetSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue

    private var backgroundColor: Color {
        if reduceTransparency {
            return palette.surfaceInset
        }

        return palette.surfaceInset.opacity(0.72)
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }

    func body(content: Content) -> some View {
        content
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }
}

extension View {
    func chatTimelineAccessorySurface(
        fallbackMaterial: Material,
        cornerRadius: CGFloat
    ) -> some View {
        modifier(ChatTimelineAccessorySurfaceModifier(
            fallbackMaterial: fallbackMaterial,
            cornerRadius: cornerRadius
        ))
    }

    func chatTimelineAccessoryInsetSurface() -> some View {
        modifier(ChatTimelineAccessoryInsetSurfaceModifier())
    }
}
