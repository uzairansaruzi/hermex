import SwiftUI
import HermexCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum HermexUIColors {
    static let gold = Color(red: 1.0, green: 0.843, blue: 0.0)
    static let darkBackground = Color.black
#if canImport(UIKit)
    static let systemBackground = Color(uiColor: .systemBackground)
    static let secondarySystemBackground = Color(uiColor: .secondarySystemBackground)
    static let separator = Color(uiColor: .separator)
#elseif canImport(AppKit)
    static let systemBackground = Color(nsColor: .windowBackgroundColor)
    static let secondarySystemBackground = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
#else
    static let systemBackground = Color.black
    static let secondarySystemBackground = Color.gray.opacity(0.22)
    static let separator = Color.primary.opacity(0.18)
#endif
}

public struct HermexScreenTitle: View {
    private let title: String
    private let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline.weight(.semibold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct HermexLogoMark: View {
    public init() {}

    public var body: some View {
        ZStack {
            hermexLogoImage("hermes-fill-mask")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(HermexUIColors.gold)
            hermexLogoImage("hermes-shading-overlay")
                .resizable()
                .scaledToFit()
            hermexLogoImage("hermes-highlight")
                .resizable()
                .scaledToFit()
            hermexLogoImage("hermes-outline-shadow")
                .resizable()
                .scaledToFit()
        }
        .aspectRatio(HermexLayoutContract.hermexLogoAspectRatio, contentMode: .fit)
        .frame(width: HermexLayoutContract.sessionListLogoWidth)
            .accessibilityLabel("HERMEX")
    }

    private func hermexLogoImage(_ name: String) -> Image {
#if SWIFT_PACKAGE
        return Image(name, bundle: .module)
#else
        return Image(name)
#endif
    }
}

public struct HermexGlassPanel<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = HermexLayoutContract.composerCornerRadiusCollapsed, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
            }
    }
}

public struct HermexCircleIconButton: View {
    private let systemImage: String
    private let accessibilityLabel: String
    private let size: CGFloat
    private let isFilled: Bool
    private let action: () -> Void

    public init(
        systemImage: String,
        accessibilityLabel: String,
        size: CGFloat = HermexLayoutContract.topChromeCircleSize,
        isFilled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.isFilled = isFilled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.34, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(isFilled ? Color.black : Color.primary)
                .background(isFilled ? HermexUIColors.gold : HermexUIColors.secondarySystemBackground.opacity(0.72), in: Circle())
                .overlay {
                    Circle().stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

public struct HermexIconCluster<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: HermexLayoutContract.topChromeClusterSpacing) {
            content
        }
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.13), lineWidth: 0.6)
        }
        .clipShape(Capsule())
    }
}

public struct HermexPillLabel: View {
    private let title: String
    private let systemImage: String?

    public init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, HermexLayoutContract.composerSecondaryBarHorizontalPadding)
        .padding(.vertical, HermexLayoutContract.composerSecondaryBarVerticalPadding)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
        }
    }
}
