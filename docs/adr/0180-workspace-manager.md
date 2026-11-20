# 0180. Workspace manager

Area: workspace-git

## Block workspace list edits while a mutation is in flight

`WorkspaceManagerView` applies `moveDisabled` and `deleteDisabled` to each row while `WorkspaceRegistryViewModel.isMutating`, blocking new drags and swipe-deletes. Actor reentrancy across the network await would otherwise let overlapping mutations race. The view model's generation guard is the second line of defense.

Lives in: `HermesMobile/Features/Workspace/WorkspaceManagerView.swift`

## Pass the confirmed workspace into confirmRemoval

The removal confirmation uses `presenting:`, which hands the staged workspace to the action at presentation time, and passes it into `WorkspaceRegistryViewModel.confirmRemoval(of:)`. The dismissal binding clears `pendingRemoval` before the confirm action's async task runs, so the target must not be re-read from the view model there.

Lives in: `HermesMobile/Features/Workspace/WorkspaceManagerView.swift`, `HermesMobile/Features/Workspace/WorkspaceRegistryViewModel.swift`

## Apply reorder offsets to the visible rows

`WorkspaceRegistryViewModel.moveWorkspaces` applies the move locally so the row lands where the user dropped it, then asks the server to persist the full order; on failure the list is refetched so local order never drifts from the server. The offsets are relative to `rows` (what the list renders), not `workspaces`: tolerant decoding can leave pathless entries that the UI filters out. So the move is applied to the visible rows and hidden entries are kept at the end, mirroring the server, which appends omitted entries.

Lives in: `HermesMobile/Features/Workspace/WorkspaceRegistryViewModel.swift`

## Treat a 2xx workspace mutation reply with ok false as a failure

The workspace mutation routes are undocumented and signal failure with a non-2xx status today, but the body explicitly carries `ok` and `error`. `WorkspaceRegistryViewModel.performMutation` honors a 2xx that reports `ok: false` as a failure instead of a success.

Lives in: `HermesMobile/Features/Workspace/WorkspaceRegistryViewModel.swift`
