---
name: delete-comment
description: Classify the Swift comments still in the baseline, record what they were holding, and delete them.
disable-model-invocation: true
---

# Delete comments

Swift source in this repo carries no comments. `ci/check_comments.py` enforces it with a
ratchet: `ci/comment_baseline.txt` lists each file that still has comments and how many
lines, and that number only goes down. This skill walks it down.

Scope is the paths given after `/delete-comment`, otherwise every file in the baseline.

## Steps

1. **List.** `python3 ci/check_comments.py --list <paths>` prints each comment block as a
   JSON line (`file`, `first`, `last`, `text`). Done when you hold the full list for the
   scope.
2. **Classify** every block as exactly one category below, reading the code around it.
   Done when every listed block has a category.
3. **Record** what deletion would lose. Each Decision Record goes into `docs/adr/`
   (format in `docs/adr/README.md`): extend the ADR that already holds that decision,
   otherwise add the next number. Each Excuse becomes one plain line for the maintainer:
   the symbol, the shortcut it takes, the proper fix. Done when every Decision Record's
   file is listed under an ADR section's `Lives in` and every Excuse has its line.
4. **Delete.** `python3 ci/check_comments.py --strip <files>` removes every comment in
   those files, so strip only files whose blocks are all classified and recorded, and
   leave out a file that holds a Keep. Then
   `python3 ci/check_comments.py --update`. Done when `python3 ci/check_comments.py`
   passes and `git diff` on Swift files shows comment lines removed and nothing else.
5. **Report** the count per category, the lines shed, and the Excuse list. The
   maintainer picks which Excuses become issues (`docs/agents/issue-tracker.md` § Bulk
   Findings); file those with the `improve` label.

For more than a few hundred blocks, split the list into shards of about 340 blocks and
give each to a read-only classifier that writes verdicts to a file outside the worktree.
Write the ADRs and run `--strip` yourself, so no two agents edit the same file.

## Categories

**Tautology.** Restates what the code says or does: a summary of the function or type
below it, a parameter description, a `// MARK:`, a file header, a test scenario in words,
a step label. Product-language summaries count when the names and body show the same
thing. This is the default.

**Stale.** A claim the code contradicts, or a name that no longer exists. `grep` names
the surrounding code does not show. Stale wins over Decision Record.

**Excuse.** Cover for an implementation this repo should fix: `TODO`, `FIXME`, "for
now", "until X lands"; an admission the behavior is wrong, approximate, or racy; a
justification for `@unchecked Sendable`, `nonisolated(unsafe)`, a force unwrap or cast
where a safe design exists; a fixed delay or retry papering over a race; two places
"kept in sync by hand"; a shim the comment says should go.

**Decision Record.** All three hold: it gives a reason the code cannot show (a server
contract quirk, an iOS or SwiftUI behavior, a past bug, a performance, privacy, or
security rule, an ordering dependency); an engineer reading only the code could
plausibly simplify it and bring back a user-visible bug; and this repo cannot fix the
cause (that would be an Excuse). A comment that says what happens and cites an issue
number is a Tautology. About one block in ten clears this bar.

**Keep.** A third-party license or attribution notice no file in
`HermesMobile/Resources/ThirdPartyNotices/` covers. It stays in the baseline until the
notice moves there; say so in the report.

A `// test-wait: <reason>` annotation is read by `ci/check_test_waits.py`. The checker
neither lists nor strips it.
