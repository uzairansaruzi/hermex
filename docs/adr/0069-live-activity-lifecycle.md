# 0069. Live Activity lifecycle

Area: live-activity-share-intents

## Start the Live Activity timer at the run's start

`AgentLiveActivityManaging.start` takes `startedAt` as when the run began, not when the widget was created. `ChatStreamCoordinator.startLiveActivity` is called right after `seedActiveRunStart` and passes the server-seeded run start, so the widget's system elapsed timer counts the same span as the in-app "Working for" label rather than starting when this process attached to the stream (#406). Callers without a seeded start pass `Date()`.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`, `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`

## Keep the earliest known run start when reusing a Live Activity

When `AgentLiveActivityManager.start` reuses an existing activity, the earliest known start wins. The reused activity may have been started from a discovery stamp before the coordinator learned the server's earlier `pending_started_at`, and the widget timer must not run behind the in-app one.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Detach the previous Live Activity synchronously before async cleanup

`AgentLiveActivityManager.start` detaches the previous owner's activity synchronously before its asynchronous cleanup runs. Feed updates for the new owner must never reach the previous owner's activity while that cleanup is in flight.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Apply the snapshot title before starting the turn

`HermesChatTurnCoordinator.reconcile(with:)` applies the snapshot's title before it begins or adopts the running turn, so the turn's Live Activity starts under the session's title.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Use long Live Activity stale dates so suspended runs don't dim

`AgentLiveActivityManager.staleDate` keeps the widget looking current longer so a suspended run doesn't get the dimmed stale treatment within seconds (#246): 15 minutes while the relay registration holds, otherwise 300 s, or 90 s once the state is already stale. Final states get no stale date. The system-rendered elapsed timer keeps ticking regardless of this window.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`
