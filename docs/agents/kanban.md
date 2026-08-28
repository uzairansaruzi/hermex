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

## Native information architecture and interaction model

Kanban is a distinct `SessionListUtilityDestination` constructed with the active
server URL and centralized authentication-error handling. Browsing a Board is local
to Hermex and never changes the server's active Board. Profile grouping is also a
local presentation choice. Any persisted Board/filter/Status preference must be keyed
by server.

The interaction model is **Status Focus**:

- a horizontally scrollable Status selector with counts;
- one Status at a time as a vertical Card list;
- Board switching in the header;
- explicit search, Profile/tenant/archive/only-mine filters, and clear-filter state;
- visible non-drag Move actions; drag may supplement but never replace them;
- Select Cards mode with named Bulk Actions and a persistent selection count;
- Card detail/editor navigation using native lists, forms, sheets, and toolbars;
- adaptive monochrome utility controls, reserving meaningful color for Status;
- Profile lanes available as a local grouping without mutating server configuration.

Card summaries preserve ID, priority, tenant, title, Markdown-aware body preview,
Assigned Profile/Unassigned, comment/dependency counts, age, and the verified WebUI
staleness thresholds: Running at 10 minutes/1 hour, Ready at 1 hour, and Blocked at
1 hour/24 hours. Running is visible but is never offered as a direct destination.

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
affected Board/Card state. After repeated stream failures, use 30-second event polling
and show a subtle persistent **Live updates delayed** notice. Pull-to-refresh performs
a full reload and retries SSE. Suspend live refresh in the background and reconcile
immediately on foreground.

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
