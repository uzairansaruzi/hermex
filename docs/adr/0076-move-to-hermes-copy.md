# 0076. Move to Hermes scan and copy

Area: move-to-hermes

## Require an exact id match on Hermes session row reads

When a host lacks an id it resolves the read to a unique prefix match, so a row answered under another id is treated as missing. `MoveToHermesScan.has` answers no for a 404 or a row under another id and nil for a failure, and `MoveToHermesReconcile`'s snapshot read takes only the exact row `id` in the Profile, as the scan does.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesScan.swift`, `HermesMobile/Features/MoveToHermes/MoveToHermesReconcile.swift`

## Collect both tip and lineage root ids from a listing

`HermesScanPage`, the page `BotTransport.sessionScanPage` reads (#1213), decodes each row's `id` and `_lineage_root_id` and the host's `total`. A compressed chain is listed by its tip with `_lineage_root_id`, and both ids exist in the Profile. A reply without `sessions` is a failed read.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesScan.swift`

## Page Hermes listings until the host's total

`MoveToHermesScan.listedIDs` returns every id each Profile lists, or nil for a Profile whose listing failed so its ids are read one by one instead. Pages run until the host-reported `total`, never until a short page, because every page back-fills the Profile's pinned rows.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesScan.swift`

## Read an id no listing showed in every Profile

A Hermes listing leaves hidden rows out, so `MoveToHermesScan.locate` reads an id that no listing showed in every Profile rather than assuming it is absent.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesScan.swift`

## Treat a webui listing that ignored all_profiles as partial

`MoveToHermesScan.Result.onlyProfile` is set when the webui listed only this Profile because it ignored `all_profiles`. Every other webui Profile then went unscanned, which is not the same as empty.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesScan.swift`

## Switch webui Profiles in a private cookie jar, only after confirmation

`WebuiSessionTransfer` (#1213) exports chats one source Profile at a time, converts each to the host's import shape, and imports them in batches under the host's limits. Each Profile's exports need the webui's Profile cookie, which only `POST /api/profile/switch` issues, so the copy switches in a cookie jar of its own (`APIClient.moveCopyClient`) that no screen sees or changes. On the server a switch clears two caches and restarts that Profile's gateway watcher, so the copy runs only after the user confirms Move. A switch reply naming an error or another Profile is a failure, since exporting after it would read under the wrong cookie.

Lives in: `HermesMobile/Features/MoveToHermes/WebuiSessionTransfer.swift`

## Recheck, journal and send each import batch once

One run is one attempt: every batch is rechecked by exact id in every Hermes Profile, then `willDispatch` records it, then it is sent once. A 400 or 413 means the host wrote nothing, so the run drops the refused chats or splits the batch and sends the rest; any other 4xx refuses the batch. A rate limit (429), a write-fence 409, a timeout or a lost reply leaves it `.uncertain`, and the runner (#1216) replays those by running them again. `MoveToHermesProgress.copyItems` sends a chat sent before to the same Profile under the same id, so a retry resends imports only and never duplicates a chat, because the host skips an id it already has.

Lives in: `HermesMobile/Features/MoveToHermes/WebuiSessionTransfer.swift`, `HermesMobile/Features/MoveToHermes/MoveToHermesRunner.swift`

## Map webui exports to import rows as the webui's state_sync does

`WebuiSessionTransfer.importRow` converts one `GET /api/session/export?format=json` reply (redacted by the webui), or returns nil when it is not the chat `id` with its messages. It keeps the id and follows the webui's own state.db mapping (`api/state_sync.py`): the model and the token, cache and estimated-cost totals, dated by `created_at` so Insights counts them on their own days. It sends no title (titles are reconciled after, #1214), folder, pin or parent. Messages keep their role, content as exported (image parts included), tool calls and timestamps, and only user, assistant and tool messages are kept; a 0.21.5 host stored all of it, read back from one disposable import on 2026-10-11.

Lives in: `HermesMobile/Features/MoveToHermes/WebuiSessionTransfer.swift`
