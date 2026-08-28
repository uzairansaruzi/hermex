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

## Pull Requests as a Triage Surface

**PRs as a request surface: no.**

## Branch and PR Workflow

GitHub Issues are the work queue; pull requests are the review and merge record.

- Pick implementation work from issues labeled `ready-for-agent`, unless the human selects another issue.
- `ready-for-agent` issues default to express mode (autonomous from approved plan to review-addressed PR). An issue also labeled `needs-manual-validation` forces staged mode, where the owner manually tests before the PR publishes. See `docs/agents/triage-labels.md`.
- Create a short `issue/<n>-slug` branch for one issue or narrow slice (no-issue branches use `chore/`/`fix/`).
- Commit completed, validated work locally with the matching handoff updates.
- Push feature branches and open PRs only when the human asks to publish/open a PR. Open them ready for review, not as drafts: the review bots only run on ready PRs.
- Use the PR for review: GitHub/Copilot review, CI, external agent review, and human comments should live there when possible.
- Address PR review comments by triaging them first; do not blindly accept automated review feedback.
- Merge into `master` only after validation passes, review feedback is resolved, and the human approves.
- Keep `master` buildable because it is the internal TestFlight candidate branch.

## Upstream Parity Tracking

- Track upstream parity in the thin, always-current index `docs/agents/feature-gap-index.md` (route group → status + priority + safety + one-line note).
- Create GitHub issues from a `roadmap` row in the index only when a specific gap becomes selected or ready for triage.
- Validate request/response shapes **just-in-time** at implementation time against the pinned upstream copy (not pre-cached in the index); record the validated shape, handler name, and upstream commit in the issue/PR, and reference the archived catalog section when its notes still help.

## Skill Semantics

When a skill says "publish to the issue tracker", create a GitHub issue.

When a skill says "fetch the relevant ticket", run `gh issue view <number> --comments`.
