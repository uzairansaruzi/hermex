# 0109. Lists, pickers, and status labels

Area: performance

## Emit each model as its own List row

`ModelPickerSheet.modelGroupDisclosure` builds one provider group. Inside a List, each view in the disclosure content becomes its own row, so every model is a separate, reusable List row and only the rows on screen get built. A single container row would build all of them at once, which is hundreds after "Show all models" (400 in `ModelPickerSheetTests`, #692).

Lives in: `HermesMobile/Features/Shared/ModelPickerSheet.swift`, `HermesMobileTests/ModelPickerSheetTests.swift`

## Store a model group's merged model list

`ModelCatalogGroup.allModels` holds every model in the group, the visible `models` plus the overflow tail the server exposes as `extra_models`, de-duplicated by `id` to keep `ForEach` identity unique. It is stored rather than computed because the picker reads it many times per body pass, and OpenRouter or Nous tails run to hundreds of models.

Lives in: `HermesMobile/Models/ServerCatalog.swift`

## Keep searchable lists still when search closes

`PluginsView` and `ConnectedAppsView` keep the list still when search closes and let scrolling reach what's under the keyboard. Otherwise closing search slides the bar back and resizes the list for the keyboard at once, which drops frames on a phone.

Lives in: `HermesMobile/Features/Settings/PluginsView.swift`, `HermesMobile/Features/Settings/ConnectedAppsView.swift`

## Keep CronJob.id stable instead of falling back to a UUID

`CronJob.id` is stable across refreshes and never a fresh `UUID`. `id` is computed, so a UUID fallback would hand SwiftUI a different identity on every read and rebuild every row of the Tasks list on every poll.

Lives in: `HermesMobile/Models/Cron.swift`

## Compute the Task countdown on render, not with a timer

`CronScheduleHumanizer.countdown` gives the wait until a date as one compact figure ("in 6m", "in 12h 21m", "in 3d 4h") that Task Detail leads with, and Foundation owns its plural rules so it is correct in every language without a catalog entry per interval. `TaskDetailHeaderCard` shows it big with the absolute time under it. Both are computed on render rather than ticked by a timer: a self-updating label repaints its whole card every second for a figure nobody watches count down, and Refresh already brings it current.

Lives in: `HermesMobile/Features/Tasks/CronScheduleHumanizer.swift`, `HermesMobile/Features/Tasks/TaskDetailHeaderCard.swift`

## Read delayed status in its own view

`DelayedStatusView` draws a driver's shown status, and nothing while there is none. It reads `shown` itself rather than in the parent, so a delayed show or hide never re-evaluates the parent's body.

Lives in: `HermesMobile/Features/Shared/DelayedStatus.swift`
