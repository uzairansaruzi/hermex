import SwiftUI

/// The shared display-only tinted-capsule chrome behind Sessions' Cached/Read-only/source badges,
/// Tasks' status badge, Workspace/Git's change-kind chip, and Settings' profile/connection pills.
/// Each caller keeps its own type name and domain mapping (label, color, whether it's decorative) —
/// this only unifies the capsule's text style, padding, fill, and shape, so every migrated site
/// renders pixel-identical to what shipped before this extraction.
///
/// Tag is always display-only: it exposes no action closure and no gesture, so it cannot become
/// tappable by accident. A tappable file or resource reference is an Inline Reference Link, not a
/// Tag styled to look interactive.
struct Tag: View {
    /// The retained display-only sizes used by production call sites.
    enum Size: Equatable {
        /// Sessions and Workspace/Git's compact status chips.
        case compact
        /// Tasks' status badge and Settings' profile "Selected"/"Server Default" badge.
        case regular
        /// Settings' connection-state pill — the largest instance.
        case prominent

        var horizontalPadding: CGFloat {
            switch self {
            case .compact, .regular:
                HermesSpacing.s8
            case .prominent:
                HermesSpacing.s12
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .compact:
                HermesSpacing.s2
            case .regular:
                HermesSpacing.s4
            case .prominent:
                HermesSpacing.s8
            }
        }
    }

    let label: String
    let foreground: Color
    let fill: Color
    var icon: String?
    var size: Size = .regular
    var font: AppFont.Role = .captionSemibold
    var minimumScaleFactor: CGFloat = 1
    /// Hides the tag from VoiceOver — Sessions' badges are decorative because the row around
    /// them already announces the same fact in its own accessibility label.
    var isDecorative: Bool = false

    init(
        label: String,
        foreground: Color,
        fill: Color,
        icon: String? = nil,
        size: Size = .regular,
        font: AppFont.Role = .captionSemibold,
        minimumScaleFactor: CGFloat = 1,
        isDecorative: Bool = false
    ) {
        self.label = label
        self.foreground = foreground
        self.fill = fill
        self.icon = icon
        self.size = size
        self.font = font
        self.minimumScaleFactor = minimumScaleFactor
        self.isDecorative = isDecorative
    }

    /// The common case: foreground and fill both derive from one `tint` (fill at `fillOpacity`).
    init(
        label: String,
        tint: Color,
        fillOpacity: Double = 0.12,
        icon: String? = nil,
        size: Size = .regular,
        font: AppFont.Role = .captionSemibold,
        minimumScaleFactor: CGFloat = 1,
        isDecorative: Bool = false
    ) {
        self.init(
            label: label,
            foreground: tint,
            fill: tint.opacity(fillOpacity),
            icon: icon,
            size: size,
            font: font,
            minimumScaleFactor: minimumScaleFactor,
            isDecorative: isDecorative
        )
    }

    var body: some View {
        HStack(spacing: HermesSpacing.s4) {
            if let icon {
                Image(systemName: icon)
                    .appFont(font)
                    .accessibilityHidden(true)
            }

            Text(label)
                .appFont(font)
                .lineLimit(1)
                .minimumScaleFactor(minimumScaleFactor)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .background(fill, in: Capsule(style: .continuous))
        .accessibilityHidden(isDecorative)
    }
}
