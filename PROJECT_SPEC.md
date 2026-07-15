# Hermex — iOS App Project Specification

**Status:** v0.4 spec — revised pre-polish plan with a glass-forward native mobile UI direction
**Author:** Project owner + planning assistant
**Target:** Native iOS client for the [`nesquena/hermes-webui`](https://github.com/nesquena/hermes-webui) Python server
**Audience:** A coding agent tasked with building the app, plus the human owner reviewing it

---

## 0. How to use this document

You (the coding agent) are building a native iOS app called **Hermex** in App Store Connect. The Xcode target remains `HermesMobile`; the iPhone home-screen display name is `Hermex`. You are NOT modifying the upstream `nesquena/hermes-webui` Python server in this project. You are building a separate Swift/SwiftUI iOS application that talks to that server over HTTPS.

Treat each section's checkboxes as your work plan. After every milestone, update the `## Progress log` at the bottom.

If anything in this spec is ambiguous, **stop and ask the human owner before guessing.** Do not invent endpoints — verify them against the running server (see §6).

---

## 1. Project summary

### 1.1 What we're building
A native iOS app (SwiftUI, iOS 18+, iPhone only) that lets the user drive a self-hosted Hermes AI agent from their phone. The user runs the `hermes-webui` Python server on a machine they control and connects from the phone via Cloudflare Tunnel (or Tailscale).

### 1.2 What it is NOT
- ❌ Not a webview wrapper around the existing browser UI.
- ❌ Not a port of the Python server to iOS (impossible due to App Store sandboxing).
- ❌ Not a hosted service — every user brings their own server.

### 1.3 Why it exists
The `hermes-webui` browser UI works on mobile via Cloudflare Tunnel/Tailscale, but a native client gives:
- A real iOS app icon, lifecycle, and Keychain-backed auth.
- Native streaming chat with proper SwiftUI rendering (no PWA quirks).
- Offline read-only cache of recent sessions.
- Foundation for native completion notifications and future out-of-app status surfaces.

### 1.4 Product mental model
Think of the app as a mobile cockpit for an agent that lives somewhere else.

The phone is not the compute plane. The phone is the control plane and review surface: start or continue work, watch streaming progress, steer or stop a run, inspect files and outputs, recover context while away from the desktop, and avoid dangerous write/admin surfaces until the mobile UX is explicit and safe.

The server owns execution. The app owns mobile interaction quality.

### 1.5 Upstream project — quick facts
- Repo: https://github.com/nesquena/hermes-webui
- Language: Python 3 (server), HTML/CSS/vanilla JS (existing browser client)
- License: MIT
- Default port: `8787`
- Default host: `127.0.0.1` (binds to `0.0.0.0` only when explicitly set)
- Activity: very high — daily commits, 67+ open issues, 5,200+ stars, 660+ forks
- The server is essentially a thin `http.server.ThreadingHTTPServer` shell in `server.py` that delegates to `api/routes.py` (~3000 LOC of route handlers).
- Real-time updates use **Server-Sent Events (SSE)**, not WebSockets.
- Auth: optional HMAC-signed HTTP-only cookie set via `HERMES_WEBUI_PASSWORD` env var, with a `/login` page and 24h TTL.

---

## 2. Decisions baked into this spec

| # | Decision | Value |
|---|---|---|
| 1 | v1 feature scope | **Expanded pre-polish scope** (login, sessions, chat with streaming, conversation actions, composer attachments/config, read-only tasks/skills/memory, limited usage analytics, workspace browser, file viewer with syntax highlighting, settings; **no push, no terminal, no file editing in v1**) |
| 2 | Hosting models documented | **Cloudflare Tunnel (primary)** and **Tailscale (secondary)** |
| 3 | Upstream strategy | **Pin to upstream tags** for v1; revisit forking later if API churn becomes painful |
| 4 | Auth method | **Password only** for v1 (no OAuth) |
| 5 | Target | iOS 18+, iPhone only, portrait + landscape |
| 6 | Distribution | **TestFlight first**, App Store later |
| 7 | Push notifications | **Skip for v1** |
| 8 | Terminal feature | **Skip for v1** |
| 9 | Offline behavior | **Read-only cache** of session list and recent messages |
| 10 | App name | **Hermex** in App Store Connect; iPhone display name **Hermex**; Xcode target remains `HermesMobile` |
| 11 | Apple Developer account | **Enrolled** — Team ID `6GYD9C9N6R`; bundle ID `com.uzairansar.hermesmobile`; SKU `hermes-mobile-ios` |

---

## 2a. Reference development environment (the dev/test target)

Development targets a self-hosted `hermes-webui` server the developer controls, exposed over real HTTPS. Docker and native (e.g. macOS + launchd, Linux + systemd) setups are both fine; the canonical shape is:

| Property | Value |
|---|---|
| Host machine | A machine the developer controls |
| Server script | `server.py` in the `hermes-webui` checkout |
| Bind | `127.0.0.1:8787` (loopback only) |
| Public transport | HTTPS tunnel or reverse proxy (e.g. **Cloudflare Tunnel**) → `http://127.0.0.1:8787` |
| TLS | Terminated by the tunnel/proxy; the app always sees real HTTPS |
| Auth | `HERMES_WEBUI_PASSWORD` set on the server (**required** whenever the hostname is reachable beyond loopback) |

**Implication:** a tunneled setup gives us **real HTTPS from day one** — App Transport Security in iOS will be happy. We do **not** need an ATS exception for development when testing against a real HTTPS hostname. The simulator-only `http://localhost:8787` path is documented as a separate "running the server locally without a tunnel" option for contributors who prefer that, but it's not the default.

Health check from anywhere: `curl https://<your-server>/health`

If the server appears down during testing, check (in order): the server process, port 8787 locally (`lsof -i :8787`), tunnel/proxy status.

## 2b. Mobile UI direction

Hermex aims for a compact, glass-forward native iOS treatment:

- Composer: a single Liquid-Glass-style surface with prompt text above and runtime controls below.
- Runtime controls: compact model and reasoning selectors in a bottom control row inside the composer, with SF Symbols for the reasoning-effort icons.
- Pickers/sheets: dense, native, scan-friendly model/profile/workspace pickers rather than marketing-style pages.
- Sessions and Settings: layout, spacing, glass treatment, and navigation hierarchy consistent with the chat/composer direction while preserving Hermes-specific actions.

This is a design direction, not a dependency. Do not add third-party UI packages to achieve this look.

---

## 3. High-level architecture

```
┌──────────────────────────┐         HTTPS (REST + SSE)        ┌────────────────────────────┐
│ Hermex iOS               │ ────────────────────────────────► │  Cloudflare Tunnel edge    │
│   SwiftUI + URLSession   │ ◄──────────────────────────────── │  hermes.yourdomain.com     │
│   LDSwiftEventSource     │                                   └────────────┬───────────────┘
│   Keychain (auth token)  │                                                │ cloudflared
│   SwiftData (cache)      │                                                ▼
└──────────────────────────┘                                   ┌────────────────────────────┐
                                                               │  hermes-webui (Python)     │
                                                               │  127.0.0.1:8787 on macOS,  │
                                                               │  managed by launchd        │
                                                               └────────────┬───────────────┘
                                                                            │ spawns
                                                                            ▼
                                                                  Hermes Agent (Python)
                                                                  + shell processes
```

### Why this shape
- The iOS app cannot run the server — iOS sandboxing forbids spawning processes, `pip install`, and binding ports in the background. The Python server stays where it is.
- We talk to the server's existing HTTP+SSE API — the same endpoints the bundled browser UI uses.
- Cloudflare Tunnel handles network reachability and TLS; the app just takes a URL and a password.

---

## 4. Required reading before coding

Read these from the upstream repo (in this order) and summarize key takeaways in your progress log:

1. `README.md` — overall product picture
2. `server.py` — request lifecycle, auth check, SSE
3. `api/routes.py` — **the API contract** (every endpoint we use lives here)
4. `api/auth.py` — cookie format, login flow, `is_auth_enabled()`
5. `api/streaming.py` — SSE event types (`token`, `tool_call`, `stream_end`, `error`, etc.)
6. `api/models.py` — Session shape (fields you'll decode in Swift)
7. `api/workspace.py` — file listing/reading endpoints
8. `ARCHITECTURE.md` — narrative reference

Also note: this repo uses a pinned, read-only upstream clone at `.codex-tmp/hermes-webui/` (clone it if missing: `git clone https://github.com/nesquena/hermes-webui .codex-tmp/hermes-webui`). **Read from that pinned copy first** when convenient. Cross-check against GitHub master only when you need to confirm something changed after the pin.

When in doubt about behavior, hit your running server with `curl` and inspect the JSON. **The wire format is the source of truth — not docs.**

---

## 5. Tech stack (locked)

| Layer | Choice | Why |
|---|---|---|
| UI framework | **SwiftUI** | Modern, less boilerplate, fine for iOS 18+ |
| Min iOS | **18.0** | Keeps the material/glass polish simpler while retaining modern SwiftUI APIs |
| Networking | **`URLSession` (built-in)** | No third-party dep needed |
| SSE client | **[LDSwiftEventSource](https://github.com/launchdarkly/swift-eventsource)** | Best-maintained Swift SSE library; `URLSession` has no native SSE parser |
| Markdown rendering | **[swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)** | Mature, themeable, supports code blocks |
| Syntax highlighting | **[Splash](https://github.com/JohnSundell/Splash)** for Swift, **[Highlightr](https://github.com/raspu/Highlightr)** for everything else | Plug into swift-markdown-ui's code block renderer |
| Local cache | **SwiftData** | Native; simple for our small schema |
| Secrets | **Keychain** via `KeychainAccess` library OR a small wrapper around `Security` framework | Don't store password/token in `UserDefaults` |
| Logging | `OSLog` (built-in) | Free, works in Console.app |
| Testing | XCTest + a tiny URLProtocol-based mock server | No third-party test framework |
| Linting | SwiftLint (optional, recommended) | Run in build phase |

**Do NOT add other dependencies without asking.**

---

## 6. API surface to integrate (v1)

These are the endpoints we know we need. Verify each one against your running server before relying on it. **All endpoints are POST or GET on the WebUI server's base URL**.

### 6.1 Auth & health
| Method | Path | Used for |
|---|---|---|
| GET | `/health` | "Test connection" button on settings screen |
| GET | `/api/auth/status` | Determine whether the server requires a password |
| POST | `/api/auth/login` | Body `{"password": "..."}` → sets cookie. Save cookie via `URLSession`'s default `HTTPCookieStorage`. |
| POST | `/api/auth/logout` | Sign out |

**CSRF note:** the server validates the `Origin` / `Referer` header on POSTs against the request `Host`. From a non-browser client, omit both `Origin` and `Referer` and the server treats it as a non-browser (curl-equivalent) call — that's the supported path. **Do NOT set `Origin` to anything.**

**Cloudflare-Access note:** this spec assumes no Cloudflare Access (or similar SSO layer) in front of the hostname. If a deployment adds one (recommended hardening), the app would need to handle a login redirect flow. Out of scope for v1; document it as a known follow-up.

### 6.2 Sessions
| Method | Path | Used for |
|---|---|---|
| GET | `/api/sessions` | Sidebar session list. Returns `{"sessions": [...]}`. |
| GET | `/api/session?session_id=...&messages=1&msg_limit=50` | Load a session with the last N messages. Use `msg_limit` aggressively on mobile. Use `msg_before=N` for scroll-to-top paging. |
| GET | `/api/session/status?session_id=...` | Polling fallback for stream state |
| POST | `/api/session/new` | Body: `{workspace, model, model_provider?, profile?}` |
| POST | `/api/session/rename` | `{session_id, title}` |
| POST | `/api/session/delete` | `{session_id}` |
| POST | `/api/session/pin` | `{session_id, pinned: bool}` |
| POST | `/api/session/archive` | `{session_id, archived: bool}` |
| POST | `/api/session/move` | `{session_id, project_id?}` for moving a session into or out of a project |
| POST | `/api/session/branch` | `{session_id, keep_count?, title?}` for forking from a message or duplicating a full conversation |
| POST | `/api/session/truncate` | `{session_id, keep_count}` for edit/regenerate flows that discard later history after confirmation |
| GET | `/api/session/usage?session_id=...` | Per-session token/cost snapshot for limited analytics and diagnostics |
| GET | `/api/projects` | List projects for "Move to project" |
| POST | `/api/projects/create` | Optional shortcut for creating a destination project from the move picker |

### 6.3 Chat (the core flow)
| Method | Path | Used for |
|---|---|---|
| POST | `/api/chat/start` | Body: `{session_id, message, workspace?, model?, attachments?}`. Returns `{"stream_id": "...", "session_id": "..."}`. |
| GET | `/api/chat/stream?stream_id=...` | **SSE endpoint.** Hold this connection open and emit each event to the chat view. |
| GET | `/api/chat/cancel?stream_id=...` | Stop button |
| GET | `/api/chat/stream/status?stream_id=...` | "Is the stream still alive?" check after reconnect |
| POST | `/api/chat/steer` | `/steer <message>` while a stream is active. Body: `{session_id, text}`. Returns `{accepted: bool, fallback?, stream_id?}`; if not accepted, mobile falls back to queue + cancel. |
| POST | `/api/upload` | Multipart upload: fields `session_id`, `file`; returns `{filename, path, mime, size, is_image}` for chat attachments |
| POST | `/api/upload/extract` | Multipart archive upload/extract; use only for supported archives and show extracted destination |

**SSE event types you must handle** (from `api/streaming.py`):
- `token` — append text to current assistant message
- `tool_call` — render a collapsible tool-call card
- `tool_result` — attach to the last tool call
- `reasoning` — collapsible "thinking" block
- `stream_end` — finalize message, close connection
- `error` — show inline error, close connection
- `cancel` — user cancelled, close connection
- Heartbeat comments (lines starting with `:`) — ignore

The server keeps connections alive for ~30s with `: heartbeat` comments. **Cloudflare Tunnel is fine with long-lived SSE** — the server already sets `X-Accel-Buffering: no` and Cloudflare respects that for `text/event-stream`. But Cloudflare's free-tier idle timeout caps streams at ~100 seconds without activity. Heartbeats every 30s keep it alive; if a single agent turn produces no tokens for >100s the connection may be cut. Handle reconnect via `/api/chat/stream/status`.

**Do NOT auto-resend the user message on reconnect** — use the status endpoint to check if the existing stream is still active before reattaching.

### 6.4 Workspace / files
| Method | Path | Used for |
|---|---|---|
| GET | `/api/workspaces` | List configured workspace roots |
| GET | `/api/workspaces/suggest?prefix=...` | Workspace path suggestions for selecting the active session workspace |
| GET | `/api/list?session_id=...&path=...` | Directory listing |
| GET | `/api/file?session_id=...&path=...` | Read text file (returns JSON with content + metadata) |
| GET | `/api/file/raw?session_id=...&path=...` | Binary/image file bytes — use for previews |

### 6.5 Models / providers / profiles / reasoning
| Method | Path | Used for |
|---|---|---|
| GET | `/api/models` | Populate model picker |
| GET | `/api/providers` | Show which providers are configured |
| GET | `/api/settings` | Bot name, theme hints, version |
| POST | `/api/default-model` | Save global default model from Settings |
| GET | `/api/reasoning` | Read current reasoning display/effort |
| POST | `/api/reasoning` | Save reasoning effort from the composer menu |
| GET | `/api/profiles` | Populate profile picker |
| POST | `/api/profile/switch` | Switch active profile for this client via profile cookie; do not expose profile create/delete in v1 |
| GET | `/api/personalities` | Populate slash-command sub-argument suggestions for `/personality` |
| GET | `/api/commands` | Populate slash-command metadata for agent/CLI command awareness |
| POST | `/api/personality/set` | Optional `/personality` slash-command action after confirming current upstream behavior |

### 6.6 Read-only server panels
| Method | Path | Used for |
|---|---|---|
| GET | `/api/crons` | Read-only scheduled jobs/tasks list |
| GET | `/api/crons/status?job_id=...` | Active/running status for a job; without `job_id`, returns all running jobs |
| GET | `/api/crons/output?job_id=...&limit=...` | Recent job outputs for the task detail page |
| GET | `/api/skills` | Skills list, grouped by category |
| GET | `/api/skills/content?name=...` | Skill detail markdown and linked files |
| GET | `/api/skills/content?name=...&file=...` | Read linked skill file content |
| GET | `/api/memory` | Read memory notes and user profile |

### 6.7 Limited analytics
There is no verified full `/insights` dashboard REST endpoint in the pinned upstream source. For v1, build a limited usage analytics page from data already available on mobile:
- `/api/sessions` fields such as `input_tokens`, `output_tokens`, `estimated_cost`, `created_at`, `updated_at`, and `last_message_at`.
- Optional per-session refresh through `/api/session/usage?session_id=...` only when the user opens a detail or refreshes analytics.
- Timeframe filtering is local to the fetched session metadata. Label this as **Usage Analytics** rather than claiming full parity with the CLI/WebUI `/insights` command.

### 6.8 Endpoints we deliberately skip in v1
Terminal (`/api/terminal/*`), cron create/edit/delete/run/pause/resume, skills save/delete, memory write/edit, profile create/delete, file editing/deletion/rename/create, OAuth, approvals, clarify prompts. Architect the code so these can slot in later (use a `Feature` enum or similar).

---

## 7. App structure (target file layout)

```
HermesMobile/
├── HermesMobileApp.swift              # @main, App scene
├── Config/
│   └── AppConfig.swift                # build constants, log subsystems
├── Networking/
│   ├── APIClient.swift                # actor wrapping URLSession
│   ├── APIError.swift
│   ├── Endpoints.swift                # one func per endpoint
│   ├── SSEClient.swift                # wraps LDSwiftEventSource
│   └── ChatStream.swift               # AsyncSequence of ChatEvent
├── Models/
│   ├── Session.swift                  # Codable, matches server JSON
│   ├── ChatMessage.swift
│   ├── ChatEvent.swift                # decoded SSE payload variants
│   ├── ToolCall.swift
│   ├── WorkspaceEntry.swift
│   └── ServerInfo.swift
├── Persistence/
│   ├── CacheStore.swift               # SwiftData @Model types
│   ├── CachedSession.swift
│   └── CachedMessage.swift
├── Auth/
│   ├── KeychainStore.swift            # tiny Keychain wrapper
│   └── AuthManager.swift              # @Observable; login/logout/state
├── Features/
│   ├── Onboarding/
│   │   ├── OnboardingView.swift       # server URL + password
│   │   └── OnboardingViewModel.swift
│   ├── SessionList/
│   │   ├── SessionListView.swift
│   │   └── SessionListViewModel.swift
│   ├── Chat/
│   │   ├── ChatView.swift
│   │   ├── ChatViewModel.swift
│   │   ├── MessageBubbleView.swift
│   │   ├── ToolCallCardView.swift
│   │   └── MarkdownRenderer.swift     # swift-markdown-ui config
│   ├── Workspace/
│   │   ├── FileBrowserView.swift
│   │   └── FilePreviewView.swift
│   ├── Tasks/
│   │   └── TasksView.swift             # read-only scheduled jobs
│   ├── Skills/
│   │   └── SkillsView.swift            # read-only skills catalog + detail
│   ├── Memory/
│   │   └── MemoryView.swift            # read-only notes + user profile
│   ├── Insights/
│   │   └── InsightsView.swift          # limited session-based usage analytics
│   └── Settings/
│       ├── SettingsView.swift
│       └── ServerHealthCheckView.swift
├── DesignSystem/
│   ├── Colors.swift
│   ├── Typography.swift
│   └── Components/
│       ├── LoadingView.swift
│       ├── EmptyStateView.swift
│       └── ErrorBanner.swift
└── Resources/
    ├── Assets.xcassets
    └── Info.plist
```

---

## 8. Step-by-step build plan

Each phase ends in a working, committable state. Run on the simulator after every phase.

### Phase 0 — Setup (½ day)
- [x] Create new GitHub repo (ask owner for the name; default `hermes-mobile`).
- [x] Initialize Xcode project: SwiftUI App, iOS 17, Swift 5.9+, name `HermesMobile`, initial placeholder bundle ID later replaced by `com.uzairansar.hermesmobile`.
- [x] Add this `PROJECT_SPEC.md` to the repo root.
- [x] Add SwiftPM dependencies: LDSwiftEventSource, swift-markdown-ui, Splash, Highlightr, KeychainAccess.
- [x] Add `.gitignore` (Xcode template), commit.
- [x] Add a `README.md` that points at this spec.
- [x] Write a one-page `DEVELOPMENT.md` with:
  - **Primary test target:** the developer's own HTTPS-exposed `hermes-webui` instance (needs the password). Works from simulator AND a physical device.
  - **Local-only fallback**: clone `nesquena/hermes-webui`, run via Docker OR `python3 server.py` from the repo. Note: physical-device testing against `http://localhost:8787` requires either a Tailscale IP or an ATS exception.
  - How to verify the server is up before debugging the app: `curl https://<your-server>/health`.

### Phase 1 — Onboarding + auth (1–2 days)
- [x] `KeychainStore`: `save(_:forKey:)`, `load(_:)`, `delete(_:)` — simple wrapper.
- [x] `AuthManager` (`@Observable`): publishes `state: .unconfigured | .loggedOut | .loggedIn(server: URL)`.
- [x] `OnboardingView`: form with **Server URL** (default placeholder `https://hermes.yourdomain.com`) and **Password** (optional).
- [x] "Test connection" button hits `GET /health` → green check or red error.
- [x] On success, save server URL to Keychain (yes, the URL too — it's effectively a credential combined with the password) and call `POST /api/auth/login` if password provided.
- [x] Persist auth cookie via `URLSession.shared.configuration.httpCookieStorage`.
- [x] If `/api/auth/status` says auth not enabled, skip the password field gracefully.
- [x] App opens to Onboarding when not configured, otherwise to SessionList.

### Phase 2 — Networking core (2–3 days)
- [x] `APIClient` actor with one `URLSession` configured for cookies.
- [x] `Endpoints.swift`: typed functions for every endpoint in §6 (start with sessions list and `/api/session`).
- [x] `Codable` models for `Session`, `ChatMessage`, etc. **Use optionals liberally.** Server adds fields constantly.
- [x] Custom decoding strategy: convert snake_case to camelCase via `JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase`.
- [x] Error model: `APIError.network`, `.http(statusCode, body)`, `.decoding(underlying)`, `.unauthorized`.
- [x] On `401`, clear cookie and bounce user to Onboarding.
- [x] Tests: hitting a live personal server from CI is not appropriate — use `URLProtocol` mocks in tests.

### Phase 3 — Session list (2 days)
- [x] `SessionListView`: pull-to-refresh, swipe actions for pin/archive/delete.
- [x] Group by Today / Yesterday / Earlier (the server returns `last_message_at` as Unix epoch).
- [x] Tap a session → push `ChatView`.
- [x] "+" button → create new session via `/api/session/new` with default workspace + model.
- [x] Empty state with helpful message.

### Phase 4 — Chat view + SSE streaming (4–6 days, the hardest part)
- [x] `ChatView`: `ScrollView` with messages, composer at bottom, "stop" button while streaming.
- [x] `MessageBubbleView`: user bubbles right-aligned, assistant left-aligned with bubble tail.
- [x] `MarkdownRenderer`: configure swift-markdown-ui with custom code-block view that runs Highlightr.
- [x] `ChatViewModel` (`@Observable`):
  - Load existing messages with `/api/session?session_id=X&msg_limit=50`.
  - On send: POST `/api/chat/start`, get `stream_id`, open SSE on `/api/chat/stream?stream_id=...`.
  - Append `token` events to a streaming buffer rendered as the in-flight assistant message.
  - On `tool_call`, push a `ToolCallCardView` into the message stream.
  - On `stream_end`, finalize message and close SSE.
  - On `error`, show banner, finalize partial message.
- [x] `ToolCallCardView`: collapsible, shows tool name + args + result.
- [x] Cancel button → `GET /api/chat/cancel?stream_id=...`.
- [x] Background → foreground: re-check stream status, attach if still alive.
- [x] Scroll-to-bottom button when user has scrolled up.
- [x] **Cloudflare-specific test:** verify a stream that runs >2 minutes still delivers events (the 30s heartbeat should keep CF from cutting it). If a turn naturally has gaps >100s with no events, that's where the connection will drop — note in known issues.

### Phase 5 — Workspace file browser (2 days)
- [x] `FileBrowserView`: pushed from a "Files" toolbar button in chat.
- [x] Tree view with breadcrumbs.
- [x] Tap file → `FilePreviewView` (text via `/api/file`, images via `/api/file/raw`).
- [x] **No file editing in v1.** Workspace file browser is read-only.

### Phase 6 — Offline cache (1–2 days)
- [x] SwiftData schema: `CachedSession`, `CachedMessage`.
- [x] On every successful sessions-list fetch, write through to SwiftData.
- [x] On every session load, cache the last N messages.
- [x] When offline, show cached data with a "Offline — viewing cached version" banner.
- [x] Disable composer when offline.
- [x] Cache invalidation: simple — TTL of 7 days, evict oldest when total messages > 5,000.

### Phase 7 — Settings (1 day)
- [x] Server URL display (read-only after onboarding; allow "Sign out & reconfigure").
- [x] App version + build number.
- [x] Server version (from `/api/settings.webui_version`).
- [x] Compatibility note: "Tested against hermes-webui vX.Y.Z. Your server reports vA.B.C."
- [x] Theme: light/dark/system.
- [x] Clear cache button.

### Phase 8 — Conversation actions (2–3 days)
**Classification:** required before polish/TestFlight.

#### 8.1 Session long-press options
- **User-facing goal:** Press and hold a session row to open native options: pin/unpin, move to project, archive/restore, duplicate, delete.
- **Upstream API/server contract to verify:** `POST /api/session/pin`, `POST /api/session/move`, `GET /api/projects`, optional `POST /api/projects/create`, `POST /api/session/archive`, `POST /api/session/branch`, `POST /api/session/delete`.
- **iOS UI changes:** Replace or supplement swipe-only row actions with a long-press context menu. "Move to project" opens a project picker with "No project" and existing projects. Delete stays behind confirmation.
- **Model/networking changes:** Add tolerant `Project` model and API client methods for project list, session move, branch, and existing mutations. Duplicate should call `/api/session/branch` with no `keep_count` and a custom title like `<title> (copy)`, then load/navigate to the returned session.
- **Persistence/cache impact:** On mutation success, update or remove cached session rows. For duplicate, insert the newly loaded session after fetching it.
- **Tests:** Request construction for move/project list/branch/delete; view model tests for cache updates and local filtering after archive/delete.
- **Manual simulator test plan:** Long-press a safe session, pin/unpin it, move it to a project and back to No project, archive/restore it, duplicate it and confirm transcript is copied, delete only a disposable session.
- **Risks/open questions:** Moving to a project needs a clear "No project" state. Duplicate is intentionally a full transcript copy, not the current WebUI empty-copy shortcut.

#### 8.2 User message long-press menu
- **User-facing goal:** Press and hold the user's own message to show Edit Message, Fork From Here, and Copy.
- **Upstream API/server contract to verify:** `POST /api/session/truncate` for edit, `POST /api/session/branch` for fork, then existing `POST /api/chat/start` for resending the edited message.
- **iOS UI changes:** Context menu on user messages. Edit opens an inline editor or sheet and warns that later history will be discarded before resending.
- **Model/networking changes:** Preserve the full-history message index using `_messages_offset` from `/api/session`. Edit flow: truncate to the edited message index, reload/update local transcript, send the edited text as a new user turn.
- **Persistence/cache impact:** After edit/fork, reload server state and rewrite cached messages for the affected session. Forked sessions should be cached after load.
- **Tests:** Message index math with `_messages_offset`, truncate body, branch body, edit flow state transitions, copy text extraction.
- **Manual simulator test plan:** Copy a user message, edit the last user message, edit an older user message and confirm the discard warning, fork from a user message and verify the new conversation contains history through that point.
- **Risks/open questions:** Edit is a history rewrite, not an in-place patch. Always confirm when any later messages would be discarded.

#### 8.3 Assistant response long-press menu
- **User-facing goal:** Press and hold an assistant response to show Listen, Fork From Here, Copy, and Regenerate Response.
- **Upstream API/server contract to verify:** `POST /api/session/branch`, `POST /api/session/truncate`, and existing `POST /api/chat/start`.
- **iOS UI changes:** Context menu on assistant messages. Regenerate is available for any assistant message and must confirm that later history will be discarded.
- **Model/networking changes:** Use `AVSpeechSynthesizer` for Listen; no third-party TTS dependency. Regenerate flow: find the nearest preceding user message, truncate before the selected assistant response, put the previous user text through the normal send/start/stream path.
- **Persistence/cache impact:** Reload and rewrite cached messages after regenerate. Forked sessions should be cached after load.
- **Tests:** Copy/listen text normalization, selected assistant index handling, regenerate body construction, branch keep count.
- **Manual simulator test plan:** Listen to a markdown-heavy response, stop listening by leaving/tapping again if supported, copy response text, fork from an assistant response, regenerate latest and older responses with the discard confirmation.
- **Risks/open questions:** Long responses should not block UI while speech is active. Regenerating an older response can discard a large part of the transcript, so the confirmation copy must be explicit.

### Phase 9 — Composer configuration, attachments, and defaults (3–5 days)
**Classification:** required before polish/TestFlight.

#### 9.1 Composer `+` menu
- **User-facing goal:** Add a `+` button in the bottom composer that opens Attach File and Photos. Workspace, profile, model, and reasoning controls live in the composer control row/sheets. Camera capture is deferred from the current v1 scope until privacy manifest and physical-device validation are complete.
- **Upstream API/server contract to verify:** `POST /api/upload`, `POST /api/upload/extract`, `POST /api/chat/start` with an `attachments` body field, `GET /api/workspaces`, `GET /api/workspaces/suggest`, `POST /api/session/update`, `GET /api/profiles`, `POST /api/profile/switch`, `GET /api/models`, `GET /api/reasoning`, `POST /api/reasoning`.
- **iOS UI changes:** Native menu plus sheets/pickers for file import, Photos, workspace selection, profile selection, model selection, and reasoning effort. Use the compact Liquid-Glass composer structure with a bottom control row, and a consistent reasoning icon style where SF Symbols support it. "Choose workspace path" changes the active session workspace for future sends; it does not insert an `@path` reference in v1. "Choose profile" switches the client profile for future sessions; if the current chat already has messages, prompt to start a new session under the selected profile rather than retagging the existing transcript.
- **Model/networking changes:** Add multipart upload support using `URLSession`; add `ChatAttachment`, profile, model catalog, workspace, and reasoning models. Keep picker state synchronized with the current session.
- **Local preference impact:** Let the user mark favorite models from the full model picker. Favorites appear first in the compact composer model menu. Store favorites locally, keyed by exact model ID/provider, and tolerate models disappearing from the server catalog.
- **Persistence/cache impact:** Attachments are pending composer state only until sent. Workspace/model changes should update the session cache after server confirmation. Do not cache uploaded file bytes. Model favorites are local app preferences, not server state.
- **Tests:** Multipart upload request, upload response decoding, chat start with attachments, workspace/model/profile/reasoning request bodies, favorite-model persistence/filtering, offline disabled-state behavior.
- **Manual simulator test plan:** Attach a document, attach a photo, confirm camera does not appear in the current composer menu, send with an image attachment, switch workspace, switch model, favorite/unfavorite models and verify the compact menu updates, switch reasoning effort, switch profile, then send and confirm the server uses selected values.
- **Risks/open questions:** Camera capture is deferred; adding it later requires privacy strings, privacy manifest coverage, and physical-device verification. Profile switching is blocked while an agent stream is running and cannot safely retag an existing conversation. Large uploads must show progress/failure without losing the draft.

#### 9.2 Context window indicator
- **User-facing goal:** Add a small context window indicator next to the send button; tapping it shows context window information.
- **Upstream API/server contract to verify:** `/api/session` fields `context_length`, `threshold_tokens`, `last_prompt_tokens`, `input_tokens`, `output_tokens`, `estimated_cost`, plus `usage` on stream completion when present.
- **iOS UI changes:** Compact indicator in the composer and a tap menu/sheet with percent used, tokens used, context window, auto-compress threshold, and estimated cost when known.
- **Model/networking changes:** Add tolerant `UsageSnapshot` decoding from session and SSE completion payloads.
- **Persistence/cache impact:** Cache the latest usage metadata with cached session/message data when available; show stale/offline state clearly.
- **Tests:** Usage decoding, percentage formatting, missing-field fallback, dark/light UI snapshot if practical.
- **Manual simulator test plan:** Open sessions with and without usage data, send a response, verify the indicator updates, tap it, and verify missing values show as unavailable rather than crashing.
- **Risks/open questions:** If `context_length` is missing, use an estimated 128K fallback only if labeled as estimated.

#### 9.3 Settings default model picker ✅
- **User-facing goal:** In Settings, select the default model from the server model picker.
- **Upstream API/server contract to verify:** `GET /api/models` for grouped models and current `default_model`; `POST /api/default-model` with `{model}` to save.
- **iOS UI changes:** Add a Settings row/sheet for Default Model grouped by provider.
- **Model/networking changes:** Preserve exact model IDs including provider-prefixed forms; do not normalize on the client.
- **Persistence/cache impact:** No durable local cache beyond UI state. New sessions should use the updated server default.
- **Tests:** Model catalog tolerant decoding, default-model request body, setting persistence after reload.
- **Manual simulator test plan:** Change default model, close/reopen Settings, create a new session, and verify the session uses the selected default.
- **Risks/open questions:** The server may return live model options asynchronously in the WebUI; mobile should tolerate missing live models and use the static catalog first.

#### 9.4 Composer slash commands
- **User-facing goal:** Typing `/` in the composer opens a compact command autocomplete panel. Selecting a command inserts or executes the command according to the upstream WebUI behavior.
- **Upstream API/server contract to verify:** Use upstream `static/commands.js` as behavior reference, especially the pinned references `9b8d0bac0ce718ac87c50142d267d6580907dba0/static/commands.js` and `1cde702d47240f233d1c7031a357cc15b2bd4b24/static/commands.js`. The newer pinned file includes `/skills`, `/usage`, and `/compact`; verify any server-backed command metadata and sub-argument sources against `GET /api/commands`, `GET /api/models`, `GET /api/personalities`, `GET /api/skills`, `POST /api/personality/set`, and existing session/chat endpoints before implementing actions.
- **iOS UI changes:** Add an autocomplete panel above the composer for command matches and sub-argument suggestions. Keep the visual style compact and scan-friendly: compact rows, command name, argument hint, and short description. Keyboard navigation is not required on iPhone, but tapping a row must be reliable.
- **Model/networking changes:** Add a local `SlashCommand` catalog for built-in commands from the verified WebUI list. Add tolerant command metadata models for `/api/commands`. Implement only commands with verified mobile-safe behavior; unsupported CLI-only commands should show an inline/local explanation rather than being sent blindly.
- **Persistence/cache impact:** Command metadata can be kept in memory for the composer session. Do not persist server command metadata unless a later offline UX requires it.
- **Tests:** Command parsing, matching, sub-argument loading for models/personalities/reasoning, unsupported-command fallback, and send interception for no-echo commands.
- **Manual simulator test plan:** Type `/`, filter commands, select `/model`, select `/reasoning`, type an unknown command, try a CLI-only command, and confirm normal non-command messages still send unchanged.
- **Risks/open questions:** Some WebUI commands are browser/terminal/theme/voice specific and may not make sense in the native app. Do not expose destructive or server-environment commands until their behavior is verified and the owner approves the mobile UX.

**Phase 9.4 implementation plan (v1.0 — saved for reference):**

**Architecture:**
- New files: `SlashCommand.swift` (model), `SlashCommandCatalog.swift` (static catalog), `SlashCommandExecutor.swift` (parse + dispatch), `SlashCommandAutocompleteView.swift` (SwiftUI panel)
- Modified files: `MessageComposerView.swift`, `ChatView.swift`, `ChatViewModel.swift`, `APIClient.swift`, `Endpoints.swift`
- No new third-party dependencies.

**Implementation slices:**
1. **Slice 1: Static command catalog + autocomplete UI**
   - Add `SlashCommand` model and `SlashCommandCatalog` with the mobile-safe subset.
   - Build `SlashCommandAutocompleteView`: compact card above composer, filters as user types.
   - Wire into `MessageComposerView`: show when `draftMessage` starts with `/`, hide on send or cancel.
   - Selection behavior: if command has no args, execute immediately; if it has args, insert `/name ` into draft and wait for sub-args.
2. **Slice 2: Send interception + client-side commands**
   - Add `SlashCommandExecutor` that parses `/name args` text.
   - Intercept in `ChatView.sendDraftMessage()`: if draft starts with `/`, hand to executor instead of `viewModel.sendMessage()`.
   - Implement client-side-only commands: `/clear` (clear transcript), `/stop` (cancel stream), `/new` (new session), `/help` (show command list).
   - Unsupported-command fallback with a friendly inline message.
3. **Slice 3: Server-backed commands (model, workspace, reasoning, title, personality)**
   - Add `GET /api/commands` endpoint + `AgentCommand` model (tolerant decoding).
   - Add `GET /api/personalities` + `POST /api/personality/set` endpoints + models.
   - Implement `/model`, `/workspace`, `/reasoning`, `/title`, `/personality` using existing or new view model methods.
4. **Slice 4: Skill and usage commands**
   - Add `/skills [query]` using the already implemented `GET /api/skills` endpoint.
   - Render the result as a local assistant-style message grouped by skill category, matching the WebUI behavior from pinned `commands.js`.
   - Add `/usage` only if it can be mapped cleanly to the existing limited session-based Usage Analytics/Insights surface; otherwise show a local explanation that full WebUI token-usage toggling is not available in v1.
   - Add `/compact` as an alias for `/compress` when manual compression is implemented.
   - Do not add `/skill` singular unless upstream exposes it; if users type `/skill`, suggest `/skills`.
5. **Slice 5: Sub-argument autocomplete**
   - After typing `/model `, show model list from `modelCatalogGroups`.
   - After typing `/personality `, fetch and cache personalities list + prepend "none".
   - After typing `/reasoning `, show hardcoded levels.
   - After typing `/workspace `, show workspace roots/suggestions.
   - Cache personalities in memory for the composer session.
6. **Slice 6: Advanced commands (compress/compact, retry, undo, branch)**
   - Add `/api/session/compress`, `/api/session/retry`, `/api/session/undo` client methods.
   - Implement `/compress [focus]`, `/compact`, `/retry`, `/undo`, `/branch [name]`.

**Mobile-safe command inventory:**
- `/help` (echoed) — Show command reference as assistant message.
- `/clear` (no-echo) — Clear local chat transcript.
- `/model <id>` (no-echo) — Switch session model.
- `/workspace <path>` (no-echo) — Switch session workspace.
- `/reasoning <level>` (no-echo) — Set reasoning effort.
- `/new` (no-echo) — Create new session.
- `/stop` (no-echo) — Cancel active stream.
- `/title <text>` (echoed) — Rename session.
- `/personality <name>` (echoed) — Set session personality.
- `/skills [query]` (echoed/local assistant response) — Search/list skills grouped by category using `GET /api/skills`.
- `/queue <message>` (no-echo) — If a response is active, queue a local follow-up turn and send it automatically after the current response finishes; if idle, send the message immediately.
- `/steer <message>` (no-echo) — If a response is active, call `POST /api/chat/steer`; on `{accepted:false}` or network failure, queue the message and cancel the active stream so it sends as the next turn. If idle, send the message immediately.
- `/interrupt <message>` (no-echo) — If a response is active, cancel it and send this message as the next turn; if idle, send the message immediately.
- `/status` (echoed/local assistant response) — Show a local ephemeral session status summary from mobile-held session metadata, active stream state, model/profile/workspace, message count, and usage snapshot when available.
- While a response is streaming, regular composer sends must remain available: empty composer shows stop, non-empty composer shows send. The default regular-send behavior is user configurable in Settings: steer, interrupt, or queue. Queue/steer/interrupt notices should be pinned above the composer while the active response streams, then become transcript notices when the response completes.
- `/usage` (no-echo, limited) — Open or explain the mobile Usage Analytics surface; do not claim WebUI token-usage toggle parity.
- `/compress [focus]` (no-echo) — Compress session context.
- `/compact` (no-echo) — Alias for `/compress`.
- `/retry` (no-echo) — Retry last turn.
- `/undo` (no-echo) — Undo last exchange.
- `/branch [name]` (no-echo) — Fork conversation.

**Unsupported with friendly inline message:** `/terminal`, `/theme`, `/voice`, `/yolo`, `/skill`.

### Phase 10 — Read-only server panels (2–3 days)
**Classification:** required before polish/TestFlight.

#### 10.1 Tasks page
- **User-facing goal:** Add a Tasks row/button on the Sessions screen. Tapping it opens a read-only scheduled jobs page with job details and active status.
- **Upstream API/server contract to verify:** `GET /api/crons`, `GET /api/crons/status`, `GET /api/crons/output`.
- **iOS UI changes:** Sessions-screen navigation row/button, jobs list, detail screen with status, schedule, next/last run, prompt, skills, delivery target, errors, and recent output.
- **Model/networking changes:** Add tolerant cron job/status/output models.
- **Persistence/cache impact:** No offline cache in v1; show normal network error state.
- **Tests:** Cron list/status/output decoding and date formatting.
- **Manual simulator test plan:** Open Tasks, refresh, open a job, confirm active/running status if any job is running, and confirm recent output appears.
- **Risks/open questions:** v1 is read-only. Do not expose create/edit/run/pause/resume even though upstream endpoints exist.

#### 10.2 Skills page
- **User-facing goal:** Add a Skills row/button on the Sessions screen. Tapping it opens all skills sorted by category; tapping a skill opens its detail.
- **Upstream API/server contract to verify:** `GET /api/skills`, `GET /api/skills/content`, and linked file reads through `GET /api/skills/content?name=...&file=...`.
- **iOS UI changes:** Category sections sorted by name, optional search, markdown detail view, linked file detail view.
- **Model/networking changes:** Add tolerant skill summary/detail models.
- **Persistence/cache impact:** No offline cache in v1.
- **Tests:** Category grouping/sorting, detail decoding, linked-file request construction.
- **Manual simulator test plan:** Open Skills, verify categories and sort order, tap several skills, open linked files if available, and verify markdown/code readability.
- **Risks/open questions:** The pinned upstream `api/routes.py` imports skill helpers from the wider Hermes environment, not files in the WebUI repo tree; verify against the running server before implementation.

#### 10.3 Memory page
- **User-facing goal:** Add a Memory row/button on the Sessions screen. Tapping it opens My Notes and User Profile.
- **Upstream API/server contract to verify:** `GET /api/memory`.
- **iOS UI changes:** Two read-only sections rendered with markdown and last-modified metadata when available.
- **Model/networking changes:** Add tolerant memory response model.
- **Persistence/cache impact:** No offline cache in v1.
- **Tests:** Missing notes/profile decoding, mtime formatting, markdown rendering.
- **Manual simulator test plan:** Open Memory, verify My Notes and User Profile content, verify empty states if either file is empty/missing.
- **Risks/open questions:** v1 is read-only. Do not expose `/api/memory/write` until explicitly approved.

### Phase 11 — Limited usage analytics (1–2 days)
**Classification:** required before polish/TestFlight, but limited scope.

- **User-facing goal:** Add an Insights row/button on the Sessions screen that opens a usage analytics dashboard with a timeframe picker.
- **Upstream API/server contract to verify:** No full `/insights` REST endpoint is available in the pinned upstream source. Use `/api/sessions` token/cost fields and optional `/api/session/usage` per-session refresh.
- **iOS UI changes:** Timeframe dropdown/segmented control; dashboard cards for total input tokens, output tokens, total tokens, estimated cost, sessions touched, and top recent costly sessions. Clearly label it as session-based analytics.
- **Model/networking changes:** Add local aggregation over session metadata plus optional per-session usage fetch on demand.
- **Persistence/cache impact:** Can use cached sessions for offline/stale display if available; clearly mark cached/stale analytics.
- **Tests:** Timeframe filtering, aggregate math, missing token/cost tolerance.
- **Manual simulator test plan:** Open Insights, switch timeframes, compare totals against visible session usage where possible, test with missing usage fields, and test offline cached/stale display if cache exists.
- **Risks/open questions:** This is not full CLI/WebUI `/insights` parity. If upstream later exposes a dashboard API, replace the local aggregation with the server endpoint.

### Phase 12 — Polish (2–3 days)
- [x] App icon with owner-supplied light and dark assets.
- [x] Launch screen.
- [x] Composer visual polish: make attachment image thumbnails and file icons larger/easier to inspect while preserving compact composer height.
- [x] Context window visual polish: replace colored context rings with neutral black/white styling that works in light/dark mode and does not compete with message state colors.
- [x] Haptics on send / receive complete.
- [x] Voice input: implement the composer microphone button with native iOS speech/recording support.
- [x] Optional local notification when an assistant response completes while the app is backgrounded, if notification permission is granted.
- [x] Dynamic Type support (test at largest size).
- [x] VoiceOver labels for all interactive elements, including new context menus and server panels.
- [x] Privacy strings for Photos/file import, microphone, and speech recognition where required. Camera remains deferred and is not declared.
- [x] Privacy manifest (`PrivacyInfo.xcprivacy`) — declares no tracking, no developer-collected data, and required-reason `UserDefaults` access for app-only preferences.
- [ ] Crash reporting? **Skip for v1** unless owner wants Firebase Crashlytics.

#### 12.1 Sessions and Settings glass polish
- **User-facing goal:** Overhaul the Sessions screen and Settings page so they feel visually consistent with the glass-forward chat/composer direction (§2b).
- **iOS UI changes:** Rework spacing, row density, toolbar placement, glass surfaces, empty states, Settings grouping, and navigation affordances while keeping existing Hermes actions and accessibility labels intact.
- **Model/networking changes:** None expected. This is a UI polish pass unless the owner explicitly approves additional behavior.
- **Tests:** Existing sessions/settings tests should continue passing. Add focused view model tests only if behavior changes.
- **Manual simulator test plan:** Compare Sessions, Chat, and Settings in light/dark mode; verify session create/open/search/actions still work; verify settings sign-out, default model, theme, cache, and server health actions still work.

#### 12.2 Composer visual polish
- **User-facing goal:** Make the composer feel more legible and tactile without increasing friction.
- **iOS UI changes:** Increase attachment thumbnails and generic file icons so attached content is easier to recognize. Rebalance the attachment strip spacing, remove cramped icon treatments, and keep the composer usable with multiple attachments. Change context window indicator/ring colors to neutral black/white variants that adapt cleanly to light and dark mode.
- **Model/networking changes:** None expected.
- **Persistence/cache impact:** None expected; pending attachments remain composer-local until sent.
- **Tests:** Existing composer and attachment tests should continue passing. Add view-level tests only if sizing logic becomes conditional.
- **Manual simulator test plan:** Attach image and non-image files, confirm thumbnail/icon size and scrolling, send a message with attachments, and inspect the context indicator in light/dark mode.

#### 12.3 Composer haptics
- **User-facing goal:** Sending a message and receiving a completed assistant response should feel responsive.
- **iOS UI changes:** Add subtle haptic feedback on send tap and on assistant response completion. Keep haptics disabled in paths that do not actually send or complete, such as validation failures, cancelled streams, or offline disabled states.
- **Model/networking changes:** None expected. Use native UIKit haptic generators; no third-party dependency.
- **Persistence/cache impact:** None.
- **Tests:** Unit-test state transitions where practical; otherwise verify haptic calls through a thin injectable helper or keep manual-only if the helper would be overengineering.
- **Manual simulator/device test plan:** On device, send a message and confirm light feedback; let a response finish and confirm completion feedback. Verify cancelling a stream does not play the completion haptic.

#### 12.4 Composer voice input
- **User-facing goal:** The microphone button in the composer should dictate text into the draft instead of being inert.
- **iOS UI changes:** Implement the existing mic affordance with recording/listening state, clear stop/cancel behavior, and visible error or permission guidance. Transcribed text should land in the composer draft for user review before sending.
- **Model/networking changes:** Prefer native iOS Speech/AVFoundation APIs if feasible. Do not add third-party dependencies without explicit approval. Keep all server chat behavior unchanged; voice input only populates text.
- **Persistence/cache impact:** Do not persist audio. Draft text follows existing composer state.
- **Tests:** Permission/error state unit tests if the voice controller is abstracted; draft update tests for completed transcription where practical.
- **Manual simulator/device test plan:** Verify permission prompt, dictate a short sentence, edit the transcribed draft, send it, cancel recording, and test denied-permission guidance. Full microphone verification likely needs a physical device.
- **Risks/open questions:** Requires Info.plist usage strings and privacy manifest updates. Simulator microphone/speech behavior may not match device behavior.

#### 12.5 Response completion notifications
- **User-facing goal:** If the user backgrounds the app while an assistant response is streaming, iOS can notify them when the response completes.
- **iOS UI changes:** Request/describe local notification permission at an appropriate moment, preferably from Settings or first background-stream scenario. Do not nag repeatedly. Tapping the notification should return to the relevant session when possible.
- **Model/networking changes:** None expected. Use local notifications only for v1; push notifications remain skipped for v1.
- **Persistence/cache impact:** Store only minimal local preference/permission state if needed. Do not store transcript content in notification payloads.
- **Tests:** Notification scheduling/cancellation helper tests where practical. Implemented policy coverage for preference, authorization, foreground/background, streaming, and normal-completion gates.
- **Manual simulator/device test plan:** Start a response, background the app, wait for completion, confirm local notification appears, tap it, and verify the app returns to Hermes. Confirm no notification appears for foreground completion or cancelled streams.
- **Risks/open questions:** Spec decision remains “no push notifications in v1.” This item is local iOS notification only and must be clearly scoped that way. The app uses only a finite iOS background task when notifications are enabled; it still does not keep streams alive indefinitely. Notification payloads include the `session_id` for future exact-session routing, but broad navigation refactoring was intentionally deferred.

### Phase 13 — TestFlight prep (½ day)
- [x] **Owner creates Apple Developer account** ($99/yr).
- [x] Configure signing in Xcode for Team ID `6GYD9C9N6R`.
- [x] Create App Store Connect app record: `Hermex`, bundle ID `com.uzairansar.hermesmobile`, SKU `hermes-mobile-ios`.
- [x] Answer export compliance: `None of the algorithms mentioned above`; repo declares `ITSAppUsesNonExemptEncryption = NO`.
- [x] Add internal TestFlight path for the owner first.
- [x] Document the install/release process in `DEVELOPMENT.md`.
- [x] Add CI/manual GitHub Actions upload workflow after the first repo-clean TestFlight setup commit.
- [ ] Add external testers after owner verifies an internal build; first external build requires Beta App Review.

**Total estimate: ~7–8 weeks of focused part-time work after the pre-polish scope expansion.**

---

## 9. Server-hosting docs (must include in README)

These instructions ship with the app's onboarding/help screen.

### 9.1 Cloudflare Tunnel (primary)

Document it as the recommended path.

1. Run `hermes-webui` on your machine bound to `127.0.0.1:8787` (the default — no extra config).
2. Install `cloudflared` and authenticate: `cloudflared tunnel login`.
3. Create a tunnel: `cloudflared tunnel create hermes`.
4. In your Cloudflare dashboard, route a hostname (e.g. `hermes.yourdomain.com`) to that tunnel.
5. Run the tunnel: `cloudflared tunnel run hermes` (or as a launchd / systemd service for auto-start — see Cloudflare's docs).
6. **Set `HERMES_WEBUI_PASSWORD`** on the server. The hostname is publicly reachable; the password is your only app-level defense unless you add Cloudflare Access.
7. In Hermex, enter `https://hermes.yourdomain.com` and the password.

**For macOS users running via launchd:**
- Server plist at `~/Library/LaunchAgents/com.hermes.webui.plist` (auto-starts at login, auto-restarts on crash).
- Cloudflared can also be installed as a launchd service via `cloudflared service install`.
- Verify both are loaded: `launchctl list | grep -E 'hermes|cloudflared'`.

**Pros:** real HTTPS, accessible from anywhere, no VPN client on the phone.
**Cons:** publicly reachable URL — if the password leaks, anyone can hit your agent. Recommended hardening: add a Cloudflare Access policy in front of the hostname.

### 9.2 Tailscale (alternative — if you don't want a public hostname)
1. Install Tailscale on the server and the iPhone, sign both into the same account.
2. On the server, start hermes-webui bound to all interfaces with auth:
   ```bash
   HERMES_WEBUI_HOST=0.0.0.0 HERMES_WEBUI_PASSWORD=your-secret ./start.sh
   ```
3. Find the server's tailnet IP with `tailscale ip -4`.
4. In Hermex, enter `http://<tailnet-ip>:8787` and the password.

**Caveat for the iOS app:** Tailscale exposes the server over plain HTTP, which iOS App Transport Security blocks by default. The app supports this in development by adding an ATS exception for tailnet IPs in `Info.plist`. For App Store submission, document that **Cloudflare Tunnel is the recommended setup** because it provides real TLS — App Review will flag a blanket ATS exception.

**Pros:** zero config, encrypted via WireGuard, no public exposure.
**Cons:** must install Tailscale on both ends; plain HTTP requires ATS exception.

---

## 10. Red flags & known risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | **Upstream API has no stability guarantees.** It's the internal API for the bundled web UI. | Pin to a known-good upstream tag; document it in README; tolerant `Codable` with optional fields. |
| 2 | **Project moves fast** (commits daily). | Set a calendar reminder every 2 weeks to re-test against latest tag and bump if green. Any local upstream checkout may drift from GitHub if pulled/edited — verify with `git status` there before assuming a behavior is upstream. |
| 3 | **Auth uses cookies**, not bearer tokens. | Use `URLSession`'s `HTTPCookieStorage` correctly. Don't try to bridge to `Authorization: Bearer`. |
| 4 | **CSRF check on POSTs.** Server inspects `Origin`/`Referer` against `Host`. | Send neither header from native client → server treats as curl-equivalent and allows. |
| 5 | **SSE not WebSocket.** | Use LDSwiftEventSource. Handle heartbeat comment lines. |
| 6 | **Cloudflare ~100s idle timeout on free plan.** | 30s server heartbeats keep streams alive; gaps >100s with no events will cut the connection. Reconnect logic must handle this. |
| 7 | **App Store review for "remote shell" apps** can be sensitive. | Position as "mobile client for your own developer agent server." Prior art: Blink Shell, Working Copy, Termius. |
| 8 | **TestFlight release automation can publish unreviewed work too easily.** | Use short feature branches and only upload owner-verified `master` builds to internal TestFlight. Promote selected builds to external testers manually. |
| 9 | Server may return new SSE event types we don't handle. | Default case in event-decoding switch logs and ignores — never crash. |
| 10 | Long agent runs may exceed iOS background time when app is backgrounded. | Don't try to keep streams alive in background for v1. On foreground, reconnect via `/api/chat/stream/status`. |
| 11 | **The server is typically a personal machine.** If it is asleep, off, or offline, the app shows network errors. | Document in onboarding: "If you can't connect, check that your server machine is awake and your tunnel is running." Add a clear error message that distinguishes "tunnel down" (DNS resolves, connection refused) from "machine asleep" (timeout) where possible. |
| 12 | **A local upstream checkout might be ahead of, behind, or have local modifications relative to GitHub master.** | When reading code from a local checkout, run `git status` and `git log -1` there first to know what version of the API is actually being tested against. Record that SHA in the progress log. |
| 13 | **Edit/regenerate actions rewrite conversation history.** | Use `/api/session/truncate` only after an explicit confirmation whenever later messages will be discarded. Reload the session after mutation before continuing. |
| 14 | **Photo/camera attachments add privacy review surface.** | Add only Apple's native pickers/camera APIs, include clear Info.plist usage strings, and verify behavior on device before TestFlight. |
| 15 | **Limited analytics is not full `/insights` parity.** | Label Phase 11 as session-based usage analytics and do not invent an upstream insights endpoint. Replace with a server endpoint later if upstream adds one. |

---

## 11. Update strategy — keeping up with upstream

This is the long-term maintenance plan. Implement the basics in v1.

### 11.1 In-app
- [ ] On launch, GET `/api/settings` and read `webui_version`.
- [x] Compare against a hard-coded tested WebUI version constant in the app. Implemented in Settings via `AppConfig.testedAgainstWebUIVersion`; the launch-level banner remains open.
- [ ] If different, show a non-blocking banner: "Your server is on v0.50.X. This app was tested with v0.50.Y. Some features may misbehave."
- [ ] Never crash on unknown JSON fields.

### 11.2 In the iOS repo
- [ ] Add a GitHub Action (`.github/workflows/upstream-watch.yml`) that runs daily:
  - Clones latest `nesquena/hermes-webui` master.
  - Diffs `api/routes.py` vs the SHA last marked "tested" in `UPSTREAM_TESTED_SHA` file.
  - If diff non-empty, opens an issue: "Upstream API drift — review needed" with the diff inline.
- [ ] Add a "contract test" target in Xcode: spins up upstream via Docker in CI and hits each endpoint we use, asserting the JSON shape decodes. Run on every PR + nightly.
  - **Note:** CI uses Docker because a native server setup (e.g. launchd) isn't reproducible in CI. The contract tests pin the same upstream SHA the maintainer validates against locally.

### 11.3 Cadence
- Bi-weekly: the maintainer pulls the latest upstream in their server checkout, restarts the server, runs the app against it, and reports any breakage.
- Tag a "tested SHA" in the iOS repo when a build passes. That's what CI's contract tests pin to.
- Hot-fix path: if upstream introduces a breaking change, pin recommended server version in README and tell users to downgrade until app is updated.

---

## 12. Definition of done for v1

The app is "v1 done" when:
- [ ] An internal TestFlight tester can install it and, given their server URL and password, can: log in, see their sessions, open a session, use session/message action menus, send a message with configured composer options and attachments, watch the response stream, browse workspace files, view a file, open read-only tasks/skills/memory, and view limited session-based usage analytics.
- [ ] All §8 pre-TestFlight phases 0–12 complete.
- [ ] Zero crashes in 30 minutes of normal use on iPhone 13 or newer running iOS 18+.
- [ ] README documents Cloudflare Tunnel (primary) and Tailscale (alternative) setup end-to-end.
- [ ] Contract tests pass against the upstream tag pinned in `UPSTREAM_TESTED_SHA`.
- [x] No third-party dependencies beyond the locked list in §5.

---

## 13. Future / post-v1 ideas

These are useful directions, not approved v1 scope. Before implementing any item here, confirm the owner wants it, check whether it changes App Store/privacy/security posture, and verify any required upstream API behavior instead of guessing.

- **Share extension:** Accept URLs/text from Safari, Notes, Mail, Files, Photos, and similar apps, then open Hermes with a draft or import screen. Start with URL/text before richer files/images/PDFs.
- **Live Activities:** Show glanceable status for long-running Hermes responses on the Lock Screen / Dynamic Island. Do not stream every token; show coarse status, elapsed time, and completion.
- **Session search:** Add fast local search across loaded/cached sessions by title, preview, workspace/project, and date grouping. Use server-backed full-text search only if upstream exposes it.
- **Mobile command launcher:** Provide quick saved commands/templates for repeated owner workflows, reusing the existing chat send/start path.
- **Voice-first workflow:** Expand voice input beyond dictation into hold-to-talk, optional auto-send, and possibly spoken summaries, with explicit safeguards against accidental sends.
- **Home Screen widgets / App Shortcuts / Siri shortcuts:** Add quick entry points such as "Ask Hermes" or "Run Hermes command" after the core app is stable.
- **Offline/cache strategy:** Decide how much transcript/workspace context should live on-device, whether extra encryption is needed beyond iOS defaults, and whether Settings needs "Clear local cache" or sensitive-session exclusions.
- **Chat maintainability:** Continue optional focused extraction slices for `ChatView`, `ChatViewModel`, and composer/services after behavior is locked down. Keep these refactors small, test-backed, and behavior-preserving.
- **Cloudflare Access login flow:** If the owner later puts Cloudflare Access in front of the server, design an iOS authentication flow deliberately instead of bolting it onto password auth.
- **Dangerous admin/write actions:** Terminal, file editing/deletion, cron mutation, memory writes, skill edits, and profile create/delete are v2+ only if the mobile safety UX is explicit and owner-approved.

---

## 14. Open questions for the human owner

Stop and ask before guessing:

1. **Repo name** for the new iOS project. ~~Default suggestion: `hermes-mobile`.~~ **Answered: `hermes-mobile`**.
2. **Bundle ID** — **Answered:** `com.uzairansar.hermesmobile`.
3. **App icon / branding** — **Answered:** owner supplied light and dark Hermes icon assets for v1; App Store Connect name is `Hermex`.
4. **Crash reporting** — Firebase Crashlytics or skip for v1?
5. **Privacy policy URL** — required for App Store. Owner needs to provide one (a simple GitHub Pages page is fine).
6. **Default Server URL** — **Answered for current builds:** leave the field empty and show placeholder text reading `https://hermes.yourdomain.com`; the owner enters their URL once.

---

## 15. References

- Upstream repo: https://github.com/nesquena/hermes-webui
- Upstream `api/routes.py`: https://github.com/nesquena/hermes-webui/blob/master/api/routes.py
- Upstream `server.py`: https://github.com/nesquena/hermes-webui/blob/master/server.py
- Upstream `ARCHITECTURE.md`: https://github.com/nesquena/hermes-webui/blob/master/ARCHITECTURE.md
- Pinned local upstream copy: `.codex-tmp/hermes-webui/` (read-only; see `CONTRACT_TESTS.md`)
- Cloudflare Tunnel docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- Tailscale download: https://tailscale.com/download
- LDSwiftEventSource: https://github.com/launchdarkly/swift-eventsource
- swift-markdown-ui: https://github.com/gonzalezreal/swift-markdown-ui

---

## 15. Progress log

> See `git log` and merged PRs for the dated history. The spec's `## 8. Step-by-step build plan` has the phase checklist.

---

## 16. Constants for the agent to fill in as you go

These values live in dedicated, authoritative files. Read them there instead of
duplicating the numbers here — duplicated copies rot.

```
UPSTREAM_TESTED_SHA / UPSTREAM_TESTED_TAG / TESTED_AGAINST_VERSION:
  read the root `UPSTREAM_TESTED_SHA` file (machine-readable pin) and the
  human-readable tag in `CONTRACT_TESTS.md` / `DEVELOPMENT.md`. Do not
  duplicate the values here — they rot.
APP_VERSION / APP_BUILD:
  read MARKETING_VERSION / CURRENT_PROJECT_VERSION from
  `HermesMobile.xcodeproj/project.pbxproj`.
```

---

## 17. Kanban implementation specification

### 17.1 Scope and authority

Hermex will provide native iPhone functional parity with every user-facing Kanban
capability in the verified Hermes WebUI baseline. Visual parity is not required. The
native interaction model, accessibility behavior, and safety boundaries in this
section are normative even where they differ from the desktop WebUI.

The compatibility baseline is the maintainer's authenticated running WebUI at commit
`d4e80b45498a914ce67e6b976145804638a46caf`. Its `api/kanban_bridge.py` is byte-for-byte
identical to pinned upstream commit
`2f3e42dc649e6d2bae572a0655681d9bb212c78d`. The official Hermes Bridge API
documentation intentionally omits Kanban internals, so Hermex makes no version-range
promise for this feature. Compatibility is capability-based and must be revalidated
after a material upstream bridge change.

The canonical rationale and evidence are:

- [Inventory the upstream Kanban domain and API contract](https://github.com/uzairansaruzi/hermex/issues/140)
- [Map Kanban integration constraints in Hermex](https://github.com/uzairansaruzi/hermex/issues/141)
- [Verify authenticated Kanban wire responses on the running server](https://github.com/uzairansaruzi/hermex/issues/146)
- [Choose Hermex's Kanban domain vocabulary](https://github.com/uzairansaruzi/hermex/issues/148)
- [Choose Hermex's Kanban compatibility boundary](https://github.com/uzairansaruzi/hermex/issues/147)
- [Choose Kanban mutation, conflict, and failure semantics](https://github.com/uzairansaruzi/hermex/issues/143)
- [Choose the native iPhone Kanban interaction model](https://github.com/uzairansaruzi/hermex/issues/142)

Use the Kanban vocabulary in root `CONTEXT.md`. In particular, upstream `task` and
`task_id` remain network-boundary names; user-facing and Swift domain names use Card
and a `Kanban` qualifier.

### 17.2 Compatibility handshake and capability boundaries

Before showing live Kanban data, Hermex must perform this non-mutating handshake:

1. `GET /api/kanban/config`
2. `GET /api/kanban/boards`
3. `GET /api/kanban/board?board=<server-reported-current-slug>`

Every upstream wire-model property is optional, unknown fields are ignored, and
decoding is followed by capability-specific semantic validation. Hermex must not
infer missing Board identity, current Board, Card identity, Card Status, dependency
direction, or mutation outcome. An unknown Status remains visible as an unsupported
server value and disables mutations for that Card.

Failure of the core read contract makes Kanban unavailable but does not hide its
normal navigation entry after release. Authentication, network reachability, server
failure, and incompatible-contract states remain distinguishable and offer Retry.
SSE failure degrades to event polling. A missing or incompatible write disables only
that capability for the current server session when browsing remains safe. Partial
compatibility is disclosed persistently and unavailable controls explain why.

Capability probes must never mutate state, Preview Dispatch, or Run Dispatcher. They
must never try speculative paths, renamed fields, or alternate payload shapes.

### 17.3 Verified HTTP surface

All requests use the existing authenticated `URLSession` cookie jar and configured
custom proxy headers. Native requests do not add `Authorization`, `Origin`, or
`Referer`. JSON routes are expected to return `application/json`; SSE is expected to
return `text/event-stream`. Each implementation slice must re-check its exact request
and response shape against the running server, then the latest official API docs, then
the pinned upstream source, in the precedence required by `AGENTS.md`.

| Capability | Verified method and path | Required contract notes |
|---|---|---|
| Configuration | `GET /api/kanban/config` | Columns, Profiles/counts, defaults, grouping/archive/Markdown flags, and `read_only`. Hermex reads but never writes the server-global grouping setting. |
| Boards | `GET /api/kanban/boards` | Board metadata/counts, `current`, and `read_only`. Never surface `db_path` in normal UI or logs. |
| Board snapshot | `GET /api/kanban/board` | `board`, Profile/tenant/archive filters, and optional event cursor; full `changed:true` or minimal `changed:false` envelope. |
| Stats and Profiles | `GET /api/kanban/stats`, `GET /api/kanban/assignees` | Stats tolerate the older minimal shape. WebUI-parity UI uses total and per-Status counts. |
| Events | `GET /api/kanban/events`, `GET /api/kanban/events/stream` | Cursor-based polling and SSE resume. SSE begins with `hello`, then `events`; reconnect when Board changes. |
| Card detail | `GET /api/kanban/tasks/{id}` | Card, comments, events, prerequisite/dependent links, Dispatch Runs, and `read_only`. |
| Worker log | `GET /api/kanban/tasks/{id}/log` | Tail is a byte limit; show log content only in an explicit Card operational-history surface. |
| Create Card | `POST /api/kanban/tasks` | Required title; supported native fields are body, initial Triage/To Do/Ready Status, priority, Assigned Profile, tenant, workspace kind/path, skills, maximum runtime, one initial Prerequisite, idempotency key, and Board. |
| Edit Card | `PATCH /api/kanban/tasks/{id}` | Title, body, tenant, priority, Assigned Profile, and permitted Status transition. Create-only fields remain visibly non-editable. Do not use the legacy `/patch` alias. |
| Comments | `POST /api/kanban/tasks/{id}/comments` | Nonblank body; no edit/delete support. |
| Block/Unblock | `POST /api/kanban/tasks/{id}/block`, `POST /api/kanban/tasks/{id}/unblock` | Preserve the structured server verbs and refusal errors. |
| Dependencies | `POST /api/kanban/links`, `POST /api/kanban/links/delete` | Exact direction is Prerequisite `parent_id` to Dependent `child_id`. |
| Bulk Actions | `POST /api/kanban/tasks/bulk` | Nonempty IDs with Archive, Status, Assigned Profile, or priority. HTTP 200 can contain per-Card failures and is never treated as atomic success. |
| Dispatcher | `POST /api/kanban/dispatch` | `board`, `dry_run`, and `max` are query parameters; Board in JSON is ineffective. Hermex always uses maximum eight. |
| Create Board | `POST /api/kanban/boards` | Slug plus name/description/icon/color. Hermex does not automatically make the new Board active. |
| Edit/Archive Board | `PATCH /api/kanban/boards/{slug}`, `DELETE /api/kanban/boards/{slug}` | Slug is immutable. Archive uses DELETE without hard-delete query. Default Board cannot be archived. |
| Make Active Board | `POST /api/kanban/boards/{slug}/switch` | Confirm because it changes shared server state visible to other Hermes clients. |

Kanban Card assignment is scoped entirely to the Kanban contract. The assigned value
is transported only in the Kanban `assignee` field, and assignment choices come from
the Kanban config, Board snapshot, and assignee-history responses above. Creating,
editing, filtering, or bulk-assigning Cards must never call `/api/profile/switch`,
change the active chat Profile cookie, or source assignment state from that client-wide
chat-profile selection.

Hermex deliberately does not expose backend-only hard deletion, archived-Board
enumeration/restoration, the global `PATCH /api/kanban/config` grouping mutation, the
legacy Card patch alias, or unsupported task attachments. A single-title quick-create
control is not required: New Card opens the complete native editor and preserves the
full user capability.

### 17.4 Native information architecture and interaction model

Kanban is a distinct `SessionListUtilityDestination` constructed with the active
server URL and centralized authentication-error handling. Browsing a Board is local
to Hermex and never changes the server's active Board. Profile grouping is also a
local presentation choice. Any persisted Board/filter/Status preference must be keyed
by server; initial implementation may keep all Kanban navigation state transient.

The selected interaction model is **Status Focus**:

- a horizontally scrollable Status selector with counts;
- one Status at a time as a vertical Card list;
- Board switching in the header;
- explicit search, Profile/tenant/archive/only-mine filters, and clear-filter state;
- visible non-drag Move actions; drag may supplement but never replace them;
- Select Cards mode with named Bulk Actions and a persistent selection count;
- Card detail/editor navigation using native lists, forms, sheets, and toolbars;
- adaptive monochrome utility controls, reserving meaningful color for Status;
- Profile lanes available as a local grouping without mutating server configuration.

Card summaries preserve ID, priority, tenant, title, Markdown-aware body preview,
Assigned Profile/Unassigned, comment/dependency counts, age, and the verified WebUI
staleness thresholds: Running at 10 minutes/1 hour, Ready at 1 hour, and Blocked at
1 hour/24 hours. Running is visible but is never offered as a direct destination.

Card detail preserves Markdown description, metadata, comments, events,
Prerequisites/Dependents, Dispatch Runs, and explicitly requested worker-log content.
Operational values such as filesystem paths, claim identifiers, worker identifiers,
and raw payloads must not leak through generic errors, analytics, or logging.

### 17.5 Mutation, concurrency, and recovery rules

Ordinary reversible Card mutations are optimistic, show an Updating state, and are
serialized per Card. Unrelated Cards may mutate concurrently. Board-wide operations
(Bulk Actions, Archive Board, Make Active Board, and Run Dispatcher) prevent
overlapping writes on the same Board. Server state is always authoritative.

SSE, polling, and refresh snapshots must not overwrite a pending optimistic mutation.
When a response contains sufficient authoritative state, apply it; otherwise refetch
the affected Card or Board. There is no revision token or conflict guarantee.

If a Card changed after its editor opened, preserve the draft and block ordinary Save.
Offer Reload Server Version (confirm before discarding the draft) or Review and
Overwrite. This is best-effort detection and must not be described as a guarantee.

Require confirmation for:

- Run Dispatcher, warning that it may start workers and consume API budget;
- Archive Board, warning that Hermex cannot restore it in-app;
- Archive Cards as a Bulk Action;
- creating a Ready, Unassigned Card;
- every transition out of Running, warning that claim/worker state may be cleared;
- Make Active Board, warning that the change is shared with other Hermes clients.

Do not require confirmation for ordinary edits, Preview Dispatch, ordinary Status
changes, or a single Archive Card. After a successful single-Card archive, offer
short-lived Undo to the immediately previous Status using the same reconciliation
rules. Archived Cards remain available through an explicit filter.

Reads may retry automatically. Writes and Run Dispatcher are never blindly retried.
After timeout, disconnect, or malformed mutation response, show Checking Result and
refetch canonical state. Report success if the intended result is present, offer Try
Again if absent, or report Outcome Uncertain and require another refresh if still
unknowable. Retrying Card creation reuses the original idempotency key.

Bulk Actions are non-atomic. Refetch every selected Card before reporting results,
keep successes committed, identify each Card needing attention, retain failed Cards
as selected, and enable Retry Failed only after reconciliation. Never retry the whole
original selection automatically.

### 17.6 Live updates, offline behavior, and Dispatcher

SSE is primary while Kanban is visible. Coalesce event bursts before refetching
affected Board/Card state. After repeated stream failures, use 30-second event polling
and show a subtle persistent **Live updates delayed** notice. Pull-to-refresh performs
a full reload and retries SSE. Suspend live refresh in the background and reconcile
immediately on foreground.

When connectivity drops, preserve the in-memory snapshot, mark it
**Offline—showing previously loaded data**, mark loaded detail stale, and disable all
mutations, shared-state controls, and Dispatcher actions. Do not persist Kanban data
for offline use in the initial implementation. Reconcile fully before re-enabling
writes after reconnection.

Preview Dispatch is advisory, timestamped, and may become stale. It is not required
before Run Dispatcher. Preview and Run are single-flight per Board. Run Dispatcher
uses maximum eight, is never automatically retried, and presents a persistent result
summary after refetching the Board. Integration/manual testing must never run billable
workers or mutate the maintainer's real Boards.

### 17.7 Accessibility, localization, and error presentation

Every slice owns its accessibility and localization; these are not final-pass cleanup.
Support all shipped languages, plural Card counts, Dynamic Type without fixed Card
heights, VoiceOver summaries and actions, 44-point practical hit targets, keyboard
operation where applicable, Reduce Motion, light/dark appearance, and meaningful focus
retention after move, archive, filtering, refresh, mutation failure, and editor
dismissal. Movement, selection, and every Bulk Action must work without drag.

Errors remain attached to the affected action or screen until resolved. Validation
errors stay with their fields. Missing entities trigger reconciliation with explicit
copy. Authentication uses the existing per-server login flow. Generic transport/server
errors preserve known data and offer contextual Retry. Normal UI never exposes raw
payloads, server filesystem paths, claim/worker identifiers, or operational logs via
generic error text.

### 17.8 Delivery, testing, and activation gates

Incomplete Kanban must remain hidden from normal navigation on `master`. Intermediate
slices are reachable only in Debug builds through `--kanban-lab`, following the
existing Streaming Lab launch-argument pattern. The final parity slice removes the
temporary gate and adds the normal Kanban utility destination only after all blockers
and release evidence pass.

Each slice must include:

- exact endpoint method/path/query/body tests for the surface it adds;
- minimal-envelope, unknown-field, unknown-Status, malformed-response, and semantic
  validation tests appropriate to that capability;
- view-model tests for stale responses, mutation serialization, reconciliation,
  partial/ambiguous outcomes, and server isolation where applicable;
- localized copy and accessibility semantics for every new UI state;
- its focused XCTest suites, then the full XCTest suite before review;
- a signed Debug simulator build and launch when UI changes.

The dependency-ordered implementation slices are:

1. hidden compatibility shell and Debug Kanban Lab;
2. read-only Status Focus Board browsing;
3. live updates and offline reconciliation;
4. Card detail, comments, and operational history;
5. Card creation and editing;
6. Card workflow, dependency, and archive mutations;
7. accessible selection and Bulk Actions;
8. Board management and shared active-Board controls;
9. Preview Dispatch and Run Dispatcher;
10. final parity validation and normal-navigation activation.

Owner validation is a required pre-publication gate for slices 2, 7, 9, and 10. The
final gate also requires automated contract coverage for every supported request and
response, mutation/Dispatcher request testing against an isolated seeded reference
server without launching billable workers, authenticated read-only smoke testing on
the maintainer's running server, the full XCTest suite, a signed simulator scenario
pass, and owner validation of the complete experience on the release-test iPhone.

The final manual scenario pass covers at minimum:

- compatible, incompatible, authentication, offline, and partial-capability entry;
- single/default and multi-Board switching without silently changing server state;
- dense, empty, filtered-empty, loading, and error Board states;
- every Status, unknown Status, local Profile grouping, search, and all filters;
- Card create/edit, Ready-Unassigned warning, conflict choices, and creation retry;
- explicit non-drag moves, Running exit, Block/Unblock, Complete, Archive, and Undo;
- comments, Prerequisites/Dependents, Dispatch Runs, and worker-log access;
- selection and each Bulk Action, including partial failure and Retry Failed;
- Board create/edit/archive and confirmed Make Active Board;
- Preview Dispatch, confirmed Run Dispatcher, stale preview, and persistent results;
- SSE refresh, polling fallback, background/foreground reconciliation, and reconnect;
- VoiceOver, accessibility Dynamic Type, Reduce Motion, light/dark appearance, and
  focus retention across the mutation and navigation cases above.
