# PR #29 Android Port — Audit Findings

**Branch:** `android-port` | **Date:** 2026-07-03 | **Auditor:** Claude (Phase 2 systematic sweep)
**Scope:** 7 dimensions, 40+ checks against iOS reference (`HermesMobile/`) and `PROJECT_SPEC.md` section 6
**Status:** Phase 4 complete — all P0, P1, P2, P3 findings fixed with tests. See Fix Status column below.

## Severity Key

| Level | Meaning |
|-------|---------|
| **P0** | Feature completely broken / unreachable — user-visible hang or crash |
| **P1** | Correctness bug — wrong behavior under realistic conditions |
| **P2** | Robustness / parity gap — degraded UX or missing iOS parity |
| **P3** | Hygiene / cosmetic — dead code, inconsistency, maintainability |

## Recurring Review-Round Classes

PR #29 reviews (rounds 1-5) repeatedly flagged these subsystems. This audit systematically covers each:

| Class | Rounds flagged | Audit dimension | Findings |
|-------|---------------|-----------------|----------|
| SSE/streaming lifecycle | 2, 3, 5 | A | A1-A11 (7 findings) |
| Auth/cookie/session | 1, 3, 4, 5 | B | B1, B4, B5 (3 findings) |
| Navigation/config-change | 4, 5 | C | C2, C4 (2 findings) |
| Manifest/backup/perms | 3 | D | All PASS |
| URLs/endpoints | 2, 4 | E | E1, E3 (2 findings) |
| Offline cache | 3 | F | F1, F3, F4 (3 findings) |
| Test health | 2, 4 | G | G2, G4 (2 findings) |

---

## Findings

### P0 — Feature Broken

| ID | File:Line | Defect | Fix | Test |
|----|-----------|--------|-----|------|
| **A10** | `SseClient.kt:73-98`, `SSEEvent.kt:46-59` | SSE event names for approval/clarification are `"approval_pending"`/`"clarification_pending"` but iOS (the working reference client) uses `"approval"`/`"clarify"`. Payload shape also mismatches: Android expects flat `{id, session_id, type}` but the real wire format is nested `{pending: {clarify_id, question, choices_offered}, pending_count}`. Every real approval/clarification event hits `else -> null` and is silently discarded. The entire approval-gate and clarification-question UI (`ChatViewModel.kt:902-928`, `ChatUiState.approvalPending/clarificationPending`) is **unreachable** — the agent appears to hang indefinitely when it needs user input. | Align event type strings to `"approval"`/`"clarify"` (matching iOS `SSEClient.swift:214,220`). Rewrite `ApprovalPendingResponse`/`ClarificationPendingResponse` models to match nested wire format (`pending.clarify_id`, `pending.question`, `pending.choices_offered`, `pending_count`). Add `"initial"` event type handling. | MockWebServer SSE test with real wire payloads for `approval`, `clarify`, `initial` events; verify `ChatViewModel` state transitions. |

### P1 — Correctness

| ID | File:Line | Defect | Fix | Test |
|----|-----------|--------|-----|------|
| **A2** | `SseClient.kt:83-97` | `parseEvent` blanket `catch (_: Exception) { null }` swallows malformed `done` payload — event vanishes silently. iOS treats malformed `done` as a transport error triggering reconnect. UI stalls waiting for finalization that never comes. | Catch only `SerializationException`; on decode failure emit `SSEEvent.Error("Malformed done event")` instead of returning null. | SseClientTest: malformed `done` JSON produces Error event. |
| **A3** | `ChatViewModel.kt:437-466` | `handleStreamError` launches its own coroutine outside `streamingJob`. `stopStreaming()` cancels only `streamingJob` — if user taps Stop while a status poll is in-flight and status returns `active==true`, `startStream()` resurrects the cancelled stream. No generation/epoch counter exists (iOS has `runGeneration` guarding every post-await resumption). | Add `private var streamGeneration = 0L` incremented in `stopStreaming()` and `startStream()`. Every post-await resumption in `handleStreamError` checks `currentGeneration == myGeneration` before acting. | Coroutines-test: stop during status poll does not restart stream. |
| **A5** | `ApiClient.kt:173-175`, `ChatViewModel.kt:744-756` | No server-driven replay (`?replay=1&after_seq=N`). Reattach dedup uses fuzzy string-overlap (`deduplicateToken`) which can mis-dedup legitimate repeated phrases or disarm too early, causing content duplication or truncation after reconnect. iOS uses `chatStreamURL(streamID:replayAfterSeq:)` with server-side sequence numbers. | Add `after_seq` query parameter to `streamUrl()`. Track `lastEventSeq` from SSE `id:` field. Pass to reattach URL. Remove or demote `deduplicateToken` to a secondary guard. | Unit test: streamUrl includes after_seq when provided. |
| **A6** | `ChatViewModel.kt:179-184, 583-604` | `onCleared()` calls `stopStreaming()` → `chatCancel(streamId)`, killing the server-side agent run when the user navigates away. iOS keeps the run alive and notifies via Live Activity / push when done. Android's `notifyResponseComplete` is effectively dead code for the nav-away case. | **Product decision required** — see below. | Depends on chosen approach. |
| **B1** | `AppModule.kt:39-49` | `CookieJar.saveFromResponse` does `cookieStore[url.host] = cookies` — replaces the entire cookie list. A response setting only one cookie (e.g., CSRF token) silently wipes the session cookie, causing involuntary logout on the next request. | Merge by cookie name: `getOrPut(host, ::mutableMapOf)` then `for (c in cookies) map[c.name] = c`. Honor expired cookies by removing them. | MockWebServer test: second response sets a different cookie; session cookie survives. |

### P2 — Robustness / Parity Gap

| ID | File:Line | Defect | Fix | Test |
|----|-----------|--------|-----|------|
| **A1** | `SseClient.kt:29,42` | Channel is `BUFFERED` (capacity 64) with `trySend` — result discarded. Under fast token bursts with stalled collector, tokens silently dropped. | Change to `Channel.UNLIMITED` (SSE token volume is bounded per-turn) or check `ChannelResult` and emit `SSEEvent.Error` on failure. | Stress test with fast-emitting mock SSE source and slow collector. |
| **A4** | `ChatViewModel.kt:551-581` | No idempotency guard on `finalizeMessage()`/`finishStream()`. `Done` on live SSE + concurrent `handleStreamError` can double-fire `notifyResponseComplete` and redundant `loadMessages()`. | Add `private var hasFinalized = false` flag, checked and set in both paths. Reset in `startStream()`. | Test: two concurrent finalize calls result in single notification. |
| **A9** | `ChatViewModel.kt` (absent) | No stale-stream watchdog. Only OkHttp `readTimeout(120s)` catches silence. iOS proactively detects silence at 5/18/25s intervals via `recoverStaleStreamIfNeeded`. | Add a `lastTokenTime` timestamp, checked by a periodic coroutine (every 15s). If exceeded, trigger `handleStreamError`. | Unit test with injected clock: silence > threshold triggers recovery. |
| **A11/G2** | `SseClientTest.kt` | Only 3 of 13+ SSE event types tested (`token`, `reasoning`, `tool`/`tool_complete`). Missing: `title`, `done`, `approval`, `clarify`, `interim_assistant`, `stream_end`, `cancel`, `error`, unknown type, malformed JSON, heartbeat. | Add table-driven tests for all event types. | Self-documenting: test IS the fix. |
| **B4** | `ApiClient.kt:234-257` | `okHttpClient.newCall(request).execute()` not wrapped — raw `IOException` escapes instead of `ApiException.Network`. The `ApiException.Network` catch branch in `OnboardingScreen.kt:223` is dead code. | Wrap `execute()` in `try { ... } catch (e: IOException) { throw ApiException.Network(e) }`. | MockWebServer: disconnect → ApiException.Network thrown. |
| **B5** | `NavHost.kt:49-65` | No auto-redirect to onboarding when `authState` flips to `LOGGED_OUT` while user is on a non-onboarding screen. User sees an error banner and must manually tap "Reconnect". | Add `LaunchedEffect(authState)` that navigates to onboarding (clearing back stack) when `authState != LOGGED_IN` and current destination is not onboarding. | Manual/instrumentation test: auth expiry mid-session redirects. |
| **C2** | `NavHost.kt:40` | `Routes.fileBrowser(sessionId)` uses raw string interpolation without `Uri.encode()`, unlike `Routes.chat()` three lines above. Session IDs containing `/`, `?`, `#` break route matching. | Add `Uri.encode(sessionId)` in `fileBrowser()`. | Unit test: sessionId with special chars round-trips correctly. |
| **C4** | `NavHost.kt:49-56, 83-86` | `startDestination` derived live from `authState`. If `markLoggedOut()` fires transiently (e.g., authenticator rejects login), Navigation-Compose resets the back stack, discarding the active chat screen with no transition gate. | Decouple start destination from live auth state. Use a stable initial value; handle auth transitions via explicit `LaunchedEffect` navigation only. | Manual test: transient LOGGED_OUT during chat does not flash onboarding. |
| **F1** | `SessionListViewModel.kt:432-438` | `shouldUseCache` only matches `IOException`/message substrings. Transient HTTP errors (408, 502, 503, 504) that iOS's `CacheFallbackPolicy` explicitly allows do NOT trigger cache fallback. | Extract `CacheFallbackPolicy` object with typed matching: `IOException` OR `ApiException.Http` with status in `{408, 502, 503, 504}`. Never 401/4xx. | Unit test: each status code → correct boolean. |
| **F3** | `ChatViewModel.kt:190-225` | `loadMessages` has no offline cache fallback. `MessageDao`/`CachedMessage` exist in `AppDatabase.kt` with `getMessages`/`insertMessages`/`clearSession`/`evictOlderThan` but are referenced nowhere — completely dead/unwired. iOS has `CacheFallbackPolicy`-gated cache serving in chat. | Wire `MessageDao` into `ChatViewModel`. On successful load, cache messages. On transient failure, serve cached messages with a "showing cached" indicator. | Unit test: loadMessages with IOException serves cached data. |

### P3 — Hygiene / Cosmetic

| ID | File:Line | Defect | Fix | Test |
|----|-----------|--------|-----|------|
| **A8** | `ChatViewModel.kt:362-370` | Dead expression: `response.streamId?.let { null } ?: "..."` — `streamId` already proven null on line 363, so `?.let { null }` always evaluates to null. Correct by accident but confusing. | Replace with `sendErrorMessage = "The server did not return a stream ID."`. | N/A (dead code removal). |
| **B6** | `build.gradle.kts:137` | `implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")` declared but never wired. Dead dependency; risk if future contributor adds it unconditionally in release. | Remove the dependency or gate behind `debugImplementation`. | Build still compiles. |
| **E1** | `ServerUrls.kt:16-26` | `normalizeServerUrl` doesn't bracket bare IPv6 literal hosts (e.g., `::1` → `https://::1`, invalid URL). | Detect IPv6 and wrap in brackets: `https://[::1]`. | ServerUrlsTest: IPv6 input produces valid URL. |
| **E3** | `ApiClient.kt:104, 173-175` | `chatCancel` and `streamUrl` build `?stream_id=$streamId` by string interpolation instead of `HttpUrl.Builder.addQueryParameter`. Low risk (server-generated IDs) but inconsistent with the rest of the file. | Use `HttpUrl.Builder.addQueryParameter("stream_id", streamId)`. | Existing tests still pass. |
| **F4** | `SessionListViewModel.kt:432` | `shouldUseCache` is a private instance method embedded in the ViewModel — cannot be unit-tested independently. | Extract to a top-level `CacheFallbackPolicy` object (pairs with F1 fix). | Unit test on the extracted function. |
| **G4** | `ApiClientTest.kt:55-95` | `ServerUrlsTest` missing edge cases: path-suffix concatenation (`host:8080/hermes`), IPv6 literals, uppercase schemes. | Add parameterized tests for these cases. | Self-documenting. |

### Informational (no fix required)

| ID | Note |
|----|------|
| **B3** | Blanket-catch sweep: 20+ sites classified. Most are swallow-OK (set error message). Two "needs-logging" sites: `TasksScreen.kt:73` and `SkillsScreen.kt:81` (fully silent on fetch failure). |
| **D1** | DISPROVEN — EncryptedSharedPreferences stores Tink keysets as keys within the SAME prefs file, not a separate file. Excluding only `hermex_auth_prefs.xml` from backup is sufficient and correct. |
| **E4** | Endpoint constants declared but with no `ApiClient` method: `SESSION_USAGE`, `PROJECTS_CREATE`, `UPLOAD`, `UPLOAD_EXTRACT`, `WORKSPACES_SUGGEST`, `FILE_RAW`, `PERSONALITY_SET`. These are spec endpoints not yet implemented — backlog, not bugs. |
| **A10-sub** | `"pending_steer_leftover"` (iOS `SSEClient.swift:226-233`) has no Android counterpart. `SSEEvent.SteerLeftover` exists in the Kotlin model but `parseEvent` never produces it — dead code. Folded into A10 fix. |

### Passed Checks (27)

A7 (status response completeness), C1 (no ViewModel NavController capture), C3 (widget PendingIntent immutability), C5 (ChatScreen effect resubscription on rotation), D1 (backup rules sufficient), D2 (RECORD_AUDIO runtime request flow), D3 (cleartext scope matches interceptor), D4 (exported components audit), D5 (no auth material in Room DB), E2 (HTTP fallback URL persisted correctly), E5 (ChatSteerRequest field names match contract), F2 (401 during list load — no stale cache served), G1 (stale git test assertions removed), G3 (Phase 1 test files present).

---

## Product Decision Required

### A6: onCleared → chatCancel kills server-side run on nav-away

**Current behavior (Android):** Pressing Back from chat screen calls `onCleared()` → `stopStreaming()` → `chatCancel(streamId)`, killing the in-flight agent run server-side.

**iOS behavior:** `deinit` only cancels local UI tasks — never calls `/api/chat/cancel`. The server run continues and completes, with a Live Activity / push notification reporting completion.

**Options:**
1. **Match iOS (recommended):** Remove `chatCancel` from `stopStreaming` when called via `onCleared`. Only cancel on explicit user action (Stop button). Enables future notification-on-completion feature.
2. **Keep Android behavior:** Cancel on nav-away. Simpler, but the server run is wasted and Android has no notification-on-completion path yet.
3. **Defer:** Flag as a known parity gap; don't change behavior now. Add TODO for when push notifications are implemented.

---

## Fix Priority Order

### Cluster 1: SSE correctness (A10, A2, A3, A4, A11)
A10 is the only P0 — fix first. A2/A3/A4 are tightly coupled streaming lifecycle fixes. A11 (test coverage) validates the cluster.

### Cluster 2: Network error typing + cache policy (B4, F1, F4, F3)
B4 (ApiException.Network) is a prerequisite for F1 (CacheFallbackPolicy). F4 extracts the policy for testing. F3 wires the dead Room cache.

### Cluster 3: Cookie jar + auth UX (B1, B5, C4)
B1 (cookie merge) and B5 (auto-redirect on auth loss) are auth-adjacent. C4 (startDestination flip) is triggered by the same auth state transition.

### Cluster 4: Navigation hygiene (C2, A6)
C2 (URI-encode fileBrowser route) is trivial. A6 depends on product decision.

### Cluster 5: URL/endpoint hygiene (E1, E3, G4)
Low-risk cleanups grouped together.

### Cluster 6: Streaming robustness (A1, A5, A9)
A1 (channel capacity) is a quick fix. A5 (server-driven replay) and A9 (watchdog) are larger parity gaps — may defer to follow-up.

### Cluster 7: Dead code / dependency cleanup (A8, B6, B3-logging)
Pure hygiene, batched in one commit.
