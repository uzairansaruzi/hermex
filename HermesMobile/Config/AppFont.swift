import MarkdownUI
import SwiftUI
import UIKit

enum AppFontFamily: String, CaseIterable, Identifiable {
    case sanFrancisco
    case sfRounded
    case dmSans
    case avenirNext
    case georgia
    case lora
    case sfMono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sanFrancisco: "San Francisco"
        case .sfRounded: "SF Rounded"
        case .dmSans: "DM Sans"
        case .avenirNext: "Avenir Next"
        case .georgia: "Georgia"
        case .lora: "Lora"
        case .sfMono: "SF Mono"
        }
    }

    fileprivate var customName: String? {
        switch self {
        case .sanFrancisco, .sfRounded, .sfMono: nil
        case .dmSans: "DM Sans"
        case .avenirNext: "Avenir Next"
        case .georgia: "Georgia"
        case .lora: "Lora"
        }
    }

    fileprivate var design: Font.Design? {
        switch self {
        case .sfRounded: .rounded
        case .sfMono: .monospaced
        default: nil
        }
    }
}

@Observable final class AppFontSettings {
    static let storageKey = "appearance.fontFamily"
    static let shared = AppFontSettings()

    var family: AppFontFamily {
        didSet { UserDefaults.standard.set(family.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        family = AppFontFamily(rawValue: UserDefaults.standard.string(forKey: Self.storageKey) ?? "") ?? .sanFrancisco
    }
}

enum AppFont {
    static func largeTitle(weight: Font.Weight? = nil) -> Font { font(.largeTitle, weight: weight) }
    static func title(weight: Font.Weight? = nil) -> Font { font(.title, weight: weight) }
    static func title2(weight: Font.Weight? = nil) -> Font { font(.title2, weight: weight) }
    static func title3(weight: Font.Weight? = nil) -> Font { font(.title3, weight: weight) }
    static func headline(weight: Font.Weight? = nil) -> Font { font(.headline, weight: weight) }
    static func body(weight: Font.Weight? = nil) -> Font { font(.body, weight: weight) }
    static func callout(weight: Font.Weight? = nil) -> Font { font(.callout, weight: weight) }
    static func subheadline(weight: Font.Weight? = nil) -> Font { font(.subheadline, weight: weight) }
    static func footnote(weight: Font.Weight? = nil) -> Font { font(.footnote, weight: weight) }
    static func caption(weight: Font.Weight? = nil) -> Font { font(.caption, weight: weight) }
    static func caption2(weight: Font.Weight? = nil) -> Font { font(.caption2, weight: weight) }

    static func fixed(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let family = AppFontSettings.shared.family
        guard let name = family.customName else {
            return .system(size: size, weight: weight, design: family.design)
        }
        let custom = Font.custom(name, fixedSize: size)
        return weight.map(custom.weight) ?? custom
    }

    static func mono(style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    static func code(style: Font.TextStyle, customSize: Double?) -> Font {
        customSize.map { .system(size: $0, design: .monospaced) } ?? mono(style: style)
    }

    static var root: Font? {
        AppFontSettings.shared.family == .sanFrancisco ? nil : body()
    }

    static var sectionFooter: Font? {
        AppFontSettings.shared.family == .sanFrancisco ? nil : footnote()
    }

    static var markdownFamily: FontProperties.Family {
        let family = AppFontSettings.shared.family
        return family.customName.map(FontProperties.Family.custom) ?? .system(family.design ?? .default)
    }

    private static func font(_ style: Font.TextStyle, weight: Font.Weight?) -> Font {
        let family = AppFontSettings.shared.family
        guard let name = family.customName else {
            return .system(style, design: family.design, weight: weight)
        }
        let custom = Font.custom(name, size: standardSize(of: style), relativeTo: style)
        return (weight ?? (style == .headline ? .semibold : nil)).map(custom.weight) ?? custom
    }

    private static func standardSize(of style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}

extension View {
    func appRootFont() -> some View { modifier(AppRootFont()) }
}

private struct AppRootFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .font(AppFont.root)
            .onChange(of: AppFontSettings.shared.family) { AppBarFont.apply() }
            .onChange(of: dynamicTypeSize) { AppBarFont.apply() }
    }
}

struct AppSectionFooterFont: ViewModifier {
    func body(content: Content) -> some View {
        content.font(AppFont.sectionFooter)
    }
}

extension Section where Parent: View, Content: View {
    init<F: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder appFooter: () -> F
    ) where Parent == EmptyView, Footer == ModifiedContent<F, AppSectionFooterFont> {
        self.init(content: content, footer: { appFooter().modifier(AppSectionFooterFont()) })
    }

    init<F: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Parent,
        @ViewBuilder appFooter: () -> F
    ) where Footer == ModifiedContent<F, AppSectionFooterFont> {
        self.init(content: content, header: header, footer: { appFooter().modifier(AppSectionFooterFont()) })
    }
}

@MainActor enum AppBarFont {
    static func applyAtLaunch() {
        let size = AppTextSize.size(atStop: UserDefaults.standard.integer(forKey: AppTextSize.storageKey))
        setProxy(traits: size.map { UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory($0)) })
    }

    static func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let (title, largeTitle) = setProxy(traits: scene.traitCollection)
            for window in scene.windows {
                setFonts(title: title, largeTitle: largeTitle, in: window)
            }
        }
    }

    @discardableResult
    private static func setProxy(
        traits: UITraitCollection?
    ) -> (title: [NSAttributedString.Key: Any]?, largeTitle: [NSAttributedString.Key: Any]?) {
        var title: [NSAttributedString.Key: Any]?
        var largeTitle: [NSAttributedString.Key: Any]?
        if AppFontSettings.shared.family != .sanFrancisco {
            title = [.font: UIFont.app(forTextStyle: .headline, weight: .semibold, compatibleWith: traits)]
            largeTitle = [.font: UIFont.app(forTextStyle: .largeTitle, weight: .bold, compatibleWith: traits)]
        }
        let proxy = UINavigationBar.appearance()
        proxy.titleTextAttributes = title
        proxy.largeTitleTextAttributes = largeTitle
        return (title, largeTitle)
    }

    private static func setFonts(
        title: [NSAttributedString.Key: Any]?,
        largeTitle: [NSAttributedString.Key: Any]?,
        in view: UIView
    ) {
        if let bar = view as? UINavigationBar {
            bar.titleTextAttributes = title
            bar.largeTitleTextAttributes = largeTitle
            return
        }
        for subview in view.subviews {
            setFonts(title: title, largeTitle: largeTitle, in: subview)
        }
    }
}

extension UIFont {
    static func app(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let family = AppFontSettings.shared.family
        if let name = family.customName {
            let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight]
            return UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: name, .traits: traits]), size: size)
        }
        let system = UIFont.systemFont(ofSize: size, weight: weight)
        let design: UIFontDescriptor.SystemDesign? = switch family {
        case .sfRounded: .rounded
        case .sfMono: .monospaced
        default: nil
        }
        guard let design, let descriptor = system.fontDescriptor.withDesign(design) else { return system }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func app(forTextStyle style: TextStyle, at size: DynamicTypeSize) -> UIFont {
        app(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)))
    }

    static func app(
        forTextStyle style: TextStyle,
        weight: UIFont.Weight = .regular,
        compatibleWith traits: UITraitCollection?
    ) -> UIFont {
        guard AppFontSettings.shared.family != .sanFrancisco else {
            return preferredFont(forTextStyle: style, compatibleWith: traits)
        }
        let standard = preferredFont(forTextStyle: style, at: .large).pointSize
        return UIFontMetrics(forTextStyle: style).scaledFont(for: app(size: standard, weight: weight), compatibleWith: traits)
    }
}
