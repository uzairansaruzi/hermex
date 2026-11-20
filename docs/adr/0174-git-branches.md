# 0174. Git branch switching

Area: workspace-git

## Run a branch checkout after the branch picker sheet closes

`ChatView.closeBranchPicker` stores the target in `pendingBranchCheckout` and dismisses `activeGitSheet`; the checkout runs from the sheet's `onDismiss` (`runPendingBranchCheckout`). It waits for the sheet to close because a dirty tree raises an alert from `ChatView`.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Guard an empty branch name inside the New Branch alert action

`GitBranchPickerView`'s New Branch alert checks for an empty name inside the Create action. Alert action buttons ignore `.disabled` at runtime, and the server answers an empty branch name with a 400.

Lives in: `HermesMobile/Features/Workspace/GitBranchPickerView.swift`

## Send checkout mode new when creating a local branch on webui

Creating a brand-new local branch must use the server's `"new"` mode. The `"local"` mode only switches to an existing branch and ignores `new_branch` entirely, so sending it for a create silently switches to `ref` instead (a no-op when already on it). Remote checkouts keep `"remote"`, which creates a tracking branch itself.

Lives in: `HermesMobile/Networking/APIClient+Git.swift`

## Switch to a remote branch only when the host lists it as the only one of its name

`HermesGitClient.checkout` switches to a listed branch with `git switch`, and a remote ref (`origin/name`) would fail, so a remote row goes out as `name`, which git makes a tracking branch of. The host can't name the remote, so a remote row is refused unless the host lists it, now, as the only branch called `name`: another remote's `name` would leave git to refuse or pick `checkout.defaultRemote`, and a local `name` would be switched to instead. A new branch (`newBranch`) is created from HEAD through the plugin (#1236), uncommitted changes and all, which is the usual reason to make one.

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`

## Block a Hermes branch switch on any uncommitted change

A branch switch (#1116) is a write, refused while the tree has any uncommitted change, untracked files included, rather than let `git switch` carry it across: there is no stash on Hermes (Decision, 2026-10-08). Nothing is sent, and the picker says why (`HermesGitRefusal.uncommittedSwitch`).

Lives in: `HermesMobile/Networking/Hermes/HermesGitClient.swift`, `HermesMobileTests/GitWorkspaceViewModelTests.swift`

## Refuse branch names the host would rewrite

The host rewrites a branch name with its sanitizer (`_sanitize_branch` at the pin) before `git switch`, so a name it would change could name another branch. `HermesREST.isBranchName` accepts only what the sanitizer leaves as it is: Python word characters (letters, numerals, `_`), `.`, `/` and `-`, no run of `-`, `/` or `.`, and none of those three at either end. It checks per scalar, not per Character, because the host strips a combining mark, so "cafe" + U+0301 would switch to "cafe". `gitSwitchBranch` and hermex-push 0.6.0's git writes (#1236: `fetch --prune`, a fast-forward-only `pull`, and `switch -c name` from HEAD as `gitCreateBranch`, each answering `{ok, message}` or 400 `{detail}`) check it first; the plugin also refuses such a name.

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`, `HermesMobile/Networking/Hermes/HermesGitClient.swift`
