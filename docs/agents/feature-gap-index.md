# Hermes Upstream Feature-Gap Index

Thin, **always-current** classification of upstream `Hermes-WebUI` API route
groups against `Hermes-Mobile`. This file replaces an earlier 1,400-line
per-endpoint catalog, which mixed durable judgment (priority, defer/skip
decisions, safety notes) with volatile detail (exact JSON shapes, handler names)
that rotted between upstream releases.

- The **durable layer** lives here: route group → status + priority + safety + a
  one-line note. Cheap to keep true.
- The **volatile layer** (request/response shapes, handler names) is **not**
  cached here. It is validated **just-in-time**, when a feature is selected for
  implementation, against the pinned upstream copy. See
  [Just-in-time research rule](#just-in-time-research-rule).
- The old catalog (durable per-feature regression notes and validated shapes as
  of 2026-05-21) was retired during open-source prep (#347); shapes are always
  re-validated just-in-time rather than recovered from it.

Keep owner-observed mobile bugs, polish notes, and tester feedback in GitHub Issues
unless the item is explicitly an upstream WebUI parity gap.

## Status vocabulary

| Status | Meaning | Source |
| :--- | :--- | :--- |
| `implemented` | Shipping in the app. | **Derived live** from `HermesMobile/Networking/Endpoints.swift` — never hand-listed here, so it cannot drift from what the app ships. |
| `roadmap` | A known upstream feature tracked as a future/deferred mobile slice (covers the old `[ ]`/`[~]`/`[defer]`). | The hand-maintained table below. |
| `n-a` | Web-, desktop-, or server-internal surface. No mobile implementation expected. | The hand-maintained table below. |
| `new` | Genuinely uncatalogued upstream route — the triage queue. | **Computed**: any upstream route matching neither `Endpoints.swift` nor the table below falls through to `new`. |

Only `roadmap` and `n-a` are hand-maintained in the table; `implemented` and
`new` are computed by `scripts/upstream-watch`, so this index stays small.

## Priority guide

- **P0**: Agent interaction can block or appear broken without it.
- **P1**: High-value user-facing parity with moderate risk.
- **P2**: Good next slices — small, useful, mostly non-destructive.
- **P3**: Settings/admin/editing features needing deliberate UX and owner approval.
- **P4**: Large systems or safety-sensitive surfaces.
- **P5**: Niche server-admin monitoring or low mobile fit.

The **Safety** column flags surfaces that need explicit confirmation/guardrails:
`write` (mutates server state/files), `exec` (runs server code), `secret`
(API keys/credentials), `privacy` (data leaves the device), `admin`
(server-management), `read` (read-only, low risk), `—` (n/a).

## Route Classification (machine-readable)

`scripts/upstream-watch` parses the table below: every row whose **Status** is
`roadmap` or `n-a` becomes a route-prefix classification. Matching is by prefix,
**first match wins**, so specific prefixes must be listed before general ones
(e.g. `/api/file/reveal` before `/api/file/`). A trailing `/` scopes a prefix to
sub-paths of a group. Do not reorder casually.

| Route prefix | Status | Priority | Safety | Note |
| :--- | :--- | :---: | :---: | :--- |
| `/api/csp-report` | n-a | — | — | Browser CSP report |
| `/api/client-events/log` | n-a | — | — | Browser telemetry |
| `/api/file/reveal` | n-a | — | — | Reveal in Finder; desktop-only |
| `/api/file/open-vscode` | n-a | — | — | Open in VS Code; desktop-only |
| `/api/admin/reload` | n-a | — | — | Server hot-reload/dev admin |
| `/api/approval/inject_test` | n-a | — | — | Localhost test endpoint |
| `/api/clarify/inject_test` | n-a | — | — | Localhost test endpoint |
| `/api/upload/extract` | n-a | — | — | Archive extraction; server-side helper |
| `/api/onboarding/` | n-a | — | — | Server setup/OAuth; mobile has its own connection onboarding |
| `/api/shutdown` | n-a | — | — | Server shutdown; admin-only |
| `/api/auth/passkey` | n-a | — | — | WebAuthn passkey browser auth; mobile uses its own server-connection auth |
| `/api/auth/passkeys` | n-a | — | — | WebAuthn passkey list; browser auth surface |
| `/api/git-info` | roadmap | P3 | read | Git Info & Rollback — branch/status read |
| `/api/git/` | roadmap | P3 | write | Git review & management — branches/diff/commit/stage/push/pull/discard/stash |
| `/api/rollback/` | roadmap | P3 | write | Git Info & Rollback — checkpoint list/diff/restore |
| `/api/crons/history` | roadmap | P2 | read | Cron History / Recent Runs |
| `/api/session/usage` | roadmap | P2 | read | Session Token Usage — mostly covered by the context ring |
| `/api/session/clear` | roadmap | P2 | write | Session Clear — destructive; needs confirmation |
| `/api/session/import` | roadmap | P3 | — | Session Import (JSON / CLI) |
| `/api/session/duplicate` | roadmap | P4 | — | Session Duplicate — branch-based duplicate already covers the need |
| `/api/session/toolsets` | roadmap | P4 | write | Advanced Session Maintenance |
| `/api/session/draft` | roadmap | P4 | write | Advanced Session Maintenance |
| `/api/session/compress/` | roadmap | P4 | write | Advanced Session Maintenance |
| `/api/session/conversation-rounds` | roadmap | P4 | write | Advanced Session Maintenance |
| `/api/session/handoff-summary` | roadmap | P4 | read | Advanced Session Maintenance |
| `/api/session/lineage/` | roadmap | P4 | read | Advanced Session Maintenance |
| `/api/session/worktree/` | roadmap | P4 | write | Advanced Session Maintenance |
| `/api/session/recovery/` | roadmap | P4 | write | Advanced Session Maintenance |
| `/api/sessions/cleanup` | roadmap | P4 | write | Advanced Session Maintenance — bulk cleanup |
| `/api/provider/` | roadmap | P3 | secret | Provider Management — quota/cost history |
| `/api/providers` | roadmap | P3 | secret | Provider Management — read-only status screen shipped (#26); key set/delete remains roadmap |
| `/api/models/refresh` | roadmap | P3 | — | Provider / Model Management |
| `/api/models/live` | roadmap | P3 | — | Provider / Model Management — live model fetch |
| `/api/model/` | roadmap | P3 | — | Provider / Model Management |
| `/api/settings` | roadmap | P3 | secret | Settings Write — single-key `show_cli_sessions` write shipped (#19); full Settings Write (bot name + password operations) remains roadmap |
| `/api/profile/` | roadmap | P3 | write | Profile Management — active/create/delete |
| `/api/skills/` | roadmap | P3 | write | Skill Management — toggle shipped; save/delete remain roadmap |
| `/api/transcribe` | roadmap | P3 | privacy | Audio Transcription — server-side; audio leaves the device |
| `/api/workspaces/` | roadmap | P3 | write | Workspace Management — add/remove/rename/reorder shipped (#22); list + `/suggest` were already shipped |
| `/api/workspace/` | roadmap | P3 | write | Workspace Management |
| `/api/file/` | roadmap | P4 | write | File Editing / Management — owner-deferred |
| `/api/folder/` | roadmap | P4 | write | File Editing / Management — owner-deferred |
| `/api/kanban` | roadmap | P4 | write | Kanban Board — owner-deferred |
| `/api/terminal/` | roadmap | P4 | exec | Terminal — owner-deferred; App Store/safety-sensitive |
| `/api/commands/exec` | roadmap | P4 | exec | Plugin command exec — owner-deferred |
| `/api/gateway/` | roadmap | P5 | read | Gateway / Messaging Bridge |
| `/api/updates/` | roadmap | P5 | admin | Server Updates |
| `/api/system/health` | roadmap | P5 | read | System Health & Logs |
| `/api/health/agent` | roadmap | P5 | read | System Health & Logs |
| `/api/logs` | roadmap | P5 | read | System Health & Logs |
| `/api/dashboard/` | roadmap | P5 | admin | Dashboard & Plugins |
| `/api/plugins` | roadmap | P5 | admin | Dashboard & Plugins |
| `/api/mcp/` | roadmap | P5 | admin | MCP Servers & Tools |
| `/api/wiki/` | roadmap | P5 | read | Wiki / Knowledge System |
| `/api/notes/` | roadmap | P5 | read | Notes / Knowledge — search/sources/item |
| `/api/tts` | roadmap | P5 | privacy | Text-to-Speech — server-side; mobile can use native TTS |
| `/api/project-os/` | roadmap | P5 | read | Project-OS dashboard |

### Implemented (for reference, derived — not parsed)

`scripts/upstream-watch` decides `implemented` live from `Endpoints.swift`; this
list is a human convenience only and is intentionally **not** machine-read.
Shipping parity features include: Clarification System, Goal Submission, Session
Search, Memory Editing, Cron mutations, Project Rename, Server-Side Insights,
Transcript `MEDIA:` inline image rendering, and the core session/chat/streaming
surface. For each feature's regression-check notes and last-validated shapes, see
the archived catalog in `git log` history (removed during open-source prep, #347).

### Not in this index → `new`

Any upstream route group not in `Endpoints.swift` and not in the table above
surfaces in the digest's **New / unclassified** bucket — the just-in-time triage
queue. As of upstream `v0.51.338` this includes groups such as `prompts` (saved
prompts library), `background`, `personalities`/`personality`, `default-model`,
and `btw`. Leaving them uncatalogued is deliberate: they need an owner triage
decision (priority + fit) before they earn a durable row here. Do not invent a
classification for them without that decision.

## Just-in-time research rule

Deep request/response/handler validation happens **when a feature is selected for
implementation**, not pre-cached in this index. When you pick up a `roadmap` row:

1. Read the matching handler in `.codex-tmp/hermes-webui/api/routes.py` (and the
   WebUI caller in `.codex-tmp/hermes-webui/static/` when one exists) at the
   pinned upstream commit. Never guess JSON shapes — see `AGENTS.md` hard rule 3.
2. Record the validated shape, handler name, and upstream commit **in the issue
   and the PR**, not in this index. The index stays thin.
3. If the durable judgment changes (priority, safety, defer/skip), update this
   row — that is the only thing the index should accumulate.

## Implementation rules for any slice

1. Start from `CURRENT.md` if it exists (local-only, gitignored — a fresh clone
   won't have one), then this index.
2. Create a short `issue/<n>-slug` branch unless the owner explicitly says otherwise.
3. Validate the route in `.codex-tmp/hermes-webui/api/routes.py` before coding
   (the just-in-time rule above).
4. Prefer existing mobile patterns in `Endpoints.swift`, `APIClient.swift`, model
   files, view models, and XCTest.
5. Decode tolerantly. Optional fields stay optional unless the server handler
   enforces them.
6. Add focused tests for endpoint path/query/body construction and tolerant model
   decoding.
7. Run focused tests for the touched area, then the full XCTest suite before
   asking for review.
8. For `write`/`exec`/`secret`/`admin`/`privacy` surfaces, add explicit
   confirmation copy and avoid default-on dangerous behavior.
9. At wrap-up or completed-slice handoff, update `CURRENT.md`,
   update this index's status if the durable judgment changed, and commit only a
   validated build/test state.

## Agent prompt template

```markdown
Read CURRENT.md first if it exists (it is local-only and gitignored), then read
docs/agents/feature-gap-index.md.

We are implementing "[FEATURE NAME]".

Before coding (just-in-time validation):
- Create a branch with the prefix `issue/` (e.g. `issue/<n>-slug`).
- Validate the endpoint and JSON shape in .codex-tmp/hermes-webui/api/routes.py
  at the pinned upstream commit. Never guess shapes.
- Check WebUI static callers when relevant.
- Record the validated shape + handler + upstream commit in the issue/PR.

Implementation:
1. Add/extend Endpoint cases and APIClient methods.
2. Add tolerant Codable models.
3. Integrate view-model and SwiftUI changes using existing patterns.
4. Add focused XCTest coverage for endpoint/body/decode/view-model behavior.
5. Run focused tests, then full simulator XCTest.
6. Update the feature-gap-index row (only if durable judgment changed)
   and CURRENT.md before a checkpoint commit.
```
