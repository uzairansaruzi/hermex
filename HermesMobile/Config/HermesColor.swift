import SwiftUI
import UIKit

struct HermesHexColor: Equatable {
    let hex: String

    init(_ hex: String) {
        let upper = hex.uppercased()
        precondition(upper.hasPrefix("#") && upper.count == 7, "HermesHexColor requires #RRGGBB")
        let payload = upper.dropFirst()
        precondition(payload.count == 6 && payload.allSatisfy(\.isHexDigit), "HermesHexColor requires #RRGGBB")
        self.hex = upper
    }

    var color: Color {
        Color(uiColor: uiColor)
    }

    var uiColor: UIColor {
        let scanner = Scanner(string: String(hex.dropFirst()))
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

enum HermesColorRamp {
    enum Neutral {
        /// An opaque light/dark pair of ramp steps, resolved with the platform's own
        /// `userInterfaceStyle` trait so the result never depends on `.opacity` to read correctly
        /// over arbitrary content underneath.
        static func adaptive(light: HermesHexColor, dark: HermesHexColor) -> Color {
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark.uiColor : light.uiColor })
        }

        static let s50 = HermesHexColor("#F9F9FA")
        static let s100 = HermesHexColor("#F1F1F2")
        static let s200 = HermesHexColor("#DFDFE1")
        static let s300 = HermesHexColor("#C9C9CB")
        static let s400 = HermesHexColor("#AEAEB1")
        static let s500 = HermesHexColor("#8E8E93")
        static let s600 = HermesHexColor("#808084")
        static let s700 = HermesHexColor("#6D6D71")
        static let s800 = HermesHexColor("#58585B")
        static let s900 = HermesHexColor("#434345")
        static let s950 = HermesHexColor("#2D2D2F")
    }

    enum Gold {
        static let s50 = HermesHexColor("#FFFDF2")
        static let s100 = HermesHexColor("#FFFAE0")
        static let s200 = HermesHexColor("#FFF4B8")
        static let s300 = HermesHexColor("#FFEC85")
        static let s400 = HermesHexColor("#FFE247")
        static let s500 = HermesHexColor("#FFD700")
        static let s600 = HermesHexColor("#E6C200")
        static let s700 = HermesHexColor("#C4A600")
        static let s800 = HermesHexColor("#9E8500")
        static let s900 = HermesHexColor("#786500")
        static let s950 = HermesHexColor("#524500")
    }

    enum Blue {
        static let s50 = HermesHexColor("#F7F8FF")
        static let s100 = HermesHexColor("#EBEFFF")
        static let s200 = HermesHexColor("#D1DAFF")
        static let s300 = HermesHexColor("#B0C0FF")
        static let s400 = HermesHexColor("#89A1FF")
        static let s500 = HermesHexColor("#5B7CFF")
        static let s600 = HermesHexColor("#5270E6")
        static let s700 = HermesHexColor("#465FC4")
        static let s800 = HermesHexColor("#384D9E")
        static let s900 = HermesHexColor("#2B3A78")
        static let s950 = HermesHexColor("#1D2852")
    }

    enum Purple {
        static let s50 = HermesHexColor("#FBF6FD")
        static let s100 = HermesHexColor("#F5EAFB")
        static let s200 = HermesHexColor("#E9CFF6")
        static let s300 = HermesHexColor("#D9ACEF")
        static let s400 = HermesHexColor("#C582E7")
        static let s500 = HermesHexColor("#AF52DE")
        static let s600 = HermesHexColor("#9E4AC8")
        static let s700 = HermesHexColor("#873FAB")
        static let s800 = HermesHexColor("#6C338A")
        static let s900 = HermesHexColor("#522768")
        static let s950 = HermesHexColor("#381A47")
    }

    enum Red {
        static let s50 = HermesHexColor("#FFF5F5")
        static let s100 = HermesHexColor("#FFE7E6")
        static let s200 = HermesHexColor("#FFC8C5")
        static let s300 = HermesHexColor("#FFA19C")
        static let s400 = HermesHexColor("#FF726A")
        static let s500 = HermesHexColor("#FF3B30")
        static let s600 = HermesHexColor("#E6352B")
        static let s700 = HermesHexColor("#C42D25")
        static let s800 = HermesHexColor("#9E251E")
        static let s900 = HermesHexColor("#781C17")
        static let s950 = HermesHexColor("#52130F")
    }

    enum Green {
        static let s50 = HermesHexColor("#F5FCF7")
        static let s100 = HermesHexColor("#E7F8EB")
        static let s200 = HermesHexColor("#C6EFD1")
        static let s300 = HermesHexColor("#9EE4AF")
        static let s400 = HermesHexColor("#6DD787")
        static let s500 = HermesHexColor("#34C759")
        static let s600 = HermesHexColor("#2FB350")
        static let s700 = HermesHexColor("#289945")
        static let s800 = HermesHexColor("#207B37")
        static let s900 = HermesHexColor("#185E2A")
        static let s950 = HermesHexColor("#11401C")
    }

    enum Orange {
        static let s50 = HermesHexColor("#FFFAF5")
        static let s100 = HermesHexColor("#FFF2E8")
        static let s200 = HermesHexColor("#FEE0C8")
        static let s300 = HermesHexColor("#FDCBA1")
        static let s400 = HermesHexColor("#FCB173")
        static let s500 = HermesHexColor("#FB923C")
        static let s600 = HermesHexColor("#E28336")
        static let s700 = HermesHexColor("#C1702E")
        static let s800 = HermesHexColor("#9C5B25")
        static let s900 = HermesHexColor("#76451C")
        static let s950 = HermesHexColor("#502F13")
    }

    enum Cyan {
        static let s50 = HermesHexColor("#F7FEFF")
        static let s100 = HermesHexColor("#EDFCFE")
        static let s200 = HermesHexColor("#D4F9FD")
        static let s300 = HermesHexColor("#B6F4FC")
        static let s400 = HermesHexColor("#92EEFB")
        static let s500 = HermesHexColor("#67E8F9")
        static let s600 = HermesHexColor("#5DD1E0")
        static let s700 = HermesHexColor("#4FB3C0")
        static let s800 = HermesHexColor("#40909A")
        static let s900 = HermesHexColor("#306D75")
        static let s950 = HermesHexColor("#214A50")
    }

    enum Pink {
        static let s50 = HermesHexColor("#FEF8FB")
        static let s100 = HermesHexColor("#FEEEF6")
        static let s200 = HermesHexColor("#FCD8EB")
        static let s300 = HermesHexColor("#FABBDC")
        static let s400 = HermesHexColor("#F799CA")
        static let s500 = HermesHexColor("#F472B6")
        static let s600 = HermesHexColor("#DC67A4")
        static let s700 = HermesHexColor("#BC588C")
        static let s800 = HermesHexColor("#974771")
        static let s900 = HermesHexColor("#733656")
        static let s950 = HermesHexColor("#4E243A")
    }
}

enum HermesProductPalette {
    // Header accent presets — ramp aliases. Casing already matches HermesColorRamp exactly, so a
    // direct `= HermesColorRamp.X.sYYY.hex` reference introduces no casing change to
    // HeaderLogoColor.presets's existing literals.
    static let headerAccentYellow: String = HermesColorRamp.Gold.s500.hex
    static let headerAccentBlue: String = HermesColorRamp.Blue.s500.hex
    static let headerAccentPurple: String = HermesColorRamp.Purple.s500.hex
    static let headerAccentRed: String = HermesColorRamp.Red.s500.hex
    static let headerAccentGreen: String = HermesColorRamp.Green.s500.hex

    // Header accent — standalone, no ramp anchor (white is not a hue).
    static let headerAccentWhite: String = "#FFFFFF"

    // Project palette — standalone, exact existing literal casing preserved (lowercase, as
    // authored in ProjectCreationSheet.swift; none of these five equals any HermesColorRamp step).
    static let projectSky: String = "#7cb9ff"
    static let projectGold: String = "#f5c542"
    static let projectRed: String = "#e94560"
    static let projectGreen: String = "#50c878"
    static let projectViolet: String = "#c084fc"

    // Project palette — ramp aliases, DERIVED from the ramp (not a second hand-typed literal).
    // Production stores these three in lowercase while HermesColorRamp stores every ramp value in
    // uppercase, so each constant lower-cases its ramp source once, here, at the single point of
    // definition — there is no independent "#fb923c"-style literal anywhere that could silently
    // drift out of sync with HermesColorRamp.Orange.s500 if the ramp were ever revised.
    static let projectOrange: String = HermesColorRamp.Orange.s500.hex.lowercased()
    static let projectCyan: String = HermesColorRamp.Cyan.s500.hex.lowercased()
    static let projectPink: String = HermesColorRamp.Pink.s500.hex.lowercased()
}
