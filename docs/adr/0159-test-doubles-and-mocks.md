# 0159. Test doubles and mocks

Area: testing

## Run MockURLProtocol handlers on a concurrent queue

`MockURLProtocol` runs its request handlers on its own concurrent `DispatchQueue` rather than on the caller's thread. URLSession drives every protocol instance from a single loading thread, so a handler that waits on that thread stalls every other in-flight request, and no test could express a race between two of them.

Lives in: `HermesMobileTests/APIClientTests.swift`

## Default test view models to a spy Live Activity manager

The test `makeViewModel` helper defaults `liveActivityManager` to `SpyChatLiveActivityManager`, so unit tests never drive ActivityKit. ActivityKit's synchronous reads can hold the main actor for seconds and starve a test's waits.

Lives in: `HermesMobileTests/ChatViewModelSendTests.swift`

## Keep Screen tests off the real notification center

`ScreenIdleNotification` is the local notice that a takeover ran out while the app was in the background; it says so and asks nothing, since control goes back when the app next runs. It is sent only if notifications are already allowed, so a Screen never raises the permission prompt. Tests use its `.off` case to stay away from the real notification center, which may stall a CI simulator for minutes on first use (#1580).

Lives in: `HermesMobile/Features/Screen/ScreenControl.swift`

## Count scripted-host reads outside the fixture lock

`TaskRunHistoryTests` counts a scripted host's reads with its own NSLock-guarded `ReadCounter`. `HermesHostFixture` runs a test's script under the fixture's own lock, so the script can't ask the fixture for its request count.

Lives in: `HermesMobileTests/TaskRunHistoryTests.swift`
