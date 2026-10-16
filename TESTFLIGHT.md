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
and preparing App Store Connect. Every **Submit** and **Release** click in
App Store Connect stays with the owner.

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
6. **App Store Connect**, in the owner's signed-in browser, after the build
   finishes processing:
   - **App Store version:** create the version and attach the build. Write
     What's New from the changelog in short user words. Rewrite the stale
     description and review notes (check them against the app's current
     onboarding strings). Select manual release, set phased release as the
     owner chose, and add new screenshots if step 2 called for them.
   - **Verify:** reload the App Store version page and confirm every field
     saved.
   - **TestFlight:** fill the beta description and What to Test, then reload
     and confirm both saved. Last, select the three external groups. Adding
     external groups and submitting for Beta App Review is a single click, so
     leave that dialog open on **Submit**, and don't reload the page after.
   - **Outside the app:** open a hermexapp-site PR for any stale page (`main`
     deploys production; never push it). Draft the X post with the
     `x-writing-guide` skill at hermex-studio `src/releases/<version>/post.md`.
7. **Owner pass.** Post numbered steps for the owner's iPhone pass on this
   build ([Test the release candidate](#test-the-release-candidate)), focused
   on what changed. The owner tests, then submits for Beta App Review and App
   Review.
8. **The owner releases** from App Store Connect after approval.
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
and submit for Beta App Review. Capture any
rejection in a GitHub issue and validate the corrected build before resubmitting.

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
from the App Store version page, with **Manually release this version**
selected. After approval, release it from App Store Connect and bump
`MARKETING_VERSION` on `master` to open the next release train.

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
