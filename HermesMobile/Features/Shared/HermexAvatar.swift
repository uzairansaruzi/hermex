import SwiftUI

/// A circular system-image identity badge, sized to the shared `HermesAvatarSize` diameters and
/// carrying the accepted `HermesIconSize.Avatar` icon at the approved pairing (32→20, 40→24,
/// 48→32). For a fallback identity — no photo exists — not a replacement for a caller's own
/// avatar image.
struct HermexAvatar: View {
    let systemImage: String
    var size: HermesAvatarSize = .medium
    var tint: Color = .secondary
    var background: Color = Color(.secondarySystemBackground)
    var isDecorative = true

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: Self.iconSize(for: size), weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size.rawValue, height: size.rawValue)
            .background(background, in: Circle())
            .accessibilityHidden(isDecorative)
    }

    static func iconSize(for size: HermesAvatarSize) -> CGFloat {
        switch size {
        case .small: HermesIconSize.Avatar.small
        case .medium: HermesIconSize.Avatar.medium
        case .large: HermesIconSize.Avatar.large
        }
    }
}
