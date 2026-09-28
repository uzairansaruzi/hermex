import SwiftUI

/// Run-status pill above the composer, shown while the transcript is scrolled
/// away from its bottom. It never animates: a static dot marks it, and an
/// active run's elapsed time ticks once a second inside a `TimelineView` that
/// wraps only the label, so the tick re-renders nothing else and stops when
/// the pill hides.
struct ChatActiveRunStatusView: View {
    let presentation: ChatActiveRunStatusPresentation

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            ChatRunStatusDot()

            if let startedAt = presentation.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    label(now: context.date)
                }
            } else {
                label(now: .now)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .chatTimelineAccessorySurface(
            fallbackMaterial: .regularMaterial,
            in: Capsule(style: .continuous)
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func label(now: Date) -> some View {
        Text(presentation.label(now: now))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            .minimumScaleFactor(0.88)
            .accessibilityLabel(presentation.accessibilityLabel(now: now))
    }
}

/// Static status dot for run-status capsules: always in the pill, and in the
/// transcript's recovery chip under Reduce Motion. It stands in for a spinner
/// that would repaint for as long as the status shows.
struct ChatRunStatusDot: View {
    var body: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

private struct ChatActiveRunStatusPreviewStack: View {
    private let startedAt = Date.now.addingTimeInterval(-133)

    var body: some View {
        VStack(spacing: 12) {
            ChatActiveRunStatusView(
                presentation: ChatActiveRunStatusPresentation(kind: .active, startedAt: startedAt)
            )

            ChatActiveRunStatusView(
                presentation: ChatActiveRunStatusPresentation(kind: .active)
            )

            ChatActiveRunStatusView(
                presentation: ChatActiveRunStatusPresentation(kind: .reconnecting)
            )
        }
        .padding()
        .background(Color(.systemBackground))
    }
}

#Preview("Active Run Status") {
    ChatActiveRunStatusPreviewStack()
}

// The pill wraps to two or three lines here; ChatView measures its height for
// the transcript spacer instead of assuming one line.
#Preview("Active Run Status · AX5") {
    ChatActiveRunStatusPreviewStack()
        .environment(\.dynamicTypeSize, .accessibility5)
}
