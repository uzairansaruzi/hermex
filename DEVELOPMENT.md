# Development

This app is developed against a self-hosted `hermes-webui` server exposed over real HTTPS. See [`PROJECT_SPEC.md`](PROJECT_SPEC.md) for the full product and API plan.

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

The app is currently tested against `hermes-webui` tag `v0.51.85`, peeled commit `f1d399b437c1ca7fe4b6d2093aebe334c32f34a3`. The root [`UPSTREAM_TESTED_SHA`](UPSTREAM_TESTED_SHA) file is the machine-readable pin for future drift checks and contract tests.

The pin was last verified against the upstream GitHub tag source during the 2026-05-05 audit slice; authenticated settings/version checks require server credentials.

Contract test readiness is documented in [`CONTRACT_TESTS.md`](CONTRACT_TESTS.md). Current coverage verifies the app's endpoint matrix and native POST header shape with URLProtocol-backed tests; the full Docker-backed upstream contract target remains future hardening.

## SSE and Cloudflare Stream Verification

Phase 4 streaming uses `GET /api/chat/stream?stream_id=...` over Server-Sent Events. Current upstream source confirms the stream response uses `Content-Type: text/event-stream; charset=utf-8`, `X-Accel-Buffering: no`, `Connection: keep-alive`, and sends `: heartbeat` comments every 30 seconds while no app event is ready.

Cloudflare can still close long-lived responses if the origin does not send data for long enough. The expected healthy behavior for Hermex is:

- streams longer than 2 minutes continue delivering tokens, tool events, reasoning events, title events, `done`, and `stream_end` when the server emits them;
- quiet periods under normal heartbeat behavior stay connected because the server writes `: heartbeat` about every 30 seconds;
- if the connection is cut while the upstream stream is still active, returning to the foreground or reconnecting should use `GET /api/chat/stream/status?stream_id=...` and reattach to the same stream instead of resending the user message.

Manual verification before closing Phase 4:

1. Sign in to `https://<your-server>` from the simulator.
2. Start a prompt that naturally runs for more than 2 minutes.
3. Keep the app foregrounded and verify streamed content continues past the 2 minute mark.
4. During another long response, background the app for at least 30 seconds, foreground it, and verify the app either reattaches to the active stream or reloads the completed transcript without duplicating the user message.
5. If a stream drops after a quiet gap, record whether the server emitted no tokens/tool/reasoning events for more than roughly 100 seconds. That is a known Cloudflare risk even with normal SSE support.

## Local-Only Fallback

For contributors without access to the tunnel:

1. Clone the upstream server:

```zsh
git clone https://github.com/nesquena/hermes-webui.git
cd hermes-webui
```

2. Run it with Docker or directly with Python, following the upstream README.

For simulator-only testing, `http://localhost:8787` can work when the server is running on the same Mac. For physical-device testing, use HTTPS or a supported Tailscale/NetBird IP in `100.64.0.0/10`; TestFlight builds include a scoped ATS exception for that private-network range.

## Example Server Setup (macOS + launchd)

One proven way to run the server natively on macOS is through launchd:

- LaunchAgent: `~/Library/LaunchAgents/com.hermes.webui.plist`
- Server script: `server.py` in your `hermes-webui` checkout
- Local bind: `127.0.0.1:8787`
- Public hostname: `https://<your-server>`
- Tunnel target: `http://127.0.0.1:8787`

Useful commands for this setup:

```zsh
launchctl load ~/Library/LaunchAgents/com.hermes.webui.plist
launchctl unload ~/Library/LaunchAgents/com.hermes.webui.plist
launchctl kickstart -k gui/$(id -u)/com.hermes.webui
cloudflared tunnel info <tunnel-name>
launchctl list | grep cloudflared
curl https://<your-server>/health
```

If the server appears down, check in this order:

1. launchd job status
2. local port `8787`
3. Cloudflare Tunnel status

For local port inspection:

```zsh
lsof -i :8787
```

## Local Validation With XcodeBuildMCP

XcodeBuildMCP is the preferred local validation path for feature and bug-fix slices. The repo config lives in `.xcodebuildmcp/config.yaml` and sets:

- Project: `HermesMobile.xcodeproj`
- Scheme: `HermesMobile`
- Configuration: `Debug`
- Simulator: `iPhone 17`
- Bundle ID: `com.uzairansar.hermesmobile`

After each completed implementation slice:

1. Confirm XcodeBuildMCP sees the repo defaults.
2. Run focused tests for the changed behavior when available.
3. Run the full XCTest suite before asking for review or committing.
4. Build and launch the app in Simulator when UI or runtime behavior changed.
5. Capture a screenshot or logs if the slice needs visual/runtime evidence.
6. Let the owner run the manual simulator checklist for the slice.

Agent/MCP flow:

- Call `session_show_defaults` before the first local build/run/test.
- If defaults are missing, set project `HermesMobile.xcodeproj`, scheme `HermesMobile`, configuration `Debug`, simulator `iPhone 17`, and bundle ID `com.uzairansar.hermesmobile`.
- Use `test_sim` for XCTest validation.
- Use `build_run_sim` to build, install, launch, and open Simulator for manual testing.
- Use `screenshot`, UI inspection, and log capture only when they help validate the slice.

Human/CLI equivalents:

```zsh
xcodebuildmcp simulator list --enabled
```

```zsh
xcodebuildmcp simulator test --output jsonl
```

```zsh
xcodebuildmcp simulator build-and-run --output jsonl
```

If `iPhone 17` is not installed, choose a nearby available iPhone simulator and update `.xcodebuildmcp/config.yaml` only if that should become the shared repo default.

## Swift File-Size Policy

The repo keeps the project style target of small Swift files, but file-size enforcement is warning-only while the large code-audit refactors continue.

Run:

```zsh
scripts/check-swift-file-sizes
```

Policy:

- Warn on production app Swift files over 500 LOC.
- Exit successfully even when warnings are present.
- Scope the check to `HermesMobile/` production app files.
- Exempt tests, generated files, preview files, the share extension, and the live activity widget for now.
- Use warnings to make future drift visible; do not block current work on known oversized files.

You can override the warning threshold for local experiments:

```zsh
HERMES_SWIFT_FILE_SIZE_LIMIT=300 scripts/check-swift-file-sizes
```

## Raw xcodebuild Fallback

Use raw `xcodebuild` when XcodeBuildMCP is unavailable, when validating lower-level build failures, or when matching the GitHub Actions release/archive commands exactly. The TestFlight workflows continue to use raw `xcodebuild` and are not replaced by XcodeBuildMCP.

List available simulators:

```zsh
xcrun simctl list devices available
```

Build for an available iPhone simulator:

```zsh
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 15' build
```

If `iPhone 15` is not installed, choose a nearby available iPhone simulator.

## TestFlight Readiness Notes

Current status:

- App Store Connect app name: `Hermex`.
- Xcode target/scheme name: `HermesMobile`.
- iPhone home-screen display name: `Hermex`.
- Bundle ID: `com.uzairansar.hermesmobile`.
- Test bundle ID: `com.uzairansar.hermesmobile.tests`.
- SKU: `hermes-mobile-ios`.
- Apple Developer Team ID: `6GYD9C9N6R`.
- Signing uses Xcode automatic signing.
- Export compliance is declared in `Info.plist` with `ITSAppUsesNonExemptEncryption = NO`; the app does not implement custom/proprietary encryption and uses normal Apple/platform networking security.
- App icon uses owner-supplied light and dark assets in `AppIcon.appiconset`.
- Launch screen uses the plist-based `UILaunchScreen` placeholder from `Info.plist`, which is acceptable for internal TestFlight validation.
- `PrivacyInfo.xcprivacy` is bundled with the app target. It declares no tracking, no developer-collected data, and app-only `UserDefaults` access for local preferences.
- Camera capture is deferred and is not declared. Add `NSCameraUsageDescription` and update the privacy review only if camera capture is implemented later.
- The current GitHub Actions upload path is intentionally internal-only. External TestFlight readiness and Beta App Review sequencing are tracked in [`TESTFLIGHT.md`](TESTFLIGHT.md).

### Owner checklist: App Store Connect rename to Hermex

After merging the repo rebrand slice, update App Store Connect metadata separately:

1. Production app (`com.uzairansar.hermesmobile`): rename listing from `Hermes Agent Mobile` → `Hermex`.
2. Branch TestFlight app (`com.uzairansar.hermesmobile.branch`): rename listing from `Hermes Agent Branch` → `Hermex Branch`.
3. Update TestFlight/review notes and any metadata copy that still says the old app name.
4. Upload a build and confirm TestFlight shows **Hermex** / **Hermex Branch** on the home screen after processing.

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
- Display name: `Hermex Branch`
- App group: `group.com.uzairansar.hermesmobile.branch`
- URL scheme: `hermes-agent-branch`
- SKU: `hermes-mobile-ios-branch`

Steps:

1. Validate the branch first: at minimum `git diff --check` plus a simulator build; run
   focused or full tests based on the branch's risk.
2. Use a unique `CURRENT_PROJECT_VERSION` for every upload — prefer a timestamp-like
   number such as `YYYYMMDDHHMM`.
3. Archive with the reusable branch build config `Config/BranchTestFlight.xcconfig`:

   ```zsh
   xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build/HermesAgentBranch.xcarchive \
     -xcconfig Config/BranchTestFlight.xcconfig CURRENT_PROJECT_VERSION=<unique-build-number> \
     archive -allowProvisioningUpdates
   ```

4. Upload with the reusable export config `Config/BranchTestFlightExportOptions.plist`:

   ```zsh
   xcodebuild -exportArchive -archivePath build/HermesAgentBranch.xcarchive \
     -exportOptionsPlist Config/BranchTestFlightExportOptions.plist \
     -exportPath build/HermesAgentBranchExport -allowProvisioningUpdates
   ```

5. After upload succeeds, tell the owner the version/build number and that App Store
   Connect/TestFlight may need processing time before it appears on the phone.

Manual internal TestFlight release flow:

1. Confirm `master` is clean and validated with the current simulator build/tests.
2. Increment `CURRENT_PROJECT_VERSION` before every upload. `MARKETING_VERSION` can remain `1.0` while internal builds iterate.
3. In Xcode, select `Any iOS Device` and run `Product > Archive`.
4. In Organizer, choose `Distribute App > App Store Connect > Upload`.
5. Wait for App Store Connect processing to complete.
6. Add the build to the internal TestFlight group first and test on the owner's iPhone.
7. Promote only owner-verified builds to external testers later. The first external build requires Beta App Review.

GitHub Actions internal TestFlight flow:

1. Configure a GitHub environment named `internal-testflight`. Require manual approval on that environment if available for the repository plan.
2. Add these environment secrets:
   - `APP_STORE_CONNECT_KEY_ID`: the App Store Connect API key ID.
   - `APP_STORE_CONNECT_ISSUER_ID`: the App Store Connect issuer ID.
   - `APP_STORE_CONNECT_PRIVATE_KEY`: the full `.p8` private key contents. A one-line value with escaped `\n` separators also works.
3. Use an App Store Connect team API key with enough access to upload builds and let `xcodebuild -allowProvisioningUpdates` manage automatic signing for Team ID `6GYD9C9N6R`. If provisioning fails in CI, check the API key role, Apple Developer agreements, and App Store Connect access before changing the project to manual signing.
4. Run the `Internal TestFlight` workflow manually from the GitHub Actions tab after the workflow file exists on the default branch.
5. Select `master` as the workflow ref, set `confirm_internal_only` to `INTERNAL`, and leave `build_number` blank so the workflow selects the next App Store Connect build number for the current marketing version.
6. The workflow archives the Release build, uploads directly to App Store Connect, and uses `testFlightInternalTestingOnly = true` so uploaded builds cannot be promoted to external TestFlight or App Store distribution.
7. Wait for App Store Connect processing to complete, then add the processed build to the internal TestFlight group and test on the owner's iPhone.

CI upload guardrails and likely failure modes:

- The workflow only runs on manual `workflow_dispatch`, fails unless the selected ref is `master`, and serializes uploads with a single concurrency group.
- The workflow detects `MARKETING_VERSION` from Xcode build settings, queries App Store Connect for existing uploaded builds for that version, selects the next build number, and overrides `CURRENT_PROJECT_VERSION` without editing the Xcode project. If `build_number` is provided manually, the workflow still fails before archiving unless that value is greater than the latest App Store Connect build.
- Missing or malformed secrets fail before archiving. The private key must remain a secret and must never be committed.
- Automatic signing can fail if the API key lacks Developer Portal/provisioning access, the Apple Developer Program agreements are pending, or App Store Connect has not finished recognizing the app record.
- GitHub macOS runner image or Xcode changes can break archive behavior; the workflow logs `xcodebuild -version` to make that visible.
- Upload success only means Apple accepted delivery. Processing, TestFlight group assignment, and later external tester promotion remain manual App Store Connect steps.
- Builds uploaded through this workflow are marked internal-only. They cannot be used for external TestFlight, Beta App Review, or App Store distribution; use the separate external-capable path described in [`TESTFLIGHT.md`](TESTFLIGHT.md) for external review builds.

GitHub Actions external-capable TestFlight flow:

1. Use this only after the intended RC commit has passed local validation, been pushed to `origin/master`, and passed owner internal TestFlight smoke on a physical iPhone.
2. Configure a GitHub environment named `external-testflight`. Require manual approval on that environment if available for the repository plan.
3. Add the same App Store Connect secrets used by the internal workflow to the `external-testflight` environment.
4. Run the `External TestFlight` workflow manually from the GitHub Actions tab.
5. Select `master` as the workflow ref, set `confirm_external_review` to `EXTERNAL_REVIEW`, and leave `build_number` blank so the workflow selects the next App Store Connect build number for the current marketing version.
6. The workflow archives the Release build, uploads directly to App Store Connect, and uses `ci/ExternalTestFlightExportOptions.plist`, which intentionally does not set `testFlightInternalTestingOnly`.
7. Wait for App Store Connect processing to complete. Adding the build to an external group and submitting it to Beta App Review remain manual App Store Connect steps; the workflow does not invite testers.

## Full-App Manual Regression Checklist

Use this before internal TestFlight smoke builds and again before adding external testers.
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
- Attach one photo.
- Attach multiple photos.
- Paste image/file.
- Failed upload preserves draft.
- Voice input allowed, denied, stopped, and sent.
- Haptics on send/response completion on device.

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

Preferred Git workflow before CI automation:

1. Create one short branch per work item, such as `issue/<n>-slug`.
2. Build and test on that branch.
3. Merge to `master` only after validation passes.
4. Treat `master` as the source for internal TestFlight candidates.
