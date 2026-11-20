# 0178. Hermes Git client

Area: workspace-git

## Guard Hermes Git writes in the client, because the host's routes guard nothing

`HermesGitClient` reads a Hermes chat's repository through the host's Git routes on the sign-in its Bot screens share (#1114) and maps it into webui's Git models, so the menu, Changes sheet, diffs and turn-changes card read it unchanged. Writes (#1115) go through the host's review routes, which guard nothing: a file-less stage or revert covers the whole tree, `file` is a git pathspec, a commit with nothing staged stages everything first, and a push on a detached HEAD does nothing. So every write names one exact file (`HermesREST.isGitFile`), reads the rows it acts on again, checks its guards here ahead of the request (`HermesGitRefusal`), and asks the owning chat first (`WriteOwner`); each successful write reads status again. Fetch, pull and New Branch (#1236) exist only in the host's hermex-push plugin and show only while it lists their routes (`supportsSync()`); This Branch (#1386) and a turn's range since the HEAD its send read (#1392) are read-only over the same review routes, and the branch's pull request (#1391) comes from the host's `gh` through ship-info. Neither the repository root nor git's own output (a refusal's `detail`, which can name host paths) reaches the screen or a log. Checked at the `HERMES_AGENT_TESTED_SHA` pin (ca678285) in `hermes_cli/web_git.py` and `web_routers/git.py`.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`

## Send each Git write's file as a literal pathspec

Each repository write (#1115) answers `{ok}`, or 400 `{detail}` with git's stderr. The host hands `file` to git as a pathspec, where `*` matches other files and `.` or no file means the whole tree. `HermesREST.gitWrite` sends `:(literal)file` and refuses a file that isn't a single repository-relative path (`isGitFile`). Stage always names a file, since without one the host runs `git add -A`.

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`

## Match a write's rows by exact, untrimmed path

`HermesGitClient.rows(for:in:)` returns the current rows for `files` by exact path, never trimmed. A path that isn't one file (`HermesREST.isGitFile`), which the host would read as the whole tree, is refused. So is a path the host lists twice: the host trims a tracked file's name, so ` a` and `a` can share one row.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`

## Refuse staging, discarding or committing a conflicted file

`HermesGitClient.stage` stages each file with something to stage, one request per file, and refuses a conflicted file (`HermesGitRefusal.conflictedStage`) because staging it would mark it resolved. webui refuses to discard or commit a conflicted file, so none of those requests is sent for one either.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Refuse unstaging a rename

`HermesGitClient.unstage` unstages each staged file with one request per file and refuses a rename (`HermesGitRefusal.renamedUnstage`). The host's row names only the rename's new path, so its old path's deletion would stay staged.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`

## Discard one file at a time and delete only when the confirmation said so

`HermesGitClient.discard` returns each file to HEAD one at a time. A staged file is unstaged first, so a file new in the index becomes untracked and goes too, since the host deletes an untracked file. Without `deleteUntracked` (a confirmation that didn't say so) a file that would be deleted is left alone. A conflicted file is refused, as webui refuses it, and so is a rename: the host's row names only its new path, so its old one couldn't be put back.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`

## Refuse a commit with nothing staged or with a conflict

`HermesGitClient.commit` commits what is staged, or only `files` (`commitSelected`), and never pushes in the same call. With nothing staged the host's commit route (`HermesREST.gitCommit`, `/api/git/review/commit`) runs `git add -A` first, so the client checks the staged count before sending and refuses an empty one; it also refuses while the repository has a conflict. A successful commit shows HEAD's short sha.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`, `HermesMobile/Networking/Hermes/HermesREST.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Refuse a push on a detached HEAD

`HermesGitClient.push` pushes the branch to its upstream, or to origin as its new upstream, naming the repository root. The host would skip a detached HEAD without a word, so one is refused (`HermesGitRefusal.detachedHead`) with webui's copy and never sent. The status is read again either way.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## List Hermes changes past the 200-file status cap from review/list

A Hermes host caps `status.files` at 200 but lists every change in `review/list`, so a change past the cap is still a row and the list isn't marked truncated. Such a row takes untracked and conflicted from its status letter. Whether a staged one also has worktree edits is unknown, so it opens its whole change against HEAD, never only the staged half.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`
