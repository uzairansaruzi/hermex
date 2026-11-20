# 0124. Local run-end alerts

Area: push

## Gate run-end alerts only on scene activity

`ResponseCompletionNotificationPolicy.shouldSchedule` fires a run-ended notification when notifications are enabled and permitted and the scene is not active when the run ends. It deliberately does not depend on any "was streaming" or "was backgrounded during the stream" memory: those in-memory flags were wiped on suspend and cold relaunch, which is exactly when the stuck-mid-response reports happened (#248). Every in-session run end funnels through one chokepoint, so scene-not-active is the only gate needed, and a stopped run never arrives because `ResponseCompletionOutcome` cannot represent it.

Lives in: `HermesMobile/Config/AppTheme.swift`

## Recheck run-end alert currency after awaiting permission

`scheduleRunEndedIfAllowed` reads `isCurrent` and `isPushPaired` only after awaiting the authorization status, because a newer run end or a pairing can arrive while it is suspended. A newer run end schedules under the same identifier and the older alert must not replace it, and a paired server's relay alerts for it instead of the local alert.

Lives in: `HermesMobile/Config/AppTheme.swift`

## Hash the server URL in local alert userInfo

A local run-end alert's `userInfo` carries `server_hash`, a SHA-256 of the normalized server URL, rather than the URL: iOS keeps delivered alerts, and server URLs are credential-like. It carries no `install_hash`, so it is never read as a relay push (#653).

Lives in: `HermesMobile/Config/AppTheme.swift`

## Claim the notification offer before showing it

`NotificationOffer.claim` marks the offer for a run that just started on a server as made before returning it, so a crash or kill can never show it twice; a nil result leaves the flag unset so a later run can still ask. `isCurrent` is read after the permission check, so a chat that closed meanwhile shows nothing and does not use the offer up.

Lives in: `HermesMobile/Config/NotificationOffer.swift`
