# 0168. Theme colors and surfaces

Area: ui-theming

## Leave unstyled text on iOS's label color

`AppTextStyle` gives SwiftUI text levels, used as `.foregroundStyle(.appSecondary)`. On the Default theme they are SwiftUI's own hierarchical levels, which keep their vibrancy on glass. On a theme they are the theme's text colors, because iOS's translucent levels miss the contrast floor there. Text with no style of its own stays iOS's label color: a foreground style set at the app root would also repaint every button's label.

Lives in: `HermesMobile/Config/AppColor.swift`

## Draw prominent button labels in appOnAccent

`AppProminentButtonStyle` stands in for `.borderedProminent`, whose label iOS always draws white. A theme's light dark-mode accent can't carry a white label, so with a theme or accent pick the label uses `appOnAccent`.

Lives in: `HermesMobile/Config/AppColor.swift`

## Replace materials with the theme surface

`AppMaterialStyle`, used as `.background(.appMaterial(.bar))`, draws the given Material only on the Default theme. A theme draws its surface (`appSurface`) instead, because iOS's materials wash the theme's colors out to gray.

Lives in: `HermesMobile/Config/AppColor.swift`

## Give List button labels a concrete text colour

A List button tints its label, and `.primary` or `.secondary` would resolve against that tint. `GitDiffFileJumpRow` sets `.foregroundStyle(Color(.appText))` so the file name stays primary and the folder secondary.

Lives in: `HermesMobile/Features/Workspace/GitDiffFileJumpList.swift`

## Paint the window background to stop black flashes on rotation

A `UIWindow` has no background of its own, so the gap that shows while a rotation outruns SwiftUI's content layout flashed black (#1528). `WindowBackgroundPainter` paints the window behind SwiftUI's content with `.appCanvas`. It also gives the window the accent, which SwiftUI's default tint and UIKit's controls both read.

Lives in: `HermesMobile/HermesMobileApp.swift`

## Switch real settings in the theme gallery

`ThemeGalleryView` (Debug builds only) shows the real chat components under one theme and color scheme at a time, switched with the real theme and color-scheme settings rather than a local override. Nested hosting inside a chat reply reads the window's trait, not a local SwiftUI override, so an override would leave those parts unthemed.

Lives in: `HermesMobile/Features/Settings/ThemeGalleryView.swift`

## Allow continuously animated Thinking slider looks

`ThinkingSliderLook` is the look a Thinking slider wears, chosen in Settings > Appearance. A look draws on a `Canvas` every frame while on screen, the one exception to the no-repainting rule, because the owner chose it for this control (#1550). Reduce Motion stills them. The raw value is stored on the device, so new cases keep their raw value and a value this build doesn't know falls back to `defaultLook`.

Lives in: `HermesMobile/Features/Chat/ThinkingSliderLooks.swift`
