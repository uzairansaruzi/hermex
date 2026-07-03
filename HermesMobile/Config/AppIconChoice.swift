import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AppIconChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case disco
    case monochromeLight
    case monochromeDark
    case gradientLight
    case gradientDark

    static let lightAlternateIconName = "AppIconLight"
    static let darkAlternateIconName = "AppIconDark"
    static let discoAlternateIconName = "AppIconDisco"
    static let monochromeLightAlternateIconName = "AppIconMonochromeLight"
    static let monochromeDarkAlternateIconName = "AppIconMonochromeDark"
    static let gradientLightAlternateIconName = "AppIconGradientLight"
    static let gradientDarkAlternateIconName = "AppIconGradientDark"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            String(localized: "System")
        case .light:
            String(localized: "Zora Light")
        case .dark:
            String(localized: "Zora Ember")
        case .disco:
            String(localized: "Zora Pulse")
        case .monochromeLight:
            String(localized: "Zora Monochrome Light")
        case .monochromeDark:
            String(localized: "Zora Monochrome Dark")
        case .gradientLight:
            String(localized: "Zora Gradient Light")
        case .gradientDark:
            String(localized: "Zora Gradient Dark")
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            String(localized: "Adapts between the Zora light and ember icons")
        case .light:
            String(localized: "Warm coral Samantha-style icon")
        case .dark:
            String(localized: "Deep ember Samantha-style icon")
        case .disco:
            String(localized: "Higher-energy Zora pulse icon")
        case .monochromeLight:
            String(localized: "Quiet monochrome Zora light icon")
        case .monochromeDark:
            String(localized: "Quiet monochrome Zora ember icon")
        case .gradientLight:
            String(localized: "Saturated Zora light gradient")
        case .gradientDark:
            String(localized: "Saturated Zora ember gradient")
        }
    }

    var alternateIconName: String? {
        switch self {
        case .system:
            nil
        case .light:
            Self.lightAlternateIconName
        case .dark:
            Self.darkAlternateIconName
        case .disco:
            Self.discoAlternateIconName
        case .monochromeLight:
            Self.monochromeLightAlternateIconName
        case .monochromeDark:
            Self.monochromeDarkAlternateIconName
        case .gradientLight:
            Self.gradientLightAlternateIconName
        case .gradientDark:
            Self.gradientDarkAlternateIconName
        }
    }

    var previewImageName: String? {
        switch self {
        case .system:
            nil
        case .light:
            "AppIconLightPreview"
        case .dark:
            "AppIconDarkPreview"
        case .disco:
            "AppIconDiscoPreview"
        case .monochromeLight:
            "AppIconMonochromeLightPreview"
        case .monochromeDark:
            "AppIconMonochromeDarkPreview"
        case .gradientLight:
            "AppIconGradientLightPreview"
        case .gradientDark:
            "AppIconGradientDarkPreview"
        }
    }

    static func resolved(from alternateIconName: String?) -> AppIconChoice {
        switch alternateIconName {
        case Self.lightAlternateIconName:
            .light
        case Self.darkAlternateIconName:
            .dark
        case Self.discoAlternateIconName:
            .disco
        case Self.monochromeLightAlternateIconName:
            .monochromeLight
        case Self.monochromeDarkAlternateIconName:
            .monochromeDark
        case Self.gradientLightAlternateIconName:
            .gradientLight
        case Self.gradientDarkAlternateIconName:
            .gradientDark
        default:
            .system
        }
    }

    #if canImport(UIKit)
    @MainActor
    static var current: AppIconChoice {
        resolved(from: UIApplication.shared.alternateIconName)
    }
    #endif
}
