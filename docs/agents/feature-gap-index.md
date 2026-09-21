# Hermes Upstream Feature-Gap Index

Thin classification of upstream `hermes-webui` route groups against Hermex.

- **`Endpoints.swift` is the authority for `implemented`.** Do not hand-list
  shipping paths here.
- This file is only durable judgment: remaining gaps (`roadmap`), non-goals
  (`n-a`), and owner drop decisions. Validate JSON shapes just-in-time against
  the pinned upstream copy when a row is selected — see
  [Just-in-time research rule](#just-in-time-research-rule).

Owner-observed mobile bugs and polish stay in GitHub Issues unless the item is
an upstream WebUI parity gap.

## Status vocabulary

| Status | Meaning | Source |
| :--- | :--- | :--- |
| `implemented` | Shipping in the app. | Whatever `HermesMobile/Networking/Endpoints.swift` calls. |
| `roadmap` | Known upstream surface still missing on mobile (or **partial**: some paths shipped, note lists what remains). | The table below. |
| `n-a` | Web-, desktop-, or server-internal; or owner-dropped. No mobile work expected. | The table below. |
| `new` | Uncatalogued upstream route. | Matches neither `Endpoints.swift` nor the table. |

## Priority guide

- **P0**: Agent interaction can block or appear broken without it.
- **P1**: High-value user-facing parity with moderate risk.
- **P2**: Good next slices — small, useful, mostly non-destructive.
- **P3**: Settings/admin/editing features needing deliberate UX and owner approval.
- **P4**: Large systems or safety-sensitive surfaces.
- **P5**: Niche server-admin monitoring or low mobile fit.

**Safety:** `write` (mutates server state/files), `exec` (runs server code),
`secret` (API keys/credentials), `privacy` (data leaves the device), `admin`
(server-management), `read` (read-only, low risk), `—` (n/a).

## Route classification

Every `roadmap` / `n-a` row is a route-prefix. Matching is by prefix,
**first match wins**, so specific prefixes must sit before general ones
(e.g. `/api/file/reveal` before `/api/file/`). A trailing `/` scopes a prefix to
sub-paths. `Endpoints.swift` still wins for any path it defines.

A `roadmap` row whose prefix also matches a live `Endpoint` must say **partial**
and name the remaining paths.

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
| `/api/commands/exec` | n-a | — | exec | Dropped by owner — must not resurface; needs product framing |
| `/api/updates/summary` | n-a | — | admin | Dropped by owner — undocumented; fires a server LLM call |
| `/api/session/import` | n-a | — | — | JSON import unused; CLI import (`/api/session/import_cli`) shipped |
| `/api/rollback/` | roadmap | P3 | write | Git checkpoint list/diff/restore |
| `/api/session/usage` | roadmap | P2 | read | Session token usage — mostly covered by the context ring |
| `/api/session/toolsets` | roadmap | P4 | write | Advanced session maintenance |
| `/api/session/draft` | roadmap | P4 | write | Advanced session maintenance |
| `/api/session/conversation-rounds` | roadmap | P4 | write | Advanced session maintenance |
| `/api/session/handoff-summary` | roadmap | P4 | read | Advanced session maintenance |
| `/api/session/lineage/` | roadmap | P4 | read | Advanced session maintenance |
| `/api/session/worktree/` | roadmap | P4 | write | Advanced session maintenance |
| `/api/session/recovery/` | roadmap | P4 | write | Advanced session maintenance |
| `/api/sessions/cleanup` | roadmap | P4 | write | Advanced session maintenance — bulk cleanup |
| `/api/provider/` | roadmap | P3 | secret | partial — `quota` shipped (#415); `cost-history` remains |
| `/api/providers` | roadmap | P3 | secret | partial — GET status shipped (#26); key set/delete and `/self-hosted` remain |
| `/api/models/refresh` | roadmap | P3 | — | Provider / model management |
| `/api/model/` | roadmap | P3 | — | Provider / model management (`set`, `auxiliary`) |
| `/api/settings` | roadmap | P3 | secret | partial — GET plus session-visibility writes shipped (#19); full settings editor remains |
| `/api/profile/` | roadmap | P3 | write | partial — switch/create shipped; `active` and `delete` remain |
| `/api/skills/` | roadmap | P3 | write | partial — list/content/toggle shipped; save/delete remain |
| `/api/workspace/` | roadmap | P3 | write | Workspace-panel `/upload`; registry CRUD is `/api/workspaces/*` and shipped |
| `/api/file/` | roadmap | P4 | write | partial — read (`/api/file`, `/api/file/raw`) shipped; mutations owner-deferred |
| `/api/folder/` | roadmap | P4 | write | File editing — owner-deferred (zip download) |
| `/api/terminal/` | roadmap | P4 | exec | Terminal — owner-deferred; App Store/safety-sensitive |
| `/api/gateway/` | roadmap | P5 | read | Gateway / messaging bridge |
| `/api/updates/` | roadmap | P5 | admin | partial — check/apply shipped; `force` and `clear_lock` remain |
| `/api/system/health` | roadmap | P5 | read | System health & logs |
| `/api/health/agent` | roadmap | P5 | read | System health & logs |
| `/api/logs` | roadmap | P5 | read | System health & logs |
| `/api/dashboard/` | roadmap | P5 | admin | Dashboard & plugins |
| `/api/plugins` | roadmap | P5 | admin | Dashboard & plugins |
| `/api/mcp/` | roadmap | P5 | admin | MCP servers & tools |
| `/api/wiki/` | roadmap | P5 | read | Wiki / knowledge system |
| `/api/notes/` | roadmap | P5 | read | Notes / knowledge — search/sources/item |
| `/api/project-os/` | roadmap | P5 | read | Project-OS dashboard |

Shipped prefixes removed from this table (now `implemented` via `Endpoints.swift`):
`/api/git-info`, `/api/git/*`, `/api/crons/history`, `/api/session/duplicate`,
`/api/session/compress`, `/api/models/live`, `/api/transcribe`,
`/api/workspaces/*`, `/api/session/import_cli`, `/api/background`,
`/api/personalities`, `/api/personality/set`, `/api/default-model`, `/api/btw`.

### Not in this index → `new`

Any upstream route matching neither `Endpoints.swift` nor the table is
**New / unclassified** — the triage queue. Do not invent a row without an owner
priority/fit decision. Current examples: `prompts` (saved prompts library),
`extensions`, `share`.

### Already triaged — do not re-file

Owner-dropped; must not resurface as new findings:

- `POST /api/updates/summary` — undocumented, and it fires a server LLM call.
- `POST /api/commands/exec` — needs product framing before any client work.

Deferred pending explicit owner opt-in — do not file without asking first:
stream/status `replay_available` decode; auxiliary model routing; settings-editor
UI; profile delete; all `/api/file/*` mutations and folder zip; skill authoring;
command bundles.

## Just-in-time research rule

Deep request/response/handler validation happens **when a feature is selected for
implementation**, not pre-cached here. When you pick up a `roadmap` row:

1. Read the matching handler in `.codex-tmp/hermes-webui/api/routes.py` (and the
   WebUI caller in `.codex-tmp/hermes-webui/static/` when one exists) at the
   pinned upstream commit. Never guess JSON shapes — see `AGENTS.md`.
2. Record the validated shape, handler name, and upstream commit **in the issue
   and the PR**, not in this index.
3. If the durable judgment changes (priority, safety, defer/skip), update this
   row — that is the only thing the index should accumulate.

## Implementing a row

Follow `AGENTS.md`. Surfaces flagged `write`/`exec`/`secret`/`admin`/`privacy`
get explicit confirmation copy and never default-on dangerous behavior.
