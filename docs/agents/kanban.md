# Kanban: contract and behavior rules

Durable rules for the shipped Kanban feature (`HermesMobile/Features/Kanban/`).
These are normative where they differ from the desktop WebUI. Vocabulary is owned by
root `CONTEXT.md`: upstream `task`/`task_id` stay network-boundary names; user-facing
and Swift domain names use Card with a `Kanban` qualifier.

The official Hermes API docs omit Kanban internals, so Hermex makes no version-range
promise for this feature. Compatibility is capability-based and must be revalidated
after a material upstream `api/kanban_bridge.py` change. Design rationale lives in
issues #140–#148.

## Compatibility handshake and capability boundaries

Before showing live Kanban data, Hermex performs this non-mutating handshake, in order:

1. `GET /api/kanban/config`
2. `GET /api/kanban/boards`
3. `GET /api/kanban/board?board=<server-reported-current-slug>`

Every upstream wire-model property is optional, unknown fields are ignored, and
decoding is followed by capability-specific semantic validation. Hermex must not
infer missing Board identity, current Board, Card identity, Card Status, dependency
direction, or mutation outcome. An unknown Status remains visible as an unsupported
server value and disables mutations for that Card.

Failure of the core read contract makes Kanban unavailable but does not hide its
navigation entry. Authentication, network reachability, server failure, and
incompatible-contract states remain distinguishable and offer Retry. SSE failure
degrades to event polling. A missing or incompatible write disables only that
capability for the current server session when browsing remains safe. Partial
compatibility is disclosed persistently and unavailable controls explain why.

Capability probes must never mutate state, Preview Dispatch, or Run Dispatcher. They
must never try speculative paths, renamed fields, or alternate payload shapes.

## Verified HTTP surface

All requests use the existing authenticated `URLSession` cookie jar and configured
custom proxy headers. Native requests do not add `Authorization`, `Origin`, or
`Referer`. JSON routes are expected to return `application/json`; SSE is expected to
return `text/event-stream`. Re-check exact request and response shapes in the
precedence `AGENTS.md` requires before changing any of them.

| Capability | Verified method and path | Required contract notes |
|---|---|---|
| Configuration | `GET /api/kanban/config` | Columns, Profiles/counts, defaults, grouping/archive/Markdown flags, and `read_only`. Hermex reads but never writes the server-global grouping setting. |
| Boards | `GET /api/kanban/boards` | Board metadata/counts, `current`, and `read_only`. Never surface `db_path` in normal UI or logs. |
| Board snapshot | `GET /api/kanban/board` | `board`, Profile/tenant/archive filters, and optional event cursor; full `changed:true` or minimal `changed:false` envelope. |
| Stats and Profiles | `GET /api/kanban/stats`, `GET /api/kanban/assignees` | Stats tolerate the older minimal shape. WebUI-parity UI uses total and per-Status counts. |
| Events | `GET /api/kanban/events`, `GET /api/kanban/events/stream` | Cursor-based polling and SSE resume. SSE begins with `hello`, then `events`; reconnect when Board changes. |
| Card detail | `GET /api/kanban/tasks/{id}` | Card, comments, events, prerequisite/dependent links, Dispatch Runs, and `read_only`. |
| Worker log | `GET /api/kanban/tasks/{id}/log` | Tail is a byte limit; show log content only in an explicit Card operational-history surface. |
| Create Card | `POST /api/kanban/tasks` | Required title; supported native fields are body, initial Triage/To Do/Ready Status, priority, Assigned Profile, tenant, workspace kind/path, skills, maximum runtime, one initial Prerequisite, idempotency key, and Board. |
| Edit Card | `PATCH /api/kanban/tasks/{id}` | Title, body, tenant, priority, Assigned Profile, and permitted Status transition. Create-only fields remain visibly non-editable. Do not use the legacy `/patch` alias. |
| Comments | `POST /api/kanban/tasks/{id}/comments` | Nonblank body; no edit/delete support. |
| Block/Unblock | `POST /api/kanban/tasks/{id}/block`, `POST /api/kanban/tasks/{id}/unblock` | Preserve the structured server verbs and refusal errors. |
| Dependencies | `POST /api/kanban/links`, `POST /api/kanban/links/delete` | Exact direction is Prerequisite `parent_id` to Dependent `child_id`. |
| Bulk Actions | `POST /api/kanban/tasks/bulk` | Nonempty IDs with Archive, Status, Assigned Profile, or priority. HTTP 200 can contain per-Card failures and is never treated as atomic success. |
| Dispatcher | `POST /api/kanban/dispatch` | `board`, `dry_run`, and `max` are query parameters; Board in JSON is ineffective. Hermex always uses maximum eight. |
| Create Board | `POST /api/kanban/boards` | Slug plus name/description/icon/color. Hermex does not automatically make the new Board active. |
| Edit/Archive Board | `PATCH /api/kanban/boards/{slug}`, `DELETE /api/kanban/boards/{slug}` | Slug is immutable. Archive uses DELETE without hard-delete query. Default Board cannot be archived. |
| Make Active Board | `POST /api/kanban/boards/{slug}/switch` | Confirm because it changes shared server state visible to other Hermes clients. |

Card assignment is scoped entirely to the Kanban contract. The assigned value is
transported only in the Kanban `assignee` field, and assignment choices come from the
Kanban config, Board snapshot, and assignee-history responses above. Creating,
editing, filtering, or bulk-assigning Cards must never call `/api/profile/switch`,
change the active chat Profile cookie, or source assignment state from that
client-wide chat-profile selection.

Hermex deliberately does not expose backend-only hard deletion, archived-Board
enumeration/restoration, the global `PATCH /api/kanban/config` grouping mutation, the
legacy Card patch alias, or unsupported task attachments.

## Hermes

A Hermes server's Kanban (#1043) is the host's bundled Kanban plugin, read and written
(#1044) by `HermesKanbanClient` over the server's shared `HermesConnection` (its sign-in,
cookie jar and connection headers), and kept live over the Board's Kanban socket
(`KanbanWebSocketEventClient`, #1045). Until #709 gives it a home, the Hermes inbox's + menu
offers it in DEBUG builds and Hermex Branch only.

Read at the pin (`ca678285`, 0.21.5; `plugins/kanban/dashboard/plugin_api.py`) and checked
against `scripts/local-hermes`. Every route is under `/api/plugins/kanban`, and every Card
route takes `?board=<slug>`; an unknown Board or Card is 404.

| Route | Shape (a route without a method is a GET) |
|---|---|
| `/config` | `{default_tenant, lane_by_profile, include_archived_by_default, render_markdown}`. No Columns and no `read_only`. |
| `/boards` | `{boards: [{slug, name, description, icon, color, archived, is_current, counts, total, default_workspace_kind, …}], current}`. |
| `/board?board=&tenant=&include_archived=` | `{columns: [{name, tasks}], tenants, assignees, latest_event_id, now}`. Columns are `triage, todo, scheduled, ready, running, blocked, review, done`, plus `archived` when included. No `changed`, no `read_only`, and no assignee or only-mine filter. |
| `/tasks/{id}` | `{task, comments, events, attachments, links {parents, children}, link_tasks, child_results, runs}`. |
| `/tasks/{id}/log?tail=` | `{task_id, path, exists, size_bytes, content, truncated}`; a Card that never ran is `exists: false`, not 404. |
| `/stats`, `/assignees` | `{by_status, by_assignee: {name: {status: n}}, …}` and `{assignees: [{name, on_disk, counts}]}`. |
| `/events?board=&since=&ticket=` (WebSocket) | `{events: [{id, task_id, run_id, kind, payload, created_at}], cursor}`, only when events after `since` exist, at most 200 a frame. No hello, no heartbeat, and client messages are ignored. A used, expired or missing ticket is HTTP 403 on the upgrade. |
| `POST /tasks` | `{title, body?, assignee, tenant?, priority?, workspace_kind?, parents?, triage, idempotency_key, max_runtime_seconds?, skills?}` → `{task, warning?}`. No `status`: Triage is `triage: true`, otherwise the host starts the Card in To Do while a parent is open and Ready otherwise. `assignee: ""` is a 400, so none is null. `warning` is a Ready, assigned Card with no dispatcher running. |
| `PATCH /tasks/{id}` | `{title, body, priority, assignee?, status?, block_reason?}` → `{task}`. No tenant field. `assignee: ""` unassigns, and any `assignee` on a running, claimed Card is 409, so it is sent only when it changed. Block, unblock, Done, Archive and moves are all `status`. |
| `POST /tasks/{id}/comments` | `{body}` → `{ok: true}`, without the comment. |
| `POST /links`, `DELETE /links?parent_id=&child_id=` | `{parent_id, child_id}` → `{ok, gated}`, and `{ok}` (200 `false` when there was no link). Neither echoes an id. A self-link, unknown id, running child or cycle is 400. |
| `POST /tasks/bulk` | `{ids, status? \| assignee? \| priority? \| archive}` → `{results: [{id, ok, error?}]}`, 200 with per-Card failures. |
| `POST /dispatch?board=&dry_run=&max=8` | The `DispatchResult` webui's keys match. A dry run starts no worker but does promote To Do Cards whose parents are done. |
| `POST /boards`, `PATCH /boards/{slug}`, `DELETE /boards/{slug}?delete=false`, `POST /boards/{slug}/switch` | `{slug, name, description, icon, color}` → `{board, current}`; `{board}`; `{result, current}`; `{current}`. Never `default_workdir` or `project_id`. The default Board can't be archived (400). |

How Hermex adapts it:

- **Absent plugin.** 404 on `/config` is a host without Kanban: `{"detail": "No such API
  endpoint: …"}` when the plugin never mounted, `{"detail": "Plugin not found"}` when it
  was disabled at runtime. Kanban shows as unavailable, not as an error.
- **Handshake.** The Board's own Columns stand in for `/config`'s, in the host's order, and
  the Board needs no `changed`. A Card Status outside those Columns still flags.
- **Writable.** Every reply is marked `read_only: false`: the host has no read-only mode.
- **No To Do.** The host promotes a To Do Card whose parents are done to Ready on its next
  dispatcher tick, so To Do never sticks. New Cards start in Triage or Ready, and Move, the
  Bulk Actions and Undo Archive offer Triage and Ready only; the host itself puts a Card in
  To Do while a prerequisite is open, and the Board shows it there. Scheduled and Review are
  never destinations, but a Card in either moves out: Ready from Scheduled unblocks it, and
  any move from Review reopens it. Undo Archive returns a Triage Card to Triage and any
  other to Ready, except Done, which offers no Undo: the host refuses Done from Archived.
- **Where a Card lands.** Block is offered only on Ready and Running Cards, the only ones the
  host blocks, and a repeat block can land the Card in Triage. Unblock (Ready from Blocked)
  lands in Ready, To Do or Review. A write succeeds wherever the reply puts the Card short of
  where it started (`KanbanBackend.accepts`), and the Card shows there.
- **Complete.** Offered only on a Card in Review: the host completes any other Card only
  with a result, which Hermex doesn't send, and refuses it with a 400. The Bulk Action to
  Done stays, for approving Review Cards, and shows any other Card as failed.
- **Editor.** Tenant is set on create and read-only after; an edit never sends it. The
  workspace kind starts at the Board's `default_workspace_kind` and is sent unless it is a
  Scratch nobody picked. An omitted kind is Scratch on a Board without a project, even one
  with a directory, and the project's worktree on a project Board. There is no workspace
  path: the host takes it from the Board's directory.
- **After a write.** No reply says what else changed, so every Card write reads the Board
  again (a gated or promoted dependent moves too); a comment reads the Card again. A 400 or
  409 `{detail}` shows the host's own words where the failure shows, and the Card stays
  where the host has it. A create `warning` shows as a dismissible notice on the Board.
- **Filters.** The Assigned Profile filter runs on the client; Only Mine is not offered,
  because the host's Kanban has no active chat Profile.
- **Host data never kept.** `workspace_path`, `stored_path`, a log's `path`, `db_path`,
  `default_workdir`, an archived Board's `new_path`, `worker_pid` and `claim_lock` (on Cards
  and on runs) are dropped from every reply before it is decoded, so no view or log can show them.
- **Errors.** A transport failure is offline, 502–504 and 520–530 are server unavailable,
  and a refused or replaced sign-in reads as signed out. The sign-out itself stays with
  `HermesConnection`, never `onAPIError`.
- **Live updates.** One socket per open Board, pinned to it, from the Board's
  `latest_event_id`. Every connect mints a fresh `POST /api/auth/ws-ticket` ticket through
  `HermesConnection` (never the gateway's) and sends the connection headers on the upgrade,
  to its own origin only. It offers no subprotocol: the host accepts without echoing one. A
  completed upgrade is live; a frame advances the cursor and triggers the same coalesced
  Board reload as webui's. Leaving the Board, the background and a server switch close it.
- **Keepalive.** The host sends nothing on a quiet Board, and a dashboard bound to loopback
  (how a tunneled one runs) sends no protocol pings, so Cloudflare would close the socket at
  about 100 s. The phone pings every 25 s; a ping with neither its pong nor a frame by the
  next one ends the socket.
- **Reconnect.** A 403 on the upgrade tries one fresh ticket first. Reconnects wait 1, 2, 5
  and 10 s, then 30 s each. From the third failure the Board shows **Live updates delayed**
  and polls while the socket keeps reconnecting: there is no events route, so polling reloads
  the Board every 30 s and keeps it while its `latest_event_id` has not moved. The socket
  opening stops the polling and clears the notice. Polling that started without a failing
  socket (a foreground check the host refused, or an offline Board) reopens the socket at
  its first successful poll.
- **Cursor regression.** The host sends only ids above `since`, so a recreated database
  would stay silent. A Board reload whose `latest_event_id` is below the cursor the request
  started with takes that lower cursor and reopens the socket.

## Native information architecture and interaction model

Kanban is a distinct `SessionListUtilityDestination` constructed with the active
server URL and centralized authentication-error handling. Browsing a Board is local
to Hermex and never changes the server's active Board. Profile grouping is also a
local presentation choice. Any persisted Board/filter/Status preference must be keyed
by server. The browsed Board slug is the one persisted preference (`KanbanBoardPreference`,
#259): it is restored on load only after the fresh Board list confirms it, and a stale
slug falls back silently to the server's current Board.

The interaction model is **Status Focus**:

- a horizontally scrollable Status selector with counts;
- one Status at a time as a vertical Card list;
- Board switching from a picker in the header's principal slot: it is capped to the
  width actually left between the back button and the trailing group, and truncates
  the Board name inside that cap, so the bar can never drop the slot. The trailing
  side is New Card, Dispatcher, and a More menu holding Select Cards and Card Filters
  (More becomes Cancel while selecting);
- explicit search, Profile/tenant/archive/only-mine filters, and clear-filter state;
- visible non-drag Move actions; drag may supplement but never replace them;
- Select Cards mode with named Bulk Actions and a persistent selection count;
- Card detail/editor navigation using native lists, forms, sheets, and toolbars;
- adaptive monochrome utility controls, reserving meaningful color for Status;
- Profile lanes available as a local grouping without mutating server configuration.

Card summaries preserve ID, priority, tenant, title, Markdown-aware body preview,
Assigned Profile/Unassigned, comment/dependency counts, age, and the verified WebUI
staleness thresholds: Running at 10 minutes/1 hour, Ready at 1 hour, and Blocked at
1 hour/24 hours. Age comes from the `{created_age_seconds, started_age_seconds}` dict
both servers send (webui as `age_seconds`, Hermes as `age`): a Running Card reads its
started age, every other Card its created age, and a plain number from an older bridge
stands for both. Running is visible but is never offered as a direct destination.

Card detail preserves Markdown description, metadata, comments, events,
Prerequisites/Dependents, Dispatch Runs, and explicitly requested worker-log content.
Operational values such as filesystem paths, claim identifiers, worker identifiers,
and raw payloads must not leak through generic errors, analytics, or logging.

## Mutation, concurrency, and recovery rules

Ordinary reversible Card mutations are optimistic, show an Updating state, and are
serialized per Card. Unrelated Cards may mutate concurrently. Board-wide operations
(Bulk Actions, Archive Board, Make Active Board, and Run Dispatcher) prevent
overlapping writes on the same Board. Server state is always authoritative.

SSE, polling, and refresh snapshots must not overwrite a pending optimistic mutation.
When a response contains sufficient authoritative state, apply it; otherwise refetch
the affected Card or Board. There is no revision token or conflict guarantee.

If a Card changed after its editor opened, preserve the draft and block ordinary Save.
Offer Reload Server Version (confirm before discarding the draft) or Review and
Overwrite. This is best-effort detection and must not be described as a guarantee.

Require confirmation for:

- Run Dispatcher, warning that it may start workers and consume API budget;
- Archive Board, warning that Hermex cannot restore it in-app;
- Archive Cards as a Bulk Action;
- creating a Ready, Unassigned Card;
- every transition out of Running, warning that claim/worker state may be cleared;
- Make Active Board, warning that the change is shared with other Hermes clients.

Do not require confirmation for ordinary edits, Preview Dispatch, ordinary Status
changes, or a single Archive Card. After a successful single-Card archive, offer
short-lived Undo to the immediately previous Status using the same reconciliation
rules. Archived Cards remain available through an explicit filter.

Reads may retry automatically. Writes and Run Dispatcher are never blindly retried.
After timeout, disconnect, or malformed mutation response, show Checking Result and
refetch canonical state. Report success if the intended result is present, offer Try
Again if absent, or report Outcome Uncertain and require another refresh if still
unknowable. Retrying Card creation reuses the original idempotency key.

Bulk Actions are non-atomic. Refetch every selected Card before reporting results,
keep successes committed, identify each Card needing attention, retain failed Cards
as selected, and enable Retry Failed only after reconciliation. Never retry the whole
original selection automatically.

## Live updates, offline behavior, and Dispatcher

SSE is primary while Kanban is visible. Coalesce event bursts before refetching
affected Board/Card state. A burst refetches only the Board (stats and assignee history
refresh on load, pull, a foreground that finds the Board changed, and mutations, or on
a burst only while they have not settled yet or the burst's refetch superseded a
refresh still reading them), and a burst
that lands mid-refetch queues one debounced follow-up refetch instead of cancelling the
one in flight. After repeated stream failures, use 30-second event polling
and show a subtle persistent **Live updates delayed** notice. Pull-to-refresh performs
a full reload and retries SSE. Suspend live refresh only in the background; `.inactive`
overlays (Control Center, Notification Center, the app switcher) keep the stream. On
foreground, fetch the Board with `since` set to the snapshot's cursor: a `changed:false`
answer keeps the Board, stats, and Board list and resumes SSE from the cursor, and a
changed Board also reconciles the Board list, stats, and assignee history. Upstream's
`latest_event_id` ignores filters, so send `since` only when the snapshot came from the
current Board and filters; otherwise fetch in full.

When connectivity drops, preserve the in-memory snapshot, mark it
**Offline—showing previously loaded data**, mark loaded detail stale, and disable all
mutations, shared-state controls, and Dispatcher actions. Kanban data is not persisted
for offline use. Reconcile fully before re-enabling writes after reconnection.

Preview Dispatch is advisory, timestamped, and may become stale. It is not required
before Run Dispatcher. Preview and Run are single-flight per Board. Run Dispatcher
uses maximum eight, is never automatically retried, and presents a persistent result
summary after refetching the Board. Integration and manual testing must never run
billable workers or mutate the maintainer's real Boards.

## Accessibility, localization, and error presentation

Every change owns its accessibility and localization. Support all shipped languages,
plural Card counts, Dynamic Type without fixed Card heights, VoiceOver summaries and
actions, 44-point practical hit targets, keyboard operation where applicable, Reduce
Motion, light/dark appearance, and meaningful focus retention after move, archive,
filtering, refresh, mutation failure, and editor dismissal. Movement, selection, and
every Bulk Action must work without drag.

Errors remain attached to the affected action or screen until resolved. Validation
errors stay with their fields. Missing entities trigger reconciliation with explicit
copy. Authentication uses the existing per-server login flow. Generic transport/server
errors preserve known data and offer contextual Retry. Normal UI never exposes raw
payloads, server filesystem paths, claim/worker identifiers, or operational logs via
generic error text.
