# 0156. Task run history

Area: tasks

## Advance the run-history cursor by page size, not rows returned

`CronRunHistoryResponse.total` counts every run the server holds, not the rows in a page. Upstream `GET /api/crons/history` slices `all_files[offset:offset + limit]` and then drops any entry whose `stat()` throws, so a page can return fewer rows than it consumed. Callers of `APIClient.cronHistory` advance `offset` by the `limit` they requested and stop at `total`; `TaskDetailViewModel` moves `historyOffset` by `historyPageSize` (50) on every page. Advancing by `runs.count` silently re-reads rows already loaded.

Lives in: `HermesMobile/Models/CronRunHistory.swift`, `HermesMobile/Networking/APIClient+Cron.swift`, `HermesMobile/Features/Tasks/TaskDetailViewModel.swift`

## Drop run-history pages from a superseded list

`TaskDetailViewModel.loadMoreRuns` drops a page when a refresh landed while it was in flight: the page describes a list that no longer exists, and splicing it onto the new one would leave the pages between them unreachable. It checks `historyOffset` as well as `historyGeneration`, because a reload that began before the request bumped the generation ahead of it, so matching generations alone do not prove the two describe the same list.

Lives in: `HermesMobile/Features/Tasks/TaskDetailViewModel.swift`

## Deduplicate run-history pages by filename

`TaskDetailViewModel.appendRuns` skips runs already on screen by filename, because the server's `total` can shift while a job is writing new output, which is enough to make two offset pages overlap.

Lives in: `HermesMobile/Features/Tasks/TaskDetailViewModel.swift`

## Read a Hermes Task's job before its runs

A Hermes host's job carries its running state and last outcome, and the host stamps `last_run_at` once the run's session has ended. `TaskDetailViewModel` reads the job (`reloadJob`) before the run history, so the run that outcome describes is among them (#1042). `latestRun`, which the header's "See full output" opens, is then the newest run that ended by that stamp; one that ended later is newer than the outcome. While the runs on screen were read before the job's outcome (a Run Now's, or a refresh whose runs read failed), `latestRun` is nil because its run is not listed yet.

Lives in: `HermesMobile/Features/Tasks/TaskDetailViewModel.swift`

## Claim a run outcome only where the server reports one

`TaskDetailViewModel.outcome(of:)` gives a verdict only to `latestRun`, because the job record reports only on its most recent finished run; a run still going is running. Every other webui row is an output file a finished run wrote, so it reads as completed. A Hermes host keeps no outcome per run, so its other rows claim none.

Lives in: `HermesMobile/Features/Tasks/TaskDetailViewModel.swift`

## Drop non-finite run timestamps before making a Date

`Date(timeIntervalSince1970:)` accepts NaN and infinity and then traps deep inside date formatting. `CronRunHistoryItem` decoding turns a non-finite `modified` mtime into no date, and `HermesCronClient`'s run-history decoding drops non-finite `started_at` and `ended_at` the same way, so the `isFinite` checks must stay.

Lives in: `HermesMobile/Models/CronRunHistory.swift`, `HermesMobile/Networking/Hermes/HermesCronClient.swift`
