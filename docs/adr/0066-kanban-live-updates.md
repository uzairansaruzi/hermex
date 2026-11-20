# 0066. Kanban live updates

Area: kanban

## Use the since-cursor only for the same Board and filters

Upstream's `latest_event_id` ignores Board filters, so a cursor refresh is only sound while the request it answers matches the one that produced the snapshot. `KanbanFeatureState` records `snapshotRequest`, the Board and filters (without `since`) of the fetch that produced `snapshot`, and reads incrementally only while it still equals the current request. When the snapshot holds the unfiltered Board and a filter such as a tenant now applies, the foreground refresh fetches the filtered Board in full with no `since`.

Lives in: `HermesMobile/Features/Kanban/KanbanFeatureState.swift`, `HermesMobileTests/KanbanLiveUpdateTests.swift`

## Suspend live updates only on background

`KanbanStatusFocusView` forwards every scene phase change to `KanbanFeatureState.setScenePhase`. Only `.background` suspends live updates: `.inactive` is a transient overlay (Control Center, Notification Center, a system alert, the app switcher), so the stream and the Board stay as they are. Returning to `.active` asks the server for the Board since the snapshot's cursor. When no event landed, the Board, its stats, and the Board list are kept and the stream resumes from `liveCursor`; a changed Board also reconciles the Board list.

Lives in: `HermesMobile/Features/Kanban/KanbanFeatureState.swift`

## Reset the cursor when Hermes event ids go backwards

When a Hermes Board refresh returns a `latest_event_id` below the cursor at request time, the host's Kanban database was recreated. `KanbanFeatureState` then sets `liveCursor` to the new value and reopens the stream, because a socket reading after the old cursor would stay silent (#1045). Otherwise `liveCursor` only moves forward.

Lives in: `HermesMobile/Features/Kanban/KanbanFeatureState.swift`

## Answer since polls from latest_event_id

A Hermes host's `/board` takes no `since`, and the host has no REST events route, so `HermesKanbanClient.kanbanEvents` throws and the feature state's polling fallback reloads the Board instead. `HermesKanbanClient` reads a `since` request as unchanged while the Board's `latest_event_id` still equals it, the way webui's `changed` does, so a poll or a foreground check keeps an unchanged Board.

Lives in: `HermesMobile/Networking/Hermes/HermesKanbanClient.swift`

## Ping the events socket every 25 s on a fresh ticket

`KanbanWebSocketEventClient` opens one WebSocket per open Board, `/api/plugins/kanban/events?board=&since=&ticket=` on the Board's `HermesConnection` (#1045). The host sends `{events, cursor}` only when events land: no hello and no heartbeat, and a dashboard bound to loopback (how a tunneled one runs) sends no protocol pings either, so a tunnel such as Cloudflare would close a quiet socket at about 100 s. The client pings every 25 s, and a ping that has seen neither its pong nor a frame by the next one ends the socket. The first pong or frame proves the upgrade and reports `.opened`; `stop()` closes the socket cleanly, and nothing from it is reported after.

Every connect mints a fresh single-use ticket on the Board's `HermesConnection`, never the gateway's, so the upgrade carries the connection's headers to its own origin only. A 403 on the upgrade is the host's answer to a used or expired ticket, so the client opens once more on a fresh ticket before the failure is reported (#1045).

Lives in: `HermesMobile/Networking/Hermes/HermesKanbanClient.swift`

## Offer no subprotocol on the events socket

`HermesREST.kanbanEventsUpgrade` builds the upgrade on the `ws`/`wss` URL matching the address's scheme and offers no subprotocol, because the host accepts without echoing one (#1045). The pass goes in the query instead, a ticket as `?ticket=` or a page token as `?token=`. The host pins the socket to `board` and sends only events after `since`.

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`, `HermesMobile/Networking/Hermes/HermesKanbanClient.swift`

## Never log stream errors or event payloads

`KanbanEventStreamClient`'s SSE handler never includes the transport error or the event payload in logs; `onError` only reports that the stream failed.

Lives in: `HermesMobile/Networking/KanbanEventStreamClient.swift`
