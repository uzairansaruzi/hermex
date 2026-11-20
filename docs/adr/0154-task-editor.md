# 0154. Task editor

Area: tasks

## Leave a Task's model blank so the server inherits the Profile's

`CronJobEditorDraft.applyProfileSelection` applies a picked Profile (or `nil` for "Server default") by setting only `profile`, and deliberately leaves `model` and `provider` alone. Upstream's `_selected_profile_snapshot_updates` computes both from the Profile's environment only while at least one is blank, so prefilling the model would suppress the server's own snapshot and move a server decision into the app. `CronJobEditorSheet`'s footer states what upstream already does rather than reimplementing it.

Lives in: `HermesMobile/Models/Cron.swift`, `HermesMobile/Features/Tasks/CronJobEditorSheet.swift`, `HermesMobileTests/CronJobEditorConfigurationTests.swift`

## Pick Task Profiles from the list, never free text

`CronJobProfileRow` offers only the Profiles `/api/profiles` returns, replaced by an inline load failure and retry when that list will not load. Upstream answers 400 for an unknown profile name, so free text would have exactly one failure mode the user cannot predict. A locked row only names the Profile, since a Hermes host cannot move an existing Task to another Profile (#1040).

Lives in: `HermesMobile/Features/Tasks/CronJobConfigurationPickers.swift`

## Never move a Profile-scoped Task to another Profile

On a server that scopes Tasks by Profile (a Hermes host), `TaskDetailViewModel`'s update keeps the job's existing `profile` instead of the draft's, because the host cannot move a job between Profiles (#1040). The editor locks the Profile there too.

Lives in: `HermesMobile/Features/Tasks/TaskDetailViewModel.swift`

## Keep free-text entry in the Task skills picker

`CronJobSkillsPickerSheet` is multi-select: it stays open as rows are toggled and commits each change straight to the draft. Unlike the Profile picker it keeps a free-text entry, because upstream accepts cron `skills` unvalidated, and without it a failed `/api/skills` load would turn a field that used to accept anything into a read-only one.

Lives in: `HermesMobile/Features/Tasks/CronJobSkillsPicker.swift`

## Keep the Task editor's model picker off ModelFavoritesStore

`ModelPickerConfiguration.cronJob` edits a draft, so committing is instant and closes the sheet. Nothing in it reads or writes `ModelFavoritesStore`: no stars on the rows or the custom entry, no favorites context menu action, and no favorites-backed `Saved Custom` group. Starring a model while editing a scheduled task would silently change what the chat composer offers, and `Saved Custom` would list models the task was never configured with. `Current Custom` stays, so a task configured against a model the catalog has since dropped still shows which model that was.

Lives in: `HermesMobile/Features/Shared/ModelPickerConfiguration.swift`

## Keep server deliver targets as a plain let in the Task editor

`CronJobEditorSheet` stores `serverDeliveryOptions` as a plain `let`, not `@State`, so a re-init while the sheet is presented (the options finishing their async load) swaps in the fresh list, while `@State draft` keeps the user's edits. As `@State` it would freeze the stale initial list.

Lives in: `HermesMobile/Features/Tasks/CronJobEditorSheet.swift`
