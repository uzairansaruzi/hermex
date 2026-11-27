# 0023. Composer layout, motion, and focus

Area: chat-composer

## Keep the composer text view mounted in pill mode

In collapsed (pill) mode `ComposerTextInputView` shows a single truncated line that focuses the editor on tap, while the real `UITextView` stays in the hierarchy, invisible. Focus and the draft survive the pill-to-card morph without recreating the editor.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`

## Open the composer card with the keyboard, not with focus

`ChatComposerView.isCardOpen` follows keyboard visibility rather than text focus. Focus flips while UIKit takes first responder, which stalls the main thread, so a SwiftUI animation started then jumps while the keyboard, animated on the render server, keeps moving smoothly. `cardFallback` opens the card when no keyboard answers focus, such as with a hardware keyboard.

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`

## Animate the composer morph from isExpanded with the keyboard curve

Focus flips arrive from UIKit outside any `withAnimation`, so `ChatComposerView` attaches `.animation(_:value: isExpanded)` itself. Expanding uses `ChatMotion.keyboard`, so the card morph and the toolbar row's insertion move as one with the keyboard; collapsing uses `ChatMotion.composerChrome`.

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`

## Do not wrap the composer in a GlassEffectContainer

`ChatComposerView.composerWithLifecycle` has no `GlassEffectContainer` around the composer. On device, after the card collapsed with a send, the container kept taking taps where the card had been, above the pill, and the scroll-to-bottom arrow there stopped working.

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`

## Keep the composer surface glass non-interactive

`ChatComposerSurfaceStyle`, shared by the chat and bot composers, draws plain glass, not interactive glass. On an iPad with a trackpad, the pointer stays over the pill after the click that focuses it. In #1650's recording the pill then held its shape, vanished, and the card appeared at once, while the same morph under touch, where the finger lifts, ran smoothly. Plain glass has no hover state to hold. The composer's buttons keep their own interactive glass.

Lives in: `HermesMobile/Features/Chat/ChatComposerPresentation.swift`

## Keep a solid canvas behind the composer toolbar row

The expanded composer's toolbar row sits on a solid `Color(.appCanvas)` background while the card above stays glass on purpose. Transcript text scrolling under the row made the pills unreadable. The background bleeds up into the gap under the card and down past the keyboard gap and the bottom safe area, so no strip of transcript shows around the row.

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`

## Defer composer focus until a navigation transition finishes

UIKit re-promotes the last editor while a navigation pop is still animating, before SwiftUI's keyboard safe area can follow, which leaves the composer behind the keyboard (#810). `ComposerChipTextView.becomeFirstResponder` defers focus until the owning view controller's `transitionCoordinator` finishes. UIKit's own restoration can re-request focus after a bound blur in the same pop (#831), so cancelling the pending focus cannot guarantee the blur wins; `wantsDeferredFocus` reads the owner's current focus intent as the deferred focus lands and can veto it.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`

## Drop composer focus while a workspace sheet is up

Git, turn-diff, and file-reference sheets open from the chat rather than the composer, so the composer reads their transition as navigation and keeps its focus intent. A still-focused composer would then take the keyboard back over a field on the sheet, such as Comment…'s. While `presentsWorkspaceSheet` is set, `ChatView` saves and clears `composerIsFocused` and restores it afterwards.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Apply Chat settings changes after the sheet closes

A change made in Chat settings can raise an alert from `ChatView`, and SwiftUI cannot present that alert over the open sheet. `ChatComposerView.chatSettingsSheet` offers the same controls and gates as the new-chat row plus the context details, and queues every change in `afterChatSettingsDismiss`, which runs only once the sheet has closed.

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`
