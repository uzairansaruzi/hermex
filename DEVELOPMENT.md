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
- Capture a photo with the camera; check denial, cancellation, and attachment import.
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
