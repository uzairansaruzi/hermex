# Contributing to Hermex

Thanks for your interest in contributing! This document covers local setup,
running tests, code signing for contributors, and the PR workflow. Please also
read the [Code of Conduct](CODE_OF_CONDUCT.md).

## Local setup

- **Xcode 26 or newer** (the project builds with the iOS 18 SDK or later; the
  deployment target is iOS 18).
- Clone the repo and open `HermesMobile.xcodeproj`. Dependencies resolve
  automatically via Swift Package Manager — the dependency list is locked in
  `AGENTS.md`; do not add new ones without maintainer approval. Their versions
  are pinned in the committed `Package.resolved`; Dependabot proposes updates,
  and CI fails rather than re-resolving when the pin no longer matches the
  project.
- Build and run the **`HermesMobile`** scheme on an iPhone simulator
  (`iPhone 17` is the reference device; any recent iPhone simulator works).
- To actually use the app you need your own
  [hermes-webui](https://github.com/nesquena/hermes-webui) server — the app is
  a client only. See the [README](README.md#getting-started) for
  reachable-server options (Cloudflare Tunnel, reverse proxy, Tailscale, or
  `http://localhost:8787` for simulator-only testing).

## Running tests

The full XCTest suite is the repo's green bar — it must pass before any PR:

```zsh
scripts/test-sim <simulator-udid>
```

Choose an available iPhone UDID from `xcrun simctl list devices available`.
The runner builds a signed Debug app and runs tests serially on that device;
see [Local XCTest](DEVELOPMENT.md#local-xctest) for focused tests and logs.
The same suite runs in CI on every pull request with code signing disabled,
so forks get green CI without any secrets.

## Code signing for contributors

The project's committed signing identity (`DEVELOPMENT_TEAM`, bundle IDs)
belongs to the maintainer. **Never edit `project.pbxproj` to sign with your own
team** — override locally instead:

1. Create `Config/Local.xcconfig` (it is gitignored, so it never lands in a PR):

   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   // Required whenever you set your own team: use your own bundle ID prefix.
   // The app-group entitlement must stay in sync with the bundle ID.
   APP_BUNDLE_IDENTIFIER = com.yourname.hermex
   APP_GROUP_IDENTIFIER = group.com.yourname.hermex
   ```

   Always override the bundle and app-group IDs along with the team. With the
   committed defaults, Xcode registers any extension ID the maintainer hasn't
   registered yet to *your* team, and the release can't use that ID afterwards.

2. Build normally. `Config/Shared.xcconfig` is wired into the project and ends
   with `#include? "Local.xcconfig"`, so your local values override the
   committed defaults for every target — no project-file changes needed.

For simulator-only development you usually don't need any of this: simulator
builds don't require a paid team. CI runs with
`CODE_SIGNING_ALLOWED=NO`; installing such a build on a simulator for *manual*
testing breaks Keychain entitlements — use a normally-signed build for that
(see `AGENTS.md`).

## What PRs we welcome (and what we don't)

Bug fixes, test coverage, and focused improvements are always welcome. For
anything larger than a small fix, **open an issue first and wait for a
maintainer nod before writing code** — it protects your time as much as the
review queue. Drive-by rewrites, reformat-the-world diffs, and unannounced
architecture overhauls will be closed without detailed review.

Keep each PR to **one logical change** with a reviewable diff. If a change is
independently useful, it deserves its own PR.

## Hermex Design System

Hermex has one versioned design-system implementation in this repository. Shared
foundations live in `HermesMobile/Config/`; reusable components and patterns live
in `HermesMobile/Features/Shared/`. Feature screens consume those APIs instead of
recreating their visual treatment locally.

For frontend contributions:

- Use the existing Hermex typography, color, spacing, radius, motion, shadow, and
  component APIs before introducing a literal or feature-local lookalike.
- Keep native platform behavior where it owns the interaction — for example
  `.searchable`, navigation/toolbars, system lists, menus, and alerts — and layer
  Hermex styling around those semantics rather than replacing them.
- Use `Tag` only for display-only metadata. Tappable choices use Button,
  Segmented Control, Checkbox, or another semantic control.
- Update `design-system-catalog/` in the same PR whenever a shared token,
  component, variant, state, or ownership classification changes — it is
  versioned in this repository, not maintained separately. See
  [`DEVELOPMENT.md`](DEVELOPMENT.md#design-system-catalog) for install/test/
  typecheck/launch commands.
- Before adding a new frontend literal, a new/customized component, or a
  lookalike of an existing one, run `scripts/design-system-guide "<query>"`
  against the checked-in `design-system-catalog/hermex-manifest.json` and
  include its `receipt` subcommand output (query, selected entry, rejected
  alternatives with reasons, and whether a new component is actually needed)
  in the PR description. `design-system-catalog/hermex-manifest.json` is a
  **generated** artifact — regenerate it with `node
  design-system-catalog/scripts/generate-hermex-manifest.mjs` in the same PR
  as any `hermesSections.tsx`/`types.ts`/`manifest.ts` change; PR CI's Design
  System Contract job fails closed if it drifts (`--check`). Never hand-edit
  the JSON file directly.
- `scripts/hermex_design_system_adoption_audit.py` (PR CI's Design System
  Contract job) protects the foundation layer: it fails closed if a required
  foundation file or one of its load-bearing API snippets goes missing, if the
  approved icon-size or avatar/icon-pairing scale drifts, or if a frozen
  legacy-baseline count (native segmented controls, direct
  `ContentUnavailableView` calls) grows or gains a new call site. It does not
  rewrite code, and it does not require or prove that any production screen has
  migrated onto a Design System component — an automatic check only enforces
  the specific contracts encoded above, nothing broader. If your PR
  legitimately adds, removes, or migrates one of the frozen baseline's call
  sites, update that baseline dict in the same PR with a comment explaining
  why — the script's own module docstring names the owner/removal-condition
  rule for each baseline.

## App bug or server bug?

Hermex is a thin client over [hermes-webui](https://github.com/nesquena/hermes-webui),
so a fair share of apparent app bugs are really server bugs. Before filing a
bug here, reproduce it in the hermes-webui **web UI** against the same server:

- **Breaks in the web UI too** → it's a server bug. File it
  [upstream](https://github.com/nesquena/hermes-webui/issues); if the app
  should still handle it more gracefully, open an issue here that links the
  upstream ticket (we track those with the `upstream-change` label).
- **Only breaks in the app** → file it here with the bug-report form.

## PR workflow

1. **Start from an issue.** Every change should trace to a GitHub issue —
   comment on it so work isn't duplicated, or open one first (bug/feature
   templates are provided).
2. **Branch** from `master` as `issue/<number>-<short-slug>` (e.g.
   `issue/42-fix-session-search`).
3. **Make the change**, keeping these repo hard rules (full list in
   [`AGENTS.md`](AGENTS.md)):
   - **Tolerant decoding:** every `Codable` model uses optionals for fields the
     server might add or rename — never crash on unknown fields.
   - **Never invent API endpoints or JSON shapes** — verify against the pinned
     upstream `hermes-webui` source or your own running server.
   - **No new third-party dependencies** without approval.
4. **Run the full test suite** (command above) and make sure it passes.
5. **Open a PR** against `master` using the PR template — link the issue with
   `Fixes #<number>`, describe what changed and how you tested it. CI must be
   green; automated review bots may comment, and the maintainer reviews and
   merges.
6. **Disclose AI usage** in one line of the PR description: the tool/model
   used (e.g. "built with Claude Code"), or "human-authored". This repo is
   itself built with coding agents, so it's normal context for review — not a
   gate.

`master` is the protected release-candidate branch. Releases and TestFlight
uploads (`.github/workflows/*-testflight.yml`) are maintainer-only operations —
contributors never need App Store Connect access.

## Questions

Ask in [GitHub Discussions](https://github.com/uzairansaruzi/hermex/discussions)
if something here is unclear or wrong — docs fixes are welcome contributions
too.
