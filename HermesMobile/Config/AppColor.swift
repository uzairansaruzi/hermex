import SwiftUI
import UIKit

/// Settings > Appearance's themes. Each has a light and a dark palette, and a user can pick a
/// different theme for each mode. Default is the app's system colors, untouched.
enum ColorTheme: String, CaseIterable, Identifiable {
    case `default`
    case paper
    case midnight
    case grove
    case ocean
    case ember
    case iris

    var id: Self { self }

    var title: String {
        switch self {
        case .default: String(localized: "Default")
        case .paper: String(localized: "Paper")
        case .midnight: String(localized: "Midnight")
        case .grove: String(localized: "Grove")
        case .ocean: String(localized: "Ocean")
        case .ember: String(localized: "Ember")
        case .iris: String(localized: "Iris")
        }
    }

    /// Text color for drawing outside the view hierarchy, where no trait reaches, such as math images.
    func resolvedText(isDark: Bool) -> UIColor {
        palette(isDark: isDark).text.resolvedColor(with: UITraitCollection(userInterfaceStyle: isDark ? .dark : .light))
    }

    func palette(isDark: Bool) -> ThemePalette {
        switch (self, isDark) {
        case (.default, _): ThemePalette.system
        case (.paper, false): ThemePalette.paperLight
        case (.paper, true): ThemePalette.paperDark
        case (.midnight, false): ThemePalette.midnightLight
        case (.midnight, true): ThemePalette.midnightDark
        case (.grove, false): ThemePalette.groveLight
        case (.grove, true): ThemePalette.groveDark
        case (.ocean, false): ThemePalette.oceanLight
        case (.ocean, true): ThemePalette.oceanDark
        case (.ember, false): ThemePalette.emberLight
        case (.ember, true): ThemePalette.emberDark
        case (.iris, false): ThemePalette.irisLight
        case (.iris, true): ThemePalette.irisDark
        }
    }
}

/// One theme's colors in one mode. A class, because every token read passes one through the trait.
final class ThemePalette {
    let canvas, surface, raised, groupedCanvas, groupedSurface, groupedRaised: UIColor
    let text, textSecondary, textTertiary, placeholder: UIColor
    let separator, fill, fillSecondary, fillTertiary: UIColor
    let accent, onAccent, link, code, inlineCode, userBubble: UIColor

    /// Today's colors. Dynamic, so one palette serves both modes and elevated sheets.
    static let system = ThemePalette(
        canvas: .systemBackground, surface: .secondarySystemBackground, raised: .tertiarySystemBackground,
        groupedCanvas: .systemGroupedBackground, groupedSurface: .secondarySystemGroupedBackground,
        groupedRaised: .tertiarySystemGroupedBackground,
        text: .label, textSecondary: .secondaryLabel, textTertiary: .tertiaryLabel, placeholder: .placeholderText,
        separator: .separator, fill: .systemFill, fillSecondary: .secondarySystemFill, fillTertiary: .tertiarySystemFill,
        accent: .systemBlue, onAccent: .white,
        link: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x4C8EF8) : UIColor(rgb: 0x2C65CF) },
        code: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1) : .secondarySystemBackground },
        inlineCode: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1) : .tertiarySystemGroupedBackground },
        userBubble: UIColor { $0.userInterfaceStyle == .dark ? .systemGray3 : .systemGray6 }
    )

    static let paperLight = ThemePalette(isDark: false, canvas: 0xF8F4EC, surface: 0xEFE9DD, text: 0x2A2520, muted: 0x6F665B, border: 0xE2DACB, accent: 0x8F5213, code: 0xEFE9DD)
    static let paperDark = ThemePalette(isDark: true, canvas: 0x1F1E1C, surface: 0x2A2926, text: 0xF1EEE8, muted: 0xA09C93, border: 0x38362F, accent: 0xE0A25E, code: 0x171614)
    static let midnightLight = ThemePalette(isDark: false, canvas: 0xF5F7FC, surface: 0xE9EDF7, text: 0x12172A, muted: 0x5C6680, border: 0xD9DFEE, accent: 0x3558E8, code: 0xE9EDF7)
    static let midnightDark = ThemePalette(isDark: true, canvas: 0x05071C, surface: 0x11142E, text: 0xEEF0FA, muted: 0x8F95B5, border: 0x1F2342, accent: 0x6E8BFF, code: 0x0B0E26)
    static let groveLight = ThemePalette(isDark: false, canvas: 0xF6F8F2, surface: 0xEAF0E3, text: 0x1C2A1F, muted: 0x5C6B5B, border: 0xD8E2CF, accent: 0x2A7349, code: 0xEAF0E3)
    static let groveDark = ThemePalette(isDark: true, canvas: 0x0C1410, surface: 0x16211A, text: 0xE9F2EA, muted: 0x8FA394, border: 0x233228, accent: 0x58C98A, code: 0x111B15)
    static let oceanLight = ThemePalette(isDark: false, canvas: 0xF3F8FA, surface: 0xE4F0F5, text: 0x11262F, muted: 0x566D78, border: 0xD0E2EA, accent: 0x0F6A9C, code: 0xE4F0F5)
    static let oceanDark = ThemePalette(isDark: true, canvas: 0x08141B, surface: 0x102029, text: 0xE6F2F7, muted: 0x86A0AD, border: 0x1C303B, accent: 0x56B4E6, code: 0x0C1A22)
    static let emberLight = ThemePalette(isDark: false, canvas: 0xFBF5F1, surface: 0xF5E8E0, text: 0x2E1D15, muted: 0x7C5F52, border: 0xEBD8CC, accent: 0xB0431B, code: 0xF5E8E0)
    static let emberDark = ThemePalette(isDark: true, canvas: 0x170E0A, surface: 0x251712, text: 0xF6EAE3, muted: 0xB0948A, border: 0x38241B, accent: 0xF08A54, code: 0x1E130E)
    static let irisLight = ThemePalette(isDark: false, canvas: 0xF8F5FC, surface: 0xEEE8F7, text: 0x211A33, muted: 0x685E80, border: 0xE0D8EF, accent: 0x6D3FC8, code: 0xEEE8F7)
    static let irisDark = ThemePalette(isDark: true, canvas: 0x100C1C, surface: 0x1C162C, text: 0xEFEAF8, muted: 0x9C92B5, border: 0x2B2342, accent: 0xA98BF5, code: 0x161125)

    private init(
        canvas: UIColor, surface: UIColor, raised: UIColor, groupedCanvas: UIColor, groupedSurface: UIColor, groupedRaised: UIColor,
        text: UIColor, textSecondary: UIColor, textTertiary: UIColor, placeholder: UIColor,
        separator: UIColor, fill: UIColor, fillSecondary: UIColor, fillTertiary: UIColor,
        accent: UIColor, onAccent: UIColor, link: UIColor, code: UIColor, inlineCode: UIColor, userBubble: UIColor
    ) {
        self.canvas = canvas
        self.surface = surface
        self.raised = raised
        self.groupedCanvas = groupedCanvas
        self.groupedSurface = groupedSurface
        self.groupedRaised = groupedRaised
        self.text = text
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.placeholder = placeholder
        self.separator = separator
        self.fill = fill
        self.fillSecondary = fillSecondary
        self.fillTertiary = fillTertiary
        self.accent = accent
        self.onAccent = onAccent
        self.link = link
        self.code = code
        self.inlineCode = inlineCode
        self.userBubble = userBubble
    }

    /// A theme's palette, from the seven colors that define it. The rest follow the same rules
    /// in every theme, with fill strengths matching iOS's own. Tertiary text and placeholders are
    /// the muted color at full strength: anything fainter misses the contrast floor.
    private convenience init(isDark: Bool, canvas: Int, surface: Int, text: Int, muted: Int, border: Int, accent: Int, code: Int) {
        let canvas = UIColor(rgb: canvas)
        let surface = UIColor(rgb: surface)
        let text = UIColor(rgb: text)
        let muted = UIColor(rgb: muted)
        let accent = UIColor(rgb: accent)
        self.init(
            canvas: canvas, surface: surface, raised: surface,
            groupedCanvas: canvas, groupedSurface: surface, groupedRaised: canvas,
            text: text, textSecondary: muted, textTertiary: muted, placeholder: muted,
            separator: UIColor(rgb: border),
            fill: text.withAlphaComponent(isDark ? 0.36 : 0.2),
            fillSecondary: text.withAlphaComponent(isDark ? 0.32 : 0.16),
            fillTertiary: text.withAlphaComponent(isDark ? 0.24 : 0.12),
            accent: accent, onAccent: accent.readableForeground, link: accent,
            code: UIColor(rgb: code), inlineCode: surface, userBubble: surface
        )
    }

    /// This palette with a user's accent, moved just far enough to stay readable on it.
    func withAccent(_ accent: UIColor, isDark: Bool) -> ThemePalette {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let readable = accent.adjustedForContrast(
            ColorContrast.minimum,
            on: [canvas, surface, groupedCanvas, groupedSurface].map { $0.resolvedColor(with: traits) },
            toward: isDark ? .white : .black
        )
        return ThemePalette(
            canvas: canvas, surface: surface, raised: raised,
            groupedCanvas: groupedCanvas, groupedSurface: groupedSurface, groupedRaised: groupedRaised,
            text: text, textSecondary: textSecondary, textTertiary: textTertiary, placeholder: placeholder,
            separator: separator, fill: fill, fillSecondary: fillSecondary, fillTertiary: fillTertiary,
            accent: readable, onAccent: readable.readableForeground, link: readable, code: code, inlineCode: inlineCode, userBubble: userBubble
        )
    }
}

/// The theme and accent a user picked. It's the value of one trait on the window scene, so a
/// change recolors SwiftUI, UIKit, sheets and the app lock without re-running view bodies.
struct AppAppearance: Equatable {
    static let `default` = AppAppearance(lightTheme: .default, darkTheme: .default, accentHex: nil)

    let lightTheme: ColorTheme
    let darkTheme: ColorTheme
    /// Nil uses each theme's own accent.
    let accentHex: String?
    private let lightPalette: ThemePalette
    private let darkPalette: ThemePalette

    init(lightTheme: ColorTheme, darkTheme: ColorTheme, accentHex: String?) {
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.accentHex = accentHex
        let accent = accentHex.flatMap(UIColor.init(hexRGB:))
        lightPalette = accent.map { lightTheme.palette(isDark: false).withAccent($0, isDark: false) }
            ?? lightTheme.palette(isDark: false)
        darkPalette = accent.map { darkTheme.palette(isDark: true).withAccent($0, isDark: true) }
            ?? darkTheme.palette(isDark: true)
    }

    func palette(isDark: Bool) -> ThemePalette { isDark ? darkPalette : lightPalette }

    /// For caches of baked images, which a new theme or accent has to redraw.
    var cacheKey: String { "\(lightTheme.rawValue)|\(darkTheme.rawValue)|\(accentHex ?? "")" }

    func theme(for colorScheme: ColorScheme) -> ColorTheme { colorScheme == .dark ? darkTheme : lightTheme }

    static func == (lhs: AppAppearance, rhs: AppAppearance) -> Bool {
        lhs.lightTheme == rhs.lightTheme && lhs.darkTheme == rhs.darkTheme && lhs.accentHex == rhs.accentHex
    }
}

struct AppAppearanceTrait: UITraitDefinition {
    static let defaultValue = AppAppearance.default
    static let affectsColorAppearance = true
    static let identifier = "com.uzairansar.hermesmobile.appearance"
}

private struct AppAppearanceKey: EnvironmentKey, UITraitBridgedEnvironmentKey {
    static let defaultValue = AppAppearance.default

    static func read(from traitCollection: UITraitCollection) -> AppAppearance {
        traitCollection[AppAppearanceTrait.self]
    }

    static func write(to mutableTraits: inout any UIMutableTraits, value: AppAppearance) {
        mutableTraits[AppAppearanceTrait.self] = value
    }
}

extension EnvironmentValues {
    var appAppearance: AppAppearance {
        get { self[AppAppearanceKey.self] }
        set { self[AppAppearanceKey.self] = newValue }
    }

    /// Whether this mode shows a theme, rather than Default's system colors. Only for what a
    /// color token can't do alone, such as hiding a list's own background.
    var isAppThemed: Bool { appAppearance.theme(for: colorScheme) != .default }
}

/// Where Settings > Appearance keeps its theme and accent, for all servers. Applied like
/// `AppTextSize`: when a scene connects, before its first frame, and when the setting changes.
enum AppAppearanceSettings {
    static let lightThemeKey = "appearance.lightTheme"
    static let darkThemeKey = "appearance.darkTheme"
    static let accentHexKey = "appearance.accentHex"

    static func stored(in defaults: UserDefaults = .standard) -> AppAppearance {
        AppAppearance(
            lightTheme: defaults.string(forKey: lightThemeKey).flatMap(ColorTheme.init(rawValue:)) ?? .default,
            darkTheme: defaults.string(forKey: darkThemeKey).flatMap(ColorTheme.init(rawValue:)) ?? .default,
            accentHex: defaults.string(forKey: accentHexKey).flatMap(HeaderLogoColor.normalizedHex)
        )
    }

    @MainActor static func applyStored(to scene: UIWindowScene) {
        scene.traitOverrides[AppAppearanceTrait.self] = stored()
    }

    @MainActor static func applyStoredToConnectedScenes() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            applyStored(to: scene)
        }
    }
}

/// The app's color tokens. Each follows the scene's theme, accent and mode wherever it's drawn.
/// In SwiftUI: `Color(.appCanvas)`. Status colors and syntax highlighting aren't tokens: they
/// stay fixed in every theme.
extension UIColor {
    static let appCanvas = token { $0.canvas }
    static let appSurface = token { $0.surface }
    static let appRaised = token { $0.raised }
    static let appGroupedCanvas = token { $0.groupedCanvas }
    static let appGroupedSurface = token { $0.groupedSurface }
    static let appGroupedRaised = token { $0.groupedRaised }
    static let appText = token { $0.text }
    static let appTextSecondary = token { $0.textSecondary }
    static let appTextTertiary = token { $0.textTertiary }
    static let appPlaceholder = token { $0.placeholder }
    static let appSeparator = token { $0.separator }
    static let appFill = token { $0.fill }
    static let appFillSecondary = token { $0.fillSecondary }
    static let appFillTertiary = token { $0.fillTertiary }
    static let appAccent = token { $0.accent }
    /// Text and icons on a solid `appAccent` fill.
    static let appOnAccent = token { $0.onAccent }
    /// Links in Markdown replies.
    static let appLink = token { $0.link }
    /// Behind code blocks.
    static let appCode = token { $0.code }
    /// Behind inline code in prose.
    static let appInlineCode = token { $0.inlineCode }
    static let appUserBubble = token { $0.userBubble }

    private static func token(_ color: @escaping (ThemePalette) -> UIColor) -> UIColor {
        UIColor { traits in
            let palette = traits[AppAppearanceTrait.self].palette(isDark: traits.userInterfaceStyle == .dark)
            return color(palette).resolvedColor(with: traits)
        }
    }

    convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Nil unless `rawValue` is a six-digit hex color.
    convenience init?(hexRGB rawValue: String) {
        guard let hex = HeaderLogoColor.normalizedHex(rawValue),
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(rgb: value)
    }
}

/// WCAG contrast, which the themes and any accent pick must meet.
enum ColorContrast {
    static let minimum = 4.5

    static func ratio(_ first: UIColor, _ second: UIColor) -> Double {
        let lighter = max(first.relativeLuminance, second.relativeLuminance)
        let darker = min(first.relativeLuminance, second.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

private extension UIColor {
    var relativeLuminance: Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ component: CGFloat) -> Double {
            let value = min(max(Double(component), 0), 1)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// White or black, whichever reads better on this color. The better one always clears 4.5:1.
    var readableForeground: UIColor {
        ColorContrast.ratio(.white, self) >= ColorContrast.ratio(.black, self) ? .white : .black
    }

    /// This color, mixed toward `target` in small steps until it reaches `minimum` on every background.
    func adjustedForContrast(_ minimum: Double, on backgrounds: [UIColor], toward target: UIColor) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        var targetRed: CGFloat = 0, targetGreen: CGFloat = 0, targetBlue: CGFloat = 0
        target.getRed(&targetRed, green: &targetGreen, blue: &targetBlue, alpha: &alpha)

        for step in 0...20 {
            let amount = CGFloat(step) / 20
            let candidate = UIColor(
                red: red + (targetRed - red) * amount,
                green: green + (targetGreen - green) * amount,
                blue: blue + (targetBlue - blue) * amount,
                alpha: 1
            )
            if backgrounds.allSatisfy({ ColorContrast.ratio(candidate, $0) >= minimum }) { return candidate }
        }
        return target
    }
}

/// Text levels for SwiftUI: `.foregroundStyle(.appSecondary)`. On Default these are SwiftUI's own
/// levels, which keep their vibrancy on glass. On a theme they're its text colors, which meet the
/// contrast floor where iOS's translucent levels don't. Text with no style of its own stays iOS's
/// label color: a foreground style set at the app root would also repaint every button's label.
struct AppTextStyle: ShapeStyle {
    enum Level { case primary, secondary, tertiary }

    let level: Level

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        let themed = environment.isAppThemed
        switch level {
        case .primary: return themed ? AnyShapeStyle(Color(.appText)) : AnyShapeStyle(.primary)
        case .secondary: return themed ? AnyShapeStyle(Color(.appTextSecondary)) : AnyShapeStyle(.secondary)
        case .tertiary: return themed ? AnyShapeStyle(Color(.appTextTertiary)) : AnyShapeStyle(.tertiary)
        }
    }
}

extension ShapeStyle where Self == AppTextStyle {
    static var appPrimary: AppTextStyle { AppTextStyle(level: .primary) }
    static var appSecondary: AppTextStyle { AppTextStyle(level: .secondary) }
    static var appTertiary: AppTextStyle { AppTextStyle(level: .tertiary) }
}

/// What a themed list draws behind its rows.
enum ThemedListRows {
    /// Cards on the canvas, as in an inset grouped list.
    case grouped
    /// Rows directly on the canvas.
    case plain
}

/// A `List` that follows the theme. On Default it's an ordinary `List`: nothing here applies, so
/// rows keep iOS's own backgrounds and highlights. Rows never draw dividers between them.
struct AppList<Content: View>: View {
    var rows = ThemedListRows.grouped
    @ViewBuilder let content: Content

    var body: some View {
        List { ThemedListContent(rows: rows, content: content) }
            .modifier(ThemedScrollBackground(rows: rows))
    }
}

/// `AppList` for a `Form`.
struct AppForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { ThemedListContent(rows: .grouped, content: content) }
            .modifier(ThemedScrollBackground(rows: .grouped))
    }
}

/// Gives every row the theme's background and hides its separators. A row with its own
/// `listRowBackground` keeps it.
private struct ThemedListContent<Content: View>: View {
    let rows: ThemedListRows
    let content: Content

    @Environment(\.isAppThemed) private var isThemed

    var body: some View {
        content
            .listRowBackground(isThemed ? Color(rows == .grouped ? .appGroupedSurface : .appCanvas) : nil)
            .listRowSeparator(.hidden)
    }
}

private struct ThemedScrollBackground: ViewModifier {
    let rows: ThemedListRows

    @Environment(\.isAppThemed) private var isThemed

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(isThemed ? .hidden : .automatic)
            .background {
                if isThemed {
                    Color(rows == .grouped ? .appGroupedCanvas : .appCanvas).ignoresSafeArea()
                }
            }
    }
}

/// `.borderedProminent` with a readable label. iOS always draws it white, which a theme's light
/// dark-mode accent can't carry, so a theme or accent pick uses `appOnAccent`.
struct AppProminentButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Prominent(configuration: configuration)
    }

    private struct Prominent: View {
        let configuration: Configuration
        @Environment(\.isAppThemed) private var isThemed
        @Environment(\.appAppearance) private var appearance

        var body: some View {
            if isThemed || appearance.accentHex != nil {
                Button(configuration).buttonStyle(.borderedProminent).foregroundStyle(Color(.appOnAccent))
            } else {
                Button(configuration).buttonStyle(.borderedProminent)
            }
        }
    }
}

extension PrimitiveButtonStyle where Self == AppProminentButtonStyle {
    static var appProminent: AppProminentButtonStyle { AppProminentButtonStyle() }
}

/// A material on Default. A theme draws its surface instead: iOS's materials wash its colors out
/// to gray. `.background(.appMaterial(.bar))`.
struct AppMaterialStyle: ShapeStyle {
    let material: Material

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        environment.isAppThemed ? AnyShapeStyle(Color(.appSurface)) : AnyShapeStyle(material)
    }
}

extension ShapeStyle where Self == AppMaterialStyle {
    static func appMaterial(_ material: Material) -> AppMaterialStyle { AppMaterialStyle(material: material) }
}

extension View {
    /// Fills a page, pushed or in a sheet, with the theme's canvas. iOS paints a page with no
    /// background of its own in the system color, and nothing above the page can change that.
    /// Draws nothing on Default.
    func themedPageBackground() -> some View {
        modifier(ThemedPageBackground())
    }
}

private struct ThemedPageBackground: ViewModifier {
    @Environment(\.isAppThemed) private var isThemed

    func body(content: Content) -> some View {
        content.background {
            if isThemed { Color(.appCanvas).ignoresSafeArea() }
        }
    }
}
