# 0175. Git commit, push and discard

Area: workspace-git

## Refuse quick commit when the git status is truncated

The webui server caps git status at 500 changed files (`STATUS_FILE_LIMIT`) and flags the list as `truncated`, so the client only knows the first 500. `filesToStage` would then cover only those, and a one-tap commit would silently leave files 501+ uncommitted while reporting success. `GitWorkspaceAvailabilityViewModel.quickCommit` returns `GitQuickCommitOutcome.tooManyChanges` instead, with no stage, commit or push, for both the Commit and Commit & Push rows. A larger commit needs a server-side "stage all" that doesn't exist yet.

Lives in: `HermesMobile/Features/Workspace/GitWorkspaceViewModel.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Report a push failure apart from a commit that landed

Once a commit has landed on the server, a failed push must not be reported as a total failure. `GitWorkspaceAvailabilityViewModel.quickCommit` keeps the commit's success path (refresh, SHA toast) and carries the push error separately in `GitQuickCommitResult.pushFailureMessage`. `GitCommitViewModel.runCommit` likewise still runs the success cleanup (clears the message and selection, bumps `committedRevision` so the caller refreshes the toolbar) and shows the push error in the sheet banner.

Lives in: `HermesMobile/Features/Workspace/GitWorkspaceViewModel.swift`

## Show a failed push on the clean-tree empty state

`GitCommitView`'s empty state normally says "No Changes". A commit and push can leave the tree clean while the push fails, and the commit bar, the error's usual home, is gone, so the empty state surfaces `actionErrorMessage` instead of swallowing it.

Lives in: `HermesMobile/Features/Workspace/GitCommitView.swift`

## Unstage staged targets before a webui discard

webui's discard only runs `git restore --worktree`, which leaves the index untouched, so a staged change would survive it. `WebUIGitClient.discard` and the commit sheet unstage staged targets first and then discard, in that order. A staged-new file then becomes untracked and goes only with `deleteUntracked`, which the confirmation accounts for.

Lives in: `HermesMobile/Networking/APIClient+Git.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Send deleteUntracked whenever a discard can delete a file

`GitCommitView.discardIncludesUntracked` is true when discarding the targets can delete a file from disk: any new file, untracked or a staged add or rename (which discard turns into an untracked file to delete once it is unstaged). It drives the stronger "deletes files" confirmation copy and the `deleteUntracked` flag, so the server never rejects the discard.

Lives in: `HermesMobile/Features/Workspace/GitCommitView.swift`

## Give commit-message generation a two-minute timeout

`APIClient.gitCommitMessage` generates a commit message from the staged diff, and is not gated by the destructive flag. Generation runs an LLM server-side, which can take far longer than the 60 s session default, especially over a cold tunnel, so it uses `commitMessageTimeout` of 120 s.

Lives in: `HermesMobile/Networking/APIClient+Git.swift`
