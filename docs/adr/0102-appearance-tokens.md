# 0102. Appearance tokens

Area: performance

## Carry the theme as one window-scene trait

The theme and accent a user picked (`AppAppearance`) is the value of one trait on the window scene. A change recolors SwiftUI, UIKit, sheets and the app lock without re-running view bodies. Moving the theme into observed SwiftUI state would re-run every body that reads a color.

Lives in: `HermesMobile/Config/AppColor.swift`

## Read the font choice through Observation

A trait can't swap a SwiftUI `Font`, so the `AppFont` tokens read the stored font choice (`AppFontSettings.family`) instead. A view body that calls a token depends on `family` through Observation wherever it's hosted, and only a change of font re-runs those bodies.

Lives in: `HermesMobile/Config/AppFont.swift`
