import MarkdownUI
import SwiftUI
import UIKit

/// Settings > Appearance's Font, one choice for the whole app across every server.
enum AppFontFamily: String, CaseIterable, Identifiable {
    case sanFrancisco
    case sfRounded
    case dmSans
    case avenirNext
    case georgia
    case lora
    case sfMono

    var id: String { rawValue }

    /// Proper names, the same in every language.
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

    /// The family name of a non-system font. DM Sans and Lora are bundled (`Resources/Fonts`).
    fileprivate var customName: String? {
        switch self {
        case .sanFrancisco, .sfRounded, .sfMono: nil
        case .dmSans: "DM Sans"
        case .avenirNext: "Avenir Next"
        case .georgia: "Georgia"
        case .lora: "Lora"
        }
    }

    /// The design of a system font. Nil asks for the plain system font, exactly as `.body` does.
    fileprivate var design: Font.Design? {
        switch self {
        case .sfRounded: .rounded
        case .sfMono: .monospaced
        default: nil
        }
    }
}

/// The stored font choice. A trait can't swap a SwiftUI `Font`, so tokens read this instead:
/// a view body that calls one depends on `family` through Observation, wherever it's hosted,
/// and only a change of font re-runs those bodies.
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

/// Typography tokens: use these in place of `.body`, `.caption` and friends so text follows the
/// Font setting. San Francisco resolves to the same fonts as the system styles.
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

    /// Text at a size that ignores Text Size, like `.system(size:)`. Glyphs keep `.system(size:)`.
    static func fixed(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let family = AppFontSettings.shared.family
        guard let name = family.customName else {
            return .system(size: size, weight: weight, design: family.design)
        }
        let custom = Font.custom(name, fixedSize: size)
        return weight.map(custom.weight) ?? custom
    }

    /// Code stays monospaced whatever the Font setting is.
    static func mono(style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    /// Monospaced tool output: `customSize` points when set (`CodeDisplaySettings`), else `style`.
    static func code(style: Font.TextStyle, customSize: Double?) -> Font {
        customSize.map { .system(size: $0, design: .monospaced) } ?? mono(style: style)
    }

    /// The default for text with no font of its own, set at each window's root. Nil on San
    /// Francisco, which leaves every control's own default alone.
    static var root: Font? {
        AppFontSettings.shared.family == .sanFrancisco ? nil : body()
    }

    /// A list's section footer. Nil on San Francisco, which keeps the list's own default.
    static var sectionFooter: Font? {
        AppFontSettings.shared.family == .sanFrancisco ? nil : footnote()
    }

    /// The family a Markdown reply's text uses.
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
        // `relativeTo:` borrows only the scaling, and a headline is semibold by nature.
        return (weight ?? (style == .headline ? .semibold : nil)).map(custom.weight) ?? custom
    }

    /// The style's point size at the standard text size.
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
    /// Sets `AppFont.root` here, in a modifier of its own so a font change re-runs only this.
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

/// `AppFont.root` also replaces the smaller default a list gives its section footers, so a section
/// with a footer uses `appFooter:` to get it back. Reads like SwiftUI's `footer:` initializers.
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

/// Navigation bar titles are UIKit's and read no SwiftUI font. The proxy covers bars made later,
/// and bars already on screen are set directly. San Francisco clears both.
@MainActor enum AppBarFont {
    /// Called from the app's `init`, because SwiftUI makes its first bar before a scene delegate
    /// hears about the scene. Nil traits follow the iPhone's text size.
    static func applyAtLaunch() {
        let size = AppTextSize.size(atStop: UserDefaults.standard.integer(forKey: AppTextSize.storageKey))
        setProxy(traits: size.map { UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory($0)) })
    }

    /// Called when the font or the text size changes.
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

// UIKit text. The caller re-reads these when the font changes: `updateUIView` is observed, and
// anything that bakes the text into an image puts `family` in the image's cache key.
extension UIFont {
    /// The app's font at a fixed size.
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

    /// The app's font for `style` at `size`, which scales with `adjustsFontForContentSizeCategory`.
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
