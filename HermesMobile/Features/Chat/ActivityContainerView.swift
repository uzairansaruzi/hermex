import SwiftUI

/// One bordered container holding a turn's activity blocks.
///
/// Thinking and tool blocks used to be free-floating cards stacked with a gap
/// between them, so an expanded turn read as several unrelated objects. They
/// are now sections inside a single surface: the turn is one thing, and the
/// sections are parts of it.
///
/// **Turn order is preserved, not regrouped.** The blocks arrive in the order
/// the turn produced them (think → tools → think → tools), and this view does
/// not reorder or merge them. Collapsing all thinking into one section and all
/// tools into another was tried and rejected: both halves become long enough
/// to be unscannable, and the causal link between a thought and the tools it
/// motivated is lost.
///
/// **Sections keep their own disclosure.** Each block still folds
/// independently, because the alternative — one container-level toggle — means
/// a long thought forces its tool list open too. The container supplies the
/// boundary and the shared background; it does not take over expansion.
struct ActivityContainerView<Content: View>: View {
    /// Vertical gap between sections. Matches the transcript's block spacing so
    /// the container reads as the same rhythm as the rest of the timeline.
    var spacing: CGFloat = 8
    /// True while the turn is still working. The container carries the running
    /// beam because its sections no longer draw their own chrome — without
    /// this, a live turn had no running indicator border anywhere.
    var isActive: Bool = false
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ActivityBeamStyle.storageKey) private var beamStyleRawValue = ActivityBeamStyle.defaultValue.rawValue
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(.horizontal, ActivityBlockChrome.horizontalPadding - 2)
        .padding(.vertical, ActivityBlockChrome.topPadding + 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Deliberately lighter than a block's own surface: the container is a
        // boundary, and matching the blocks' fill would flatten the sections
        // into it instead of holding them.
        .background(ActivityBlockChrome.shape().fill(palette.surface.opacity(0.55)))
        .overlay(ActivityBlockChrome.shape().strokeBorder(palette.tableRule, lineWidth: 1))
        // Secondary containment for disclosure animations: children still
        // drive normal layout, but a transient SwiftUI render layer cannot
        // paint through the Activity header or outside this shared boundary.
        .clipShape(ActivityBlockChrome.shape())
        .borderBeam(
            style: beamStyle,
            shape: ActivityBlockChrome.shape(),
            active: isActive && beamStyle.isVisible
        )
    }

    private var beamStyle: BeamStyle {
        BeamStyle(
            resolved: ActivityBeamStyle.storedValue(beamStyleRawValue).resolved(
                palette: palette,
                colorScheme: colorScheme,
                accent: HeaderLogoColor.color(for: headerLogoColorHex)
            )
        )
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }
}

/// Hairline between two sections inside an `ActivityContainerView`.
///
/// Inset from the container's edges so it reads as a separator *between
/// siblings* rather than a second border cutting the container in half.
struct ActivitySectionDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue

    var body: some View {
        Rectangle()
            .fill(palette.tableRule.opacity(0.7))
            .frame(height: 1)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }
}
