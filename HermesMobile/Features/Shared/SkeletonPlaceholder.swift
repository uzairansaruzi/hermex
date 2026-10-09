import SwiftUI

/// Static loading geometry for content that has not arrived yet. Text keeps using
/// `.skeletonPlaceholder()` when its final layout is already known; non-text placeholders use these
/// explicit shapes instead of inventing a one-off filled view.
struct Skeleton: View {
    enum Shape {
        case textLine(maxWidth: CGFloat, height: CGFloat = HermesSpacing.s12)
        case block(height: CGFloat)
        case circle(diameter: CGFloat)
        case roundedRectangle(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = HermesRadius.r12)
    }

    let shape: Shape

    var body: some View {
        switch shape {
        case .textLine(let maxWidth, let height):
            RoundedRectangle(cornerRadius: HermesRadius.r4, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(maxWidth: maxWidth, minHeight: height, maxHeight: height)
        case .block(let height):
            RoundedRectangle(cornerRadius: HermesRadius.r8, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        case .circle(let diameter):
            Circle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: diameter, height: diameter)
        case .roundedRectangle(let width, let height, let cornerRadius):
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: width, height: height)
        }
    }
}

extension View {
    /// The shared static skeleton treatment every "content isn't here yet" placeholder in Hermex
    /// should reach for instead of calling `.redacted(reason: .placeholder)` directly — one name
    /// for the same platform behavior, so a future change to the shared treatment has one call
    /// site to update. Intentionally motion-free; pair with `.skeletonAnnouncement(label:value:)`
    /// to say so once per group of rows instead of once per row.
    func skeletonPlaceholder() -> some View {
        redacted(reason: .placeholder)
    }

    /// Groups one or more `.skeletonPlaceholder()` rows behind a single VoiceOver announcement and,
    /// by default, blocks interaction with the placeholder — the pattern
    /// `ChatTranscriptLoadingSkeletonView` and `ProviderLimitsPlaceholderCard` each built ad hoc
    /// before this extraction.
    func skeletonAnnouncement(label: Text, value: Text? = nil, disablesHitTesting: Bool = true) -> some View {
        modifier(SkeletonAnnouncementModifier(label: label, value: value, disablesHitTesting: disablesHitTesting))
    }
}

private struct SkeletonAnnouncementModifier: ViewModifier {
    let label: Text
    let value: Text?
    let disablesHitTesting: Bool

    func body(content: Content) -> some View {
        Group {
            if let value {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityValue(value)
            } else {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
            }
        }
        .allowsHitTesting(!disablesHitTesting)
    }
}
