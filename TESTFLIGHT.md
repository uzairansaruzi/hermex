# External TestFlight Launch Runbook

> **Maintainer-only ops.** Everything in this file requires the maintainer's Apple Developer account, App Store Connect access, and signing credentials. Contributors never need this runbook to build, test, or contribute to the app.

This is the step-by-step checklist for getting Hermex ready for external TestFlight testers. Work through it in order. Each numbered item is intended to be a fresh, focused Codex session or an owner-only App Store Connect task.

Goal: invite external testers only after a clean release-candidate build has been uploaded, owner-verified internally on device, submitted to Beta App Review, and approved.

## Current Readiness Snapshot

As of 2026-05-30:

- This file remains the external TestFlight mechanics runbook (the separate full App Store release checklist doc was retired during open-source prep).
- The GitHub Actions `External TestFlight` workflow is available and has uploaded an external-capable production build.
- Current external-capable upload: version `1.0.1`, build `1`.
- Verified workflow evidence: run `26833031469` / `External TestFlight from master` completed successfully from `master` at `9e8078215586643eb11c519bf9c73dfa103070ea`.
- Run `26833031469` selected build number `1`, used `ci/ExternalTestFlightExportOptions.plist`, archived successfully, and uploaded to App Store Connect successfully.
- Owner still needs to wait for App Store Connect processing, confirm build `1.0.1 (1)` appears and is not internal-only, and resolve any compliance prompts before using it for external testing or App Review replacement.
- Earlier external-capable build `1.0 (32)` remains the repo-recorded App Review submission unless the owner manually replaces it in App Store Connect.
- The local release branch cleanup is complete; the feature-gap and crash-investigation notes were committed, and the whitespace-only `AGENTS.md` change was removed.
- The share extension's automatic app-launch workaround remains the highest Beta/App Store Review code risk until removed or explicitly accepted.
- Full local XCTest passed on iPhone 17 Simulator for the latest code validation recorded in `CURRENT.md`, but every RC should be validated again before submission.

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

Owner/Codex tasks:

1. Review `codex/i-013-record-permission-deprecation`.
2. Either merge it into local `master` after review, or explicitly defer it and leave it out of the RC.
3. Confirm paused issues remain unreproduced:
   - `I-002`: active session can show blank transcript after sleep/return.
   - `I-004`: thinking card spacing inconsistency.
   - `I-005`: pin can return `HTTP 404 Session not found`.
4. Do not start new feature/polish work unless it fixes an external TestFlight blocker.

Validation:

```zsh
git switch master
git status --short --branch
git log --oneline --decorate --max-count=12
```

Exit criteria:

- `master` contains the selected RC fixes.
- `git status --short --branch` is clean.
- Any excluded issue is intentionally deferred or paused in GitHub Issues.

Current result as of 2026-05-15:

- Complete. `codex/i-013-record-permission-deprecation` is merged into local `master`.
- `I-002`, `I-004`, and `I-005` remain paused (legacy tracker notes; see GitHub Issues).
- `master` remains ahead of `origin/master`; do not upload or invite testers until the intended RC is validated and pushed.

### 2. Reconcile Handoff Docs Before RC

Purpose: make sure future sessions and the owner see the real RC state.

Codex tasks:

1. Update `CURRENT.md` to describe the RC candidate state.
2. Confirm any merged readiness slice is reflected in `CURRENT.md` (history lives in `git log` and merged PRs).
3. Confirm `README.md`, `DEVELOPMENT.md`, `PROJECT_SPEC.md`, and this file agree about:
   - whether `I-013` is done;
   - whether external TestFlight is still pending;
   - the current tested WebUI pin;
   - privacy policy status;
   - internal-only versus external-capable upload path.

Validation:

```zsh
git diff --check
rg -n "I-013|external TestFlight|internal-only|testFlightInternalTestingOnly|privacy policy|UPSTREAM_TESTED_SHA" README.md DEVELOPMENT.md PROJECT_SPEC.md TESTFLIGHT.md
```

Exit criteria:

- Handoff docs accurately describe the release candidate and remaining external-launch tasks.

### 3. Add An External-Capable Upload Path

Purpose: create a safe way to upload a build that can be submitted to external TestFlight.

Current state:

- `.github/workflows/internal-testflight.yml` uses `ci/TestFlightExportOptions.plist`.
- `ci/TestFlightExportOptions.plist` sets `testFlightInternalTestingOnly = true`.
- Apple marks those builds internal-only; they cannot be submitted for external testing or customers.

Preferred implementation:

1. Keep the existing internal-only workflow unchanged for quick owner smoke builds.
2. Add a separate external-capable export options plist, for example `ci/ExternalTestFlightExportOptions.plist`, with:
   - `method = app-store-connect`
   - `destination = upload`
   - `signingStyle = automatic`
   - `teamID = 6GYD9C9N6R`
   - `uploadSymbols = true`
   - no `testFlightInternalTestingOnly` key
3. Add a separate manual workflow, for example `.github/workflows/external-testflight.yml`, with stronger gates:
   - only runs on `master`;
   - requires an explicit input such as `confirm_external_review = EXTERNAL_REVIEW`;
   - uses a separate GitHub environment such as `external-testflight`;
   - does not auto-invite testers;
   - logs the commit SHA and build number clearly;
   - uses the external export options file.
4. Document that this workflow only uploads the build. Adding it to an external group and submitting to Beta App Review remains manual in App Store Connect.

Validation:

```zsh
plutil -lint ci/ExternalTestFlightExportOptions.plist
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/external-testflight.yml"); puts "YAML OK"'
rg -n "testFlightInternalTestingOnly|EXTERNAL_REVIEW|external-testflight" ci .github/workflows DEVELOPMENT.md TESTFLIGHT.md
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Exit criteria:

- There is a clearly separate, manually gated external-capable upload path.
- The internal-only path still exists and remains internal-only.

Current result as of 2026-05-15:

- Complete locally on `codex/testflight-doc-reconcile`.
- `.github/workflows/external-testflight.yml` adds a manually gated `External TestFlight` upload workflow with `confirm_external_review = EXTERNAL_REVIEW`, `external-testflight` environment gating, `master`-only enforcement, and no tester invites.
- `ci/ExternalTestFlightExportOptions.plist` uploads to App Store Connect without `testFlightInternalTestingOnly`.
- The existing `Internal TestFlight` workflow and `ci/TestFlightExportOptions.plist` remain internal-only.

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

Current local result as of 2026-05-15:

- Local validation passed on `codex/testflight-doc-reconcile`.
- App target Release settings use automatic signing, Team ID `6GYD9C9N6R`, bundle ID `com.uzairansar.hermesmobile`, and `HermesMobile/Resources/HermesMobile.entitlements`.
- Share extension Release settings use automatic signing, Team ID `6GYD9C9N6R`, bundle ID `com.uzairansar.hermesmobile.shareextension`, and `HermesShareExtension/Resources/HermesShareExtension.entitlements`.
- Both entitlement files include `group.com.uzairansar.hermesmobile`.
- Owner confirmed the Apple Developer Portal and App Store Connect API key items on 2026-05-15.

Current Step 4 status:

- Complete.

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

Beta App Review Information:

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

Current Step 5 status as of 2026-05-15:

- Draft metadata is prepared in this runbook.
- Owner confirmed the metadata was entered and saved in App Store Connect, the private review password was supplied there, the public privacy policy URL was saved, and App Privacy answers were confirmed.

Current Step 5 status:

- Complete.

### 6. Decide On Share Extension Auto-Launch Risk

Purpose: choose the safest external-review posture before the RC upload.

Current behavior:

- The share extension stages a draft/attachment in the App Group.
- It then attempts to open the containing app through a dynamic `UIApplication`/`openURL:` workaround because iOS share extensions do not provide a clean containing-app launcher.

Decision options:

1. Keep the workaround for external TestFlight.
   - Pros: best current user experience.
   - Cons: highest Beta App Review risk; dynamic use may be rejected even though it builds.
   - Required: explain the share flow clearly in Notes for Review and be ready to remove it quickly if rejected.
2. Replace with a review-safer flow before external submission.
   - Pros: lower review risk.
   - Cons: less automatic UX; may require user to open Hermes manually after sharing.
   - Required: implement, test Safari/Notes/Files/Photos share cases, and update docs.

Recommended path:

- Decide this before uploading the external-capable build. Do not submit one build and then change this behavior unless you are willing to restart the review cycle for a new build.

Current code note as of 2026-05-15:

- The extension saves the pending draft/attachment import to the App Group before attempting to open Hermes.
- The automatic launch path uses responder-chain and dynamic `UIApplication` URL-opening fallbacks to open `hermes-agent://share`.
- If automatic launch fails, the App Group import fallback still lets Hermes import the pending share when the app is next opened or foregrounded.
- The review-safer alternative is to remove automatic launch and show a saved status, requiring the user to open Hermes manually.

Exit criteria:

- The owner explicitly chooses keep or revert.
- The exact RC behavior is covered in manual regression.
- App Store Connect review notes match the chosen behavior.

Current Step 6 status as of 2026-05-15:

- Complete. Owner chose to keep the automatic app-launch workaround for external TestFlight.
- App Store Connect review notes include the share import flow.
- Manual regression should cover Safari/Notes/Files/Photos share import and fallback behavior before external submission.

### 7. Run Local RC Validation

Purpose: prove the code is buildable/testable before spending App Store Connect cycles.

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

Current Step 7 status as of 2026-05-15:

- Complete on `codex/testflight-doc-reconcile`.
- iPhone 17 Simulator is available.
- `git diff --check` passed.
- plist lint passed for app/share-extension Info.plist and privacy manifests.
- `xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17'` completed with `TEST SUCCEEDED`.
- XCTest result bundle: `~/Library/Developer/Xcode/DerivedData/HermesMobile-dodyrzzipcxecicrwnfmjwjkqngb/Logs/Test/Test-HermesMobile-2026.05.14_22-45-59--0400.xcresult`.
- `xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` completed with `BUILD SUCCEEDED`.

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
15. Exercise paused-risk repros:
    - active session sleep/return;
    - pin/unpin on multiple sessions;
    - thinking/tool card spacing in long sessions.

Exit criteria:

- No crash.
- No unexplained auth/logout issue.
- No blank transcript after reload/foreground.
- No destructive action affects non-disposable data.
- Any issue found is captured in GitHub Issues and either fixed or explicitly accepted before external launch.

Current Step 8 status as of 2026-05-16:

- Complete on iPhone 17 Simulator `A6ACE4D8-B20A-4E1C-AB21-4F92B862337A` against `https://<your-server>`.
- `GET https://<your-server>/health` returned HTTP 200 with `status: ok`.
- Owner entered credentials directly in the Simulator; no server password or reviewer password was committed.
- Sessions loaded, one WebUI-created session opened, and two disposable Step 8 sessions were created for state-changing checks.
- Normal send, stream completion, stop streaming, and background/foreground during an active stream passed without crash, logout, or blank transcript.
- Image and PDF attachment upload passed in a disposable session.
- Files text preview, image preview, and unsupported binary `No Preview` state passed.
- Tasks list/detail/output, Skills list/search/detail/linked file, Memory, and Usage Analytics timeframe switching passed.
- Paused-risk checks passed or remained known issues:
  - active session sleep/return did not reproduce `I-002`;
  - pin/unpin on multiple disposable sessions passed and did not reproduce `I-005`;
  - existing long-session Thinking-card duplication/spacing issues were observed again under `I-004`/`I-015`.
- New polish issue captured: `I-016`, Skills linked-file sheets need an obvious visible close/dismiss control.

### 9. Push The RC Commit

Purpose: ensure the upload workflow uses the audited source.

Owner task:

```zsh
git switch master
git status --short --branch
git push origin master
```

Exit criteria:

- `origin/master` points to the intended RC commit.
- App Store Connect upload workflow will build the audited source, not an older commit.

Current Step 9 status as of 2026-05-17:

- Complete. `master` was pushed for the internal TestFlight RC path.
- The latest local and remote commit before this Step 11 handoff was `cebdb38` (`Issues: Capture owner-observed polish items`).

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
- The installed build number is recorded in `CURRENT.md`.
- Internal smoke passes before any external-capable upload.

Current Step 10 status as of 2026-05-17:

- Complete. Owner installed internal TestFlight build `1.0 (7)` on a physical iPhone for Step 11 manual regression.

### 11. Owner Device Manual Regression

Purpose: verify real-device behavior that simulator and unit tests cannot cover.

Use the full checklist in `DEVELOPMENT.md`, with extra attention to:

- onboarding and wrong-password errors;
- server/tunnel down messaging;
- background audio does not pause until voice recording starts;
- voice permission allowed and denied;
- notification permission behavior;
- haptics;
- large Dynamic Type;
- VoiceOver core path;
- physical share sheet behavior from Safari, Notes/Mail, Photos, Files/PDF;
- attachment upload progress and failure recovery;
- long streaming response over two minutes;
- background/foreground stream recovery;
- app icon and launch screen;
- landscape and portrait.

Exit criteria:

- 30 minutes of normal iPhone use without crashes.
- Full checklist has no unresolved P0/P1.
- Accepted known risks are written down in GitHub Issues, `CURRENT.md`, or review notes.

Current Step 11 status as of 2026-05-17:

- Complete. Owner completed the physical iPhone manual regression on internal TestFlight build `1.0 (7)`.
- Step 11.7 Server Panels passed in Simulator before the device pass:
  - Files list/search;
  - text file preview;
  - image preview;
  - unsupported binary preview;
  - Tasks list/detail/output;
  - Skills list/search/detail;
  - Memory notes/profile;
  - Usage Analytics timeframe switching.
- Polish/Launch checks passed:
  - light mode;
  - dark mode;
  - portrait;
  - landscape on owner iPhone;
  - largest Dynamic Type on owner iPhone;
  - app icon/display name;
  - relaunch;
  - launch screen;
  - VoiceOver core path;
  - privacy prompts;
  - TestFlight path;
  - share sheet behavior.
- Owner documented newly observed issues in the tracker; there are no open P0/P1 blockers.
- Accepted non-blocking risks for external beta include `I-014`, `I-015`, `I-016`, `I-017`, `I-018`, `I-019`, `I-020`, `I-024`, `I-025`, `I-026`, and `I-027`.

### 12. Upload External-Capable Build

Purpose: create the build that can be submitted to Beta App Review.

Use the new external-capable workflow or manual Xcode upload. The build must not be marked internal-only.

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

Current Step 12 status as of 2026-05-17:

- External upload workflow was dispatched from `master` at commit `a6767f4`.
- First run `25979198228` failed during App Store Connect upload because the default external workflow run number selected bundle version `1`, and App Store Connect already had uploaded build `7`.
- Retried as run `25979270377` / `External TestFlight #8 from master` with explicit `build_number = 8`.
- Run `25979270377` completed successfully:
  - manual gate passed;
  - required App Store Connect secrets were present;
  - archive succeeded;
  - upload to App Store Connect succeeded.
- Owner still needs to wait for App Store Connect processing, confirm build `1.0 (8)` appears and is not marked internal-only, and resolve any compliance prompts before Step 13.

Current Step 12 update as of 2026-05-27:

- Owner reran `External TestFlight` from GitHub Actions after repairing the Apple signing/upload path.
- Run `26485474969` completed successfully from `master` at commit `8ebafc8fb8e4d30414be120b4194140322da53bb`.
- Verified run/job metadata:
  - workflow: `External TestFlight`;
  - display title: `External TestFlight from master`;
  - conclusion: `success`;
  - job: `Archive and Upload`, conclusion `success`;
  - marketing version: `1.0`;
  - build number: `30`;
  - export options: `ci/ExternalTestFlightExportOptions.plist`;
  - archive and App Store Connect upload succeeded.
- Current uploaded RC candidate is build `1.0 (30)`.
- Owner reported App Store Connect looks good for build `1.0 (30)`. Next owner decision is whether to submit build `1.0 (30)` for Beta App Review or hold it for internal/external stabilization first.

Current Step 12 update as of 2026-05-30:

- After issue #23 merged, GitHub Actions `External TestFlight` run `26674733144` completed successfully from `master` at commit `70d818fba2dced6eb3e37188c900ec79734fbb8c`.
- Verified run/job metadata:
  - workflow: `External TestFlight`;
  - display title: `External TestFlight from master`;
  - conclusion: `success`;
  - job: `Archive and Upload`, conclusion `success`;
  - marketing version: `1.0`;
  - build number: `33`;
  - export options: `ci/ExternalTestFlightExportOptions.plist`;
  - archive and App Store Connect upload succeeded.
- Current uploaded external-capable build is `1.0 (33)`.
- The workflow upload did not assign external tester groups, submit Beta App Review, replace the existing App Review build, invite testers, or release the app.
- Owner still needs to wait for App Store Connect processing, confirm build `1.0 (33)` appears and is not internal-only, resolve any compliance prompts, and manually choose whether to use build `1.0 (33)` for external testing and/or App Review replacement.

Current Step 12 update as of 2026-06-02:

- After issue #50 merged, GitHub Actions `External TestFlight` run `26831954965` was dispatched from `master` at commit `720105514823354f8c1988095596c9cb611e9c84`.
- Run `26831954965` selected build `1.0 (34)` and archived successfully, but App Store Connect rejected the upload because the `1.0` pre-release train is closed after the previously approved `1.0` version.
- Owner approved bumping `MARKETING_VERSION` to `1.0.1`.
- GitHub Actions `External TestFlight` retry run `26833031469` completed successfully from `master` at commit `9e8078215586643eb11c519bf9c73dfa103070ea`.
- Verified run/job metadata:
  - workflow: `External TestFlight`;
  - display title: `External TestFlight from master`;
  - conclusion: `success`;
  - job: `Archive and Upload`, conclusion `success`;
  - marketing version: `1.0.1`;
  - build number: `1`;
  - export options: `ci/ExternalTestFlightExportOptions.plist`;
  - archive and App Store Connect upload succeeded.
- Current uploaded external-capable build is `1.0.1 (1)`.
- The workflow upload did not assign external tester groups, submit Beta App Review, replace the existing App Review build, invite testers, or release the app.
- Owner still needs to wait for App Store Connect processing, confirm build `1.0.1 (1)` appears and is not internal-only, resolve any compliance prompts, and manually choose whether to use build `1.0.1 (1)` for external testing and/or App Review replacement.

### 13. Submit Beta App Review

Purpose: get the first external build approved by Apple.

Owner task in App Store Connect:

1. Create an external tester group, for example `External Beta`.
2. Add the external-capable build to that group.
3. Fill `What to Test` with concise tester instructions.
4. Submit for review.
5. Monitor App Store Connect review status and email.
6. If rejected, capture the rejection in GitHub Issues or `CURRENT.md`, fix only the rejection scope, upload a new external-capable build, and resubmit.

Suggested `What to Test`:

```text
Test core Hermex workflows: sign in to a self-hosted Hermes Web UI server, browse sessions, open existing conversations, send messages with model/reasoning/workspace options, stream responses, attach photos/files, use share extension import, browse workspace files, and view read-only Tasks, Skills, Memory, and Usage Analytics.
```

Exit criteria:

- External build is approved for TestFlight beta testing.

Historical Step 13 status as of 2026-05-17:

- Owner submitted external-capable build `1.0 (8)` for Beta App Review in App Store Connect.
- App Store Connect status is `Waiting for Review`.
- External testers have not been invited yet. Continue to wait for Beta App Review approval before Step 14.

Current Step 13 status as of 2026-05-30:

- Repo-local evidence records App Review submission for build `1.0 (32)`, not build `1.0 (33)`.
- No repo-local evidence has been recorded yet that build `1.0 (33)` was submitted for Beta App Review, assigned to external testers, or selected as an App Review replacement.
- Use build `1.0 (33)` for the next external review/stabilization decision unless the owner intentionally uploads a newer RC.

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

Before each new external build:

```zsh
git status --short --branch
git diff --check
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## App Store Connect Review Notes Template

Use this as a starting point and keep it accurate for the exact submitted build.

```text
Hermex is a native iOS client for a user-controlled Hermes Web UI developer-agent server.

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

## Known Risk Register For External Beta

Track these during launch:

- Share extension automatic app launch may be rejected by Beta App Review.
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

## CI Signing Credentials

Both TestFlight workflows (`internal-testflight.yml`, `external-testflight.yml`) use **manual signing** — a stored Apple Distribution certificate and three provisioning profiles — rather than automatic signing. This prevents the workflows from minting new distribution certificates on every run and exhausting the Apple Developer cert cap.

### Required GitHub secrets

Add these secrets to **both** the `internal-testflight` and `external-testflight` GitHub environments (Settings → Environments):

| Secret | Contents |
|---|---|
| `DIST_CERT_P12_BASE64` | base64-encoded Apple Distribution `.p12` |
| `DIST_CERT_P12_PASSWORD` | password used when exporting the `.p12` |
| `PROVISION_PROFILE_APP_BASE64` | base64-encoded App Store profile for `com.uzairansar.hermesmobile` |
| `PROVISION_PROFILE_SHAREEXT_BASE64` | base64-encoded App Store profile for `com.uzairansar.hermesmobile.shareextension` |
| `PROVISION_PROFILE_WIDGET_BASE64` | base64-encoded App Store profile for `com.uzairansar.hermesmobile.liveactivitywidget` |

### Exporting the certificate

1. Open **Keychain Access** → My Certificates → find "Apple Distribution: …".
2. Right-click → Export → choose `.p12` format, set a strong password.
3. Base64-encode it: `base64 -i cert.p12 | pbcopy` — paste as `DIST_CERT_P12_BASE64`.
4. Store the password as `DIST_CERT_P12_PASSWORD`.

### Downloading provisioning profiles

Each profile must be the **App Store** variant (not Development or Ad Hoc):

| Bundle ID | Profile name |
|---|---|
| `com.uzairansar.hermesmobile` | `Hermes Mobile App Store` |
| `com.uzairansar.hermesmobile.shareextension` | `Hermes Mobile Share Extension App Store` |
| `com.uzairansar.hermesmobile.liveactivitywidget` | `Hermes Mobile Live Activity App Store` |

Download from [developer.apple.com](https://developer.apple.com) → Certificates, IDs & Profiles → Profiles, then:

```
base64 -i HermesMobileAppStore.mobileprovision | pbcopy   # → PROVISION_PROFILE_APP_BASE64
base64 -i HermesShareExtensionAppStore.mobileprovision | pbcopy   # → PROVISION_PROFILE_SHAREEXT_BASE64
base64 -i HermesLiveActivityAppStore.mobileprovision | pbcopy   # → PROVISION_PROFILE_WIDGET_BASE64
```

### Rotation and expiry

- **Distribution certificates** expire after ~1 year. Apple also caps accounts at 3 active distribution certs. Renew in Xcode (Preferences → Accounts → Manage Certificates) or the Developer Portal, re-export the `.p12`, and update the two secrets.
- **Provisioning profiles** expire after ~1 year (or sooner if the certificate they reference is revoked). Download the renewed profile and update the corresponding secret. Profile names are stable across renewals so the export options plists need no changes.
- After rotating any secret, trigger one workflow run manually to confirm it resolves before the next scheduled release.
