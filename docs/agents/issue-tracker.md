# Issue Tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for issue operations.

## Repository

- GitHub repo: `uzairansaruzi/hermex`
- Remote: `https://github.com/uzairansaruzi/hermex.git`

Infer the repo from `git remote -v` when possible; `gh` does this automatically when run inside the clone.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`
- **Read an issue**: `gh issue view <number> --comments`
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply a label**: `gh issue edit <number> --add-label "..."`
- **Remove a label**: `gh issue edit <number> --remove-label "..."`
- **Close an issue**: `gh issue close <number> --comment "..."`

Use heredocs for multi-line issue bodies and comments.

## Issue Body

Every issue opens with a plain header written for the owner, above the spec:

```markdown
**What the user gets:** one sentence.
**Why it matters:** who asked, or what breaks without it.
**Cost:** Small, Medium, or Large, and whether it needs the owner's hands on a phone.
```

- An issue the owner or an agent creates carries the header at the top of its body.
- On an outside reporter's issue, leave their words alone: the header goes in the owner's first triage comment.
- Do not write a `Priority: Pn` line. Order comes from the release milestone.

## Pull Requests as a Triage Surface

**PRs as a request surface: no.** Bug reports and feature requests belong in issues, not in PR comments. Review comments on an open PR are still actionable — triage and address them as described below.

## Branch and PR Workflow

GitHub Issues are the work queue; pull requests are the review and merge record.

- Pick implementation work from issues in the open release milestone (see Release Milestones) that are labeled `ready-for-agent`, unless the human selects another issue. The triage label says whether and how an agent runs an issue; the milestone says when.
- Skip an issue assigned to someone other than the owner: that contributor has the go-ahead to build it (`CONTRIBUTING.md` § PR workflow).
- `ready-for-agent` issues default to express mode (autonomous from approved plan to review-addressed PR). An issue also labeled `needs-manual-validation` forces staged mode, where the owner manually tests before the PR publishes. See `docs/agents/triage-labels.md`.
- Create a short `issue/<n>-slug` branch for one issue or narrow slice (no-issue branches use `chore/`/`fix/`).
- Commit completed, validated work locally with the matching handoff updates.
- Push feature branches and open PRs only when the human asks to publish/open a PR. Open them ready for review, not as drafts: the review bots only run on ready PRs.
- Use the PR for review: GitHub/Copilot review, CI, external agent review, and human comments should live there when possible.
- Address PR review comments by triaging them first; do not blindly accept automated review feedback.
- Merge into `master` only after validation passes, review feedback is resolved, and the human approves.
- Keep `master` buildable because it is the release-candidate branch.

## Release Milestones

- One open milestone per release, named for the marketing version (`1.9`). A serious bug found after a release ships gets a patch milestone (`1.9.1`).
- Everything in the milestone is intended for that release. The release ships when the milestone has no open issues, no open issue is labeled `release-blocker`, and the gates in `TESTFLIGHT.md` pass.
- To ship sooner, the owner moves what is left to the next milestone. Agents never add an issue to a milestone or take one out without the owner saying so.
- An issue with no milestone is backlog. Backlog is unranked.

## Choosing the Next Release

The owner picks what goes into a milestone. An agent asked what to work on next offers a shortlist of about 10 candidates, each shown by its plain header and the evidence for it (who asked, reactions, what it unblocks). It does not rank the whole backlog.

## Bulk Findings

When an agent produces many findings at once (an audit, a review sweep), it gives the owner one list of plain one-liners, and only the ones the owner accepts become issues. Children of an epic the owner already approved are exempt.

## Upstream Parity Tracking

- Track upstream parity in the thin, always-current index `docs/agents/feature-gap-index.md` (route group → status + priority + safety + one-line note).
- Create GitHub issues from a `roadmap` row in the index only when a specific gap becomes selected or ready for triage.
- Validate request/response shapes **just-in-time** at implementation time against the pinned upstream copy (not pre-cached in the index); record the validated shape, handler name, and upstream commit in the issue/PR, and reference the archived catalog section when its notes still help.

## Skill Semantics

When a skill says "publish to the issue tracker", create a GitHub issue.

When a skill says "fetch the relevant ticket", run `gh issue view <number> --comments`.
