# Multi-server state isolation

Which app state is **per-server** versus intentionally **global**, where each
lives, and which tests guard the isolation. Almost all isolation holds by
construction through the server-keyed view tree and cache keys described below;
"Clear Offline Cache" is explicitly scoped to the active server.

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
| Push notification preferences | Server-scoped shared Keychain pairing (`PushPairing.preferences`) | Replies, subagent mute, and previews apply to this device for that server. Every relay registration sends its confirmed choices, including after token rotation. Settings → Interaction → Notifications separates these from the global local-alert and Live Activity excerpt preferences. |
| Auth cookies | `HTTPCookieStorage` (shared jar) | Cleared/queried per active server URL (#16). Same-host/different-port servers still share the jar — documented #16 limitation. |
| Custom request headers | Keychain, per-server-scoped keys (#16) | `CustomHeaderStore` is hydrated for the active server; SSE + requests source headers from the active store. |
| Display name / initials / **Header Logo Color** | `ServerAccount` in the Keychain registry blob (`Models/ServerAccount.swift`) | Per-server. The **active** server's identity is mirrored into the global `@AppStorage` keys (`SessionIdentitySettings.*`, `HeaderLogoColor.storageKey`) by `ServerRegistry.mirrorIdentityToDefaults`, on activate / set-active / identity-edit / remove — **never on first insert**, so first-run/single-server behavior is unchanged. Consumers (session-list avatar, header logo tint, New Chat / Send primary-action tint) read the mirrored global keys and therefore follow the active server automatically. |
| Offline session/message cache | SwiftData (`CachedSession`, `CachedMessage`) | Keyed by `serverURLString` (the active server URL's `absoluteString`) on the unique `cacheKey` and on every read/write predicate. See below. |
| Session unread marks | UserDefaults (`SessionUnreadStore`) | Per-server dictionary under `session-inbox-seen.<server absoluteString>`, with session IDs as keys and server `lastMessageAt` timestamps as values. A successful list load seeds new rows and prunes absent sessions; sign-out or server removal drops that server's dictionary. |
| Default model / profile | Server defaults are not persisted locally; unfinished new-chat choices can be | Settings re-fetches defaults from the **active** server. A non-empty new-chat draft may also retain that server's effective composer choices in `ChatDraftStore`, keyed by server URL plus `newChat`; removing the server discards those records. Without a saved draft, new sessions use the server's current defaults. |
| Active project / session selection | View-local `@State` only | Not persisted. Destroyed and rebuilt on switch via `.id(server)`. |
| Browsed Kanban Board | UserDefaults, per-server key (`KanbanBoardPreference.key(for:)` = `kanban.selectedBoard|<server absoluteString>`) | Per-server since #259: `KanbanFeatureState` restores the last locally browsed Board on load after validating it against the server's fresh Board list, and drops a stale slug silently. Local browsing never calls the server's switch endpoint. Tested in `KanbanFeatureStateTests` (`testBrowsedBoardIsRestoredForTheSameServerAndIsolatedFromOthers`). |
| "Show CLI sessions" toggle | UserDefaults, per-server key (`SessionRowDisplaySettings.showCliSessionsKey(for:)` = `sessionRow.showCliSessions|<server absoluteString>`) | Per-server since #19: the toggle mirrors the server's own `show_cli_sessions` setting (adopted on Settings load, written back via `POST /api/settings`), so an adopted value on one server cannot leak to another. Reads fall back to the pre-#19 global key as a migration seed, then to shown-by-default. Tested in `CliSessionsSyncModelTests`. |
| Chat attachment thumbnails | In-memory `AttachmentImageCache` (process-wide) | Keyed by `AttachmentImageCacheKey(namespace, path)` where `namespace` is `server.absoluteString|session`, matching `TranscriptMediaImageCache`. The cache survives `.id(server)` teardown, so the key—not view identity—is the isolation. Callers cannot default to an empty namespace. Tested in `TranscriptMediaParserTests.testAttachmentImageCacheKeySeparatesSamePathAcrossServersAndSessions`. |

### Offline cache keying (`Persistence/CacheStore.swift`)

- `CachedSession.cacheKey = "\(serverURLString)|session|\(sessionID)"`;
  `CachedMessage.cacheKey` additionally includes the message + sort index.
- **Reads** (`cachedSessions`, `cachedMessages`) filter on
  `serverURLString == <active>` (and `sessionID` for messages).
- **Writes** (`cacheSessions`, `cacheSession`, `cacheMessages`) insert with
  `serverURLString` and run their stale-row cleanup under a `serverURLString`-
  scoped `FetchDescriptor`, so re-caching one server **cannot** delete another
  server's rows.
- TTL expiry (a store-side `delete(model:where:)`) and the 5,000-message
  overflow eviction (counted with `fetchCount` first), both run by
  `saveAndTrim`, are intentionally **global** cache-health policies — a shared
  on-device budget across all servers, not a per-server leak.
- All call sites pass the active `server` URL: `SessionListViewModel` and
  `ChatViewModel`.

## Global (intentionally shared) state

These are app-wide preferences, stored as plain `@AppStorage` (see the block at
the top of `Features/Settings/SettingsView.swift`). They are deliberately **not**
per-server:

- App theme (`AppTheme`)
- Haptics (`AppHaptics`)
- Response-completion notifications + permission flag (`ResponseCompletionNotifications`). A server with a stored push pairing suppresses local completion banners on both chat completion and cold-launch reconciliation; disabling its pairing restores this global preference without affecting other servers.
- Live Activity response-excerpt privacy (`AgentRunLiveActivityPrivacy`)
- Session-row display toggles (`SessionRowDisplaySettings`: message count, workspace, cron — the CLI toggle moved to per-server storage in #19, see the per-server table above)
- Sidebar disclosure state (`sessionSidebar.profilesAreExpanded` / `projectsAreExpanded`)
- Chat transcript display toggles (`ChatTranscriptDisplaySettings`: thinking/tool cards, attachment paths, timestamps, code-block wrap)
- Streamed-text animation (`StreamedTextAnimationSettings`)
- Streaming send behavior (`StreamingSendBehavior`)
- Bot quick replies (`BotQuickReplyStore`): the user's own text, the same chips for every server, connection and Profile
- Adaptive Glass preference (`adaptiveGlass.isEnabled`)
- **Primary-action tint *toggle*** (`PrimaryActionTintSettings.isEnabledKey`) — the
  on/off behavior is global; only the *color* it applies (Header Logo Color) is
  per-server.

`APIClient`'s HTTP sessions (`APIClient.sharedSession` and
`sharedPublicMediaSession`) are also process-wide and outlive server switches,
so a newly opened chat reuses warm connections (#688). They hold nothing
server-specific: connections pool per host, auth cookies live in the shared jar
(scoped as in the table above), custom headers are applied per request, and the
#277 cross-origin redirect guard is a per-task delegate bound to each client's
server. Never invalidate these sessions or give them a session delegate.
`CrossOriginRedirectHeaderTests` covers the sharing and the per-task guard.

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

## Where isolation is tested

| Dimension | Tests |
| --- | --- |
| Session cache read isolation | `CacheStoreTests.testCachedSessionsReturnsOnlyUnexpiredVisibleSessionsForServer` |
| Message cache read isolation (same sessionID, two servers) | `CacheStoreTests.testCachedMessagesAreScopedToTheirServerForTheSameSessionID` |
| Cross-server stale-deletion guard (sessions) | `CacheStoreTests.testCacheSessionsForOneServerDoesNotDeleteAnotherServersStaleSessions` |
| Cross-server stale-deletion guard (messages) | `CacheStoreTests.testCacheMessagesForOneServerDoesNotDeleteAnotherServersMessages` |
| Session unread scoping and removal | `SessionRowAttentionStateTests.testUnreadStoreScopesEqualSessionIDsByServer`, `AuthManagerStateTests.testSignOutAndServerRemovalClearOnlyTheirUnreadMarks` |
| Scoped clear-cache (one server cleared, other intact) | `CacheStoreTests.testClearCacheRemovesOnlyTheGivenServersData` |
| Per-server identity (no re-seed, mirror on activate/set-active/update/remove) | `ServerRegistryTests` (`testActivateDoesNotReseedIdentityWhenServerAlreadyExists`, `testSetActiveMirrorsTheNewActiveIdentityToDefaults`, `testUpdateMirrorsToDefaultsOnlyWhenServerIsActive`, `testReactivatingAnExistingServerMirrorsItsIdentityToDefaults`, `testActivatingANewServerDoesNotMirrorIntoEmptyDefaults`), `AuthManagerStateTests.testUpdateServerIdentityPersistsAndMirrorsTheActiveServer` |
| Per-server browsed Kanban Board | `KanbanFeatureStateTests.testBrowsedBoardIsRestoredForTheSameServerAndIsolatedFromOthers`, `testStaleSavedBoardIsDroppedAndColdStartFallsBackToCurrentBoard` |
| Per-server custom headers | `CustomHeaderInjectionTests` (`testSSEStreamSourcesHeadersFromActiveServerStore`, `testLaunchMigratesLegacyGlobalHeadersToActiveServerScope`), `AuthManagerStateTests` (`testSignOutLeavesOtherServerHeadersAndRegistryIntact`, `testAddServerFailureKeepsActiveServerAndItsHeaders`) |
| Per-server cookies | `AuthManagerStateTests` (`testSignOutClearsOnlyActiveServerCookies`, `testRemoveNonActiveServerClearsOnlyItsCookies`, `testUnauthorizedClearsOnlyActiveServerCookies`) |
| Default model/profile | No persisted state to leak (server-fresh per active server); covered by the switch mechanism + `9.3` Settings tests. |
| Chat attachment thumbnail cache (same path, two servers/sessions) | `TranscriptMediaParserTests.testAttachmentImageCacheKeySeparatesSamePathAcrossServersAndSessions` |

## Bot connection and drafts

Bot Mode has a separate per-server Keychain connection and ephemeral cookie jar.
Bot drafts use configured server + connection UUID + Profile, independently of
webui session IDs. Recent Bot/room transcript value snapshots stay in a bounded memory cache keyed by
configured server hash + connection UUID + bot/room. New screens can display them
before reconnecting, but never restore runtime identity or action permissions.
The same removal/clear paths invalidate recent snapshots and their writer tokens.
The bounded local search cache uses a hash
of the configured server URL plus connection UUID and Profile, and is cleared
with that server’s offline cache or connection removal. See [Bot Mode](bots.md) for
identity, removal and recovery rules. `BotDraftTests` covers disk persistence,
connection/server removal and compatibility with existing webui records.
