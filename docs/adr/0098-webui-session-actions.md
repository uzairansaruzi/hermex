# 0098. webui session actions

Area: networking-webui

## Fall back to the session detail route when an external import fails

`sessionForOpening` imports an external session before navigating, and webui treats that import as a refresh. If the import fails, an already imported session may still be available, so the app still tries the canonical detail route, `client.session(id:)`.

Lives in: `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Treat only a JSON 503 as the session-busy move refusal

Only a 503 carrying the server's JSON error payload (`serverMessage != nil`) is the documented "session is busy (streaming)" refusal of a move, which `SessionMutator` maps to `SessionMoveWhileStreamingError` (#25). A proxy or tunnel 503 has no JSON body and keeps the generic connectivity message.

Lives in: `HermesMobile/Features/SessionList/SessionMutator.swift`

## Duplicate sessions with /api/session/duplicate, not branch

`SessionMutator.duplicate` calls `/api/session/duplicate`, which deep-copies `messages` and `tool_calls`, carries the token and cost counters over, and leaves the copy a root session. It used to call `/api/session/branch`, which means "fork a child from here": that dropped the tool calls and usage totals and filed the copy under the original in the lineage tree (#25). The server names the copy itself (`title + " (copy)"`) and answers with the whole duplicated session, so no title is passed and no second fetch follows.

Lives in: `HermesMobile/Features/SessionList/SessionMutator.swift`

## Request archived sessions with include_archived and filter client-side

`ArchivedSessionsViewModel` calls `client.sessions(includeArchived: true)` because the default response excludes archived rows entirely, which made the Archived view permanently empty (#17). The merged response keeps the visible rows too, each with an `archived` flag (verified against upstream `routes.py` @312d3fab and the live server), so the view filters to archived rows client-side.

Lives in: `HermesMobile/Features/Settings/ArchivedSessionsViewModel.swift`
