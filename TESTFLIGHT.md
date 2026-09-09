# TestFlight

Maintainer-only release procedures. Uploads, tester invitations, and App Store
Connect changes require an explicit owner request. Contributors only need
[DEVELOPMENT.md](DEVELOPMENT.md).

These procedures target the production app, `com.uzairansar.hermesmobile`.
For the side-by-side **Hermex Branch** app, use the
[branch upload commands](DEVELOPMENT.md#branch-testflight-upload-cli--the-push-to-branch-testflight-command).

## Release gates

Before a production upload, select a clean release-candidate commit on `master`,
run the local validation below, and obtain approval to push it. The upload
workflows build `origin/master`; confirm it points to that exact commit and CI
is green. Record the commit, version, build number, and validation in the release's
GitHub issue.

Before external distribution, all of these must hold:

- The owner tested an internal TestFlight build from the same RC commit on a
  physical iPhone, including the manual checklist below.
- No unresolved P0/P1 issue blocks normal use; accepted risks are recorded.
- An external-capable build is processed, with compliance information resolved
  and symbols uploaded. An internal-only build cannot be promoted externally.
- TestFlight information, privacy policy URL, and reviewer access are complete.
- Beta App Review has approved the build for external testing.

## Signing and workflow setup

Use Xcode automatic signing for the app, share extension, and Live Activity
widget. Confirm their bundle identifiers, entitlements, App Group capabilities,
and provisioning in the Apple Developer account before the first upload or
after a signing change. Inspect the current settings rather than copying identities
from a previous release:

```zsh
xcodebuild -showBuildSettings -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release | rg "PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN_ENTITLEMENTS|CODE_SIGN_STYLE"
```

Configure the `internal-testflight` and `external-testflight` GitHub environments,
with manual approval where available. Each needs these secrets:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`, the full `.p8` contents

The workflows accept actual or escaped newlines in the private key. The API key
needs upload and provisioning access, and Apple Developer agreements must be
accepted. Keep signing credentials out of the repository and command output.

## Local validation

Run on the exact RC commit:

```zsh
xcrun simctl list devices available
git status --short --branch
git diff --check
plutil -lint HermesMobile/Resources/Info.plist HermesMobile/Resources/PrivacyInfo.xcprivacy HermesShareExtension/Resources/Info.plist HermesShareExtension/Resources/PrivacyInfo.xcprivacy
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

If that simulator is unavailable, choose an available iPhone and record it.
If it needs restarting, shut down only the exact simulator UDID used for this
run. The unsigned Release command is compile-only; use a signed Debug build for
simulator installation, as described in `AGENTS.md`.

Run authenticated smoke against an owner-authorized server. Use a disposable
session for mutations and clean up only that session and its branches. Cover
sign-in, a WebUI-created session, send/stop, stream completion, background recovery,
image/file uploads, workspace previews, and Tasks/Skills/Memory/Usage panels.
Record and resolve failures before proceeding.

## Upload an internal build

1. Run [Internal TestFlight](.github/workflows/internal-testflight.yml) from GitHub
   Actions with ref `master` and `confirm_internal_only = INTERNAL`.
2. Leave `build_number` blank to select the next App Store Connect build number
   for the current marketing version. A manual override must exceed existing builds.
3. Wait for processing, add the build to the internal group, and install it on
   the owner's physical iPhone.
4. Run the [full-app manual checklist](DEVELOPMENT.md#full-app-manual-regression-checklist).
   Include an update over an existing TestFlight install, feedback capture, and
   30 minutes of normal use. Record the tested build and outcome.

The workflow uses [internal-only export options](ci/TestFlightExportOptions.plist).
Upload success means delivery was accepted; processing and group assignment
remain separate steps.

## Upload an external-capable build

After internal device validation of the RC:

1. Run [External TestFlight](.github/workflows/external-testflight.yml) from GitHub
   Actions with ref `master` and `confirm_external_review = EXTERNAL_REVIEW`.
2. Leave `build_number` blank for automatic selection.
3. Wait for processing and confirm compliance information and symbols are resolved.

This workflow uses [external-capable export options](ci/ExternalTestFlightExportOptions.plist)
and does not invite testers or submit for review. It checks the release train
before archiving through `ENFORCE_OPEN_TRAIN` in
[the build-number selector](ci/select_testflight_build_number.rb).
After an App Store release, bump all `MARKETING_VERSION` entries on `master`
to open the next release train; the external workflow rejects a closed train.

For a manual upload instead, select the validated RC in Xcode, archive Release
for `Any iOS Device`, and choose `Distribute App > App Store Connect > Upload`.
Use a unique build number and an external-capable export, then wait for processing.

## Review information and privacy

In App Store Connect, verify the beta description, What to Test, feedback email,
contact details, review notes, privacy policy, and applicable support/marketing
URLs. Check the age rating and category for the submitted build.

Provide a working review server and credential in App Store Connect, never in
git. Keep the server available throughout review. Describe a short review path:
sign in, open a session, send a message, browse workspace files, and import through
the share extension.

Review notes and App Privacy answers must match the submitted build:

- Hermex is a native client for a user-configured, self-hosted Hermes server,
  with no in-app account creation or purchase flow.
- There is no tracking or third-party analytics. Account for what the server
  operator can access when providing an owner-hosted server to testers.
- The composer supports camera capture, selected photos/files, and explicit
  voice input. Check permission descriptions against the app's current Info.plist.
- Shared content is staged in the App Group and selected attachments are uploaded
  to the configured server. The user still taps Send to send the message.

The share extension's automatic app-opening workaround is an accepted review
risk. It attempts to open `hermes-agent://share` through dynamic URL-opening
fallbacks. If opening fails, the app imports the pending share when next opened
or foregrounded. Test Safari, Notes, Files, and Photos imports, including that
fallback, and describe the behavior accurately in review notes.

## External review and rollout

With owner authorization, add the external-capable build to an external group,
fill What to Test for this release, and submit for Beta App Review. Capture any
rejection in a GitHub issue and validate the corrected build before resubmitting.

Invite testers only after the release gates pass. Start with a small private group;
provide server requirements, known limitations, install instructions, and a feedback
contact. Ask for the build number and screenshots or recordings with bug reports.
Make server exposure and local cache behavior clear before testers connect sensitive
workspaces.

Review feedback and crashes daily during the first week. Resolve P0 issues
immediately and P1 issues before widening access; pause expansion if either
appears. Track actionable reports in GitHub Issues and rerun validation for each RC.
Upstream compatibility is recorded in `UPSTREAM_TESTED_SHA`; server availability
and quiet-stream disconnections remain part of connection testing.

## Exported feedback

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
