# 0112. Persistence and Keychain writes

Area: performance

## Load the server registry from Keychain once

`ServerRegistry` is a process-wide, thread-safe registry of configured servers plus which one is active, persisted as a JSON blob in the Keychain because the server URL is a credential (#15). Like `CustomHeaderStore`, it loads the blob once at init into a lock-guarded in-memory snapshot; reads come from the snapshot, with no synchronous `securityd` IPC on every property access, and mutations update the snapshot and write through to the Keychain under the same lock. `AuthManager` owns all writes: `activate(url:)` when it configures or restores a server, `forgetActiveServer()` on full sign-out. Per-server identity is seeded from the global identity defaults on first insert only, so later per-server edits (#17) survive relaunch.

Lives in: `HermesMobile/Models/ServerAccount.swift`

## Skip redundant Keychain writes when re-activating the active server

For an already registered server, `ServerRegistry.activate(url:)` flips the active selection and writes through only when it actually changes. The launch path (`restoreSavedServer` calling `activate` for the already-active server) would otherwise do a redundant synchronous Keychain write every start.

Lives in: `HermesMobile/Models/ServerAccount.swift`

## Defer custom header Keychain writes until the editor closes

The Connection Headers editor live-refreshes the network clients on every edit (`updateCustomHeaders(_:persist: false)`, cheap and in-memory only) but defers the slow Keychain write until the editor is dismissed, so typing never stutters. `onDisappear` doesn't fire when the app is backgrounded or terminated mid-edit, so it also flushes to the Keychain when the scene leaves `.active`.

Lives in: `HermesMobile/Features/Settings/WebuiServerSettings.swift`

## Rewrite unchanged cache rows at most hourly

`CachedMessage.refresh` upserts a message into an existing row during a window write. A row that already holds exactly this message is not rewritten; only its `cachedAt`/`expiresAt` move forward, and at most once per `CachePolicy.rowRefreshInterval` (one hour). Recaching a 50-300 row window then dirties only the rows that changed, while LRU eviction and the TTL stay roughly right.

Lives in: `HermesMobile/Persistence/CachedMessage.swift`
