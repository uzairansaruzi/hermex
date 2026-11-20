# 0037. Hermes side tasks and delegated workers

Area: chat-streaming

## Buffer side-task completions that arrive before their ask's reply

The host can finish a `/btw` or `/background` task (`btw.complete`, `background.complete`)
before the chat has read the ask's reply that names the task id. `HermesChatSideTasks` keeps
such completions in `unclaimed`, keyed by task id, only while an ask or start is in flight,
so they are not dropped as unknown ids.

Lives in: `HermesMobile/Features/Chat/HermesChatSideTasks.swift`

## Require a start timestamp before interrupting a worker

Subagent ids are treated as potentially reusable across snapshots, even though current
hosts generate a fresh id per spawn. `HermesDelegatedWorker.canInterrupt` therefore
requires the generation-bearing `startedAt` timestamp as part of the identity a
destructive control acts on.

Lives in: `HermesMobile/Features/Chat/HermesDelegatedWork.swift`

## Re-list workers before interrupting one

`HermesDelegatedWork.interrupt` re-lists the roster immediately before the destructive
call. That rejects a worker that completed during confirmation and an id that has since
been reused; the gateway then resolves the authorized live record at dispatch time.

Lives in: `HermesMobile/Features/Chat/HermesDelegatedWork.swift`
