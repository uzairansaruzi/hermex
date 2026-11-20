# 0130. Hermes session actions and links

Area: sessions

## Detect Hermes branches by the `_branched_from` mark

A branch's own row names its parent (`parent_session_id`) and stores `{"_branched_from": <parent>}` as its `model_config`, which `session.branch` writes; that mark drives its "Forked from" row and Fork From Here (#1051). A reset continuation or a compression segment has a parent too but no such mark, so it is no branch. A session's own row holds its whole history as the host counts a branch (`_resume_lineage_ids`) only when it has no parent or is a branch, whose rows are a copy; any other parent, a legacy compression segment or a reset continuation, puts that parent's rows first, and the session's own transcript pages never show them.

Lives in: `HermesMobile/Networking/Hermes/HermesSessionActions.swift`

## Refuse row-based branches of sessions that continue another

Fork From Here, `/branch` and `/fork` (#1051) send `session.branch` once on the runtime and answer the new session's stored key. Through `rowID` the branch keeps the history up to that saved row, but the host counts from the first row of the session's whole lineage while this chat's pages hold only its own rows, so a session whose own row continues another (`HermesBranchParent.standsAlone`) is refused; otherwise every older page is read first and counted (`HermesBranchCount`). Without a row the branch copies the whole history, under `name` when given. It throws `NotSent`, `BranchRowGone`, `BranchContinuesEarlierSession`, and the host's refusal as `BotSettingFailure`. A canonical host (#1603) branches with a fenced `branch` edit that keeps the rows through the saved row's own id, so nothing is counted.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Duplicate Hermes sessions by export and untitled import

Duplicate on a Hermes row (#1051) makes an independent copy with every row the session's export holds, tool output, reasoning and timestamps included, which `session.branch_stored` would drop. The export (#1048) is imported under a new id with no parent, then titled. The import is all-or-nothing, skips an id the Profile already has, and fails the whole import on a title in use, so the copy goes in untitled and is titled after: "<title> (copy)", then "(copy 2)" and on while the host has the title. A copy the host won't title stays untitled.

Lives in: `HermesMobile/Networking/Hermes/HermesSessionActions.swift`

## Delete Hermes sessions through `session.delete`

Deletion goes through `session.delete`, never REST `DELETE` (#1048), so a runtime that holds the session blocks it instead of losing that work. The host refuses (4023) while any runtime in its process holds the session and keeps a runtime after the screen that attached it leaves, so this phone's own runtimes on it (`BotTransport.attachedRuntimes`, as `session.active_list` still lists them) are closed first when idle, and a busy one refuses the delete before anything is sent. A 4023 after that means another app has the session open, and nothing changed; the host can't say who else views a runtime this phone attached, so closing one ends it for them too. A canonical host (#1603) has no runtimes to close: one fenced `delete` edit removes it, and a session still replying refuses it (`session_busy`).

Lives in: `HermesMobile/Networking/Hermes/HermesSessionActions.swift`

## Detect cron runs by key or lineage root prefix

A scheduled task's run is stored as `cron_<job>_<time>`, and its prompt row shows as a `CronRunPromptCard` (#1413). A compressed run opened by its tip has an ordinary key under a `cron_` root, so `HermesChatTurnCoordinator` checks the lineage root too. The chat's `SessionSummary` is a placeholder that cannot say so.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Open archived Bot Chat rows through the bot route

An archived row that is a bot's Bot Chat (#1146) opens through the app's bot route, as a Sessions search hit does, so the Bots tab owns that chat's replaced notice, Update sign-in and read mark. `ArchivedSessionsViewModel` resolves the bot for such a row and nil for any other.

Lives in: `HermesMobile/Features/Settings/ArchivedSessionsViewModel.swift`

## Don't page archived sessions while a restore or delete is in flight

`ArchivedSessionsViewModel` reads the next page one at a time, and reads on past a page of room sessions alone, which shows no row (#1146). A restore or delete moves the host's later rows, so no page is read while one is out, and a page already out is dropped.

Lives in: `HermesMobile/Features/Settings/ArchivedSessionsViewModel.swift`

## Show no error for a stale archived page read, but do for a stale first read

`BotClient` throws `BotFailure.stale`, not `CancellationError`, when the task reading a page is cancelled, so `loadMore` drops `stale` silently, or a "load more" whose task ends shows "This action is no longer current" (#1782). Nothing is lost: `hasMore` still holds and the next "load more" reads the page. `loadHermes` drops a cancelled task by `Task.isCancelled` instead and still shows `stale` with the task live, because then the screen's client has gone dead: it closes that client, so the next load connects a new one, and the error stops an empty list looking like no archived sessions.

Lives in: `HermesMobile/Features/Settings/ArchivedSessionsViewModel.swift`

## Match session-link lookups by exact id

`HermesSessionLookup` finds the stored session a Hermes session link names (#1176) on the server's saved connection, and never guesses. A named Profile is one `GET /api/sessions/{id}` read; `""` is the Profile `profiles.list` marks `is_default`; with none, every Profile is read at once and only a key exactly one of them has opens. The host answers an unknown key with the one session it prefixes, so a row whose `id` isn't the link's key is no match, and `HermesSessionLookupTests` holds that. Any failed read fails the lookup: a Profile that couldn't be read leaves the link unproven.

Lives in: `HermesMobile/Features/Hermes/HermesSessionLookup.swift`, `HermesMobileTests/HermesSessionLookupTests.swift`

## Open a subagent link's delegator only when proven

A subagent's push names the child, but the user follows the session that delegated to it (#1177), in the child's Profile (`opensParent`). `delegate_task` stamps `_delegate_from` on the child and every compression segment inherits it, so a marked row names its delegator outright. A host without the mark goes one hop up, unless that parent ended in compression: it could be the subagent's own earlier segment or a delegator that compressed, so the boundary is unproven and nothing opens. A child naming no parent opens itself.

Lives in: `HermesMobile/Features/Hermes/HermesSessionLookup.swift`
