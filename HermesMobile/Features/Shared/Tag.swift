import SwiftUI

/// A display-only tinted-capsule chrome modeled on the separate capsules production draws for
/// Sessions' Cached/Read-only/source badges, Tasks' status badge, Workspace/Git's change-kind chip,
/// and Settings' profile/connection pills. Each of those keeps its own padding and type; none of
/// them uses Tag. A caller would keep its own type name and domain mapping (label, color, whether
/// it's decorative) — Tag supplies only the capsule's text style, padding, fill, and shape.
///
/// Tag is always display-only: it exposes no action closure and no gesture, so it cannot become
/// tappable by accident. A tappable file or resource reference is an Inline Reference Link, not a
/// Tag styled to look interactive.
struct Tag: View {
    /// The display-only padding steps.
    enum Size: Equatable {
        /// The compact status-chip step (8/2 padding).
        case compact
        /// The default step (8/4 padding).
        case regular
        /// The largest step (12/8 padding).
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
    /// Hides the tag from VoiceOver, for a caller whose surrounding row already announces the same
    /// fact in its own accessibility label (as Sessions' badges, which Tag does not draw, are).
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
