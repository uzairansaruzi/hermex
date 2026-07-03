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

## 1. Recommended approach: native Kotlin + Jetpack Compose, same repo (monorepo)

Three realistic options were considered:

| Option | Verdict |
|---|---|
| **Native Kotlin + Jetpack Compose** | **Recommended.** Mirrors the project's core promise ("Real native UI, not a web wrapper"). Compose is the direct conceptual analog of SwiftUI, so the existing feature/view-model structure translates almost one-to-one. |
| Kotlin Multiplatform (shared networking/models, Compose UI) | Not for v1. The iOS app is finished, pure-Swift, and stable; adopting KMP would mean rewriting the *iOS* data layer to get any sharing benefit. Worth revisiting only if maintaining two hand-written API clients becomes painful (see §7). |
| Flutter / React Native | Rejected. Contradicts the project ethos and throws away the "native" differentiator; also adds a runtime dependency surface the project has deliberately avoided. |

**Repo:** both apps live in *this* repo. The two apps share no code — they share a
*contract* (the upstream API pin, `PROJECT_SPEC.md` §6, and the contract-test
fixtures) — and a monorepo makes that contract a single physical artifact instead of
something copied between repos: one `UPSTREAM_TESTED_SHA`, one fixture corpus, one
issue tracker, and atomic PRs when an upstream pin advance touches both clients.
The costs (one-time iOS path churn, path-filtered CI, a bigger clone) are covered
below.

### Monorepo layout

```
hermex/
├── ios/                    # everything Apple moved here, history preserved via git mv
│   ├── HermesMobile/  HermesMobile.xcodeproj/  HermesMobileTests/
│   ├── HermesShareExtension/  HermesLiveActivityWidget/
│   ├── Config/  ci/        # xcconfigs + TestFlight export options
│   └── AGENTS.md           # iOS-specific rules (tooling, simulator, TestFlight)
├── android/                # self-contained Gradle project (phase 0 scaffolds this)
│   ├── app/  gradle/  build.gradle.kts  settings.gradle.kts  gradlew
│   └── AGENTS.md           # Android-specific rules (tooling, emulator, Play)
├── shared/
│   └── fixtures/           # recorded JSON contract fixtures, consumed by BOTH test suites
├── docs/                   # cross-platform docs (this plan, agents conventions)
├── scripts/                # repo-level helpers (upstream-watch, webui-json, size check)
├── .xcodebuildmcp/         # stays at root — the tool reads config from the workspace root
├── PROJECT_SPEC.md         # product + API contract (platform-neutral sections stay root-level)
├── UPSTREAM_TESTED_SHA     # ONE pin for both clients
├── CONTRACT_TESTS.md  AGENTS.md  CLAUDE.md  README.md  …
└── .github/workflows/      # path-filtered: pr-ci (iOS), android (later), TestFlight
```

Rules that make it work:

- **Toolchains never leak past their directory.** Xcode/SwiftPM own `ios/`, the
  Gradle wrapper owns `android/`, the repo root stays tool-agnostic. Neither build
  references files outside its subtree except `shared/fixtures/` and the pin.
- **CI is path-filtered.** `ios.yml` runs on `ios/**` changes (macOS runner),
  `android.yml` on `android/**` (cheap Linux runner), and both contract-test jobs
  run when `shared/fixtures/**` or `UPSTREAM_TESTED_SHA` change. Docs-only changes
  keep skipping builds. Note the branch-protection gotcha: a *required* check that
  path-filters itself away blocks merging — use a gate job that reports success
  when its paths didn't change.
- **Layered agent instructions.** Root `AGENTS.md`/`CLAUDE.md` keeps only the
  platform-neutral hard rules (never invent endpoints; tolerant decoding; locked
  dependency lists; don't commit broken builds). Platform tooling rules move into
  `ios/AGENTS.md` and `android/AGENTS.md` — agents pick up the nested file when
  working inside that directory.
- **Issues and releases are labeled/prefixed per app.** `ios` / `android` labels on
  issues; tags like `ios-v1.4.0` and `android-v0.1.0`; `CHANGELOG.md` gets one
  section per app. Branch conventions (`issue/<n>-slug`) stay unchanged.
- **`master` stays the protected release-candidate branch for both apps** — the
  path-filtered required checks keep it buildable on both sides.

### Migration steps (before Android phase 0)

- [x] **Step A — move iOS under `ios/`.** Done: pure `git mv` (history follows) of
      `HermesMobile*`, both extensions, `Config/`, and `ci/`; path references fixed
      in the three workflows, `.xcodebuildmcp/config.yaml` (kept at root, pointed at
      `ios/`), `scripts/check-swift-file-sizes`, `scripts/upstream-watch`,
      `.gitignore`, and the command paths in README/DEVELOPMENT/TESTFLIGHT/
      CONTRIBUTING/PR template. The `.xcodeproj` uses relative paths inside the
      moved tree, so it needed no surgery. Verified by PR CI's full build + test run
      (no Xcode available in the migration environment).
- [x] **Step B — hoist the shared contract.** Done: `shared/fixtures/` created with
      recording rules (the corpus itself is recorded when Android contract tests
      need it — today's iOS fixtures are inline in Swift test code);
      `UPSTREAM_TESTED_SHA` + `CONTRACT_TESTS.md` stay at root; `AGENTS.md` split
      into a platform-neutral root layer + `ios/AGENTS.md` (with an `ios/CLAUDE.md`
      symlink mirroring the root pattern).
- [x] **Step C — scaffold `android/`** (this is phase 0 of §4). Done: Gradle
      project with version-catalog locked dependency list, `android/AGENTS.md`
      (+ `CLAUDE.md` symlink), minimal Compose placeholder screen, unit tests
      pinning the tolerant-decoding Json config and the shared-fixtures/pin
      wiring, and a path-filtered `android-ci.yml` (with the iOS `pr-ci.yml`
      filter taught to skip Android-only changes). Verified by a local
      `gradlew build` (all tests + lint green) and the Android CI run.

All three steps landed together on the plan PR at the maintainer's request.
`PROJECT_SPEC.md` §7's file layout was left untouched — it describes the tree
*inside* the app project, which is unchanged relative to `ios/`.

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
development at the same cadence as the iOS build). Check phases off as they land.

- [x] **Phase 0 — Setup** (1 day, after the §1 migration PRs)
  - [x] `android/` Gradle project scaffold
  - [x] Path-filtered CI: build + unit tests on `android/**` pushes
  - [x] Locked dependency list + `android/AGENTS.md` committed; wire tests to the
        shared fixtures and root upstream pin
- [x] **Phase 1 — Networking core + auth** (2–3 days)
  - [x] `ApiClient`, login/health, cookie/token handling
  - [x] Keystore-backed secret storage
  - [x] Tolerant-decoding test harness with MockWebServer
- [x] **Phase 2 — Onboarding** (2 days)
  - [x] Welcome → connect (URL + password) → Tailscale/tunnel guidance pages
  - [x] Connection troubleshooting states
- [ ] **Phase 3 — Session list** (3 days)
  - [ ] Fetch/search/resume sessions; projects & profiles
  - [ ] Room cache for offline reads; pull-to-refresh
- [ ] **Phase 4 — Chat + SSE streaming** *(the hardest slice, same as iOS)* (6–8 days)
  - [ ] SSE client: token / tool_call / stream_end / error events
  - [ ] Streaming markdown rendering
  - [ ] Thinking + tool-call cards
  - [ ] Stop/steer; approvals & clarifications overlays
- [ ] **Phase 5 — Composer** (4–5 days)
  - [ ] Model/reasoning/workspace/profile selectors
  - [ ] Attachments (upload + image picking)
  - [ ] Slash commands; context-window indicator
  - [ ] Voice input
- [ ] **Phase 6 — Workspace + git** (3–4 days)
  - [ ] File browser + file preview
  - [ ] Git status/diff/branch/commit views
- [ ] **Phase 7 — Server panels** (3 days)
  - [ ] Tasks (cron CRUD)
  - [ ] Skills; Memory; Insights/analytics
- [ ] **Phase 8 — Settings + conversation actions** (2–3 days)
  - [ ] Defaults + theming; session rename/delete
  - [ ] Message long-press actions (copy/regenerate/listen)
- [ ] **Phase 9 — Platform integration** (2–3 days)
  - [ ] Share target; deep links
  - [ ] Response-complete notifications; ongoing run notification
- [ ] **Phase 10 — Polish + release prep** (3–4 days)
  - [ ] Haptics, animations, empty/error states
  - [ ] Play Console internal-testing track; store listing

**Total: roughly 6–8 working weeks to feature parity.** A useful v1 cut (phases 0–5
plus settings basics) ships in about half that; everything after phase 5 is additive.

Recommended v1 cut if time-boxed: onboarding, sessions, chat with streaming,
composer with model/profile selection and attachments, offline cache, settings.
Defer: math rendering, Live Updates, voice input, insights, app shortcuts.

---

## 5. Testing & contract strategy

- Both apps share the **contract-test approach** (`CONTRACT_TESTS.md`) and the
  single root `UPSTREAM_TESTED_SHA`. A pin advance is one PR that runs both
  clients' contract tests — the apps chase upstream in lockstep by construction.
- MockWebServer (Android) and the URLProtocol mock server (iOS) replay the same
  recorded JSON fixtures from `shared/fixtures/`, keeping the two clients honest
  against one wire format.
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
6. **Open questions for the maintainer** (check off as decided):
   - [x] Repo strategy — decided: monorepo, both apps in this repo (§1)
   - [ ] Play developer account
   - [ ] Min SDK (26 vs 28)
   - [ ] Whether the Android app shares the Hermex name/branding on the Play
         Store from day one

---

## 7. Long-term option: Kotlin Multiplatform

If both apps are alive a year from now, the natural consolidation is a KMP module
owning *models + API client + SSE parsing* (the parts governed by the upstream
contract), with SwiftUI and Compose remaining fully native above it. The monorepo
makes this cheap to adopt later — a `shared/kotlin/` module next to
`shared/fixtures/`, consumed by both apps, with no cross-repo publishing. That
migration is only worth it once (a) the Android client exists and (b) contract
drift has actually caused duplicated bug-fixing. Do not start there.
