import CoreGraphics

enum HermesSpacing {
    static let s0: CGFloat = 0
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s40: CGFloat = 40
    static let s48: CGFloat = 48
    static let s64: CGFloat = 64

    /// Standard left/right inset owned by app-level screens and surfaces.
    static let screenHorizontal: CGFloat = s16
}

/// The Usage family's fixed geometry that exceeds or is not spacing-scale geometry: the chart's
/// height, the legend swatch diameter, and the remaining-balance bar's height and minimum visible
/// fill. Shared by `UsageChartCard` and `ProviderLimitsCard`.
enum HermesUsageSize {
    static let chartHeight: CGFloat = 180
    static let legendIndicator: CGFloat = 7
    static let balanceBarHeight: CGFloat = 8
    static let minimumBalanceFill: CGFloat = 8
}

enum HermesIconSize {
    static let xs: CGFloat = 12
    static let small: CGFloat = 16
    static let medium: CGFloat = 20
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 32

    /// Semantic pairing of an icon size with the AppFont.Role(s) it sits beside inline.
    enum Typography {
        static let compact = HermesIconSize.xs
        static let standard = HermesIconSize.small
        static let prominent = HermesIconSize.medium
        static let title = HermesIconSize.large
        static let feature = HermesIconSize.extraLarge
    }

    /// Semantic pairing of an icon size with the Avatar diameter it sits inside: 32pt avatar → 20pt
    /// icon, 40pt avatar → 24pt icon, 48pt avatar → 32pt icon.
    enum Avatar {
        static let small = HermesIconSize.medium
        static let medium = HermesIconSize.large
        static let large = HermesIconSize.extraLarge
    }
}

/// Named Avatar diameters shared by production Avatar compositions and the design-system catalog.
enum HermesAvatarSize: CGFloat, CaseIterable {
    case small = 32
    case medium = 40
    case large = 48
}

/// The Attachment family's fixed geometry: file/image tile frames, the composer's icon-badge panel,
/// and its text and remove-control insets. Shared by `MessageBubbleView`'s message grid and
/// `ChatComposerAttachmentStripView`'s pending-attachment strip.
enum HermesAttachmentSize {
    static let compactPreview: CGFloat = 30
    static let messageGridCell: CGFloat = 118
    static let composerImage: CGFloat = 96
    static let composerImageAccessibility: CGFloat = 108
    static let fileIconPanelWidth: CGFloat = 58
    static let fileIconPanelHeight: CGFloat = 68
    static let fileIconPanelWidthAccessibility: CGFloat = 76
    static let fileIconPanelHeightAccessibility: CGFloat = 84
    static let composerFileTextWidth: CGFloat = 128
    static let composerFileTextWidthAccessibility: CGFloat = 160
    static let composerFileTileWidth: CGFloat = 222
    static let composerFileTileWidthAccessibility: CGFloat = 280
    static let composerFileTileMinHeight: CGFloat = 92
    static let composerFileTileMinHeightAccessibility: CGFloat = 112
    static let composerStripHeight: CGFloat = 108
    static let composerStripHeightAccessibility: CGFloat = 132
    static let messageFileTextInset: CGFloat = 18
    static let removeControl: CGFloat = 24
    static let removeOverlap: CGFloat = 6
    static let accessibilityVerticalPadding: CGFloat = 10
}
