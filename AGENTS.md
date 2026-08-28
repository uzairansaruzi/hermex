# Hermex

Hermex is a native SwiftUI iPhone app for a self-hosted Hermes agent. It talks directly to the user's `hermes-webui` server over HTTPS and gives them a phone-native control surface: start and steer sessions, watch streaming work, browse the workspace, and recover from wherever they are. The Xcode target and scheme are `HermesMobile`; the App Store name is `Hermex`.

You can think of Hermex as an open source "bring-your-own-server" iPhone client for Hermes. The phone is the control and review plane; the server owns execution, tools, models, and the user's data.

## What makes Hermex special?

Hermex is on the App Store and people run it against their own servers every day. It's important we maintain the things they rely on as we continue to iterate on the product. Here's a brief list of the things we can never compromise on.

### 1. Open at the core

Hermex is truly open. We share our roadmap (GitHub Issues), we share how we think about things, and of course we share all our code. There is no Hermex relay, hosted backend, analytics service, or tracking layer: agent work and data stay on the user's hardware. We work in the open, and should strive to stay that way.

### 2. Performance without compromise

Lots of apps have gotten bogged down with bad tech decisions and "slop". We have not, and we're proud of the performance of Hermex. We regularly audit for performance regressions, often caused by unnecessary view invalidation, unstable identity in lists, eager work in scrolling paths, and animations that ignore Reduce Motion. Make sure all changes are considerate of performance impact.

### 3. Remote ready

Hermex connects to servers wherever they live: on the same Mac over `localhost`, across a Tailscale tailnet, or through an HTTPS tunnel such as Cloudflare. Long-lived SSE streams over those hops, reattaching after backgrounding, and multiple configured servers are core to the product. Whether users are on their local network or half a world away from their Mac, we need to make sure new features are properly supported, and that nothing scoped to one server ever shows up under another.

### 4. Multi-surface

Hermex has 3 key app surfaces: **the app**, **the share extension**, and **the Live Activity widget**.

**The app** is the main surface. It is a native SwiftUI app, not a web wrapper, and should behave like a first-rate iOS app across navigation, gestures, keyboard input, accessibility, backgrounding, deep links, App Intents, and notifications.

**The share extension** (`HermesShareExtension`) lets users send files and text from other apps into a session. It stages imports through the app group and hands off to the main app.

**The Live Activity widget** (`HermesLiveActivityWidget`) shows streaming progress on the Lock Screen and Dynamic Island and routes taps back into the app. Both extensions are separate Xcode targets with their own membership of shared models and resources.

## A note from Uzair

I like ambitious ideas, simple systems, and software that feels obvious. Do not preserve complexity just because it already exists. Do not introduce machinery because it looks architecturally impressive. Understand the real constraint, then fight for the smallest model that makes the correct behavior unsurprising.

Channel both "measure twice, cut once" and "yagni". Fight scope creep. Try to honor the dev's intent in both a minimal and realistic fashion.

The rest of this document is meant to help you navigate the codebase and make changes effectively. Think of these instructions less as "hard rules", more as "good defaults". The developer's preferences should be able to override anything here. If a request conflicts with a rule here or with the server contract, stop and ask.

## A small glossary

We need to be on the same page with terminology. When communicating, use this language:

- **you** means the agent reading this file and changing Hermex.
- **we, us, and maintainer** mean Uzair and the people building Hermex. These are who you are talking to now.
- **user** means the person using Hermex to direct their Hermes agent.
- **agent** means the Hermes agent a user runs on their server. Depending on context, that may also include you.
- **server** means the user-configured `hermes-webui` instance. **upstream** means the `hermes-webui` project itself, whose API can drift.
- **active server** means the configured server whose auth, identity, cached data, and screens are currently selected.
- **session** means a server-backed agent conversation. A **stream** is the SSE connection carrying one response's live events.
- **workspace** means a server-side filesystem location available to a session. A **Profile** is a server-side agent configuration.
- **Tasks** are scheduled cron jobs. Kanban work units are **Cards**, not tasks. `CONTEXT.md` owns the rest of the canonical Kanban vocabulary.
- **slice** means one independently testable part of the selected issue.

## Start with the current state

1. Inspect `git status` and preserve changes you did not create.
2. The selected GitHub issue is the scope and the handoff. Read it with its comments (`gh issue view <n> --comments`) before anything else. Implement only the issue the maintainer selected or one labeled `ready-for-agent`; an open issue list is not an instruction to implement everything.
3. Read only the docs the issue and this file point at. There is no product spec; the issue, the code, and the server contract are the spec.
4. On "wrap up": verify the build and tests, commit the validated code, and leave the resumable state (what landed, how it was validated, what is next) as a comment on the issue or in the PR body. A push still needs approval.

## The three ways to hurt yourself

1. **Killing by pattern.** Never `pkill -f`, `pgrep | kill`, or `kill` a PID you found by matching a name, path, or worktree string. Your own agent process has this worktree's path in its argv, and this Mac runs several simulators and agent sessions at once. Kill only a PID you captured at spawn. The same goes for `rm -rf`, `git push --force`, and `simctl shutdown all`: suggest them and let the maintainer run them.
2. **Touching the live server.** The maintainer's `hermes-webui` runs on another Mac behind a tunnel, holding real sessions and real credentials. Reading from it with `curl` is fine, and the best way to verify a contract (see Working with the server). Never restart it, change its tunnel or Tailscale routes, or run mutations against its sessions. A mutating smoke uses one disposable session you created and cleans up only that session and anything it branched.
3. **Installing an unsigned build.** `CODE_SIGNING_ALLOWED=NO` is for compile-only checks and CI. It strips entitlements, so Keychain writes fail with `errSecMissingEntitlement` and login silently breaks. Put the app on the simulator via XcodeBuildMCP `build_run_sim` or a plain signed Debug build, and never hand-sign a simulator app: a normal sim build is ad-hoc signed and that is exactly what works.

## Hit every surface

The most common defect in this repo is a change that works on the path you tested and is missing everywhere else. Before calling UI work done, walk this list and say which entries applied:

- **Entry points.** A behavior reachable from the chat view is usually also reachable from the session list's context menus, Settings, hardware-keyboard shortcuts, deep links, App Intents, the share extension, and Live Activity taps. Fixing one is not fixing the feature.
- **Targets.** Main app, `HermesShareExtension`, `HermesLiveActivityWidget`, and `HermesMobileTests`. A shared model or resource change needs a target-membership decision for every target that consumes it.
- **Servers.** Multiple configured servers are real. Switch between two and check that credentials, custom headers, cache, drafts, identity, selections, and defaults stay with their server. Read `docs/agents/multi-server-state-isolation.md` before touching auth, server switching, cache keying, or per-server settings.
- **Contracts.** Anything crossing the wire goes through `Endpoint` and a tolerant `Codable` model. Change endpoint construction, request body, decode, and SSE handling together, and verify each against upstream (see Working with the server).
- **Reverse states.** If you added a way in, add the way out and the way to see it. Archive needs restore. Pin needs unpin. Start needs stop. Optimistic mutation needs rollback. A one-way door is a bug.
- **Connection modes.** `localhost`, Tailscale, and tunnel behave differently; Cloudflare closes quiet streams. Backgrounding, reconnecting, and reattaching to a live stream instead of resending the message are real cases.
- **Native quality.** Dynamic Type, VoiceOver labels, Reduce Motion, light and dark appearance, keyboard focus, and localization. Read `docs/agents/i18n.md` before touching the String Catalog, plurals, casing, or RTL.
- **Docs.** Agent conventions live in `docs/agents/`; new vocabulary in `CONTEXT.md`; build and simulator mechanics in `DEVELOPMENT.md`; upstream parity status in `docs/agents/feature-gap-index.md`; Kanban contract and behavior rules in `docs/agents/kanban.md`. `CHANGELOG.md` is written at release time, not per PR.

## Working with the server

- There is no in-repo dev server. Hermex is developed against a self-hosted `hermes-webui` reachable over real HTTPS; `curl https://<your-server>/health` before debugging the client. For simulator-only work `http://localhost:8787` works when the server runs on the same Mac. Setup options live in `DEVELOPMENT.md`.
- **Never invent an endpoint, header, SSE event, or JSON shape.** Verify in this precedence order: (a) `curl` a running server, the final arbiter; (b) the official API docs at https://get-hermes.ai/api-docs/ for endpoint intent, the auth contract, and SSE vocabulary (no version pin; tracks the latest release); (c) the pinned upstream copy at `.codex-tmp/hermes-webui/api/routes.py` for exact JSON shapes, which may lag the release the docs describe. Clone it if missing: `git clone https://github.com/nesquena/hermes-webui .codex-tmp/hermes-webui`. It is read-only; refreshing with `git pull` is fine.
- `UPSTREAM_TESTED_SHA` is the compatibility pin (currently `hermes-webui` v0.51.85). To advance it: `curl` the read-only endpoints in `Endpoints.swift` against a live server, run the mutating ones against one disposable session, then edit the file and name the validating commit in the PR. When a contract changes, record the verified handler, shape, and upstream commit in the issue or PR. Validate volatile details just in time instead of copying them into long-lived docs.
- Every server-facing `Codable` model decodes tolerantly: optionals for fields upstream might add, omit, or rename. Unknown fields never crash the app.
- No new third-party dependency without approval. The locked list is LDSwiftEventSource, swift-markdown-ui, Splash, Highlightr, KeychainAccess, and SwiftMath; everything else is Apple frameworks (`URLSession`, SwiftData, Keychain, OSLog, XCTest).
- A bug that also reproduces in the upstream web UI against the same server is a server bug. File it upstream and link it from a Hermex issue only if the app still needs a safer fallback.

## Test data

A live server is not a test fixture. Unit tests run against `URLProtocol` mocks, Keychain doubles, in-memory SwiftData, and scripted SSE fixtures (`HermesMobileTests/ScriptedSSEStreamFixture.swift`); prefer the established pattern for the area you touch.

- Read-only checks against a live server are fine when the maintainer has put one in scope. Mutation follows rule 2.
- Real credentials, App Store Connect secrets, and tester data stay out of the repo and out of command output.

## Verifying

- Smallest proof that the change works while iterating: focused XCTest for the behavior you touched, via XcodeBuildMCP `test_sim`. Defaults live in `.xcodebuildmcp/config.yaml` (scheme `HermesMobile`, sim **iPhone 17**); if that sim is missing, pick a nearby iPhone and say which.
- **Run the full XCTest suite before asking for review or committing a slice.** A failing build or test becomes the current task; fix it before writing more code on top.
- Behavior changes ship with focused tests for that behavior.
- Async flows wait on expectations and scripted fixtures, never on sleeps or polling. A test that needs a timeout to pass is wrong.
- UI or runtime changes get one integrated pass in the real app: build, install, and launch a signed Debug build (`build_run_sim`), then hand the maintainer a short manual simulator test plan. Capture screenshots or logs when they are evidence. Subagents do not launch their own builds.
- Run `scripts/check-swift-file-sizes` when a production Swift file grows. It is a warning, not a gate: use it to notice a missing seam, not to force unrelated refactors into the current issue.

## Pull requests

- Never push a branch, open or update a PR, or merge unless the developer explicitly asks you to do so.
- One issue → one short `issue/<n>-slug` branch → one PR (`chore/` or `fix/` for approved work without an issue). `master` is the protected internal-TestFlight candidate: keep it buildable, never do feature work on it.
- Conventional commit titles, plain language: `fix(chat): recover the active stream after foregrounding`.
- Body: follow the PR template. `Fixes #<n>`, the problem in a sentence or two, then how you fixed it and exactly how it was tested. End with the model and harness that did the work.
- UI changes need before/after images. Motion or timing needs a short video.
- Upload PR evidence to GitHub. Never commit PR-only screenshots or assets.
- One concern per PR. If the description says "also", split it.
- When babysitting: poll checks and comments newer than the last push, verify each bot finding against the source, fix real ones, dismiss false positives with a written reason. Stay quiet when nothing is new. Stop when the bots are green on the latest commit.

## Plans and work artifacts

- Do not commit implementation plans, research notes, or agent scratch files. Keep temporary working material outside the worktree.
- Track active maintainer work in the GitHub issue that owns it. Issue, label, and staged-versus-express conventions live in `docs/agents/issue-tracker.md` and `docs/agents/triage-labels.md`. External proposals follow `CONTRIBUTING.md`.
- Put durable architecture, constraints, and decisions in the checked-in docs (`docs/agents/`, `CONTEXT.md`, `DEVELOPMENT.md`). Update those docs when the product changes so agents find current facts instead of abandoned intentions.
- A merged PR is the implementation record. Close or update its issue when the work lands; do not preserve a second checklist in the repository.

## How it works

`HermesMobileApp` owns the scene, `AuthManager`, and the SwiftData container. `ContentView` routes unconfigured, logged-out, and logged-in states; the logged-in subtree is keyed by the active server so a switch rebuilds server-bound views. Feature views own `@MainActor @Observable` _view models_, which call the `APIClient` actor through feature-specific extensions; `Endpoint` centralizes paths and query construction. `SSEClient` decodes chat events, `ChatStreamCoordinator` owns response lifecycle, reconnect, replay, and Live Activity updates, and `KanbanEventStreamClient` handles Kanban live updates. Keychain holds credentials, the server registry, and custom headers; SwiftData holds server-keyed cached sessions and messages; draft and attachment stores keep unsent composer work. The share extension stages imports through the app group; App Intents, deep links, notifications, and Live Activities route the user back into the app.

Canonical vocabulary: `CONTEXT.md`.

## Where code lives

- `HermesMobile/HermesMobileApp.swift` and `HermesMobile/ContentView.swift` - app entry and root routing.
- `HermesMobile/Features/` - feature views, view models, and coordinators for Chat, SessionList, Settings, Workspace, Tasks, Skills, Memory, Insights, Kanban, Onboarding, and Share.
- `HermesMobile/Networking/` - `Endpoint`, `APIClient` and its extensions, SSE, request encoding, API errors.
- `HermesMobile/Models/` - server and presentation models, including the server registry.
- `HermesMobile/Auth/` - authentication and Keychain access.
- `HermesMobile/Persistence/` - SwiftData cache models and stores.
- `HermesMobile/AppIntents/` and `HermesMobile/LiveActivities/` - system entry points and activity coordination.
- `HermesShareExtension/` and `HermesLiveActivityWidget/` - separate targets. Shared files need target-membership checks.
- `HermesMobileTests/` - the XCTest suite, one target directory. Keep tests near the behavior in name and scope.
- `Config/`, `ci/`, and `.github/workflows/` - signing, CI, and release configuration. Treat edits there as release-sensitive. App identity resolves through xcconfig and is not grep-able: bundle ID `com.uzairansar.hermesmobile`, tests `….tests`, Team `6GYD9C9N6R`, SKU `hermes-mobile-ios`.
- `.codex-tmp/hermes-webui/` - the gitignored, read-only upstream reference. Prefer its patterns over invented ones. Never edit or import from it; refresh with `git pull` when advancing the pin.

## Taste

- Complexity belongs at the networking boundary. `Endpoint` and the `APIClient` extensions absorb the server contract, view models own screen state, views stay dumb.
- The server owns execution. The app owns mobile interaction, presentation, drafts, credentials, and the read-only offline cache. Do not move server responsibilities into this repo.
- Make async ownership explicit. Cancellation, stale results, reconnects, and duplicate events are normal mobile conditions; never mutate state after the owning view or task is gone.
- Optimistic UI only when failure has a clear rollback. Never show success before the server says the operation succeeded.
- Destructive and privacy-sensitive actions stay deliberate: file writes, Git operations, server administration, and credential changes get copy that states the real consequence.
- Comments describe how a thing is used, and move when the code moves. To be used mostly to describe functions, not to annotate every line of behavior.
- Our users drive agents from a phone all day and notice a dropped frame, a lying spinner, and a stale label. The intended feel is dense, calm, and operator-grade. No continuously repainting animations; every animation respects Reduce Motion.
- The look is compact and glass-forward: a Liquid-Glass composer with the runtime controls in its bottom row, dense native pickers rather than marketing pages, and no third-party UI packages to get there.
- The target builds in Swift 5 language mode with targeted concurrency. Fix what the build flags, not what strict Swift 6 would.
- If a rule here fights the task in front of you, say so loudly and get a human sign-off before breaking it.

## Branch TestFlight (maintainer-only)

"push to branch testflight" means upload the current branch to the side-by-side **Hermex Branch** internal TestFlight app (`com.uzairansar.hermesmobile.branch`). It is a TestFlight upload, **not** a git push. Validate first, use a unique `CURRENT_PROJECT_VERSION` (e.g. `YYYYMMDDHHMM`), and follow the archive and export commands in `DEVELOPMENT.md`. Never touch the production `com.uzairansar.hermesmobile` app, invite testers, or change App Store Connect state unless explicitly asked. `TESTFLIGHT.md` owns release gates.

## Additional tips

- Don't drive the simulator UI or take screenshots unless the user explicitly agrees or the slice needs visual evidence. The maintainer runs the manual checks.
- Surface tradeoffs in plain English before non-obvious choices. Product decisions belong to the maintainer: an issue labeled `ready-for-human` is a question, not a task.
- After each slice, report: (1) files changed (2) build/test command run (3) result (4) next suggested step, plus a short manual simulator test plan when UI changed.
- Security is important, but should not be over-indexed on, especially for dev mode/maintainer-only features. Credential-like values (server URLs, sessions, headers) live in Keychain, not `UserDefaults`.
- If something here surprises you or contradicts the project, tell the developer and propose an `AGENTS.md` edit rather than silently editing it. Every line here is a Band-Aid for what can't be fixed in code, tests, or tooling.
