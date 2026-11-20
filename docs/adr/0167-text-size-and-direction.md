# 0167. Text size and direction

Area: ui-theming

## Make custom-font headlines semibold

In `AppFont`, `Font.custom(_:size:relativeTo:)` borrows only the Dynamic Type scaling from the text style, not its weight. A headline is semibold by nature, so a headline in a custom family is given `.semibold` explicitly.

Lives in: `HermesMobile/Config/AppFont.swift`

## Set the navigation bar font proxy from the app init

Navigation bar titles are UIKit and read no SwiftUI font, so `AppBarFont` sets the `UINavigationBar` appearance proxy and updates bars already on screen. `AppBarFont.applyAtLaunch()` is called from the app's `init`, because SwiftUI makes its first bar before a scene delegate hears about the scene. Nil traits follow the iPhone's text size.

Lives in: `HermesMobile/Config/AppFont.swift`

## Resolve UIKit preferred fonts at the app Text Size

`UIFont.preferredFont(forTextStyle:at:)` returns the style's font at a given `DynamicTypeSize`. Plain `preferredFont(forTextStyle:)` reads the iPhone's setting, which misses the in-app `AppTextSize`.

Lives in: `HermesMobile/Config/AppTheme.swift`

## Use a plain HStack instead of Label for tool rows

`HermesDelegatedWorkView`'s tool row is a plain `HStack` rather than a SwiftUI `Label`, because `Label` truncates beside free space at accessibility sizes.

Lives in: `HermesMobile/Features/Chat/HermesDelegatedWorkView.swift`

## Default RTL chat layout from the preferred language

`isRightToLeftLanguage` asks whether the user's primary preferred language reads right to left (Arabic, Hebrew, Persian, Urdu, …). It reads the device language preference, not the app's resolved UI direction, so it still fires for an RTL user while Hermex isn't translated into their language: the app text falls back to English (LTR), but the chat layout should not. Only the primary preference counts, so a German-first user with Arabic further down the list stays LTR. `preferredLanguages` is injectable for tests.

Lives in: `HermesMobile/Config/AppTheme.swift`

## Isolate URLs and paths with bidi marks in RTL strings

`BotAddressError.path` wraps the path in a first-strong isolate (U+2068/U+2069) so it lays out left to right on its own and its leading "/" stays in front of it inside right-to-left translations. `BotConnectionView` and `AddServerView` append a left-to-right mark (U+200E) to the "Will connect to" address preview, so a URL ending in a neutral character, such as an IPv6 literal's "]", stays one left-to-right run inside right-to-left text.

Lives in: `HermesMobile/Features/Bots/BotConnection.swift`, `HermesMobile/Features/Bots/BotConnectionView.swift`, `HermesMobile/Features/Settings/AddServerView.swift`
