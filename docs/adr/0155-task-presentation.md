# 0155. Task list and schedule text

Area: tasks

## Use a separate localized frame for weekly cron schedules

`CronScheduleHumanizer` renders a single-weekday schedule as "Weekly on <day>" rather than reusing the interval's "Every %@" frame. "Every %@" has to read correctly for durations such as "15 minutes" in every language, and a weekday would force a different article or case in several of them.

Lives in: `HermesMobile/Features/Tasks/CronScheduleHumanizer.swift`

## Humanize only unambiguous day-of-month cron schedules

`CronScheduleHumanizer` describes a day-of-month schedule only when the day-of-week field is `*`. A day-of-month and a day-of-week together mean different things on different cron implementations, so a combined expression is left raw rather than risking a wrong description of when the job runs.

Lives in: `HermesMobile/Features/Tasks/CronScheduleHumanizer.swift`

## Pin calendar and time zone when formatting cron times

`CronScheduleHumanizer.timeText` formats the clock time with the same calendar and time zone the `DateComponents` were built in, so the rendered time is the one cron will actually fire at.

Lives in: `HermesMobile/Features/Tasks/CronScheduleHumanizer.swift`

## Require both enabled and state to call a Task live

`CronJob.isLive` means the server will fire the job again. `enabled` and `state` are the same fact surfaced twice, and a paused job can still carry `enabled: true` briefly, so `isLive` requires both `enabled != false` and `state != "paused"`.

Lives in: `HermesMobile/Features/Tasks/TaskAgenda.swift`

## Share pause/resume state and use a circled resume icon

`CronJob.shouldResume` and the related pause/resume control state are shared by Task Detail and its header card so the two buttons cannot drift apart again, as they had before. Resume is a circled triangle, never `play.fill`: beside "Run now" the same solid triangle twice would say the two buttons do the same thing.

Lives in: `HermesMobile/Features/Tasks/TaskAgenda.swift`

## Lay out Task configuration as a grid sized to its widest label

`TaskDetailView`'s configuration card holds everything the list row deliberately stopped showing, laid out as a grid so the label column takes the width of its widest label. A fixed column has to guess and guesses low: "Notifications" wrapped onto three lines against the 64pt the old rows used.

Lives in: `HermesMobile/Features/Tasks/TaskDetailView.swift`

## Match recent runs to jobs by id, then by name

`TasksViewModel.job(for:)` finds the loaded job a recent run belongs to, or `nil` when the feed names a job the list does not have. It matches on id first and falls back to the name, because `/api/crons` has shipped with `id` null before, and then the name is all there is.

Lives in: `HermesMobile/Features/Tasks/TasksViewModel.swift`
