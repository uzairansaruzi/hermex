# 0171. Git in the chat

Area: workspace-git

## Refresh Git state after every response, even without a repository

The agent may have edited files during a turn, so once the response finishes `ChatView` refreshes git state (status, ahead/behind, branch) through `gitAvailabilityViewModel.refreshAfterExternalMutation()`. That keeps the toolbar badge, Changes row and commit surfaces in sync without re-entering the chat. It runs unconditionally: the refresh re-checks `/api/git-info` first, so it also detects a repository the agent just created mid-turn (`git init` or clone). On Hermes, a folder outside a repository is likewise asked again on the next read, so a repository the agent creates shows at turn end.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Derive a turn's changed files from its tool calls, not git status

The in-chat "N files changed" recap (#316, Workspace git Slice D) takes its file list from an assistant turn's tool-call metadata: which file-mutating tools ran, and on which paths. A `git/status` snapshot can't isolate a single turn's edits from accumulated uncommitted or external changes. Each path is then joined to the rows of one range for the `+N −M` counts and status chip: `git/status` on webui and for a Hermes turn without a base, or a Hermes turn's range since the HEAD its send read (#1392), which keeps work the agent committed. It is read-only over data the chat already has, and mirrors webui's aggregation in `static/workspace.js` (mutation tool-name set, path-arg keys, path normalization, ignore filter).

Lives in: `HermesMobile/Models/TurnFileChangeSummary.swift`

## Map a chat folder spelled through a symlink into the repository root

A Hermes chat shows the whole repository holding its folder: the root is resolved once from `GET /api/fs/git-root`, and every read names it, since the host's paths are relative to the root. The host resolves symlinks in the root it returns (`/private/tmp/app` on a Mac) but keeps the folder as configured (`/tmp/app/Sources`). `HermesGitClient.rowPath(forToolPath:)` must still map the folder into the root, so the turn's `App.swift` is `Sources/App.swift`, not the root's `App.swift`.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Render the pull request number as a String

`GitActionsMenuButton` interpolates `String(pullRequest.number)` into its localized label, so the number never takes a grouping separator ("#1,462").

Lives in: `HermesMobile/Features/Workspace/GitActionsMenuButton.swift`
