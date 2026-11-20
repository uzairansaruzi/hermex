# 0150. Settings server pages

Area: settings-onboarding-auth

## Serialize settings toggle writes behind the in-flight POST

Cancelling a Task does not un-send a POST that already left the device, so a previous request could land at the server after a newer one and flip the stored value against the UI. `CliSessionsSyncModel` holds the next write until the previous response arrives, which guarantees the server applies toggles in UI order. A superseded write skips its POST entirely, since the newest queued write carries the final value, so a long chain of toggles collapses to one request.

Lives in: `HermesMobile/Features/Settings/CliSessionsSyncModel.swift`, `HermesMobileTests/CliSessionsSyncModelTests.swift`

## Refresh provider quota only on an explicit user gesture

`GET /api/provider/quota` reads one provider's subscription limits or credits. Its `refresh` parameter bypasses the server's 45 s probe cache and re-probes the upstream account, and a cold probe can take several seconds, so only explicit refresh gestures pass `refresh: true`.

Lives in: `HermesMobile/Networking/APIClient+ProviderQuota.swift`, `HermesMobile/Networking/Endpoints.swift`

## Route Hermex-managed plugins to their own pages for removal

A user-installed plugin's way out in `PluginsView.pluginActions` is a remove action, except hermex-push and hermex-screen, which go to the pages that manage them because each has its own pairing or hold to undo. Screen's page can remove it only while it's running, so a hermex-screen that's off removes like any other plugin. Bundled plugins have no removal.

Lives in: `HermesMobile/Features/Settings/PluginsView.swift`

## Read Profile serving from the page, not the empty section

`ProfileServingSection` is the active Hermes server's Profiles section while its gateway's Webapp serves only one Profile (#1611): how many it serves, why in plain words, the host's own words, and the way to serve every Profile (`ServeEveryProfileView`). It shows nothing until `serving` reports a reason, and an empty section's own task never runs, so the page reads it through `read(connection:server:)`.

Lives in: `HermesMobile/Features/Settings/ProfileServingSection.swift`

## Open the recovery chat on the served Profile

`ServeEveryProfileView.openRecoveryChat` opens a new chat on the server's served Profile, never New Session's, which may be one the Webapp doesn't serve. Its text names the unserved Profile and `blockers` in the host's words, and asks the agent to explain the migration's dry run and propose commands, under the triage playbook's guardrails. Nothing is sent until the user does.

Lives in: `HermesMobile/Features/Settings/ServeEveryProfileView.swift`
