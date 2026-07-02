# Android Port Plan — Hermex for Android

Status: **proposal / planning document**. Nothing in this document is committed work;
it exists so the port can be discussed and scoped before any Android code is written.

Hermex today is a native SwiftUI iPhone app (~175 Swift files, ~50k lines across the
app, share extension, and Live Activity widget) that drives a self-hosted
[hermes-webui](https://github.com/nesquena/hermes-webui) server over REST + SSE.
The good news for a port: **all product thinking, API contracts, and UX decisions are
already made** and written down in `PROJECT_SPEC.md`. The port is an engineering
translation, not a product redesign.

---

## 1. Recommended approach: native Kotlin + Jetpack Compose, separate repo

Three realistic options were considered:

| Option | Verdict |
|---|---|
| **Native Kotlin + Jetpack Compose** | **Recommended.** Mirrors the project's core promise ("Real native UI, not a web wrapper"). Compose is the direct conceptual analog of SwiftUI, so the existing feature/view-model structure translates almost one-to-one. |
| Kotlin Multiplatform (shared networking/models, Compose UI) | Not for v1. The iOS app is finished, pure-Swift, and stable; adopting KMP would mean rewriting the *iOS* data layer to get any sharing benefit. Worth revisiting only if maintaining two hand-written API clients becomes painful (see §7). |
| Flutter / React Native | Rejected. Contradicts the project ethos and throws away the "native" differentiator; also adds a runtime dependency surface the project has deliberately avoided. |

**Repo:** a new sibling repo (e.g. `hermex-android`), not a directory in this repo.
The two apps share no code — they share a *contract* (the upstream API pin and
`PROJECT_SPEC.md`). Keeping them separate keeps CI, tooling, releases, and agent
working agreements simple. What gets copied/adapted into the new repo:

- `PROJECT_SPEC.md` §6 (API surface) verbatim — it is platform-neutral.
- The hard rules from `AGENTS.md`/`CLAUDE.md` (never invent endpoints; tolerant
  decoding; locked dependency list; don't commit broken builds).
- `UPSTREAM_TESTED_SHA` and the `CONTRACT_TESTS.md` approach, pinned to the same
  upstream commit so both clients are tested against the same server behavior.

---

## 2. Tech-stack mapping (the Android "locked list")

Direct translation of `PROJECT_SPEC.md` §5, keeping the same "minimal, boring,
well-maintained dependencies" philosophy:

| Concern | iOS (today) | Android (proposed) |
|---|---|---|
| UI framework | SwiftUI, iOS 18+ | **Jetpack Compose** (Material 3), minSdk 26–28, target latest |
| Language | Swift 5.9+ | **Kotlin** (2.x), coroutines + Flow |
| Architecture | MVVM: feature folders, `@Observable` view models | Same shape: feature packages, `ViewModel` + `StateFlow` |
| Networking | `URLSession` | **OkHttp** (+ Retrofit optional; plain OkHttp keeps it closer to the hand-rolled `APIClient`) |
| SSE streaming | LDSwiftEventSource | **`okhttp-sse`** (same OkHttp stack, maintained by Square) |
| JSON decoding | `Codable`, all-optional fields | **kotlinx.serialization** with `ignoreUnknownKeys = true` + nullable fields — preserves hard rule #3 (never crash on unknown/renamed fields) |
| Offline cache | SwiftData | **Room** (sessions + messages schema mirrors `CachedSession`/`CachedMessage`) |
| Secrets | Keychain (`KeychainStore`) | **Android Keystore**-backed encryption around DataStore (do not use plain `SharedPreferences`; note `EncryptedSharedPreferences`/Jetpack Security is deprecated — wrap Keystore directly, analogous to the small `KeychainStore` wrapper) |
| Markdown | swift-markdown-ui | **Markwon** (View interop) or a Compose-native renderer; see risk §6.2 |
| Syntax highlighting | Splash + Highlightr | Markwon's Prism4j plugin or an equivalent highlighter |
| Logging | OSLog | Logcat (`android.util.Log`); no logging framework |
| Testing | XCTest + URLProtocol mock server | **JUnit + OkHttp MockWebServer** (near-perfect analog) + Compose UI tests |
| CI | xcodebuild | Gradle on GitHub Actions (build + unit tests run fine on Linux runners — easier CI than iOS) |

Everything else stays platform APIs — same "do NOT add other dependencies
without asking" rule.

### Platform-feature mapping (the non-obvious parts)

| iOS feature | Android equivalent |
|---|---|
| Share Extension (`HermesShareExtension`) | `ACTION_SEND`/`ACTION_SEND_MULTIPLE` intent filters + a share-target activity writing to the same "shared draft" store. Simpler than iOS — no separate extension target needed. |
| Live Activity (agent-run progress) | Ongoing notification with live progress; on Android 16+ adopt Live Updates (`ProgressStyle`). Ship v1 with a plain ongoing notification. |
| App Intents / Siri shortcuts | App Shortcuts + deep links (`hermes://…` scheme already exists as `HermesDeepLink`). Low priority — defer past v1. |
| Local "response complete" notifications | `NotificationManager` + POST_NOTIFICATIONS runtime permission (Android 13+). |
| Voice input (`ComposerVoiceInputController`, server transcription) | Same server-side `/transcribe` path for voice notes; `SpeechRecognizer` for local dictation. |
| Listen / TTS (`AVSpeechSynthesizer`) | `TextToSpeech` platform API. |
| Haptics (`ChatHaptics`, `SessionHaptics`) | `View.performHapticFeedback` / `VibrationEffect`. Keep the same semantic call sites. |
| ATS + Tailscale HTTP exception | Android blocks cleartext by default (API 28+). Network Security Config can't express an IP range (`100.64.0.0/10`), so enforce the same rule in the connection layer: allow `http://` only when the host parses into the CGNAT range, plus `localhost`/emulator `10.0.2.2` for debug builds. |
| Background streaming | iOS suspends the app; Android additionally has Doze. Same strategy: don't fight it — reconnect/refresh on foreground (the server owns the run). Optionally a short foreground service while a run is active, paired with the progress notification. |

---

## 3. Architecture: keep the shape identical

The iOS layering ports directly and should be kept deliberately parallel so fixes and
features can be diffed across the two codebases:

```
app/src/main/java/…/hermex/
├── auth/          # AuthManager, KeystoreStore          (≈ Auth/)
├── network/       # ApiClient + per-domain extensions,  (≈ Networking/)
│                  # SseClient, Endpoints, ApiError,
│                  # MultipartBody, CacheFallbackPolicy
├── model/         # kotlinx.serialization data classes  (≈ Models/, all-nullable)
├── persistence/   # Room entities + DAOs                (≈ Persistence/)
├── features/
│   ├── onboarding/  chat/  sessionlist/  workspace/
│   ├── tasks/  skills/  memory/  insights/  settings/  share/
└── config/        # theme, fonts, app config            (≈ Config/)
```

Concurrency translates cleanly: `async/await` → coroutines, `AsyncSequence` SSE
events → `Flow`, `@MainActor` view models → `viewModelScope` + `StateFlow`.

UI direction: **Material 3 with Hermex theming**, not a pixel-clone of the iOS
glass look. Follow platform conventions (predictive back, edge-to-edge, dynamic
color optional) the same way the iOS app follows iOS conventions.

---

## 4. Phased build plan

Mirrors `PROJECT_SPEC.md` §8, re-ordered slightly because Android CI is cheap from
day one. Estimates assume one experienced Android developer (or agent-driven
development at the same cadence as the iOS build).

| Phase | Scope | Est. |
|---|---|---|
| **0. Setup** | New repo, Gradle project, CI (build + test on push), locked dependency list, copy spec/contract docs, pin upstream SHA | 1 day |
| **1. Networking core + auth** | `ApiClient`, login/health, cookie/token handling, Keystore storage, tolerant-decoding test harness with MockWebServer | 2–3 days |
| **2. Onboarding** | Welcome → connect (URL + password) → Tailscale/tunnel guidance pages; connection troubleshooting states | 2 days |
| **3. Session list** | Fetch/search/resume sessions, projects & profiles, Room cache for offline reads, pull-to-refresh | 3 days |
| **4. Chat + SSE streaming** *(the hardest slice, same as iOS)* | SSE client, token/tool_call/stream_end/error events, streaming markdown rendering, thinking + tool-call cards, stop/steer, approvals & clarifications overlays | 6–8 days |
| **5. Composer** | Model/reasoning/workspace/profile selectors, attachments (upload + image picking), slash commands, context-window indicator, voice input | 4–5 days |
| **6. Workspace + git** | File browser, file preview, git status/diff/branch/commit views | 3–4 days |
| **7. Server panels** | Tasks (cron CRUD), Skills, Memory, Insights/analytics | 3 days |
| **8. Settings + conversation actions** | Defaults, theming, session rename/delete, message long-press actions (copy/regenerate/listen) | 2–3 days |
| **9. Platform integration** | Share target, response-complete notifications, ongoing run notification, deep links | 2–3 days |
| **10. Polish + release prep** | Haptics, animations, empty/error states, Play Console internal-testing track, store listing | 3–4 days |

**Total: roughly 6–8 working weeks to feature parity.** A useful v1 cut (phases 0–5
plus settings basics) ships in about half that; everything after phase 5 is additive.

Recommended v1 cut if time-boxed: onboarding, sessions, chat with streaming,
composer with model/profile selection and attachments, offline cache, settings.
Defer: math rendering, Live Updates, voice input, insights, app shortcuts.

---

## 5. Testing & contract strategy

- Port the **contract-test approach** (`CONTRACT_TESTS.md`), pinned to the same
  `UPSTREAM_TESTED_SHA`. Both apps then chase upstream in lockstep: when the pin
  advances here, open a matching issue in the Android repo.
- MockWebServer replays the same recorded JSON fixtures; extracting the fixture
  corpus into a small shared location (or duplicating it initially) keeps the two
  clients honest against one wire format.
- Every model gets a "decodes with unknown fields / missing fields" test, same as
  the iOS tolerant-decoding rule.
- Compose UI tests for the critical flows only (login, send message, stream render);
  unit tests carry the bulk, as they do on iOS.

---

## 6. Risks & open questions

1. **Streaming markdown rendering** is where most of the iOS effort went
   (word-drain animation, streaming-safe markdown parsing, code blocks, tables).
   Compose has no swift-markdown-ui equivalent that handles *incrementally growing*
   markdown gracefully; expect custom work here. Budgeted in phase 4, but this is
   the schedule's biggest variance.
2. **Math rendering** (`MarkdownMathFormatter` + `DisplayMathView`) has no light
   Android analog (KaTeX implies a WebView, which the project avoids). Recommend:
   ship v1 with math as formatted code/text, decide later.
3. **Two hand-written clients drifting.** Upstream declares no API stability yet.
   Mitigation: shared pin + shared fixtures (§5). If drift still hurts, that — not
   day one — is the moment to evaluate a KMP shared `network/model` module.
4. **Doze vs. long runs:** an agent run can outlive the app process. The server is
   the source of truth, so "reconnect and re-hydrate on foreground" must be
   first-class from phase 4, not bolted on.
5. **Cleartext policy for Tailscale** needs the custom CGNAT-range check (§2) since
   Android's Network Security Config can't express CIDR ranges — small but easy to
   get wrong; needs tests.
6. **Open questions for the maintainer:** repo name and ownership; Play developer
   account; min SDK (26 vs 28); whether the Android app shares the Hermex
   name/branding on the Play Store from day one.

---

## 7. Long-term option: Kotlin Multiplatform

If both apps are alive a year from now, the natural consolidation is a KMP module
owning *models + API client + SSE parsing* (the parts governed by the upstream
contract), with SwiftUI and Compose remaining fully native above it. That migration
is only worth it once (a) the Android client exists and (b) contract drift has
actually caused duplicated bug-fixing. Do not start there.
