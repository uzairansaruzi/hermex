# 0133. Session list data

Area: sessions

## Send every Hermes session list filter explicitly

`HermesREST.sessionList` sends every filter value instead of relying on the host's defaults. Those defaults order by creation, list empty sessions, and keep cron, Kanban, one-shot, subagent and tool runs.

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`

## Count unreadable rows when paging Hermes sessions

A `HermesSessionPage` is one `GET /api/sessions` page (#1046). Ordinary paging ignores `total`; the source-scoped cron list uses it only for its count badge. A row that can't be read is skipped yet still counts in `count`, so it never ends paging early, and a page without its `sessions` list is a failed read, not an empty Profile.

Lives in: `HermesMobile/Networking/Hermes/HermesSessionPage.swift`

## Drop non-finite Hermes session timestamps

Session row timestamps that decode as NaN or infinity are dropped. `Date(timeIntervalSince1970:)` accepts them and traps later, in formatting.

Lives in: `HermesMobile/Networking/Hermes/HermesSessionPage.swift`

## Page Hermes session lists around pinned back-fill

A Hermes Profile's list accumulates the pages read so far (#1046). Every page repeats each pinned row its own rows missed, archived ones included, and rows shift between pages as sessions move, so a row is kept once, by identity, and an archived one never; the Archived screen's pages (#1048) keep only archived rows, since their back-fill brings unarchived pinned ones, and leave out a room's session (#1146). A page shorter than a full page ends the list. Back-filled pinned rows can't be told from the page's own, so a page at least that long reads on unless it brought no new row, which also ends a list whose pinned rows alone would fill every page.

Lives in: `HermesMobile/Networking/Hermes/HermesSessionPage.swift`

## Hold back merged rows past the slowest Profile's frontier

The Sessions list pages by Profile (#709): one Profile's, or every Profile's for All Profiles. The host lists one Profile at a time, so a merged list holds back each row older than the oldest row read by any Profile that has more pages. That Profile's next page could still hold a newer row, and showing the older row now would let the page land above it.

Lives in: `HermesMobile/Networking/Hermes/HermesSessionPage.swift`

## Read Hermes row state from runtime status, not `is_active`

A Hermes list's row states come from one `session.active_list` reply (#1046), by the stored session each runtime runs (`session_key`). `waiting` (an open approval, question or other request) reads as Input, since the item can't say which, until the list's `approval.pending` read finds an approval (#1679); `starting`, `working` and `streaming` read as Working; idle, `resuming` and unknown states as nothing. Of several runtimes on one session, Input wins. The list's `is_active` is a 300-second guess and is never read.

Lives in: `HermesMobile/Networking/Hermes/HermesSessionPage.swift`

## Decode session rows lossily, one row at a time

`SessionSummary` decodes field by field, like `SessionDetail` and `ProjectSummary`. The synthesized `Decodable` it replaced failed the whole value on one mistyped field, and `SessionsResponse` decoded the array as a unit, so one malformed row emptied the entire session list and pull-to-refresh could not recover it. The rows come from three sources (sidecar JSON, the state.db overlay, `get_cli_sessions()`), and upstream coerces these fields with `_numeric_count` / `_safe_first`, conceding the inputs are not uniform. The array decodes a row at a time, so an unreadable row costs only that row; it returns nil only when the key is absent or not an array.

Lives in: `HermesMobile/Models/Session.swift`

## Classify subagent rows only by explicit source marker

`SessionSummary.isDelegatedSubagentSession` reads only an explicit `subagent` source marker. Parent linkage is shared by ordinary forks and compression continuations, so it must never classify a row as a subagent on its own.

Lives in: `HermesMobile/Models/Session.swift`
