import SwiftUI
import UIKit

enum AppFont {
    static func body(weight: Font.Weight? = nil) -> Font {
        system(.body, weight: weight)
    }

    static func subheadline(weight: Font.Weight? = nil) -> Font {
        system(.subheadline, weight: weight)
    }

    static func footnote(weight: Font.Weight? = nil) -> Font {
        system(.footnote, weight: weight)
    }

    static func caption(weight: Font.Weight? = nil) -> Font {
        system(.caption, weight: weight)
    }

    static func caption2(weight: Font.Weight? = nil) -> Font {
        system(.caption2, weight: weight)
    }

    static func headline(weight: Font.Weight? = nil) -> Font {
        system(.headline, weight: weight)
    }

    static func title(weight: Font.Weight? = nil) -> Font {
        system(.title, weight: weight)
    }

    static func title3(weight: Font.Weight? = nil) -> Font {
        system(.title3, weight: weight)
    }

    static func title2(weight: Font.Weight? = nil) -> Font {
        system(.title2, weight: weight ?? .bold)
    }

    static func mono(style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> Font {
        system(style, design: .monospaced, weight: weight)
    }

    private static func system(
        _ style: Font.TextStyle,
        design: Font.Design = .default,
        weight: Font.Weight? = nil
    ) -> Font {
        .system(style, design: design, weight: weight)
    }
}

extension AppFont {
    enum Role: CaseIterable {
        case caption, captionSemibold, footnote, caption2, mono12
        case subheadline, subheadlineSemibold, mono14
        case body, label, headline, headlineSemibold, title3, title2, title

        var baseSize: CGFloat {
            switch self {
            case .caption, .captionSemibold, .footnote, .caption2, .mono12: return 12
            case .subheadline, .subheadlineSemibold, .mono14: return 14
            case .body, .label: return 16
            case .headline, .headlineSemibold: return 18
            case .title3: return 20
            case .title2: return 22
            case .title: return 28
            }
        }

        var swiftUIAnchor: Font.TextStyle {
            switch self {
            case .caption, .captionSemibold, .footnote, .caption2, .mono12: return .caption
            case .subheadline, .subheadlineSemibold, .mono14: return .subheadline
            case .body, .label: return .body
            case .headline, .headlineSemibold: return .headline
            case .title3: return .title3
            case .title2: return .title2
            case .title: return .title
            }
        }

        var uiKitAnchor: UIFont.TextStyle {
            switch self {
            case .caption, .captionSemibold, .footnote, .caption2, .mono12: return .caption1
            case .subheadline, .subheadlineSemibold, .mono14: return .subheadline
            case .body, .label: return .body
            case .headline, .headlineSemibold: return .headline
            case .title3: return .title3
            case .title2: return .title2
            case .title: return .title1
            }
        }

        var defaultWeight: Font.Weight {
            switch self {
            case .caption, .footnote, .caption2, .mono12, .subheadline, .mono14, .body, .headline:
                return .regular
            case .captionSemibold, .subheadlineSemibold, .label, .headlineSemibold:
                return .semibold
            case .title3, .title2, .title: return .bold
            }
        }

        var defaultUIKitWeight: UIFont.Weight {
            switch self {
            case .caption, .footnote, .caption2, .mono12, .subheadline, .mono14, .body, .headline:
                return .regular
            case .captionSemibold, .subheadlineSemibold, .label, .headlineSemibold:
                return .semibold
            case .title3, .title2, .title: return .bold
            }
        }

        var defaultDesign: Font.Design {
            switch self {
            case .mono12, .mono14: return .monospaced
            default: return .default
            }
        }
    }
}

extension AppFont {
    static func scaledFont(role: Role, traitCollection: UITraitCollection = .current) -> UIFont {
        let base = UIFont.systemFont(ofSize: role.baseSize, weight: role.defaultUIKitWeight)
        return UIFontMetrics(forTextStyle: role.uiKitAnchor).scaledFont(for: base, compatibleWith: traitCollection)
    }
}

private struct AppFontModifier: ViewModifier {
    let role: AppFont.Role
    @ScaledMetric private var scaledSize: CGFloat

    init(role: AppFont.Role) {
        self.role = role
        _scaledSize = ScaledMetric(wrappedValue: role.baseSize, relativeTo: role.swiftUIAnchor)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaledSize, weight: role.defaultWeight, design: role.defaultDesign))
    }
}

extension View {
    func appFont(_ role: AppFont.Role) -> some View {
        modifier(AppFontModifier(role: role))
    }
}

extension DynamicTypeSize {
    /// Explicit, exhaustive map from SwiftUI's `DynamicTypeSize` to UIKit's
    /// `UIContentSizeCategory`, so a caller needing a `UIFontMetrics`/
    /// `UITraitCollection`-based scaling result (`HermexPopoverMenuContentSizing.
    /// estimatedRowHeight`, for instance) can drive it off a caller-supplied
    /// `DynamicTypeSize` environment value instead of the ambient (and, for
    /// SwiftUI's own `\.dynamicTypeSize` environment, unreliable)
    /// `UITraitCollection.current`. Every case is named on purpose — a future
    /// case Apple adds must be mapped here deliberately, never silently
    /// absorbed by a catch-all default.
    var appFontContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default:
            // A DynamicTypeSize case newer than this SDK build. SwiftUI has
            // only ever grown DynamicTypeSize at the top of the accessibility
            // range, so clamping to the largest known category is the
            // conservative choice (never under-scales), not a silent no-op —
            // this branch is a real, reachable, intentionally-visible gap:
            // add the new case above the moment this SDK is updated.
            return .accessibilityExtraExtraExtraLarge
        }
    }
}

extension Text {
    /// `Text`-returning sibling of `View.appFont(_:)`, needed because
    /// concatenated fragments (`text1 + text2`) require the `+` operator's
    /// `Text`-typed operands and reject `some View`.
    ///
    /// Takes `dynamicTypeSize` explicitly rather than reading
    /// `\.dynamicTypeSize` from the environment: `@ScaledMetric` (the View
    /// modifier's mechanism) only works as a stored property of a `View`,
    /// injected from that view's own environment, and a free function
    /// returning `Text` has no such storage to attach it to. Reading
    /// `UITraitCollection.current` instead does not work either — it does
    /// not reflect SwiftUI's `.environment(\.dynamicTypeSize, ...)` overrides
    /// (proven by `AppFontDynamicTypeRenderTests`, which measured identical
    /// rendered widths at `.large` and `.accessibility3` under that
    /// approach). No normal production caller composes this overload yet;
    /// `AppFontModifierBuildProofTests` and `AppFontDynamicTypeRenderTests`
    /// exercise its explicit-size contract.
    func appFont(_ role: AppFont.Role, dynamicTypeSize: DynamicTypeSize) -> Text {
        let traitCollection = UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.appFontContentSizeCategory)
        let scaledSize = AppFont.scaledFont(role: role, traitCollection: traitCollection).pointSize
        return font(.system(size: scaledSize, weight: role.defaultWeight, design: role.defaultDesign))
    }
}
