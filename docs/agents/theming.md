# Theming — agent notes

## Colors

Settings > Appearance sets a theme for each mode and an optional accent, for all servers. `HermesMobile/Config/AppColor.swift` owns all of it. Default is iOS's system colors and must stay pixel-identical to an app with no themes.

One trait on the window scene (`AppAppearanceTrait`) carries the choice. Color tokens read it when they resolve, so a change recolors SwiftUI, UIKit, sheets and the app lock with no view body re-running. The share extension and Live Activity are separate processes and don't follow it.

## Coloring new UI

| Need | Use | Not |
|---|---|---|
| Backgrounds, fills, separators | `Color(.appCanvas)`, `.appSurface`, `.appSeparator`, … | `Color(.systemBackground)` and other system colors |
| Text levels | `.foregroundStyle(.appSecondary)` | `.foregroundStyle(.secondary)`, which misses the contrast floor on a theme |
| Accent | `Color.accentColor` or `.tint`: both read the window's tint | `.blue`, or a root `.tint`, which recolors every Toggle |
| Filled accent button | `.buttonStyle(.appProminent)` | `.borderedProminent`, whose white label fails on a light accent |
| Material | `.background(.appMaterial(.bar))` | `.bar`, which grays a theme out |
| List or form | `AppList`, or `AppForm` | `List`, whose rows keep iOS's backgrounds |
| Page or sheet with no list | `.themedPageBackground()` | Nothing: iOS paints it the system color |
| UIKit | `.appCanvas` and so on, as `UIColor` | |

Status colors (`.red`, `.green`, `.orange`) and syntax highlighting stay fixed in every theme.

## What a token can't do

- **No root foreground style.** Any `.foregroundStyle` above a `Button`, even `.primary`, repaints its label. Text with no style of its own stays iOS's label color, which clears the floor on every theme.
- **A theme is scene-wide.** `.environment(\.appAppearance, …)` on a subtree doesn't reach a reply's nested hosting view, which reads the window's trait. `ThemeGalleryView` switches the real setting for this reason.
- **Baked images need the theme in their key.** Math images and composer chips draw once and cache, so their keys include it (`InlineMathImageCache`, `AppAppearance.cacheKey`). A view that bakes colors registers for `AppAppearanceTrait`.
- **A fresh `UITraitCollection` has no theme.** It resolves a token to Default. Set the trait on it, as `ComposerChipTextStyle` does.

The diff highlighter's contrast adjustment measures against Default's background, not the theme's, because syntax colors stay fixed.

`AppColorTests` holds every theme and any accent pick to 4.5:1. Default is exempt: system blue on white is 4.02:1.

## Fonts

Settings > Appearance sets one font for the whole app, across all servers. `HermesMobile/Config/AppFont.swift` owns it. San Francisco is the system font and must stay pixel-identical to an app with no font setting.

A trait can't swap a SwiftUI `Font`, so the tokens read `AppFontSettings.shared.family` when they run. A body that calls a token depends on it through Observation, wherever it's hosted, and only a change of font re-runs those bodies.

| Need | Use | Not |
|---|---|---|
| Text | `.font(AppFont.caption(weight: .semibold))` | `.font(.caption.weight(.semibold))`, which stays San Francisco |
| Text at a fixed size | `AppFont.fixed(size: 11, weight: .bold)` | `.system(size:)`. An SF Symbol keeps `.system(size:)` |
| Code | `AppFont.mono`, `AppFont.code`, or `.monospaced()` | A text token: code stays monospaced under every font |
| List section footer | `Section { … } appFooter: { … }` | `footer:`, whose text grows to body size under a chosen font |
| UIKit text | `UIFont.app(forTextStyle:at:)` or `UIFont.app(size:weight:)` | `preferredFont` or `systemFont` |

- **`.bold()` isn't `weight: .bold`.** The trait renders lighter on a system font, so keep whichever the design used: `AppFont.title3().bold()`.
- **Text with no font of its own** follows `AppFont.root`, set at each window's root with `.appRootFont()`. It's nil on San Francisco, because a root font also replaces the smaller defaults a control gives itself.
- **Read a token in `body` or `updateUIView`.** A value kept in a `static let` or built once in `makeUIView` won't change with the setting.
- **Baked text needs the font in its key.** Composer chips key on the label font's name. Math images don't use the font.
- **Navigation titles** are UIKit's, so `AppBarFont` sets them.

The bundled fonts, DM Sans and Lora, live unmodified in `Resources/Fonts` under `UIAppFonts`, with their licenses in `ThirdPartyNotices`.

These stay San Francisco: system menus and alerts, segmented controls, and `ContentUnavailableView`, which sets its own fonts. The share extension and Live Activity are separate processes and don't follow the setting.

## HTML reports

A Hermes reply's `.html` file renders in place in the chat and in a full-height sheet (#1623, `HermesMobile/Features/Chat/HTMLReport.swift`). Like a browser, a visible report loads whatever remote images, styles or scripts it names without a tap, so those hosts see the request and the device's IP address; no Hermes cookie, credential or header goes with it. The page gets the active theme, font and text size as zero-specificity defaults (`:where()`), so any style of its own wins. A live page restyles in place when the theme, accent, font, text size or light/dark changes. These CSS variables are set on `:root`:

| Variable | From |
|---|---|
| `--background` | canvas |
| `--foreground` | text |
| `--card` | surface |
| `--muted-foreground` | secondary text |
| `--border` | separator |
| `--primary` | accent |
| `--font-sans` | the Font setting; DM Sans falls back to the system sans and Lora to Georgia, because the page's web process can't see bundled fonts |
| `--font-mono` | the system monospaced font |

A user can paste this to their agent:

> When you make an HTML report for me, send it as a single `.html` file. Style it with the CSS variables `--background`, `--foreground`, `--card`, `--muted-foreground`, `--border`, `--primary`, `--font-sans` and `--font-mono` instead of fixed colors and fonts, so it matches my app's theme in light and dark. Inline images, styles and data; a relative link to another file won't load.
