# 0071. Live Activity push relay handoff

Area: live-activity-share-intents

## Wait for relay registration before marking a suspended Live Activity stale

When the live connection drops while the relay registration is still in flight, usually because the user left the app right after sending (#635), `AgentLiveActivityManager.awaitPushHandoff` keeps the last state and holds a background task until the registration settles, up to `pushHandoffLimit` (10 s). A handoff that lands a moment later then never leaves "Not connected" on a run the relay now drives. Only a failed or stalled registration marks the activity stale, and any newer write wins.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Keep relay-provided tool counts on local Live Activity writes

The app's local reducers never count a webui run's tools; only the push relay does (#644). `ContentState.keepingCounts(from:)` and `AgentLiveActivityManager.keepingRelayCounts` therefore copy the counts the activity already shows onto a local write that has none, rather than dropping them. A bot's feed owns its own chips, so bot activities are left as written.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Skip local Live Activity alerts when the relay drives the activity

`AgentLiveActivityAlertPolicy` lets a local write alert only when the run first stops for an approval or an answer, the app is not in the foreground, and the relay does not drive the activity. A paired server's relay banners approvals and questions itself (#740), so alerting locally too would buzz twice. A repeated waiting event keeps the status and stays silent.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Persist moved Live Activity push keys outside ActivityKit attributes

ActivityKit attributes are immutable, so after a legacy compression moves a bot's or Hermes session's stored key the activity still names the old one (#1179). `LiveActivityPushKeys` keeps the key each activity's pushes last moved to across a relaunch; cold launch reads it to match the host's live list, re-register an adopted activity, and retire the route it really used. Entries are scoped by the push server and the activity's identity, dropped when the activity ends, and pruned at cold launch. They live in standard defaults because a key names a session on its server and is not a credential.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Serialize Live Activity relay registrations

`PushActivityRegistrar` serializes activity PUT and DELETE calls, including retirement during an in-flight PUT, so an old owner's cleanup completes before a new owner can register the same session, and no task reads a mutable active server after suspension. In `reconcile`, when a newer activity's PUT settled on the route while this cleanup waited in line, a DELETE would revoke it, so the old receipt is dropped without one (#566). A failed PUT leaves no receipt, so a finished activity's route is still deleted.

Lives in: `HermesMobile/Push/PushRegistrar.swift`
