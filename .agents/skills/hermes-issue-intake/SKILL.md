---
name: hermes-issue-intake
description: Turns rough Hermes Mobile bugs/features into clear GitHub issues, and unblocks needs-info or ready-for-human issues, by grilling the user one question at a time. Use when the user wants to draft a new hermex issue from a rough item, or unblock an existing needs-info or ready-for-human issue.
---

# Hermes Issue Intake

Use this in the hermex repo root. Goal: turn a rough item or a blocked issue into a clear GitHub issue — never implement it. **Don't edit code, touch git, or publish/update an issue without user approval.** This guardrail holds for every step below.

## Quick Start

Two branches:

- **Draft** a new issue from a rough bug/feature.
- **Unblock** an existing `needs-info` or `ready-for-human` issue (e.g. "Resolve needs-info issue #7").

Both run on **grill**: one question at a time, each with a recommended answer, exploring the codebase instead of asking when that answers better (the `grilling` loop).

## Context Rules

1. Read `CURRENT.md`, `docs/agents/issue-tracker.md`, and `docs/agents/triage-labels.md` only as needed. Repo rules are auto-loaded from `CLAUDE.md` — don't re-read them.
2. Check open GitHub issues only for likely duplicates of this specific item.
3. Keep context lean: read only the doc sections you need, never the whole `PROJECT_SPEC.md`.

## Intake Flow

1. Restate the rough item in one sentence.
2. Grill on current behavior, expected behavior, affected surface, repro, examples, and priority — only as needed.
3. Stop grilling once you can fill every Draft Format field below (mark a field N/A only deliberately).
4. If the item is too large for one issue, propose smaller vertical slices and ask before handing off to `to-issues`.
5. Draft the issue, show it, and wait for approval. On approval, publish it and report the URL.

## Draft Format

Show:

- Title
- Category label: `bug` or `enhancement`
- State label: `needs-info`, `ready-for-agent`, or `ready-for-human`
- Optional routing label: `needs-manual-validation` (see below)
- Body: Context · Current behavior · Expected behavior · Acceptance criteria · Validation plan · Non-goals

For UI issues, include manual simulator validation. For API/server-shaped issues, require route-shape validation from the repo-local upstream copy or the running server before implementation.

## Choosing the state label

Canonical label strings and meanings live in `docs/agents/triage-labels.md`; this is the intake-specific decision logic. Move every item out of `needs-triage` into exactly one state label:

- `ready-for-agent` — narrow, implementable, acceptance criteria clear, no unresolved product/API decision. Defaults to express mode of `hermes-issue-pr-workflow`.
- `ready-for-human` — valid but needs owner/product/design/API judgment before implementation.
- `needs-info` — missing repro, affected input, expected behavior, or other blocking detail.
- `wontfix` — grilling shows the item shouldn't be actioned; recommend closing (owner decides).

Routing flag `needs-manual-validation` combines with `ready-for-agent` to force staged mode; apply it under the rules in `docs/agents/triage-labels.md`.

## Unblocking an issue (`needs-info` / `ready-for-human`)

Use when an existing issue carries one of these labels. Goal: for `needs-info`, collect the missing detail needed to triage/implement; for `ready-for-human`, resolve the product/design/API/owner decision blocking it.

1. Read the issue, comments, and any prior triage notes.
2. Grill until the blocker is resolved.
3. Summarize what's new/decided, the remaining unknowns, and the next label: `ready-for-agent`, `ready-for-human`, `needs-info`, or split.
4. On approval, comment the summary on the issue and update labels. If narrow and clear, relabel `ready-for-agent`; if too large, propose vertical slices and ask before handing off to `to-issues`.

## Publishing

`gh issue create` in the repo, with exactly one category label and one state label (plus `needs-manual-validation` if it applies). After publishing, stop — implementation is `hermes-issue-pr-workflow`'s job, and only when the user asks for it.
