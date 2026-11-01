# TestFlight

Maintainer-only release procedures. Uploads, tester invitations, and App Store
Connect changes require an explicit owner request. Contributors only need
[DEVELOPMENT.md](DEVELOPMENT.md).

These procedures target the production app, `com.uzairansar.hermesmobile`.
For the side-by-side **Hermex Branch** app, use the
[branch upload commands](DEVELOPMENT.md#branch-testflight-upload-cli--the-push-to-branch-testflight-command).

## Release flow

Every release candidate (RC) is **one build** that moves through audiences.
Changing the audience never needs a new upload; changing the code does.

| Stage | Audience | How the build gets there |
|---|---|---|
| Feature work | Owner | **Hermex Branch** app, from the feature branch ([branch upload](DEVELOPMENT.md#branch-testflight-upload-cli--the-push-to-branch-testflight-command)) |
| RC | Owner | [Upload a release candidate](#upload-a-release-candidate) from `master`; the internal **Owner Testing** group distributes it automatically |
| External testing | **Beta Testers**, **Hermex Members**, **Hermex Supporters** | The same build, added to all three external groups and approved by Beta App Review |
| App Store | Customers | The same build, submitted to App Review and released manually |

Internal groups are for App Store Connect team members (the owner). Testers
outside the team belong in the three external groups, which do not distribute
automatically. Hermex Branch builds are internal-only and never reach external
testers.

## Release runbook

One release from start to close-out. Agents run it as
`/hermex-release <version>`, then `/hermex-release <version> done` after
the owner releases. The owner's go on the release pack (step 2) approves steps
3–7: merging the changelog PR, approving the `external-testflight` upload gate,
and preparing App Store Connect through the [CLI](#app-store-connect-cli).
Submission and publication each need an explicit owner request for this version;
the release-pack go covers preparation only. The owner can request these through
the agent or use App Store Connect directly.

1. **Release issue.** One per version, titled `Release <version>`, opening
   with the plain header (`docs/agents/issue-tracker.md` § Issue Body). It
   holds the release pack, the RC commit and build, what was submitted, and
   the day-2 and day-7 checks. If the milestone has an epic, the epic
   links to the release issue. Reuse the issue if it already exists.
2. **Release pack**, posted on the release issue, then stop for the owner's go:
   - The version, the RC commit (`origin/master`), and what merged since the
     last tag (`git log v<previous>..origin/master`).
   - Milestone leftovers and open `release-blocker` issues, each with a
     recommendation. Only the owner moves issues between milestones.
   - The draft changelog entry (step 3).
   - The [release gates](#release-gates) that can be checked now, including
     the hermex-push plugin version.
   - Outward copy this release makes stale: the App Store description, review
     notes, and beta description, and hermexapp-site pages (including
     `/setup`, the App Store support URL).
   - Screenshots and the release video: needed or not, with one reason for
     each. App Store Connect takes new screenshots only with a version
     submission, so a refresh lands before step 6.
   - Phased release: on or off, with a recommendation.
3. **Changelog PR**, titled `chore(release): Hermex <version> changelog`,
   writes the `## [<version>.0] - Unreleased` entry:
   - When the release has a headline change, open with a short paragraph
     about it.
   - Use Added / Changed / Fixed / Security, user-visible changes only. Leave
     out CI, tests, docs, and refactors that change nothing for users.
   - Fold fixes to features that are new in this release into those features'
     bullets.
   - Write what the user can do now, in plain words. Use reference-style links
     (`[#1020]`), defined under the entry: the issue for an epic, otherwise the PR.
   Merge it once CI and the review bots are green.
4. **Upload the RC** from the merged commit:
   - Run [Local validation](#local-validation).
   - [Upload a release candidate](#upload-a-release-candidate), approving the
     `external-testflight` gate.
   - Record the commit and build on the release issue.
5. **GitHub draft release:** `gh release create v<version>.0 --draft
   --target <rc-sha> --title "Hermex <version>"`, with notes from the
   changelog entry. Publishing it creates the public tag, so publishing waits
   for step 9.
6. **App Store Connect**, through the CLI, after the build
   finishes processing:
   - **App Store version:** create the version and attach the build. Write
     What's New from the changelog in short user words. Rewrite the stale
     description and review notes (check them against the app's current
     onboarding strings). Select manual release, set phased release as the
     owner chose, and add new screenshots if step 2 called for them.
   - **Verify:** read the version, localizations, attached build, and review
     details back through the API; confirm the saved values match the release
     pack and run submission validation.
   - **TestFlight:** fill the beta description and What to Test for every
     configured locale, then read both back. Preview assigning the exact build
     to the three external groups with `builds add-groups --dry-run`. Assigning
     groups or submitting for Beta App Review waits for step 7 authorization.
   - **Outside the app:** open a hermexapp-site PR for any stale page (`main`
     deploys production; never push it). Draft the X post with the
     `x-writing-guide` skill at hermex-studio `src/releases/<version>/post.md`.
7. **Owner pass.** Post numbered steps for the owner's iPhone pass on this
   build ([Test the release candidate](#test-the-release-candidate)), focused
   on what changed. After testing, the owner requests submission for Beta App
   Review and/or App Review; run only the requested action against the recorded
   build. Submission can also be completed in the browser.
8. **Release after approval.** The owner requests publication of this exact
   approved version, or releases it in App Store Connect. Confirm it is live
   before close-out.
9. **Close-out**, run right after the release:
   - Publish the draft release, or create it at the RC commit if there is
     none. This creates the `v<version>.0` tag.
   - In one PR, date the changelog entry and bump every `MARKETING_VERSION`
     to the next open milestone. If there is none, stop and ask. Merge the
     PR once it is green.
   - Close the milestone and post the release record on the release issue.
     Leave the issue open with two checkboxes: the day-2 and day-7 crash and
     feedback checks. It closes when both are ticked.
   - Give the owner the changelog link to post as a reply to the X post.

## Release gates

Before a production upload, select a clean RC commit on `master`, run the local
validation below, and obtain approval to push it. The upload workflow builds
`origin/master`; confirm it points to that exact commit. Every `master` commit
passed the required `CI Gate` on its PR, so CI is the full-suite gate. Record the
commit, version, build number, and validation in the release's GitHub issue.

Before external distribution, all of these must hold:

- The owner tested this exact build on a physical iPhone as described in
  [Test the release candidate](#test-the-release-candidate).
- The release's milestone has no open issues; the owner moved anything
  unfinished to the next milestone (`docs/agents/issue-tracker.md`).
- No open issue is labeled `release-blocker`; accepted risks are recorded.
- `HermexPushPlugin.newestVersion` equals `version` in `plugin/plugin.yaml` on
  hermex-push `main`. If the plugin changed since the last release, bump the
  constant, or Settings will never offer paired hosts the update.
- The build is processed, with compliance information resolved and symbols uploaded.
- TestFlight information, privacy policy URL, and reviewer access are complete.
- Beta App Review has approved the build for external testing.

## App Store Connect CLI

Use `scripts/app-store` for App Store Connect work. It passes commands to the
open-source [`asc` CLI](https://github.com/rorkai/App-Store-Connect-CLI), defaults
to the production Hermex app and the `hermex` auth profile, and sets
`ASC_READ_ONLY=1`. Add `--write` before the command only for an owner-authorized
change. Native `--confirm` flags still apply. Ordinary release preparation,
tester changes, review submission, and publication are separate authorizations;
setting up this tooling does not submit or release an update.

The native CLI's `--app` flag can override the default app. Keep production
release commands on Hermex; use `scripts/branch-testflight` for branch uploads.
Run `scripts/app-store <command> --help` for current flags. The initial setup was
verified with Homebrew `asc` 5.14.3. After upgrading, recheck the relevant help
and dry-run before a write.

### One-time machine setup

```zsh
brew install asc
brew pin asc
asc telemetry disable
asc auth login --name hermex --key-id KEY_ID --issuer-id ISSUER_ID \
  --private-key /absolute/path/to/AuthKey_KEY_ID.p8 --fix-permissions --network
scripts/app-store auth status --validate
scripts/app-store apps view --id 6767006319
scripts/app-store status
```

Use an App Manager API key (or an existing Admin key). Upload-only access is
insufficient for release and tester management. Authentication uses the macOS
Keychain; an individual API key instead needs `--key-type individual` without
`--issuer-id`. Keep `.p8` files out of the checkout. `.asc/` is ignored for local
release metadata, checkpoints, and any tester exports. The wrapper disables CLI
telemetry. CI continues to use its existing GitHub secrets and upload workflow;
local setup does not replace those credentials or change signing.

### Prepare the selected build

Set `VERSION` to the full App Store version and `BUILD_ID` to the processed RC's
App Store Connect resource ID, not its displayed build number. Use `status`,
`versions list --platform IOS`, `builds list`, and `testflight groups list` to
resolve the exact version, build, locales, and external group IDs. Verify the
app is `com.uzairansar.hermesmobile` before writing. Avoid `--latest` when
promoting an RC: use the build recorded on the release issue throughout.

Pull the previous released version's public metadata with `metadata pull` into
`.asc/releases/<version>/metadata`. Move its version directory to the new version
and edit the locale JSON files: `whatsNew` is the public App Store release note.
Use the release pack's approved copy; preserve untouched fields and locales.
Run `metadata validate --dir "$METADATA_DIR"` locally, then preview and apply:

```zsh
scripts/app-store release stage --version "$VERSION" --build-id "$BUILD_ID" \
  --metadata-dir "$METADATA_DIR" --dry-run
# After the owner approves the release pack:
scripts/app-store --write release stage --version "$VERSION" --build-id "$BUILD_ID" \
  --metadata-dir "$METADATA_DIR" --confirm
VERSION_ID="$(scripts/app-store versions view --version "$VERSION" --output json \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
scripts/app-store --write versions update --version-id "$VERSION_ID" --release-type MANUAL
```

Resolve and save `VERSION_ID` after staging so it includes a newly created
version. It is the App Store version's resource ID, distinct from `VERSION`
and `BUILD_ID`; keep it with the release record for the later publication step.

Staging creates the version, applies localization text, attaches the existing
build, and validates without submitting. It does not populate screenshots,
age ratings, or review details. If validation fails after staging, earlier
changes may have saved: read them back, fix the reported blockers, then resume
with the same inputs instead of creating another version or build. Configure
`versions phased-release` only as chosen in the release pack. Upload approved
screenshots with `screenshots upload`; preview replacements with `--dry-run`
before using `--replace --confirm`.

TestFlight copy is separate from App Store copy. List `builds test-notes` first,
then use `create` for a missing locale or `update` for an existing one:

```zsh
scripts/app-store --write builds test-notes update --build-id "$BUILD_ID" \
  --locale en-US --whats-new "@file:$WHAT_TO_TEST_FILE"
scripts/app-store --write testflight app-localizations update \
  --id "$BETA_LOCALIZATION_ID" --description "@file:$BETA_DESCRIPTION_FILE"
```

Apply the approved text to each configured locale; do not assume `en-US` is the
only locale. Inspect `review details-for-version` and `testflight review view`
for reviewer access and contact information. Update only stale fields, using
`review details-update` or `testflight review edit`. Pass multiline copy via
`@file:/absolute/path`; use `@env:VARIABLE` or a private local file for demo
credentials. Never print secrets or use `--include-sensitive` in agent output.

Read the saved localizations, test notes, beta descriptions, review details,
and attached build back. Run `scripts/app-store validate --version "$VERSION"`
and preview `builds add-groups --build-id "$BUILD_ID" --group "$GROUP_IDS" --dry-run`.
`GROUP_IDS` contains only the resolved **Beta Testers**, **Hermex Members**, and
**Hermex Supporters** external groups. Passing validation is a readiness check,
not an Apple approval or permission to submit.

Readiness checks assume an editable draft. An already-submitted version reports
`WAITING_FOR_REVIEW` as a blocker; inspect `status` and wait for review rather
than canceling or recreating the submission to make preparation checks pass.

### Submit and release on request

After the owner's pass on this build and explicit authorization for each action:

```zsh
# External TestFlight: assign the selected groups and submit for Beta App Review.
scripts/app-store --write builds add-groups --build-id "$BUILD_ID" \
  --group "$GROUP_IDS" --submit --confirm
# App Review: submit the prepared version using that same uploaded build.
scripts/app-store --write review submit --version "$VERSION" --build-id "$BUILD_ID" --confirm
scripts/app-store status
# Only after approval and the owner's explicit request to publish:
scripts/app-store --write versions release --version-id "$VERSION_ID" --confirm
```

Before submission, confirm manual release is saved and the version's attached
build still matches the tested RC. After a timeout or ambiguous write failure,
inspect server state before retrying a submission, invitation, or release.
Keep Beta App Review and App Review outcomes separate in the release issue.
Apple still reviews submissions. Account agreements and privacy questionnaire
changes may require the owner's browser; use it for those exceptions.

### Manage external testers

Resolve membership with `testflight testers list --email` and
`testflight testers groups list --id` before changing it. Tester records and
exports contain personal information; keep them out of public issues and logs.

```zsh
scripts/app-store --write testflight testers invite --email "$TESTER_EMAIL" --group "$GROUP_ID"
scripts/app-store --write testflight testers add-groups --id "$TESTER_ID" --group "$GROUP_ID"
scripts/app-store --write testflight testers remove-groups --id "$TESTER_ID" --group "$GROUP_ID" --confirm
```

Invitations can send email immediately and need an owner request. Prefer removing
only the requested group membership rather than `testers remove`, which deletes
the tester more broadly. Read group membership back after either change.

## Signing and workflow setup

Use Xcode automatic signing for the app, share extension, Live Activity widget,
and notification service extension. Confirm their bundle identifiers,
entitlements, App Group capabilities, and provisioning in the Apple Developer
account before the first upload or after a signing change. Inspect the current
settings rather than copying identities from a previous release:

```zsh
xcodebuild -showBuildSettings -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release | rg "PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN_ENTITLEMENTS|CODE_SIGN_STYLE"
```

The upload workflow runs in the `external-testflight` GitHub environment, whose
required reviewer is the upload gate. It needs these secrets:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`, the full `.p8` contents

The workflow accepts actual or escaped newlines in the private key. The API key
needs upload and provisioning access, and Apple Developer agreements must be
accepted. Keep signing credentials out of the repository and command output.

## Local validation

Run on the exact RC commit:

```zsh
git status --short --branch
git diff --check
plutil -lint HermesMobile/Resources/Info.plist HermesMobile/Resources/PrivacyInfo.xcprivacy HermesShareExtension/Resources/Info.plist HermesShareExtension/Resources/PrivacyInfo.xcprivacy
xcodebuild -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The full XCTest suite already ran in PR CI before the merge; do not repeat it
locally. The unsigned Release command is compile-only; use a signed Debug build
for simulator installation, as described in `AGENTS.md`.

Live behavior is proven by the owner's pass on the uploaded RC
([Test the release candidate](#test-the-release-candidate)), not by a separate
smoke run.

## Upload a release candidate

1. Run [TestFlight Release Candidate](.github/workflows/release-candidate-testflight.yml)
   from GitHub Actions with ref `master`, and approve the `external-testflight`
   environment when prompted.
2. Leave `build_number` blank to select the next App Store Connect build number
   for the current marketing version. A manual override must exceed existing builds.
3. Wait for processing and confirm compliance information and symbols are resolved.

If the upload fails because the Apple certificate limit is reached, stop. The
owner revokes old Apple Development certificates on developer.apple.com, then
rerun the workflow. Each CI run creates a new certificate until
[#4](https://github.com/uzairansaruzi/hermex/issues/4) is fixed.

The workflow uses [external-capable export options](ci/ReleaseCandidateExportOptions.plist),
so the tested build can later go to external testers and App Review. It invites
no testers and submits nothing for review. Upload success means delivery was
accepted; processing is a separate step. It checks the release train before
archiving through `ENFORCE_OPEN_TRAIN` in
[the build-number selector](ci/select_testflight_build_number.rb).
After an App Store release, bump all `MARKETING_VERSION` entries on `master`
to open the next release train; the workflow rejects a closed train.

For a manual upload instead, select the validated RC in Xcode, archive Release
for `Any iOS Device`, and choose `Distribute App > App Store Connect > Upload`
without restricting it to internal testing. Use a unique build number, then
wait for processing.

## Test the release candidate

The owner's internal group distributes each processed RC automatically. Install
it over the existing TestFlight or App Store install on the owner's iPhone.

- **First RC of a marketing version:** run the
  [full-app manual checklist](DEVELOPMENT.md#full-app-manual-regression-checklist),
  including an update over an existing install, feedback capture, and 30 minutes
  of normal use.
- **Later RCs of the same version:** test what changed since the previous RC,
  plus an update over the previous RC.

Record the tested build and outcome in the release's GitHub issue. A failed RC
is fixed on `master` and replaced by a new upload; never promote it.

### Diagnostics (MetricKit)

About → Diagnostics keeps the crash, hang, CPU and disk-write reports MetricKit
hands the main app (#1397), sanitized, at most 10 for 14 days, on the device
only. iOS decides when and whether to deliver one, so an empty list does not
mean the app never crashed; the share extension, widget and notification
service are not covered. Nothing is uploaded: a tester copies a report into a
bug report, and its frame UUIDs and offsets are symbolicated off the device
against the build's dSYMs.

Simulators never receive payloads. To check the page, or to capture a real
payload as a test fixture, run a signed Debug build on a physical iPhone from
Xcode, choose Debug → Simulate MetricKit Payloads, then open About →
Diagnostics. A captured payload can replace the documented-format sample in
`DiagnosticsLogTests` once its real device values are swapped for placeholders.

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

## External testing and App Store release

With owner authorization, add the tested RC to the Beta Testers, Hermex
Members, and Hermex Supporters groups, fill What to Test for this release,
and submit for Beta App Review through the CLI above or App Store Connect.
Capture any rejection in a GitHub issue and validate the corrected build before
resubmitting.

Invite new testers only after the release gates pass. Provide server
requirements, known limitations, install instructions, and a feedback contact. Ask for the build number and screenshots or recordings with bug reports.
Make server exposure and local cache behavior clear before testers connect sensitive
workspaces.

Check crashes and feedback on day 2 and day 7 after release, and tick each
check on the release issue. Resolve
`release-blocker` issues immediately, and never widen access while one is
open; pause expansion if one appears. Track actionable reports in GitHub Issues and rerun validation for each RC.
Upstream compatibility is recorded in `UPSTREAM_TESTED_SHA`; server availability
and quiet-stream disconnections remain part of connection testing.

When the RC is ready for customers, submit **the same build** for App Review
through the CLI above or the App Store version page, with **Manually release
this version** selected. After approval and an explicit owner request, release
it through the CLI or App Store Connect and bump `MARKETING_VERSION` on `master`
to open the next release train.

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
