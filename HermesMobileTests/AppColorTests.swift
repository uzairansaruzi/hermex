import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class AppColorTests: XCTestCase {
    private let themed = ColorTheme.allCases.filter { $0 != .default }

    private func traits(isDark: Bool) -> UITraitCollection {
        UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
    }

    private func resolved(_ color: UIColor, isDark: Bool) -> UIColor {
        color.resolvedColor(with: traits(isDark: isDark))
    }

    func testEveryThemeMeetsTheContrastFloor() {
        for theme in themed {
            for isDark in [false, true] {
                let palette = theme.palette(isDark: isDark)
                for (background, backgroundName) in [(palette.canvas, "canvas"), (palette.surface, "surface"), (palette.code, "code")] {
                    for (foreground, foregroundName) in [
                        (palette.text, "text"), (palette.textSecondary, "secondary"), (palette.textTertiary, "tertiary"),
                        (palette.placeholder, "placeholder"), (palette.accent, "accent")
                    ] {
                        let ratio = ColorContrast.ratio(foreground, background)
                        XCTAssertGreaterThanOrEqual(
                            ratio, ColorContrast.minimum,
                            "\(theme) dark=\(isDark): \(foregroundName) on \(backgroundName) is \(ratio)"
                        )
                    }
                }
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(palette.onAccent, palette.accent), ColorContrast.minimum, "\(theme) dark=\(isDark)")
            }
        }
    }

    /// Any pick, on any theme and on Default, in both modes: a color that's too close to the
    /// background moves until it's readable, and its label stays readable on it.
    func testAnyAccentPickIsMovedToMeetTheFloor() throws {
        for hex in ["#FFFFFF", "#000000", "#808080"] {
            for theme in ColorTheme.allCases {
                let appearance = AppAppearance(lightTheme: theme, darkTheme: theme, accentHex: hex)
                for isDark in [false, true] {
                    let palette = appearance.palette(isDark: isDark)
                    let accent = resolved(palette.accent, isDark: isDark)
                    for background in [palette.canvas, palette.surface, palette.groupedCanvas, palette.groupedSurface] {
                        XCTAssertGreaterThanOrEqual(
                            ColorContrast.ratio(accent, resolved(background, isDark: isDark)),
                            ColorContrast.minimum,
                            "\(hex) on \(theme) dark=\(isDark)"
                        )
                    }
                    XCTAssertGreaterThanOrEqual(ColorContrast.ratio(palette.onAccent, accent), ColorContrast.minimum)
                }
            }
        }
    }

    /// Default must look exactly like the app before themes.
    func testDefaultResolvesToSystemColors() {
        let appearance = UITraitCollection { $0[AppAppearanceTrait.self] = .default }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = appearance.modifyingTraits { $0.userInterfaceStyle = style }
            for (token, system) in [
                (UIColor.appCanvas, UIColor.systemBackground),
                (.appSurface, .secondarySystemBackground),
                (.appText, .label),
                (.appTextSecondary, .secondaryLabel),
                (.appSeparator, .separator),
                (.appAccent, .systemBlue)
            ] {
                XCTAssertEqual(token.resolvedColor(with: traits), system.resolvedColor(with: traits))
            }
        }
    }

    /// A card sets both modes and an orb sets one, so each mode reads its own theme.
    func testTokensFollowTheThemeForTheirMode() {
        let appearance = AppAppearance(lightTheme: .paper, darkTheme: .midnight, accentHex: nil)
        let light = UITraitCollection { $0[AppAppearanceTrait.self] = appearance; $0.userInterfaceStyle = .light }
        let dark = UITraitCollection { $0[AppAppearanceTrait.self] = appearance; $0.userInterfaceStyle = .dark }
        XCTAssertEqual(UIColor.appCanvas.resolvedColor(with: light), UIColor(rgb: 0xF8F4EC))
        XCTAssertEqual(UIColor.appCanvas.resolvedColor(with: dark), UIColor(rgb: 0x05071C))
    }

    func testEachModeReadsItsStoredThemeAndAnUnknownOneFallsBackToDefault() throws {
        let suite = "AppColorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-theme", forKey: AppAppearanceSettings.lightThemeKey)
        defaults.set("paper", forKey: AppAppearanceSettings.darkThemeKey)
        let stored = AppAppearanceSettings.stored(in: defaults)
        XCTAssertEqual(stored.lightTheme, .default)
        XCTAssertEqual(stored.darkTheme, .paper)
    }

    /// Teal is the swatch the server color's luminance rule would label white, at 2.39:1.
    func testPrimaryActionsUseTheAccentWithAReadableLabel() {
        let tint = PrimaryActionTintSettings.colors(accentHex: "#30B8C4", serverHex: "#FFD700")
        let appearance = AppAppearance(lightTheme: .default, darkTheme: .default, accentHex: "#30B8C4")
        for isDark in [false, true] {
            let traits = UITraitCollection { $0[AppAppearanceTrait.self] = appearance; $0.userInterfaceStyle = isDark ? .dark : .light }
            let fill = UIColor(tint.fill).resolvedColor(with: traits)
            XCTAssertEqual(fill, appearance.palette(isDark: isDark).accent)
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(UIColor(tint.label).resolvedColor(with: traits), fill), ColorContrast.minimum)
        }
    }

    func testPrimaryActionsUseTheServerColorWithNoAccent() {
        XCTAssertEqual(PrimaryActionTintSettings.colors(accentHex: nil, serverHex: "#5B7CFF").fill, HeaderLogoColor.color(for: "#5B7CFF"))
    }
}
