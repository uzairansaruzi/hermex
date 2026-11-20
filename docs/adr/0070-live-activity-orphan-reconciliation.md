# 0070. Live Activity orphan reconciliation

Area: live-activity-share-intents

## Alert for orphaned run ends only on cold launch

On cold launch `ContentView` ends any Live Activity left "running" by a run that finished while the app was terminated (#246), calling `LiveActivityReconciler.reconcileOrphanedActivities` with `notifiesOnCompletion: true`. A relaunched process means every orphan's run ended while the app was not active, so that is the one pass allowed to send a run-ended notification for a recent run (#248). The foreground (`scenePhase == .active`) pass passes false and stays silent, because the in-session run-end paths own notifications while the app is alive.

Lives in: `HermesMobile/ContentView.swift`, `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Gate orphaned Live Activities on server status, not in-memory stream state

`AgentLiveActivityManager.orphanedActivities` treats every non-final persisted activity as a candidate and deliberately does not exclude `currentStreamID`. That in-memory value goes stale when a run ends without the manager being told, for example when the app froze in the background and came back with the stream untracked, which left the activity stuck on "running" with nothing to finalize it (#246). The caller gates purely on the server's status, the ground truth: a genuinely live run reports `active=true` and is left alone.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Exclude the live-connected stream from orphan reconciliation

`AgentLiveActivityManager.activeConnectedStreamID` is the stream whose SSE is live in this process: set when the coordinator (re)connects (`start`), cleared when it suspends or hits trouble (`markStale`) or finalizes (`end`, `reset`). `orphanedActivities` skips it, so a server status poll that briefly reports inactive, between the server finishing and the on-device `.done` arriving, can't finalize a stream the foreground coordinator still owns; this mirrors the `refreshTranscriptIfCompleted` safety net (PR #266). Because it is cleared on suspend and end, a genuinely stuck orphan is never excluded, and a terminated app starts with nothing tracked, so the #246 fix still applies.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Map unknown run-journal terminal states to complete, lost bookkeeping to failed

`LiveActivityReconciler.reconciledOutcome(forTerminalState:)` maps the server run journal's `terminal_state` to the outcome a reconciled orphan finalizes with, using the owner-decided table on #267 and the existing localized completion lines, so there is no new copy. The default arm (missing, `"unknown"`, `"running"`, or any unrecognized value) keeps the pre-#267 `.complete` fallback, so an unmapped state never mislabels a genuine completion as a failure. The load-bearing case is `"lost-worker-bookkeeping"`, which the server reports for a silently dropped run (neither active nor terminal) and which must finalize as `.failed`.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Notify a reconciled orphan's end only when it is recent, real, and on the checked server

`reconcileOrphanedActivities` fetches each orphan's server status and ends the activity only on a definitive inactive status; a failed check (`nil` response) or a still-active stream is left alone, so a transient error or a live run can never cut an activity short. A run-ended notification fires only when this is the cold-launch pass; the outcome is `.complete` or `.failed` (a cancelled run ends without an alert because whoever stopped it already knows, #862); `endOrphan` reports it actually ended a still-running activity, so a run another path finalized can't double-fire (#248); the run finished within `recencyWindow`; and the orphan is known to belong to the server whose status was checked. Another server's stream ID means nothing to that server, so its alert would name the wrong chat and route to the wrong server (#862). An activity from a build before 1.7.0 has no recorded server and ends without an alert.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`
