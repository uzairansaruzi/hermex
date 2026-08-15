import SwiftUI

/// Compact one-line summary of a finished agent turn: a small stack of
/// static orb glyphs (one per distinct activity kind, in order of first
/// appearance) plus a "5 steps · 40s" label. Tapping expands the rail
/// with a spring to reveal the full step list as completed activity
/// capsules; tapping again collapses it.
///
/// Gallery prototype only — not wired into the live transcript.
struct ActivityHistoryRailView: View {
    /// One finished activity step in the turn, in transcript order.
    struct Step: Identifiable {
        let id = UUID()
        let orbState: ThinkingOrbState
        let completedLabel: String
        let icon: String
    }

    let steps: [Step]
    let totalDuration: TimeInterval?
    /// Variant (b): appends "Thinking → Ran tests" style first/last step
    /// names after the step count.
    var showsEndpoints: Bool = false

    @State private var isExpanded = false

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue

    // Dotted orbs need room to read as distinct marks: heavy overlap at small
    // sizes smears them into a single speckle. Three larger, barely-overlapping
    // glyphs stay legible while still reading as a stack.
    private static let orbGlyphSize: CGFloat = 22
    private static let orbOverlap: CGFloat = 2
    private static let maxOrbGlyphs = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    orbStack

                    Text(summaryText)
                        .font(AppFont.subheadline())
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(isExpanded ? [] : [])
            .accessibilityHint(
                isExpanded
                    ? String(localized: "Collapses the step list")
                    : String(localized: "Expands the step list")
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        ActivityCapsuleView(
                            orbState: step.orbState,
                            label: step.completedLabel,
                            isActive: false,
                            completedIcon: step.icon,
                            completedLabel: step.completedLabel
                        )
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    )
                )
            }
        }
    }

    // MARK: - Orb stack

    /// Up to `maxOrbGlyphs` distinct step kinds, in order of first appearance,
    /// overlapping like an avatar stack. Orbs are drawn paused so the rail
    /// stays visually quiet in history.
    private var orbStack: some View {
        let kinds = distinctOrbStates
        return HStack(spacing: -Self.orbOverlap) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, state in
                ThinkingOrbView(
                    state: state,
                    size: Self.orbGlyphSize,
                    color: .secondary,
                    paused: true
                )
                .zIndex(Double(kinds.count - index))
            }
        }
    }

    private var distinctOrbStates: [ThinkingOrbState] {
        var seen: [ThinkingOrbState] = []
        for step in steps where !seen.contains(step.orbState) {
            seen.append(step.orbState)
            if seen.count == Self.maxOrbGlyphs { break }
        }
        return seen
    }

    // MARK: - Summary text

    private var summaryText: String {
        var parts: [String] = [stepCountText]
        if let duration = totalDuration, duration > 0 {
            parts.append(Self.durationText(duration))
        }
        var summary = parts.joined(separator: " · ")
        if showsEndpoints, let endpoints = endpointsText {
            summary += " · \(endpoints)"
        }
        return summary
    }

    private var stepCountText: String {
        steps.count == 1
            ? String(localized: "1 step")
            : String(localized: "\(steps.count) steps")
    }

    /// "Thinking → Ran tests" style first/last labels for variant (b).
    private var endpointsText: String? {
        guard let first = steps.first else { return nil }
        guard steps.count > 1, let last = steps.last else {
            return first.completedLabel
        }
        return "\(first.completedLabel) → \(last.completedLabel)"
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 {
            return String(localized: "\(seconds)s")
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0
            ? String(localized: "\(minutes)m")
            : String(localized: "\(minutes)m \(remainder)s")
    }

    private var accessibilitySummary: String {
        String(localized: "Turn activity, \(summaryText)")
    }

    // MARK: - Palette

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }
}

#if DEBUG
#Preview("History rail") {
    VStack(alignment: .leading, spacing: 24) {
        ActivityHistoryRailView(
            steps: [
                .init(orbState: .thinking, completedLabel: "Thought for 12s", icon: "brain"),
                .init(orbState: .searching, completedLabel: "Read 3 files", icon: "doc.text.magnifyingglass"),
                .init(orbState: .writing, completedLabel: "Wrote patch", icon: "pencil"),
                .init(orbState: .working, completedLabel: "Ran tests", icon: "checkmark.circle.fill")
            ],
            totalDuration: 40
        )

        ActivityHistoryRailView(
            steps: [
                .init(orbState: .thinking, completedLabel: "Thinking", icon: "brain"),
                .init(orbState: .working, completedLabel: "Ran 3 tools", icon: "hammer")
            ],
            totalDuration: 21,
            showsEndpoints: true
        )
    }
    .padding(24)
}
#endif
