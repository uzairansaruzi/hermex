import SwiftUI

enum HermexSurfaceBorderRamp {
    static let restingLight = HermesColorRamp.Neutral.s600
    static let restingDark = HermesColorRamp.Neutral.s400
    static let focusedLight = HermesColorRamp.Neutral.s700
    static let focusedDark = HermesColorRamp.Neutral.s300
    static let increasedContrastLight = HermesColorRamp.Neutral.s800
    static let increasedContrastDark = HermesColorRamp.Neutral.s200
}

enum HermexSurfaceBorderColors {
    static let resting = HermesColorRamp.Neutral.adaptive(
        light: HermexSurfaceBorderRamp.restingLight,
        dark: HermexSurfaceBorderRamp.restingDark
    )
    static let focused = HermesColorRamp.Neutral.adaptive(
        light: HermexSurfaceBorderRamp.focusedLight,
        dark: HermexSurfaceBorderRamp.focusedDark
    )
    static let increasedContrast = HermesColorRamp.Neutral.adaptive(
        light: HermexSurfaceBorderRamp.increasedContrastLight,
        dark: HermexSurfaceBorderRamp.increasedContrastDark
    )
}
