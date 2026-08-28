# External TestFlight Launch Runbook

> **Maintainer-only ops.** Everything in this file requires the maintainer's Apple Developer account, App Store Connect access, and signing credentials. Contributors never need this runbook to build, test, or contribute to the app.

This is the step-by-step checklist for getting Hermex ready for external TestFlight testers. Work through it in order. Each numbered item is intended to be a fresh, focused Codex session or an owner-only App Store Connect task.

Goal: invite external testers only after a clean release-candidate build has been uploaded, owner-verified internally on device, submitted to Beta App Review, and approved.

## Stop Conditions

Do not invite external testers if any of these are true:

- `git status --short --branch` is not clean on the RC branch.
- The intended RC commit has not been pushed to `origin/master`.
- Full `xcodebuild test` has not passed on the intended RC commit.
- The owner has not installed and manually smoke-tested the exact RC build from internal TestFlight on a physical iPhone.
- App Store Connect TestFlight test information is incomplete.
- Privacy policy URL is missing.
- The backend server or demo credentials for Beta App Review are not available.
- The build in App Store Connect is marked internal-only.

## Optimal Order

### 1. Resolve Outstanding Repo State

Purpose: make sure the source tree has one clear release candidate.

Start from a clean, up-to-date `master` with CI green. Do not start new feature/polish work unless it fixes an external TestFlight blocker.

Validation:

```zsh
git switch master
git status --short --branch
git log --oneline --decorate --max-count=12
```

Exit criteria:

- `master` contains the selected RC fixes.
- `git status --short --branch` is clean.

### 2. Reconcile Handoff Docs Before RC

Purpose: make sure future sessions and the owner see the real RC state.

Confirm `README.md`, `DEVELOPMENT.md`, and this file agree on the current version and external-TestFlight status.

Exit criteria:

- Handoff docs accurately describe the release candidate and remaining external-launch tasks.

### 3. External-Capable Upload Path

`.github/workflows/external-testflight.yml` uploads a build that can be submitted to external TestFlight, gated to `master` and an explicit `confirm_external_review = EXTERNAL_REVIEW` input. It uses `ci/ExternalTestFlightExportOptions.plist` (no `testFlightInternalTestingOnly` key), so builds are not internal-only. The separate internal-only workflow (`.github/workflows/internal-testflight.yml` + `ci/TestFlightExportOptions.plist`) stays available for quick owner smoke builds. The external workflow only uploads the build — assigning it to an external group and submitting to Beta App Review stays manual in App Store Connect.

### 4. Confirm Apple Developer Portal Capabilities

Purpose: prevent archive/upload failures caused by missing identifiers or entitlements.

Owner task in Apple Developer / App Store Connect:

1. Confirm app bundle ID exists:
   - `com.uzairansar.hermesmobile`
2. Confirm share extension bundle ID exists:
   - `com.uzairansar.hermesmobile.shareextension`
3. Confirm App Group exists:
   - `group.com.uzairansar.hermesmobile`
4. Confirm the App Group is enabled for both the app and share-extension bundle IDs.
5. Confirm automatic signing can create/update App Store provisioning profiles for both targets.
6. Confirm Apple Developer Program agreements are accepted.
7. Confirm App Store Connect API key used by GitHub has enough access for upload/provisioning.

Local validation:

```zsh
plutil -p HermesMobile/Resources/HermesMobile.entitlements
plutil -p HermesShareExtension/Resources/HermesShareExtension.entitlements
xcodebuild -showBuildSettings -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release | rg "PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN_ENTITLEMENTS|CODE_SIGN_STYLE"
```

Exit criteria:

- App and extension archive/export signing can succeed without manual project setting changes.

### 5. Finish App Store Connect Metadata Required For Beta Review

Purpose: avoid Beta App Review rejection for incomplete metadata or missing reviewer access.

Owner task in App Store Connect:

1. TestFlight > Test Information:
   - Beta App Description.
   - Feedback Email.
   - Contact Information.
   - Beta App Review Information.
   - Notes for Review.
2. Provide reviewer access:
   - server URL: `https://<your-server>`
   - reviewer password or demo credential;
   - a short path to verify the app: sign in, open sessions, send a message, view files/panels, use share extension if appropriate.
3. Make sure the backend service is awake and available for the review window.
4. Explain the app in review notes:
   - native iOS client for a user-controlled/self-hosted Hermes developer-agent server;
   - password auth is against the user-configured server;
   - no in-app account creation;
   - no purchases;
   - camera capture is not implemented;
   - shared files/photos/PDFs are staged locally, then uploaded only to the configured Hermes server for composer attachment import;
   - user must explicitly send the message after import.
5. Enter a public privacy policy URL.
6. Review App Privacy answers:
   - no tracking;
   - no third-party analytics unless one is later added;
   - voice, photo, file, and shared content behavior is described accurately;
   - if using the owner's server for external testers, be conservative and disclose data the developer/server operator can access as needed.
7. Confirm age rating/category are accurate for a developer productivity app.
8. Confirm support URL and marketing URL fields if App Store Connect requires them for the current app state.

Exit criteria:

- TestFlight test information is complete.
- Privacy policy URL is saved.
- Reviewer can access the backend without asking for more info.

Draft App Store Connect metadata:

Beta App Description:

```text
Hermex is a native iOS client for a self-hosted Hermes Web UI developer-agent server. Use it to sign in to your configured server, browse sessions, send messages with composer options and attachments, stream responses, view workspace files, and open read-only Tasks, Skills, Memory, and Usage Analytics panels.
```

What to Test:

```text
Test core Hermex workflows: sign in to a self-hosted Hermes Web UI server, browse sessions, open existing conversations, send messages with model/reasoning/workspace options, stream responses, attach photos/files, use share extension import, browse workspace files, and view read-only Tasks, Skills, Memory, and Usage Analytics.
```

Beta App Review Information (this is also the App Store Connect review notes template — keep it accurate for the exact submitted build):

```text
Review server:
https://<your-server>

Review password:
<provide current password in App Store Connect, not in git>

Suggested review path:
1. Launch the app.
2. Enter the review server URL and password.
3. Open Sessions and select an existing session.
4. Send a short message and watch the streamed response.
5. Open Files, Tasks, Skills, Memory, and Usage Analytics from the Sessions screen.
6. Optional: use the iOS share sheet from Safari/Notes/Files/Photos to import content into a new Hermes draft. The app stages shared content locally, uploads selected attachments to the configured Hermes server, and does not send a chat message until the user taps Send.

Notes:
- There is no in-app account creation or purchase flow.
- The server is self-hosted and password protected.
- Camera capture is not implemented in this build.
- Microphone and speech recognition are used only for explicit composer dictation.
- Photo/file access is used only when the user selects attachments or shares content into the app.
```

### 6. Share Extension Auto-Launch Risk

Keep the automatic app-launch workaround for external TestFlight (current behavior and accepted risk are recorded in the Known Risk Register below). App Store Connect review notes must describe the share import flow, and manual regression must cover Safari/Notes/Files/Photos share import and fallback behavior before external submission.

Exit criteria:

- The exact RC behavior is covered in manual regression.
- App Store Connect review notes match the current behavior.

### 7. Run Local RC Validation

Purpose: prove the code is buildable/testable before spending App Store Connect cycles. (Step 9, pushing the RC commit, is merged into this step below.)

Commands:

```zsh
xcrun simctl list devices available
git status --short --branch
git diff --check
plutil -lint HermesMobile/Resources/Info.plist HermesMobile/Resources/PrivacyInfo.xcprivacy HermesShareExtension/Resources/Info.plist HermesShareExtension/Resources/PrivacyInfo.xcprivacy
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

If simulator launch is stale:

```zsh
xcrun simctl shutdown all
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17'
```

Exit criteria:

- `git status --short --branch` is clean.
- `git diff --check` passes.
- plist lint passes.
- full XCTest passes.
- generic iOS Release build passes.

Once validation passes, push the RC commit so the upload workflow builds the audited source:

```zsh
git switch master
git status --short --branch
git push origin master
```

`origin/master` must point to the intended RC commit before Step 10.

### 8. Run Live Authenticated Server Smoke

Purpose: catch issues that mock tests and endpoint-shape tests cannot catch.

Owner/Codex task:

Use the owner server and credentials. Do not mutate real data unnecessarily; use a disposable session where state-changing checks are needed.

Minimum smoke:

1. `GET /health` is reachable.
2. Sign in from the app.
3. Load sessions.
4. Open at least one WebUI-created session.
5. Create a new session.
6. Send a normal message and watch stream completion.
7. Stop a streaming response.
8. Background/foreground during an active stream.
9. Upload one image and one file/PDF attachment.
10. Open Files, preview text, preview image, and view unsupported binary state.
11. Open Tasks list/detail/output.
12. Open Skills list/search/detail/linked file.
13. Open Memory.
14. Open Usage Analytics and switch timeframes.
15. Exercise any currently open paused-risk issues from GitHub Issues.

Exit criteria:

- No crash.
- No unexplained auth/logout issue.
- No blank transcript after reload/foreground.
- No destructive action affects non-disposable data.
- Any issue found is captured in GitHub Issues and either fixed or explicitly accepted before external launch.

### 10. Upload Fresh Internal TestFlight Build

Purpose: test the exact RC through Apple's distribution path before external review.

Use the existing internal-only workflow:

1. Run `Internal TestFlight` from GitHub Actions.
2. Select `master`.
3. Set `confirm_internal_only = INTERNAL`.
4. Leave `build_number` blank so the workflow selects the next App Store Connect build number for the current marketing version.
5. Wait for App Store Connect processing.
6. Add the build to the internal TestFlight group.
7. Install from TestFlight on the owner's physical iPhone.

Exit criteria:

- The owner installs the internal RC build from TestFlight.
- The installed build number is recorded on the release's GitHub issue.
- Internal smoke passes before any external-capable upload.

### 11. Owner Device Manual Regression

Purpose: verify real-device behavior that simulator and unit tests cannot cover.

Run the Full-App Manual Regression Checklist in `DEVELOPMENT.md`. In addition, cover these TestFlight-specific items not in that checklist:

- install from TestFlight (not a direct Xcode/simulator install);
- update over an existing TestFlight install;
- TestFlight feedback capture (screenshot + text) works.

Exit criteria:

- 30 minutes of normal iPhone use without crashes.
- Full checklist has no unresolved P0/P1.
- Accepted known risks are written down in GitHub Issues or review notes.

### 12. Upload External-Capable Build

Purpose: create the build that can be submitted to Beta App Review.

Use the external-capable workflow or manual Xcode upload. The build must not be marked internal-only.

Version-train rule: once a version is approved for the App Store, Apple closes its pre-release train and rejects any upload with that `CFBundleShortVersionString` (ASC errors 90186/90062). Two defenses:

- Bump `MARKETING_VERSION` (in `HermesMobile.xcodeproj/project.pbxproj`, all entries) on `master` right after each App Store release goes live, so the next upload always targets an open train.
- The workflow preflights the train against App Store Connect before archiving (`ENFORCE_OPEN_TRAIN` in `ci/select_testflight_build_number.rb`) and fails in seconds with a bump instruction if the train is closed.

Workflow path, if implemented:

1. Run `External TestFlight` from GitHub Actions.
2. Select `master`.
3. Set `confirm_external_review = EXTERNAL_REVIEW`.
4. Leave `build_number` blank so the workflow selects the next App Store Connect build number for the current marketing version.
5. Wait for App Store Connect processing.

Manual path, if chosen instead:

1. Archive Release in Xcode from the RC commit.
2. Distribute through App Store Connect upload.
3. Do not choose an internal-only TestFlight upload option.
4. Wait for App Store Connect processing.

Exit criteria:

- Build appears in App Store Connect and is not marked internal-only.
- Build has compliance information resolved.
- dSYMs/symbols are uploaded.

### 13. Submit Beta App Review

Purpose: get the first external build approved by Apple.

Owner task in App Store Connect:

1. Create an external tester group, for example `External Beta`.
2. Add the external-capable build to that group.
3. Fill `What to Test` — use the What to Test text from Step 5.
4. Submit for review.
5. Monitor App Store Connect review status and email.
6. If rejected, capture the rejection in a GitHub Issue, fix only the rejection scope, upload a new external-capable build, and resubmit.

Exit criteria:

- External build is approved for TestFlight beta testing.

### 14. Invite External Testers

Purpose: start the external beta with controlled scope.

Recommended rollout:

1. Start with a small private external group, not a public link.
2. Add testers by email first.
3. Include:
   - TestFlight install instructions;
   - server setup requirements;
   - known limitations;
   - feedback email;
   - request for screenshots/screen recordings when reporting issues;
   - warning not to connect the app to sensitive production workspaces unless they understand server exposure and local cache behavior.
4. Watch TestFlight feedback and crash reports daily for the first few days.
5. Disable public links or pause expansion if P0/P1 issues appear.

Exit criteria:

- External testers can install and sign in.
- Feedback collection path is working.
- No immediate crash spike or install blocker.

### 15. Post-Launch Monitoring And Triage

Purpose: keep the beta useful without destabilizing the RC.

Daily during first week:

1. Review TestFlight feedback.
2. Review crash reports in App Store Connect/Xcode Organizer.
3. Check server health and logs if testers report connection issues.
4. Capture actionable reports in GitHub Issues.
5. Triage:
   - P0: fix immediately, upload new external-capable build, resubmit if required.
   - P1: fix before widening tester pool.
   - P2/P3: batch unless they block trust or core workflows.

#### Where exported TestFlight feedback lives

Feedback exported by Xcode lands on the maintainer's Mac at:

```
~/Library/Developer/Xcode/Products/com.uzairansar.hermesmobile/Feedback/Points/
```

One `<id>.xcfeedbackpoint/` bundle per submission, each containing
`Filters/Filter_*-<version>-<build>/PointInfo.json` and `Images/Thumbnail.jpg`.
Useful `PointInfo.json` keys: `appInfo.versionString` / `buildNumber`,
`timestamp`, `testerInfo.emailAddress`, `comment` (free text; empty for
screenshot-only reports), `deviceMetadata` (model / osVersion), `kind`
(`textual` | `screenshot`), `imageCount`. The folder name encodes app version and
build — use it to decide whether a report predates a later fix. Read the
`Thumbnail.jpg` files directly to see the screenshots.

**Tester email addresses are PII.** Never put them in public GitHub issues —
paraphrase the report and cite the build number instead.

Triage method that works: parse every `PointInfo.json` into one sorted list,
cluster by theme, cross-reference each cluster against `git log` and open/closed
issues to spot already-shipped fixes, verify "is it actually fixed?" against
current code, then confirm each cluster with the owner before filing issues.

Before each new external build: re-run the Step 7 validation commands.

## Known Risk Register For External Beta

Track these during launch:

- Share extension automatic app launch may be rejected by Beta App Review. Current behavior: the extension stages a draft/attachment in the App Group, then attempts to open the containing app via a dynamic `UIApplication`/`openURL:` workaround (responder-chain and dynamic URL-opening fallbacks to `hermes-agent://share`); if that fails, the App Group import fallback lets Hermes import the pending share when next opened/foregrounded. Accepted risk: this workaround is kept for external TestFlight rather than switched to a review-safer manual-open flow.
- Upstream API has no stability guarantee; current pin is recorded in `UPSTREAM_TESTED_SHA`.
- Full Docker-backed contract tests are future hardening; current gate is request-shape coverage plus URLProtocol-backed decoding tests.
- Cloudflare long-stream behavior can still fail if no bytes are emitted for longer than Cloudflare's idle tolerance.
- Owner-hosted backend availability affects review and tester experience.
- Privacy policy and App Store Connect privacy answers must stay aligned with share/import behavior.

## Definition Of External TestFlight Ready

External TestFlight is ready when all are true:

- `master` is clean, validated, and pushed.
- A fresh internal TestFlight RC from that commit passed owner device regression.
- An external-capable build from the same approved RC is uploaded and not marked internal-only.
- Privacy policy URL is live and entered in App Store Connect.
- TestFlight test information and Beta App Review notes are complete.
- Reviewer server URL/password are valid and the server is awake.
- Share extension auto-launch risk is consciously accepted or removed.
- No open P0/P1 issue blocks normal use.
- Beta App Review approves the build.
