# Contract Test Readiness

Hermex is tested against `hermes-webui` tag `v0.51.85`, peeled commit `f1d399b437c1ca7fe4b6d2093aebe334c32f34a3`.

The machine-readable pin is `UPSTREAM_TESTED_SHA`. Any future contract test runner must clone or check out upstream at that exact SHA unless the pin is intentionally updated after manual verification.

## Advance Policy

`UPSTREAM_TESTED_SHA` records the last upstream commit the app was *validated*
against. Without a rule for moving it, the pin drifts ever further behind
`master` and the contract tests validate against an increasingly ancient
upstream. This section is that rule.

**Trigger — what makes the pin eligible to advance.** A green live-smoke
against the target upstream release:

1. All read-only endpoint groups in this file's "Endpoint Priority" list return
   and decode through the app's tolerant `Codable` models.
2. The mutating checks run against **one disposable session only** (create a
   throwaway session, exercise branch/truncate/rename/pin/archive/move/delete,
   then delete it). No production or owner session is touched.

Only after both pass is the target release "validated".

**Cadence and owner.** The repo owner runs the smoke and advances the pin
**after each successful smoke** — there is no fixed calendar; the smoke is the
gate. When a smoke is green, move the pin to the latest release it validated.
When a smoke is skipped or held, the pin stays and the reason is recorded (in
`CURRENT.md` for the session, or the relevant issue).

**How to advance.** Replace the SHA in `UPSTREAM_TESTED_SHA` with the peeled
commit of the validated release, then update the human-readable tag references
in this file, `README.md`, and `DEVELOPMENT.md` to match. Commit the pin move
together with a one-line note of which smoke validated it. `PROJECT_SPEC.md`
§16 now points at the pin file instead of carrying its own copy, so it needs no
update on advance.

**Visibility.** `scripts/upstream-watch` prints `Releases behind tested pin`
(the count of release tags the target is ahead of the pin) in both the Triage
Verdict and Baselines. Past the loud threshold (default `20`, configurable with
`--releases-loud-threshold`) the digest emits a ⚠️ LOUD line in the verdict so
the validation debt cannot grow silently. The current gap is large because the
pin has never advanced via the watch cycle; the first advance happens the next
time the owner runs a green smoke.

> Follow-up candidate (`ready-for-agent`): the "releases behind" count is now
> computed; a future slice could add per-release diff summaries or auto-open a
> `needs-triage` issue when the loud threshold is crossed.

## Current Slice

This slice adds lightweight readiness coverage, not the full Docker-backed CI contract target from `PROJECT_SPEC.md`.

Implemented now:
- `HermesMobileTests/APIClientTests.swift` contains a contract-readiness matrix for every app-used `Endpoint` case.
- The matrix asserts HTTP method intent, path, and query parameters for health, auth, sessions, destructive session actions, streaming, uploads, workspaces/files, models/providers/profiles/reasoning, slash-command endpoints, read-only server panels, skills, memory, and analytics source endpoints.
- Focused request tests assert native POST calls do not send `Origin` or `Referer`, preserving the upstream CSRF contract for non-browser clients.
- Multipart upload request tests also assert no `Origin` or `Referer`.

Not implemented in this slice:
- No live calls to the owner's server.
- No Docker startup.
- No new Xcode contract-test target.
- No mutating checks against a real upstream instance.

## Endpoint Priority

Read-only checks, safe for live contract smoke tests:
- `GET /health`
- `GET /api/auth/status`
- `GET /api/sessions`
- `GET /api/session?session_id=...&messages=...`
- `GET /api/session/status?session_id=...`
- `GET /api/projects`
- `GET /api/workspaces`
- `GET /api/workspaces/suggest?prefix=...`
- `GET /api/list?session_id=...&path=...`
- `GET /api/file?session_id=...&path=...`
- `GET /api/file/raw?session_id=...&path=...`
- `GET /api/models`
- `GET /api/providers`
- `GET /api/settings`
- `GET /api/reasoning`
- `GET /api/profiles`
- `GET /api/personalities`
- `GET /api/commands`
- `GET /api/crons`
- `GET /api/crons/status`
- `GET /api/crons/output?job_id=...&limit=...`
- `GET /api/skills`
- `GET /api/skills/content?name=...`
- `GET /api/memory`

State-changing checks, only safe against disposable test data:
- `POST /api/auth/login`
- `POST /api/auth/logout`
- `POST /api/session/new`
- `POST /api/session/rename`
- `POST /api/session/delete`
- `POST /api/session/pin`
- `POST /api/session/archive`
- `POST /api/session/move`
- `POST /api/session/duplicate`
- `POST /api/session/branch`
- `POST /api/session/truncate`
- `POST /api/session/update`
- `POST /api/session/compress`
- `POST /api/session/undo`
- `POST /api/session/retry`
- `POST /api/chat/start`
- `GET /api/chat/cancel?stream_id=...`
- `POST /api/chat/steer`
- `POST /api/default-model`
- `POST /api/reasoning`
- `POST /api/profile/switch`
- `POST /api/personality/set`

Streaming and async checks:
- `GET /api/chat/stream?stream_id=...`
- `GET /api/chat/stream/status?stream_id=...`
- `POST /api/btw`
- `POST /api/background`
- `GET /api/background/status?session_id=...`

Upload checks:
- `POST /api/upload`

## Future Full Contract Target

The full v1 target should:

1. Clone `nesquena/hermes-webui`.
2. Check out the SHA in `UPSTREAM_TESTED_SHA`.
3. Start upstream in Docker with a disposable workspace and password.
4. Run an XCTest or command-line Swift contract harness against the local upstream base URL.
5. Exercise read-only endpoints first.
6. Create one disposable session for mutating endpoints, then run branch/truncate/rename/pin/archive/move/delete checks only against that disposable session.
7. Assert each JSON response decodes through the app's tolerant `Codable` models.
8. Verify SSE event decoding from a controlled stream fixture or a short disposable chat turn.
9. Run on pull requests and nightly.

Until that target exists, the existing mock tests and this endpoint matrix are the readiness gate for request shape drift inside the iOS client.

## Upstream Watch Report

Use `scripts/upstream-watch` for the lightweight weekly upstream triage pass.
It compares `UPSTREAM_TESTED_SHA` and `UPSTREAM_TRIAGED_SHA` with a target
upstream ref, defaults to `.codex-tmp/hermes-webui` and `origin/master`, and
prints a markdown report.

`.codex-tmp/hermes-webui` is a local, read-only clone of the public upstream
that contributors create themselves (it is gitignored):

```bash
git clone https://github.com/nesquena/hermes-webui .codex-tmp/hermes-webui
```

Never modify that clone; it exists so endpoint shapes, tags, and diffs can be
checked against the exact upstream source.

Example:

```bash
scripts/upstream-watch --fetch
```

The report highlights:
- how many release tags the target is ahead of the tested pin
  ("Releases behind tested pin"), with a ⚠️ LOUD flag past the threshold
  (see "Advance Policy" above);
- mobile endpoint paths no longer found in upstream route literals;
- mobile endpoint paths missing from `APIEndpointContractTests`;
- newly added upstream route literals since the last triaged SHA;
- removed upstream route literals since the last triaged SHA;
- upstream route literals still unvalidated since the tested SHA, bucketed into
  **new / unclassified** (led by feature group so passkeys, Notes, TTS,
  `project-os`, and the expanded `/api/git/*` surface stand out), plus collapsed
  counts for **implemented** (derived from `Endpoints.swift`), **roadmap**, and
  **n-a** (classified from the `docs/agents/feature-gap-index.md` table);
- changed high-signal upstream files such as `api/routes.py`, `api/streaming.py`,
  model/provider/session modules, upload/media/workspace modules, and upstream
  contract/RFC docs;
- recent commit subjects containing risk keywords;
- the upstream `CHANGELOG.md` bullets added since the last triaged SHA, parsed
  from the `### Added/Changed/Fixed/Security/Removed` sections and rendered inline
  grouped by category (the highest-signal upstream summary; additive to the
  subject-keyword scan, which still covers cases where upstream forgets to update
  the CHANGELOG). Per-category lists cap at `--changelog-limit` (default 40); a
  truncated category shows `- ... N more` and logs the drop to stderr. Degrades to
  "None" when `CHANGELOG.md` is absent at either ref.
- new upstream **request keys** since the last triaged SHA — snake_case string
  literals read via `.get("<key>")` in `api/routes.py` (e.g. `explicit_model_pick`,
  `expand_renderable`) that a route-*path* diff cannot see. This catches new
  params/fields added to existing, unchanged routes; it is additive to the route
  and CHANGELOG scans. The list caps at `--request-key-limit` (default 80) with a
  `- ... N more` marker + stderr notice, and shows "None" when nothing was added.
- upstream **SSE wire event types the app does not handle** — the `event:` name in
  the 2nd positional arg of every `_sse(handler, "<name>", ...)` call in
  `api/routes.py` + `api/streaming.py`, unioned with the documented callback-emitted
  set (`token`, `reasoning`, `tool`, `tool_complete`, `title`, `done`,
  `interim_assistant`), minus the `case "<name>":` literals the app handles in
  `SSEClient.swift`. SSE drift is path-invisible (a new event lands on an existing,
  unchanged route), so this is additive to the route/CHANGELOG/request-key scans and
  feeds the coverage verdict. Wire `event:` names only — inner `event_type` fields
  (`tool.started`, etc.) are out of scope. The list caps at `--sse-event-limit`
  (default 40) with a `- ... N more` marker + stderr notice, shows "None" when fully
  covered, and degrades gracefully if either source file is missing.

Treat the report as triage input, not approved scope. Create `needs-triage`
issues for likely contract breakage or meaningful parity opportunities, and
promote an issue to `ready-for-agent` only after the app impact and acceptance
criteria are clear. Update `UPSTREAM_TRIAGED_SHA` only after the digest has
been reviewed and any follow-up issues have been created. Update
`UPSTREAM_TESTED_SHA` only after focused validation against that upstream commit.

The GitHub Action `Upstream Hermes-WebUI Watch` runs the same report, uploads
it as an artifact, and creates or updates the standing
`Upstream Hermes-WebUI watch digest` issue. It can be run manually and also
runs weekly on Monday at 14:00 UTC. Scheduled runs post the digest issue by
default; manual runs can disable issue posting with the `post_issue` input.
