---
name: contributor-pr
description: Triage and review contributor PRs on uzairansaruzi/hermex — private briefing with a verdict, then gated post/fix/merge.
disable-model-invocation: true
---

# Contributor PR

Maintainer workflow for pull requests from other contributors on uzairansaruzi/hermex.
`CONTRIBUTING.md` is the policy source of truth and `AGENTS.md` hard rules apply — cite them, never restate them.

Invoked with no argument → **Triage**. With a PR number or URL → **Review** that one PR.

## Triage

List open contributor PRs. Rank by reviewability: small, focused diffs with a linked issue first. Flag every PR that violates CONTRIBUTING.md's "What PRs we welcome" (large work with no prior issue, multi-change diffs, out-of-scope platforms) and draft a courteous close-with-comment for each flagged one.

Done when every open PR has either a rank or a flag, each with a one-line rationale. Post nothing.

## Review

1. **Pin.** Fetch the PR: diff, commits, checks, reviews, unresolved threads, linked issue, mergeability. Record the head and base SHAs — all evidence below binds to that head. Check the branch out in an isolated worktree; never disturb the main checkout.
   Done when the exact code under review and every existing piece of feedback are in hand.

2. **Understand.** Trace what the diff does — behavior, not paraphrased hunks: call sites, state, error paths, tests, deletions. Verify API-shape and `Codable` changes per AGENTS.md rules 1 and 3. Give each posted AGY finding an independent verdict: confirmed, or false positive with the reason (the repo is Swift 5 — discount strict-concurrency noise). If AGY hasn't posted yet, record it as a pending gate; don't wait for it.
   Done when every behavior change maps to the PR's stated intent and every inherited finding has a verdict.

3. **Validate.** A green CI Gate on the pinned head is full-suite test evidence — no local rerun unless CI is stale for that head or suspicious. For behavior or UI changes, build and launch a normally signed simulator build and exercise the changed flow yourself. Anything needing human perception, a physical device, or the live server goes on a short numbered plan for the human.
   Done when evidence passes for the pinned head, or every remaining check is on the human's numbered list.

4. **Brief.** Deliver in chat, written for a reader new to the codebase but familiar with Hermex's goal:
   - Verdict: `ready` | `changes needed` | `blocked` | `manual pending`.
   - Plain-English summary: what the user gets, how the change works, what could break.
   - Confirmed findings with evidence; pending gates.
   - Drafts: the public review comment (each actionable item = what happens, why it matters, what resolves it) and, when ready, a squash-commit message.
   Done when the human can decide the next action without opening GitHub.

5. **Act on explicit command only.** Each action is a separate instruction — a `ready` verdict authorizes nothing:
   - **post** — submit the approved review text, nothing more.
   - **fix** — push one small disclosed commit to the contributor branch (requires maintainer-edits allowed; preserve their intent), then redo step 3 on the new head.
   - **merge** — re-fetch first: if the head SHA moved, restart at step 1. Confirm gates are green, squash-merge with the approved message (toggle `enforce_admins` off, merge, toggle it back on), then report the resulting state of master.
   Done when the commanded action succeeded and the PR's resulting state is reported accurately.
