# Multi-server state isolation audit (I-039 / issue #18)

This is the audit deliverable for issue #18 (I-039d). It documents which app
state is **per-server** versus intentionally **global**, where each lives, and
which tests guard the isolation. It reflects the state of the multi-server epic
after #15 (server model), #16 (auth/cookie/header isolation), #17 (Settings
list + switcher), and #18 (cache isolation validation + scoped clear-cache).

The short version: with the #15–#17 foundation in place, **almost all isolation
already holds by construction**. Issue #18 added focused two-server tests and
the one behavioral fix that was missing — scoping "Clear Offline Cache" to the
active server.

## How a server switch works (the mechanism most isolation relies on)

`ContentView` keys the logged-in subtree on the active server URL:

```swift
case .loggedIn(let server):
    SessionListView(authManager: authManager, server: server, …)
        .id(server)   // ContentView.swift
```

`AuthManager.State.loggedIn(server: URL)` carries the active server's normalized
URL. Switching servers stays in `.loggedIn` but changes the URL, so `.id(server)`
**tears down and rebuilds the entire session/chat/settings stack** against the
new server. Every view passes that same `server: URL` down to its view model and
to `CacheStore`. Two consequences:

- All transient, view-local selection state (`@State` for selected session,
  project filter, composer pickers, etc.) is destroyed on switch — it **cannot**
  carry between servers.
- Every cache read/write is parameterised by the active `server` URL.

## Per-server state

| State | Where it lives | How it's scoped |
| --- | --- | --- |
| Auth cookies | `HTTPCookieStorage` (shared jar) | Cleared/queried per active server URL (#16). Same-host/different-port servers still share the jar — documented #16 limitation. |
| Custom request headers | Keychain, per-server-scoped keys (#16) | `CustomHeaderStore` is hydrated for the active server; SSE + requests source headers from the active store. |
| Display name / initials / **Header Logo Color** | `ServerAccount` in the Keychain registry blob (`Models/ServerAccount.swift`) | Per-server. The **active** server's identity is mirrored into the global `@AppStorage` keys (`SessionIdentitySettings.*`, `HeaderLogoColor.storageKey`) by `ServerRegistry.mirrorIdentityToDefaults`, on activate / set-active / identity-edit / remove — **never on first insert**, so first-run/single-server behavior is unchanged. Consumers (session-list avatar, header logo tint, New Chat / Send primary-action tint) read the mirrored global keys and therefore follow the active server automatically. |
| Offline session/message cache | SwiftData (`CachedSession`, `CachedMessage`) | Keyed by `serverURLString` (the active server URL's `absoluteString`) on the unique `cacheKey` and on every read/write predicate. See below. |
| Default model / profile | Not persisted locally | Held in transient `@State` in `SettingsView` and re-fetched from the **active** server's API client each time Settings opens. There is no cross-server storage to leak. New sessions use the server's current default. |
| Active project / session selection | View-local `@State` only | Not persisted. Destroyed and rebuilt on switch via `.id(server)`. |
| "Show CLI sessions" toggle | UserDefaults, per-server key (`SessionRowDisplaySettings.showCliSessionsKey(for:)` = `sessionRow.showCliSessions|<server absoluteString>`) | Per-server since #19: the toggle mirrors the server's own `show_cli_sessions` setting (adopted on Settings load, written back via `POST /api/settings`), so an adopted value on one server cannot leak to another. Reads fall back to the pre-#19 global key as a migration seed, then to shown-by-default. Tested in `CliSessionsSyncModelTests`. |

### Offline cache keying (`Persistence/CacheStore.swift`)

- `CachedSession.cacheKey = "\(serverURLString)|session|\(sessionID)"`;
  `CachedMessage.cacheKey` additionally includes the message + sort index.
- **Reads** (`cachedSessions`, `cachedMessages`) filter on
  `serverURLString == <active>` (and `sessionID` for messages).
- **Writes** (`cacheSessions`, `cacheSession`, `cacheMessages`) insert with
  `serverURLString` and run their stale-row cleanup under a `serverURLString`-
  scoped `FetchDescriptor`, so re-caching one server **cannot** delete another
  server's rows.
- TTL expiry and the 5,000-message overflow eviction (`performMaintenance`) are
  intentionally **global** cache-health policies — a shared on-device budget
  across all servers, not a per-server leak.
- All call sites pass the active `server` URL: `SessionListViewModel` and
  `ChatViewModel`.

## Global (intentionally shared) state

These are app-wide preferences, stored as plain `@AppStorage` (see the block at
the top of `Features/Settings/SettingsView.swift`). They are deliberately **not**
per-server:

- App theme (`AppTheme`)
- Haptics (`AppHaptics`)
- Response-completion notifications + permission flag (`ResponseCompletionNotifications`)
- Live Activity response-excerpt privacy (`AgentRunLiveActivityPrivacy`)
- Session-row display toggles (`SessionRowDisplaySettings`: message count, workspace, cron — the CLI toggle moved to per-server storage in #19, see the per-server table above)
- Sidebar disclosure state (`sessionSidebar.profilesAreExpanded` / `projectsAreExpanded`)
- Chat transcript display toggles (`ChatTranscriptDisplaySettings`: thinking/tool cards, attachment paths, timestamps, code-block wrap)
- Streamed-text animation (`StreamedTextAnimationSettings`)
- Streaming send behavior (`StreamingSendBehavior`)
- Adaptive Glass preference (`adaptiveGlass.isEnabled`)
- **Primary-action tint *toggle*** (`PrimaryActionTintSettings.isEnabledKey`) — the
  on/off behavior is global; only the *color* it applies (Header Logo Color) is
  per-server.

"Which server am I on" is surfaced only by the avatar + Settings (+ the #283
long-press menu) — there is no separate on-screen server label.

## Clear-cache behavior (issue #18 change)

"Clear Offline Cache" (Settings → Offline Data) is **scoped to the active
server**: `CacheStore.clearCache(for: server, in:)` deletes only that server's
cached sessions/messages. Other configured servers' offline data and the Hermes
server itself are untouched. The footnote and confirmation copy state this
explicitly, matching the implemented behavior.

Additionally, removing a server (`ServerDetailView`) purges that server's cache
via the same scoped call, so a removed server leaves **no orphaned rows**
(resolves the W2 follow-up deferred from PR #286). This is done in the Settings
view layer (which holds the SwiftData `modelContext`) rather than in
`AuthManager`, to avoid coupling auth to persistence. The purge is best-effort:
because the cache is server-keyed, a leftover row can never surface as another
server's content even if the purge fails.

`CacheStore.clearAll(in:)` (delete every server's cache) is retained as a tested
utility but is no longer wired to any user action.

## Where isolation is tested

| Dimension | Tests |
| --- | --- |
| Session cache read isolation | `CacheStoreTests.testCachedSessionsReturnsOnlyUnexpiredVisibleSessionsForServer` |
| Message cache read isolation (same sessionID, two servers) | `CacheStoreTests.testCachedMessagesAreScopedToTheirServerForTheSameSessionID` |
| Cross-server stale-deletion guard (sessions) | `CacheStoreTests.testCacheSessionsForOneServerDoesNotDeleteAnotherServersStaleSessions` |
| Cross-server stale-deletion guard (messages) | `CacheStoreTests.testCacheMessagesForOneServerDoesNotDeleteAnotherServersMessages` |
| Scoped clear-cache (one server cleared, other intact) | `CacheStoreTests.testClearCacheRemovesOnlyTheGivenServersData` |
| Per-server identity (no re-seed, mirror on activate/set-active/update/remove) | `ServerRegistryTests` (`testActivateDoesNotReseedIdentityWhenServerAlreadyExists`, `testSetActiveMirrorsTheNewActiveIdentityToDefaults`, `testUpdateMirrorsToDefaultsOnlyWhenServerIsActive`, `testReactivatingAnExistingServerMirrorsItsIdentityToDefaults`, `testActivatingANewServerDoesNotMirrorIntoEmptyDefaults`), `AuthManagerStateTests.testUpdateServerIdentityPersistsAndMirrorsTheActiveServer` |
| Per-server custom headers | `CustomHeaderInjectionTests` (`testSSEStreamSourcesHeadersFromActiveServerStore`, `testLaunchMigratesLegacyGlobalHeadersToActiveServerScope`), `AuthManagerStateTests` (`testSignOutLeavesOtherServerHeadersAndRegistryIntact`, `testAddServerFailureKeepsActiveServerAndItsHeaders`) |
| Per-server cookies | `AuthManagerStateTests` (`testSignOutClearsOnlyActiveServerCookies`, `testRemoveNonActiveServerClearsOnlyItsCookies`, `testUnauthorizedClearsOnlyActiveServerCookies`) |
| Default model/profile | No persisted state to leak (server-fresh per active server); covered by the switch mechanism + `9.3` Settings tests. |
