# 0064. Kanban Card decoding

Area: kanban

## Read a Card's age from the host's age dict by Status

A Hermes host sends `age` as `{created_age_seconds, started_age_seconds, …}`, and webui forwards the same dict as `age_seconds`. A Running Card reads the started age, every other Status the created age.

Lives in: `HermesMobile/Models/Kanban.swift`, `HermesMobileTests/KanbanFeatureStateTests.swift`

## Compute a retried Card's run age from host times only

The host's started age counts from the Card's first start, so `KanbanCardAge.sinceCurrentRun(firstStart:currentRunStart:)` shifts it so a retried Card's run reads from the start of its current run. Only the host's own times go into it, because the phone's clock can differ. Without both times, as from an older host, the age stays as sent.

Lives in: `HermesMobile/Models/Kanban.swift`

## Spell KanbanDetailEvent's runID coding key as runId

The decoder runs `.convertFromSnakeCase`, which turns the server's `run_id` into "runId". `runID` without a raw value spells the key "runID", so it never matched and `runID` was always nil; `KanbanDetailEvent.CodingKeys` gives it the raw value "runId".

Lives in: `HermesMobile/Models/Kanban.swift`
