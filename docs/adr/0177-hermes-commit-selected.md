# 0177. Hermes Commit Selected

Area: workspace-git

## Run Commit Selected as unstage, stage, commit, then restage

The Hermes host commits the whole index, so `HermesGitClient.commitSelected` is a sequence: unstage everything, stage the selection, check something is staged, commit, then stage again the files that were staged before. Because `git add` puts back a whole file only, the sequence is refused before it starts while a staged file also has worktree edits, or may have (a row past the status cap), or is a rename, whose old path the host's row doesn't name; while a staged file's path isn't one file to stage again (`rows(for:in:)`); and before the first commit. A failure once any write went out, whose lost reply may hide that it ran, stages those files again and throws; a failure to stage them again after the commit is reported with it (`stagingNotRestored`).

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Check something is staged after staging the selection

Inside `HermesGitClient.commitSelected`, the commit is refused (`HermesGitRefusal.nothingStaged`) when nothing is staged once the selection has been staged. With nothing staged the host would stage everything instead.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`

## Refuse Commit Selected while a staged file outside the selection has worktree edits

`git add` can put back only a whole file. So Commit Selected is refused before it changes the index while a staged file outside the selection also has worktree edits, or may have them (past the status cap): restoring it would stage those edits too (`HermesGitRefusal.partlyStagedSelection`).

Lives in: `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Refuse Commit Selected before the first commit

Before the first commit the host can't unstage everything, so Commit Selected is refused up front (`HermesGitRefusal.firstCommitSelected`) and the index stays as it was.

Lives in: `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Refuse Commit Selected when a staged path names two files

Commit Selected clears the whole index and promises to put back every staged file, so each one it remembers must name one file. The host trims a tracked file's name, so ` a.txt` and `a.txt` both list as `a.txt`; staging that path again couldn't reach both, and the sequence is refused before it changes anything.

Lives in: `HermesMobileTests/GitWorkspaceViewModelTests.swift`
