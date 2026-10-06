# Development

This app is developed against a self-hosted `hermes-webui` server exposed over real HTTPS. See [`README.md`](README.md) for the product overview and [`AGENTS.md`](AGENTS.md) for the working rules.

> Sections covering TestFlight and App Store Connect are **maintainer-only ops** — they require the maintainer's Apple Developer account and App Store Connect access. Contributors never need them to build, test, or run the app.

## Primary Test Target

Use:

```text
https://<your-server>
```

Point this at your own `hermes-webui` server exposed through an HTTPS tunnel or reverse proxy (e.g. Cloudflare Tunnel). Real HTTPS works from both the iOS simulator and physical devices without an App Transport Security exception. If the server sets `HERMES_WEBUI_PASSWORD`, you need that password to sign in.

Before debugging the app, verify the server is reachable:

```zsh
curl https://<your-server>/health
```

## Upstream Contract Pin

The app is tested against the `hermes-webui` commit in the root [`UPSTREAM_TESTED_SHA`](UPSTREAM_TESTED_SHA) file — the only copy of the pin, so it cannot drift. To see its release tag: `git -C .codex-tmp/hermes-webui describe --tags --exact-match $(cat UPSTREAM_TESTED_SHA)`. The advance procedure lives in `AGENTS.md` § Working with the server.

## SSE and Cloudflare Stream Verification

Chat streaming uses `GET /api/chat/stream?stream_id=...` over Server-Sent Events. The stream response uses `Content-Type: text/event-stream; charset=utf-8`, `X-Accel-Buffering: no`, `Connection: keep-alive`, and sends `: heartbeat` comments about every 30 seconds while no app event is ready. If the connection is cut while the upstream stream is still active, returning to the foreground or reconnecting should use `GET /api/chat/stream/status?stream_id=...` and reattach to the same stream instead of resending the user message.

Cloudflare's free-plan idle timeout is roughly 100 seconds, so a gap with no events longer than that cuts the stream and reconnect logic must handle it even with normal heartbeat behavior. The server's CSRF check compares `Origin`/`Referer` against `Host` on POSTs; the native client sends neither header, so the server treats it as curl-equivalent and allows it.

## Local-Only Fallback

For contributors without access to the tunnel:

1. Clone the upstream server:

```zsh
git clone https://github.com/nesquena/hermes-webui.git
cd hermes-webui
```

2. Run it with Docker or directly with Python, following the upstream README.

For simulator-only testing, `http://localhost:8787` can work when the server is running on the same Mac. For physical-device testing, use HTTPS, a local network address (a private IP, `.local` or single-label name), or a Tailscale IP or `ts.net` name; the app's ATS policy allows plain HTTP to exactly those (`HermesMobile/Resources/Info.plist`).

## Example Server Setup (macOS + launchd)

One proven way to run the server natively on macOS is through launchd, for contributors who want a local reference (this is not the maintainer's setup, which runs on a different Mac):

- LaunchAgent: `~/Library/LaunchAgents/com.hermes.webui.plist`
- Local bind: `127.0.0.1:8787`
- Tunnel target: `http://127.0.0.1:8787`

```zsh
launchctl load ~/Library/LaunchAgents/com.hermes.webui.plist
launchctl unload ~/Library/LaunchAgents/com.hermes.webui.plist
launchctl kickstart -k gui/$(id -u)/com.hermes.webui
```

## Xcode version

Local work, PR CI, and release builds all use **Xcode 27.0 (27A266a)**, so a
change that compiles on this Mac compiles on CI. CI and release builds run on
GitHub's `xcode-27` runner image with `DEVELOPER_DIR` pinned in
`.github/workflows/pr-ci.yml` and `.github/workflows/release-candidate-testflight.yml`.
Check yours with `xcodebuild -version`. With several Xcodes installed, select
27.0 for one shell with `export DEVELOPER_DIR=<path to Xcode 27.0>.app/Contents/Developer`,
or for the whole Mac with `sudo xcode-select -s <path to Xcode 27.0>.app`.
Move the local Xcode and both workflow pins together.

## Local XCTest

Use the repository runner for local tests, including when XcodeBuildMCP is
available. It builds a signed Debug app once and runs XCTest serially on the
assigned simulator (once, or up to N times with `--repeat N`). Separate worktrees can test concurrently on separate devices.

Choose the session's simulator once (`hermex-flow` owns its device pool). The
main checkout normally uses **iPhone 17**. Resolve its UDID with
`xcrun simctl list devices available`; names shared by multiple iOS runtimes
are ambiguous, so pass the UDID. The runner never chooses another device or
creates one, and refuses to boot a fifth simulator.

```zsh
# Focused tests; repeat --only for multiple classes or individual test methods.
scripts/test-sim <simulator-udid> --only HermesMobileTests/BotLiveActivityTests

# Stress a flaky test: up to 20 iterations in one build and launch, stopping at
# the first failure. Use this rather than calling the runner in a loop.
scripts/test-sim <simulator-udid> --only HermesMobileTests/BotLiveActivityTests --repeat 20

# Full suite (also builds): use the same assigned UDID throughout the session.
scripts/test-sim <simulator-udid>
```

Choose local coverage using `AGENTS.md` § Verifying: slices run affected tests,
and PR CI, which runs every retained test with one simulator worker, is the
full-suite gate. `--only` limits execution, but still builds the app and test
target.

The runner waits for simulator readiness, terminates any running Hermex app on
that device (an app left attached by a build-and-run makes the test runner hang
before connecting, `0 tests executed`; set `HERMEX_BUNDLE_ID` if
`Config/Local.xcconfig` changes the bundle ID), then holds locks on the simulator
and checkout until testing finishes. A competing runner reports the current
owner immediately; different checkout/device pairs run independently. These
locks coordinate this runner only: keep other build/install tools on their
session's assigned device, and do not run them during its test run.

Before each test attempt, a bounded `get_app_container` check skips termination
if Hermex is not installed (terminating an absent app can hang on iOS 27).
Both the check and termination have a 25-second limit, or `--boot-timeout` or
the remaining test budget if shorter. Only a missing-bundle result skips
termination; other lookup errors stop the run. A not-running exit status is
ignored; a timeout still stops the run.

Build products live in the checkout's gitignored `.build/DerivedData/`, which
XcodeBuildMCP also uses (`.xcodebuildmcp/config.yaml`), so launching the app
after a test run reuses that build instead of compiling a second copy, and
removing a worktree removes its build. Timestamped logs live under
`~/Library/Developer/Xcode/DerivedData/hermex-tests-<checkout-path-hash>/runs/`;
the full absolute checkout path determines the hash, so identically named
worktrees do not share them. The command prints the log directory at
startup and test counts/failures at completion; `command.json`, `test.log`,
`summary.json`, and `Tests.xcresult` retain the evidence.

Wait on the runner using the longest supported tool wait; avoid separate log
polls or status commands. It checks readiness with bounded commands (120 seconds
for boot operations) and allows 30 minutes for build and tests.
`--boot-timeout` and `--test-timeout` override those limits in seconds when a
known workload requires it.

It retries in one case only. Xcode sometimes fails with `The test runner hung
before establishing connection` before any test runs: the app launches, but
XCTest inside it never hears that the simulator's `testmanagerd` is ready, and
xcodebuild gives up after 300 seconds. On that failure, and only when no test
passed, the runner reboots that simulator (its own UDID only), stops the app,
and reruns once within the same test time limit, printing `RETRY:`. The retry
writes `test-retry.log`, `summary-retry.json`, and `Tests-retry.xcresult` next
to the first attempt's files. Every other failure is reported without a retry.

Exit codes: **0** passed; **1** build/test failure; **2** busy device, setup, or
result-verification failure; **124** timeout; **130** interrupted. On a busy
device or infrastructure failure, report the blocker and log path; stop rather
than rebooting, erasing devices, clearing caches, or rerunning unchanged tests.
For actual test failures, inspect the recorded failure and follow the repo's
baseline-check procedure where applicable. On timeout or interruption, the runner
terminates the isolated process group it spawned, including remaining descendants,
and leaves other jobs and the simulator itself alone.

Runner checks: `python3 -m unittest discover -s scripts/tests -v`.

## PR CI

`.github/workflows/pr-ci.yml` pins the hosted Xcode path, iOS runtime, and phone
model. Update these together after checking the runner's installed software;
a missing pin fails setup rather than selecting another toolchain or runtime.
CI tests on the iOS 27 simulator only. The `xcode-27` image ships no iOS 26
runtime, and downloading one would add minutes to every run, so iOS 26 is
deliberately not covered on CI to keep it fast. Run the affected tests on a
local iOS 26 simulator when a change depends on OS behavior.
CI resolves the device UDID and runs the complete suite with one test worker,
except `MathTranscriptPerformanceTests`: that benchmark prints medians, asserts
no time budget, and took 1-3 minutes of every run, so CI skips it. Run it by
hand with `--only` when comparing rendering performance.
Xcode owns that worker's simulator clone and boot. Explicit preboot plus fully
serial execution did not improve the hosted trial, so retain the one-worker
configuration unless new measurements justify changing it. Two more hosted
experiments were measured and rejected (details in the closed PRs):

- Booting the base device during the build and testing on it serially (#845):
  the fresh device's first boot competed with the compiler on the 3-core
  runner, tripling the build while saving less in test preparation, and a
  keyboard test behaved differently on the base device.
- Caching Swift packages and Xcode compilation results (#838): each compile
  job's cache key covers its whole module's sources, so one edited app file
  missed every compile job of the app target, the build's longest step, and a
  typical PR built no faster; only reruns and test-only PRs gained. Package
  caching saved about 3 s net.

The test step has a 30-minute timeout covering worker preparation and the full
suite, so a stalled worker does not consume the 90-minute job budget and prevent
failure diagnostics from running. This is a combined limit, not a separate
five-minute boot deadline.

The Actions summary records phase timings, the failed phase, assertion messages,
and slow tests. Failure artifacts include setup/build/test logs and any result
bundle. Tests run with `-collect-test-diagnostics never`, as locally: on the
`xcode-27` image a failure otherwise spends 10 minutes timing out a
simulator sysdiagnose. A missing bundle does not establish an infrastructure flake; inspect the
failed phase before rerunning. The reporter cannot turn a failed build or test
green. Validate workflow changes with `actionlint .github/workflows/pr-ci.yml`
and `python3 -m unittest discover -s ci -p 'test_*.py'`.

A separate Linux job, Tooling Tests, runs the `scripts/tests` and `ci/` Python
suites and the TestFlight build-number selector test on every PR and master
push, including docs- and scripts-only PRs that skip the macOS runner. CI Gate
fails when it fails.

## Build and Launch With XcodeBuildMCP

Defaults and the verification flow live in `AGENTS.md` § Verifying. Human/CLI equivalents:

```zsh
xcodebuildmcp simulator list --enabled
```

```zsh
xcodebuildmcp simulator build-and-run --output jsonl
```

Update `.xcodebuildmcp/config.yaml` only when a new simulator should become the shared repo default.

### Signing a simulator in

Each simulator has its own Keychain, so a fresh or erased one starts logged out. When the installed Debug build shows the login screen (or Bots has no connection), run:

```zsh
scripts/sim-login <simulator-udid>
```

It relaunches the app with `HERMEX_DEV_*` environment variables read from the macOS Keychain; `DevAutoLogin.swift` (DEBUG builds only) signs in through the normal login paths. Nothing is printed and nothing is stored in the repo. One-time setup, prompting for each password:

```zsh
security add-generic-password -s hermex-webui -a <server-host> -w
security add-generic-password -s hermex-bot -a <bot-username> -j <bot-address> -w
```

`hermex-bot` is optional; with it the script also saves the Bot connection and turns Bot Mode on.

`scripts/sim-login <simulator-udid> --hermes` also adds a Hermes server at the `hermex-bot` address, signed in with the same username and password, and opens it once per launch; switching away afterwards sticks until the next run. It needs `hermex-bot`, or all three of `HERMEX_BOT_ADDRESS`, `HERMEX_BOT_USERNAME` and `HERMEX_BOT_PASSWORD` in the environment, which replace the Keychain item for that run. Without `--hermes` the script behaves as before.

### Local Hermes test server

For tool and approval turns without a real model or the real host, run the pinned hermes-agent on this Mac:

```zsh
scripts/local-hermes
```

The first run clones the commit in `HERMES_AGENT_TESTED_SHA` into `~/Library/Caches/hermex-local-hermes/` and installs it with `uv` (network needed); later runs start in seconds. It serves `http://127.0.0.1:9199` with the credentials it prints (`hermex` / `hermex-local`), backed by a scripted stub model: every turn says "Let me run a quick check.", asks to run `python3 -c "print(1)"` behind a manual approval, then replies "The command returned: …" with the result or the denial. **Approving really runs that command on this Mac.** Each run uses a temporary Hermes home, deleted on exit, with a fixed install id, so a saved connection keeps working across restarts. Ctrl-C stops only the process group the script started.

It listens on loopback, so only the simulator can reach it. To open it as a Hermes server, run:

```zsh
HERMEX_BOT_ADDRESS=http://127.0.0.1:9199 HERMEX_BOT_USERNAME=hermex HERMEX_BOT_PASSWORD=hermex-local \
  scripts/sim-login <simulator-udid> --hermes
```

That also saves it as your webui server's own Hermes connection if that server has none yet. To point an existing webui server's connection at it instead, open Settings → your server → **Hermes connection**, enter `http://127.0.0.1:9199` and the printed credentials, and save. This replaces that server's saved Hermes connection until you enter the real one again. `scripts/sim-login` never replaces an existing connection, so it won't switch back for you.

## Launch arguments and profiling

Debug builds read these launch arguments; Release builds compile none of them in.

| Argument | What it does |
|---|---|
| `--streaming-lab` | Opens the Streaming Lab as the root screen: a canned markdown reply replayed through the real streaming renderer, with the fade knobs exposed (#234). No server needed. |
| `--rating-prompt-eligible` | Makes this launch eligible for the App Store rating prompt, so its real navigation and stream guards can be exercised. It rewrites the stored rating and tip-jar counters. |
| `--stale-runtime-send` | Fails the first chat send of this launch with hermes-webui's `agent_runtime_stale` 409 instead of sending it, so the composer's restart banner and **Copy fix prompt** can be checked without updating Hermes on a server (#955). Later sends go to the server as usual. |
| `--hitch-meter` | Shows a frame-hitch readout in the top-leading corner, such as `12.4 ms/s · 3 hitches · 60 Hz`: late-frame milliseconds per second, hitch count, and the refresh rate the display link reports, over the last second. It takes no touches, VoiceOver skips it, and it updates at most twice a second. |

```zsh
xcrun simctl launch <simulator-udid> com.uzairansar.hermesmobile --hitch-meter
```

The `HERMEX_DEV_*` environment variables (`HERMEX_DEV_SERVER_URL`, `HERMEX_DEV_PASSWORD`, `HERMEX_DEV_BOT_ADDRESS`/`_USERNAME`/`_PASSWORD`, and `HERMEX_DEV_HERMES_SERVER=1` for a Hermes server) sign a Debug build in; `scripts/sim-login` sets them from the macOS Keychain (§ Signing a simulator in).

### Recording signposts

`HermesMobile/Config/PerformanceSignposts.swift` marks six intervals in every build, under the bundle ID as subsystem (`com.uzairansar.hermesmobile`, or `com.uzairansar.hermesmobile.branch` for Hermex Branch) and category `Performance`. Metadata is counts only; never add text, titles, paths, URLs, or IDs.

| Interval | Measures | Metadata |
|---|---|---|
| `Session Open` | A session-list open (tap or keyboard) to the first transcript frame, or to the empty state when the transcript is empty | `messages` |
| `Transcript Apply` | Painting the cached transcript, or applying a reloaded one | `messages` |
| `Markdown Parse` | Parsing one markdown block | `chars` |
| `Stream Batch Apply` | Applying one batch of streamed tokens | `mutated` (0 or 1) |
| `Cache Read` | A SwiftData read of cached sessions or messages | `rows` |
| `Cache Write` | A SwiftData write of cached sessions or messages | `rows` |

In Xcode: Product → Profile (a Release build), choose the Animation Hitches or Time Profiler template, add the `os_signpost` instrument from the library, and filter it by the subsystem and category `Performance`.

From the command line, with the app running on a simulator (`--attach` takes the app's display name, `Hermex`), then print the recorded intervals as XML:

```zsh
xcrun xctrace record --template 'Time Profiler' --instrument os_signpost \
  --device <simulator-udid> --attach Hermex --time-limit 30s --output /tmp/hermex.trace
xcrun xctrace export --input /tmp/hermex.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"][1]'
```

### Watching the Bot connection log

`HermesConnection` logs Bot sign-ins and the gateway socket's lifecycle under the bundle ID as subsystem and the category `HermesConnection` (`docs/agents/bots.md`). In Console.app, select a cabled iPhone, start streaming, and filter `subsystem:com.uzairansar.hermesmobile category:HermesConnection` (`com.uzairansar.hermesmobile.branch` for Hermex Branch). Check it on a device: the simulator's `log show` doesn't show these lines.

## Swift File-Size Policy

`scripts/check-swift-file-sizes` warns on production app Swift files (`HermesMobile/`) over 500 LOC; tests, generated files, preview files, the share extension, and the live activity widget are exempt. It exits successfully even with warnings — it makes drift visible without blocking current work. Override the threshold for local experiments with `HERMES_SWIFT_FILE_SIZE_LIMIT=300 scripts/check-swift-file-sizes`.

## Raw xcodebuild Fallback

Use raw `xcodebuild` for builds when XcodeBuildMCP is unavailable, when validating lower-level build failures, or when matching the GitHub Actions release/archive commands exactly. Local XCTest uses `scripts/test-sim` above. The TestFlight workflows continue to use raw `xcodebuild` and are not replaced by XcodeBuildMCP.

List available simulators:

```zsh
xcrun simctl list devices available
```

Build for an available iPhone simulator:

```zsh
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17' build
```

If `iPhone 17` is not installed, choose a nearby available iPhone simulator.

## TestFlight

Production internal/external uploads, signing setup, release gates, and review notes
live in [`TESTFLIGHT.md`](TESTFLIGHT.md). The separate branch-app upload is below.

### Branch TestFlight upload (CLI) — the "push to branch testflight" command

When the owner says **"push to branch testflight"**, upload the current *feature branch*
to the side-by-side **Hermex Branch** internal TestFlight app. This is a TestFlight
upload, **not** a Git push. Never merge, Git push, or upload the production
`com.uzairansar.hermesmobile` TestFlight app unless the owner explicitly asks.

Branch TestFlight app identity:

- App Store Connect app name: `Hermex Branch`
- Main bundle ID: `com.uzairansar.hermesmobile.branch`
- Share extension bundle ID: `com.uzairansar.hermesmobile.branch.shareextension`
- Live Activity widget bundle ID: `com.uzairansar.hermesmobile.branch.liveactivitywidget`
- Notification Service Extension bundle ID: `com.uzairansar.hermesmobile.branch.notifications`
- Display name: `Hermex Branch`
- App group: `group.com.uzairansar.hermesmobile.branch`
- URL scheme: `hermes-agent-branch`
- SKU: `hermes-mobile-ios-branch`

Steps:

1. Validate the branch first: at minimum `git diff --check` plus a simulator build; run
   focused or full tests based on the branch's risk.
2. Commit the work, then run from the feature branch:

   ```zsh
   scripts/branch-testflight
   ```

   It archives Release with `Config/BranchTestFlight.xcconfig` and a `YYYYMMDDHHMMSS`
   build number, uploads with the internal-only `Config/BranchTestFlightExportOptions.plist`,
   and keeps the archive and log under `build/branch-testflight/<build-number>/`.
   It refuses to run on `master` or with uncommitted changes.
3. Tell the owner the version and build number it prints. TestFlight shows the build
   after App Store Connect finishes processing.

## Full-App Manual Regression Checklist

Run this on the first release candidate of each marketing version ([TESTFLIGHT.md](TESTFLIGHT.md#test-the-release-candidate)).
Capture bugs, polish notes, and follow-up ideas in [GitHub Issues](https://github.com/uzairansaruzi/hermex/issues).

### Onboarding/Auth
- Fresh install opens onboarding.
- Valid server URL + password logs in.
- Wrong password shows clear error.
- Server/tunnel down shows useful error.
- Sign out and reconfigure returns to onboarding.

### Sessions
- Load sessions online.
- Pull to refresh.
- Search sessions.
- Create new session.
- Pin/unpin.
- Archive/restore.
- Move to project and back to no project.
- Duplicate/fork.
- Delete disposable session only.
- Offline cached session list displays clearly.

### Chat/Streaming
- Open existing session at latest message.
- Send normal message.
- Watch response stream.
- Stop response.
- Send while streaming using each configured behavior.
- Background/foreground during active stream.
- Long response over 2 minutes.
- Network interruption recovery.
- Offline cached transcript is read-only.

### Message Actions
- User message: edit, fork, copy.
- Assistant message: listen, stop listening, select text, regenerate, fork, copy.
- Older edit/regenerate shows discard warning.
- Local assistant command cards do not expose destructive message actions.

### Composer
- Model picker and favorites/recents.
- Reasoning picker.
- Workspace picker.
- Profile switch, including new-session confirmation.
- Attach file.
- Capture a photo with the camera; check denial, cancellation, and attachment import.
- Attach one photo.
- Attach multiple photos.
- Paste image/file.
- Failed upload preserves draft.
- Voice input allowed, denied, stopped, and sent.
- Haptics on send/response completion on device, in Sessions chat and Bot Chat. Bot Chat also plays them on Stop and answers; rooms on send, Stop and approve, never on completion. A Bot turn that finished in the background plays none.

### Slash Commands
- `/help`
- `/new`
- `/model`
- `/workspace`
- `/reasoning`
- `/title`
- `/personality`
- `/skills`
- Direct skill slash shortcut.
- `/queue`
- `/steer`
- `/interrupt`
- `/status`
- `/btw`
- `/background` and `/bg`
- `/branch` and `/fork`
- `/undo`
- `/retry`
- `/compress` and `/compact`
- Unsupported commands show friendly local message.

### Server Panels
- Files list/search.
- Text file preview.
- Image preview.
- Unsupported binary preview.
- Tasks list/detail/output.
- Skills list/search/detail/linked file.
- Memory notes/profile.
- Usage analytics timeframe switching.

### Polish/Launch
- Light and dark mode.
- Portrait and landscape.
- Largest Dynamic Type.
- VoiceOver core path.
- App icon visible.
- Launch screen acceptable.
- Privacy permission prompts readable.
- TestFlight install path documented.
