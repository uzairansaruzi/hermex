---
name: hermes-issue-pr-workflow
description: Runs the Hermes Mobile issue-to-PR development workflow in staged mode (human gate per stage) or express mode (autonomous from approved plan to review-addressed PR). Use when working in the hermex repo from a GitHub issue — starting an issue, addressing bot reviews on its PR, or post-merge cleanup.
---

# Hermes Issue PR Workflow

Use this in the hermex repo root. Source of truth: `CURRENT.md`, `docs/agents/issue-tracker.md`, and the GitHub issue/PR — plus the repo rules already auto-loaded from `CLAUDE.md` (don't re-read `CLAUDE.md`/`AGENTS.md`; it's already in context). If repo state is not ready, stop and report the blocker.

## Modes

- **Express (default for `ready-for-agent`):** one human gate after the plan, then autonomous through implement → PR → bot reviews → review fixes → final handoff. Use unless the issue is large/risky or labeled `needs-manual-validation`.
- **Staged:** every stage is human-gated. Use for `needs-manual-validation` issues, large/risky changes, human-scoped work, or when the user asks.

```text
Use hermes-issue-pr-workflow. Express issue #13.
Use hermes-issue-pr-workflow. Start issue #13.   (staged)
```

Both modes begin with Stage 1 and do not edit code until the user approves the plan.

## Shared procedures

**Green bar.** Validate with `git diff --check` + build/tests via XcodeBuildMCP (raw `xcodebuild`/`xcrun simctl` fallback). Never proceed on red; never hide failed validation. The full unit suite must pass on the final head commit before any PR is reported merge-ready (both modes).

**In scope.** Implement only the approved scope — no unrelated redesigns. (`CLAUDE.md`'s hard rules — no new dependencies, no invented API, tolerant decoding, no broken builds — already apply; don't restate them.)

**Open the PR.** Push the feature branch, then open a PR into `master` with `Fixes #<issue>`, summary, validation, and owner manual checks. (Mode decides draft vs. ready for review.)

**Wait for reviews.** Marking a PR ready for review — and any later push to it — auto-triggers the bot review(s). To force one by hand, post `/hermes review` as its own standalone comment.

```bash
.agents/skills/hermes-issue-pr-workflow/scripts/wait-for-reviews.sh <pr-number>
```

The script blocks only on the *required* review (Antigravity) and prints which landed. Exit 0: proceed. Exit 2: timeout — report which review is missing and continue with whatever landed, noting the gap. Other active reviewers (current roster in memory) also post on ready/push and must be triaged too — let them land before running **Review triage**.

**Review triage.** Fetch every review body, inline review thread, and PR comment from each reviewer (more than one bot may review). Triage adversarially — you are not defending this code: for each finding, first try to prove it correct against repo/spec/code and state that evidence before classifying it. Classify each as **Valid**, **Probably valid**, **Needs human decision**, or **False positive**. Resolution: implement Valid + Probably-valid, defer Needs-human-decision to the final report, skip False positives with stated evidence.

**Triage coverage.** Advisory pre-merge check that the *final* review round was actually triaged (review rounds landing right before merge historically went undispositioned):

```bash
.agents/skills/hermes-issue-pr-workflow/scripts/check-triage-coverage.sh <pr-number>
```

Exit 0: covered (triage newer than the last round, or the last round had no findings). Exit 3: warning — the last round has undispositioned findings (triage it) or failed outright (re-trigger `/hermes review full`). Never report a PR merge-ready while this warns.

**Refresh follow-ups.** Re-derive the Manual/Owner Follow-Up list from `gh pr list --state open` / `gh issue list` — keep only verifiably open items; never copy `CURRENT.md`'s previous list forward (it goes stale).

## Express Mode

After the user approves the Stage 1 plan, run E2–E5 without further gates. Pushing the feature branch, opening the PR, marking it ready for review, and pushing review-fix commits are pre-authorized. Merging and pushing `master` are never authorized.

### E1 - Plan Gate

Run Stage 1, then state: "Express mode: after approval I will implement, publish the PR, address bot reviews, and report back for your manual test + merge." Stop and wait for approval.

### E2 - Implement and Publish

1. Follow **In scope**.
2. Reach the **green bar**; iterate until green.
3. Update `CURRENT.md` (**Refresh follow-ups**), commit code + handoff together.
4. **Open the PR** and mark it ready for review.

### E3 - Wait for Bot Reviews

Run **Wait for reviews** for the PR.

### E4 - Triage and Address Reviews

1. Run **Review triage**.
2. Implement the fixes, then reach the **green bar**.
3. Commit, push, and post a triage summary comment (classification table + what was fixed/skipped/deferred).
4. If the fixes were substantial (new logic, not just test/doc tweaks), run **Wait for reviews** again — the push in step 3 already re-triggered the follow-up review — and repeat E4 once. At most two fix rounds; if findings persist, stop and escalate to the user.

### E5 - Handoff

Abort conditions (any time in E2–E4): tests can't go green within scope, a finding needs a product/API decision, or the change grows beyond the Stage 1 file list. On abort: stop, leave the branch + PR as-is, report state + blocker.

Final report:

1. Diff summary and behavior changed, in simple terms.
2. Confirm the **green bar** held on the final head commit.
3. Review triage table, including deferred Needs-human-decision items and any missing/silent bot review.
4. The issue's manual validation checklist for the owner.
5. Boot the simulator with the final branch build and leave it running for the owner's manual test.
6. Run **Triage coverage**; on a warning, triage the final round first (one extra E4 pass) — never hand off merge instructions while it warns.
7. Exact GitHub UI actions to merge. Do not merge.

After the user merges, run Stage 8.

## Staged Mode

### Stage 1 - Start Issue

1. Read `CURRENT.md`.
2. Fetch the issue; confirm it is open and `ready-for-agent`, unless the user wants human-scoped work.
3. Check `git status` and current branch.
4. Switch to `master`, pull `--ff-only`, create `issue/<issue-number>-<short-slug>`.
5. Do not edit code.
6. Report branch, cleanliness, one-sentence issue summary, what we'll address and why in simple terms, and the smallest implementation plan. Stop.

### Stage 2 - Implement

1. Restate the files expected to be touched before editing.
2. Follow **In scope**.
3. Reach the **green bar** (focused build/test is fine mid-flow).
4. Report files changed, behavior changed (in simple terms), validation, and owner manual checks. Leave the simulator open for manual tests. Do not commit unless approved.

### Stage 3 - Checkpoint Commit

1. Record owner manual validation notes if provided.
2. Re-run `git diff --check`, summarize the diff, and update `CURRENT.md` (**Refresh follow-ups**).
3. Commit code + handoff together. Do not push.
4. Report commit hash and clean status.

### Stage 4 - Publish Draft PR

1. Confirm clean status and correct branch.
2. **Open the PR** as a draft.
3. Do not merge or push `master`. Report the PR URL.

### Stage 5 - Review PR

Mark the PR ready for review, run **Wait for reviews**, then run **Review triage**, give a minimal fix plan, and do not edit until approved.

### Stage 6 - Address Review

1. Implement approved fixes only; explicitly skip false positives and deferred human decisions.
2. Reach the **green bar** (focused).
3. Report changed files and validation.
4. Commit review fixes, push, comment on the PR, and confirm the PR updated when the user approves.

### Stage 7 - Final PR Check

1. Confirm clean local status.
2. **Precondition: the green bar held on the final head commit.** If the full suite hasn't been run on that commit, run it now; never report ready on red or stale results.
3. Check PR state, head commit, unresolved review threads, comments, and checks; confirm the body links the issue with `Fixes #<issue>`.
4. Run **Triage coverage** (below). On a warning, run **Review triage** for the final round (and post the triage comment) before reporting ready.
5. If ready, tell the user the exact GitHub UI actions to mark ready/merge. Do not merge unless explicitly asked.

### Stage 8 - Post-Merge Cleanup

1. Fetch/prune origin; switch to `master`; pull `--ff-only`.
2. Confirm the linked issue is closed; delete the local feature branch if safe.
3. Report clean status and latest `master` commit. For other pending work, follow **Refresh follow-ups** rather than echoing `CURRENT.md`.

## Guardrails

- Express pre-authorizes feature-branch pushes and PR publishing only; staged keeps every push behind user approval. Merging and pushing `master` are never auto-authorized in either mode.
- `needs-manual-validation` issues must use staged mode so the owner tests before the PR publishes.
