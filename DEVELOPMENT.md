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

For simulator-only testing, `http://localhost:8787` can work when the server is running on the same Mac. For physical-device testing, use HTTPS or a Tailscale `100.64.0.0/10` IP; TestFlight builds include a scoped ATS exception for that Tailscale range.

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

## Local Validation With XcodeBuildMCP

Defaults and the verification flow live in `AGENTS.md` § Verifying. Human/CLI equivalents:

```zsh
xcodebuildmcp simulator list --enabled
```

```zsh
xcodebuildmcp simulator test --output jsonl
```

```zsh
xcodebuildmcp simulator build-and-run --output jsonl
```

Update `.xcodebuildmcp/config.yaml` only when a new simulator should become the shared repo default.

## Swift File-Size Policy

`scripts/check-swift-file-sizes` warns on production app Swift files (`HermesMobile/`) over 500 LOC; tests, generated files, preview files, the share extension, and the live activity widget are exempt. It exits successfully even with warnings — it makes drift visible without blocking current work. Override the threshold for local experiments with `HERMES_SWIFT_FILE_SIZE_LIMIT=300 scripts/check-swift-file-sizes`.

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

- Signing uses Xcode automatic signing.
- Export compliance is declared in `Info.plist` with `ITSAppUsesNonExemptEncryption = NO`; the app does not implement custom/proprietary encryption and uses normal Apple/platform networking security.
- App icon uses owner-supplied light and dark assets in `AppIcon.appiconset`.
- Launch screen uses the plist-based `UILaunchScreen` placeholder from `Info.plist`, which is acceptable for internal TestFlight validation.
- `PrivacyInfo.xcprivacy` is bundled with the app target. It declares no tracking, no developer-collected data, and app-only `UserDefaults` access for local preferences.
- Camera capture is deferred and is not declared. Add `NSCameraUsageDescription` and update the privacy review only if camera capture is implemented later.
- The current GitHub Actions upload path is intentionally internal-only. External TestFlight readiness and Beta App Review sequencing are tracked in [`TESTFLIGHT.md`](TESTFLIGHT.md).

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
