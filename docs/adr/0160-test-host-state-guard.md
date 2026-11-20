# 0160. Test host state guard

Area: testing

## Treat a failed Keychain snapshot as unknown, not empty

The tests run inside the app as their host, so `TestHostStateGuard` snapshots the host app's Keychain when the bundle starts and, when it finishes, deletes every current generic password and adds the snapshot back. `genericPasswords(returningData:)` reads every generic password the host app can reach, in all of its access groups, and returns nil when the read fails; `keychainItems` then stays nil and `testBundleDidFinish` leaves the Keychain alone. A failed read must never pass for an empty Keychain, or the restore would delete the simulator app's saved servers and credentials and add nothing back.

Lives in: `HermesMobileTests/TestHostStateGuard.swift`

## Restore only writable Keychain attributes

When it adds a snapshotted item back, `TestHostStateGuard` passes the item's identity plus only `restoredAttributes`: `kSecValueData`, `kSecAttrAccessible`, `kSecAttrLabel`, `kSecAttrComment`, `kSecAttrDescription` and `kSecAttrGeneric`. Read-only attributes such as creation dates would make `SecItemAdd` fail, so the snapshot cannot be re-added verbatim.

Lives in: `HermesMobileTests/TestHostStateGuard.swift`

## Warm up the software keyboard before the first hosted test

A freshly cloned CI simulator boots without the keyboard daemon. The first focus change after a text view takes focus blocks the main thread inside UIKit until `kbd` answers, which took 5–55 s on hosted runners, so no test's wait is safe while it starts. `TestHostStateGuard` calls `XCTestCase.warmUpSoftwareKeyboard()` before the first test, where no test's clock runs; later calls return at once.

Lives in: `HermesMobileTests/BotTestFixtures.swift`, `HermesMobileTests/TestHostStateGuard.swift`
