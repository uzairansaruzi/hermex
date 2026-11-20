# 0139. App lock

Area: settings-onboarding-auth

## Make the app lock a cover, not a gate

`AppLock` (#885) is one Settings toggle, off by default, app-wide rather than per server, so it lives in `UserDefaults`; `AppLockSceneDelegate` feeds it the scene's phases and shows its window whenever `showsLockWindow` is true. With the lock on, a cold launch is locked, and so is becoming active more than `relockDelay` after entering the background; that time runs on `ContinuousClock`, so the phone sleeping counts and changing the clock doesn't, and going inactive and back (Control Center, the Face ID sheet) never locks. While on, the scene is covered whenever it isn't active, so the app switcher snapshot and Control Center show the app icon instead of a chat; the lock's own Face ID or passcode sheet doesn't cover. When locked it prompts once by itself as the scene becomes active, and after a cancel or failure only the Unlock button tries again. Turning it on or off needs a successful authentication, it can't be turned on without a device passcode, and if the passcode is removed while it's on the lock says so and Continue turns it off, so it never opens silently. It is a cover, not a gate: the app stays mounted behind it, so streams, Live Activities and reconnects keep running and deep links, App Intents, notification taps and share handoffs land behind it; while locked, keyboard commands are off, "New Chat with Voice" holds dictation, and push presence reports no chat on screen. It can't cover other processes: notifications, Live Activities and the share sheet still show their content, as the Settings footer says.

Lives in: `HermesMobile/Auth/AppLock.swift`

## Use a fresh LAContext per authentication

`DeviceAppLockAuthenticator` wraps `LocalAuthentication` with a new `LAContext` for every call, so one attempt's result never carries into the next.

Lives in: `HermesMobile/Auth/AppLock.swift`

## Show the app lock in its own window above alerts

`AppLockSceneDelegate` puts `AppLock`'s window on the app's one window scene (#885). `PushAppDelegate` names this class in the scene configuration; SwiftUI still creates and owns the app window and forwards the scene's lifecycle calls here. The window sits above alerts, so it also covers sheets, full-screen covers, alerts and menus, which an overlay on `ContentView` would sit under. It appears in the same call that reports the phase, before the first frame of a cold launch and before the app switcher snapshot, with no animation.

Lives in: `HermesMobile/Auth/AppLockWindow.swift`

## Resign text input behind the app lock

The keyboard sits above every window, so when the lock window appears `AppLockSceneDelegate.update` resigns the current first responder (`UIResponder.currentFirstResponder`) and gives it back when the lock goes. An input that takes the keyboard after the lock appeared, such as the composer of a new chat an App Intent or share opened, is resigned the same way by `textInputDidBeginEditing` until the lock goes, so no keys (⌘↩ included) reach the hidden app.

Lives in: `HermesMobile/Auth/AppLockWindow.swift`

## Defer resigning first responder out of the begin-editing callback

`AppLockSceneDelegate.textInputDidBeginEditing` resigns the newly focused input on the next main-actor turn in a `Task`, because resigning inside UIKit's begin-editing call leaves UIKit half done.

Lives in: `HermesMobile/Auth/AppLockWindow.swift`

## Re-key the app lock window on cold launch

After showing the lock window, `AppLockSceneDelegate.update` calls `makeKey()` again whenever the window isn't key, because on a cold launch SwiftUI may make its own app window key after the lock window appears.

Lives in: `HermesMobile/Auth/AppLockWindow.swift`
