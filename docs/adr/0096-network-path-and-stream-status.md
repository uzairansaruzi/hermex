# 0096. Network path and stream status

Area: networking-webui

## Use a short timeout for chat stream status probes

Stream status probes run inside the reconnect retry budget (#537), so `APIClient.chatStreamStatusTimeout` is an explicit 10 s instead of the 60 s session default.

Lives in: `HermesMobile/Networking/APIClient+Chat.swift`

## Publish network path updates on the main queue

`NetworkPathMonitor` hops each path update with `DispatchQueue.main.async` and `MainActor.assumeIsolated`. The main queue keeps updates in order; a `Task` per update might not.

Lives in: `HermesMobile/Networking/NetworkPathMonitor.swift`

## Treat only unsatisfied as offline

`NetworkPathSnapshot` counts only `NWPath.Status.unsatisfied` as offline. A `.requiresConnection` path, such as an on-demand VPN, comes up only when something connects, so waiting on it would never end.

Lives in: `HermesMobile/Networking/NetworkPathMonitor.swift`

## Ignore the SSE close that follows cancel or error

webui closes the socket right after sending `cancel` or `error`, and the SSE library reports that close as a transport error. `ChatStreamCoordinator.handleTransportError` returns early once `isTransportFinished`, since a finished run has nothing left to fail.

Lives in: `HermesMobile/Features/Chat/ChatStreamCoordinator.swift`
