# Theming — agent notes

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
