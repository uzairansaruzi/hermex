# When to use X vs Y (Hermex)

This is a decision **guide**, not the source of truth. Every current Hermex catalog entry — a
token group, material, native-iOS pattern, component, or pattern — carries its own structured
decision contract in `native/catalog/hermes/hermesSections.tsx` (the `hermesReference` field on its
`SectionDef`, typed in `native/catalog/types.ts`):

- **`useWhen`** — the deciding condition under which to reach for this entry.
- **`avoidWhen`** — the deciding condition under which it's the wrong choice, even if it looks
  applicable at a glance.
- **`alternatives`** — structured `{ name, useWhen }` entries naming what to reach for instead, and
  under what condition — never a single prose blob.
- **`adoptionStatus`** — a closed-vocabulary state (`foundation-available`, `production-adopted`,
  `partially-adopted`, `native-platform`, or `reference-only`) plus truthful plain-English detail,
  so a choice between two entries also accounts for which one is actually shipping today.

Those four fields render live in the catalog under the exact labels **Use when** / **Avoid when** /
**Alternatives** / **Adoption status** (`HermesReferenceDetails`), and the same facts are available
as plain JSON from the catalog's own machine-readable manifest (`HermesOverview` → "Machine-readable
manifest", built via `buildHermesManifestEnvelope()` wrapping the shared `buildComponentManifest()` in
`native/catalog/manifest.ts`) for a tool or agent instead of a human. Every entry's `hermesReference`
also carries `canonicalSymbols` (the native Swift symbols to search for), at least one Swift
`usageExamples` entry, explicit `compositionSlots`/`compositionConstraints`, and — for a Foundations
token group — structured `tokenFacts`, so an agent can select and compose an entry from the manifest
alone. That manifest is checked in, generated, at `design-system-catalog/hermex-manifest.json`
(regenerate with `node scripts/generate-hermex-manifest.mjs`; `--check` is what CI runs), and the
repo-root `scripts/design-system-guide` reads only that file to answer a ranked lookup, an exact
`--select`, and a structured decision `receipt` — see "Checking a decision mechanically" below.
Read an entry's own fields there before guessing from its name or
description alone — this file exists to explain *the decision model*, not to duplicate every entry's
prose.

## The decision model in practice

A few representative, real Hermex disambiguations — read as examples of how `useWhen`/`avoidWhen`/
`alternatives` combine, not as the complete list (every entry's own fields are the complete list):

- **Toast vs Banner** — both are transient/persistent status surfaces. Toast is a one-off
  confirmation the caller dismisses after a short interval — it has no internal timer or
  auto-dismiss (HermexToast.swift), so the caller's own binding is what clears it; Banner stays
  in-flow until the condition it describes resolves. Reaching for the wrong one shows either a
  message that never clears, or a persistent condition that silently disappears. The native
  HermexBanner (HermesMobile/Features/Shared/HermexBanner.swift) takes an independently
  caller-optional `title` and `description` — at least one is required, and omitting one is a
  content choice, not an interactive collapse/disclosure state. It remains foundation-available
  with zero production call sites in this branch; the catalog's description-only composer-style
  specimen demonstrates valid composition without claiming that ChatComposerView.swift or another
  production surface has adopted it.
- **Checkbox vs Radio vs Segmented Control** — Checkbox records an independent multi-select fact;
  Radio is one-of-many exclusive selection; Segmented Control is also exclusive selection, but as a
  primary, prominent view switch rather than a list-style choice. Picking Checkbox for exclusive
  selection lets two conflicting states coexist; picking Radio for an independent fact silently
  un-checks a sibling the user meant to keep checked.
- **Tag vs Buttons** — Tag is always display-only, never tappable; a tappable element uses a real
  control or link component (Buttons), never Tag or tag-like styling. Styling a tappable element
  like a Tag (or vice versa) breaks the affordance VoiceOver and sighted users both rely on.
- **Card vs Transcript Log Row vs Hermes Tooltip vs Accordion List** — all show supplementary
  detail, differing in how much and how persistently. Card is a standalone, always-visible surface;
  Transcript Log Row (the real, production-adopted `TranscriptLogRowView`) is one collapsed line
  with a summary, an optional trailing detail/accessory (placed trailing before the chevron at
  ordinary Dynamic Type sizes, and below the summary/detail at accessibility sizes — fold its
  meaning into the caller's `accessibilityLabel`, since the row ignores its child accessibility
  semantics), optional status, and copy-on-long-press that expands into a bounded, scrollable
  detail body; Hermes Tooltip is a tap-triggered aside anchored to a control; Accordion List is a
  *collection* of independently expandable `ListItem` rows, not a single expandable surface — reach
  for it over Transcript Log Row specifically when the pattern repeats across a list, not for one
  status line.
- **List / ListItem vs Hermes Card** — a homogeneous set of peer rows (settings, search results,
  sessions) is List/ListItem, which supplies the shared surface and dividers; a standalone
  self-contained unit sitting alongside differently-shaped content is a Card.
- **Dialog vs Bottom Sheet** — both are Hermex-owned custom-presented surfaces, but for opposite
  jobs. Dialog (`HermexDialog`) is an always-centered, fully custom modal for a short, focused
  interruption or confirmation — it never scrolls, never accepts text input, and its dimmed
  backdrop never dismisses it. The component always supplies the standard close button and
  accessibility Escape; the caller supplies the footer actions. Bottom Sheet (`HermexBottomSheet`) is content supplied to native
  `.sheet` for forms, editable content, or a longer workflow that may need to scroll — the caller
  keeps owning `.sheet` itself, including its dismiss policy. Reaching for Dialog with form fields or
  long content forces content past the point Dialog is contracted to stay short; reaching for Bottom
  Sheet for a one- or two-action confirmation loses Dialog's forced-attention, non-dismissible
  backdrop.
- **Popover Menu vs Dialog vs Bottom Sheet vs Hermes Selection Sheet** — Popover Menu
  (`HermexPopoverMenu`) is immediate-action-only: a short list of simple, anchored actions on a
  trigger (a row's "…" overflow) that run once and dismiss — it is always trigger-anchored, flips
  above/below to stay on screen, and clamps horizontally inside the safe area, with no nested
  submenus, toggles, or persistent selection model of its own. Route any persistent selection to a
  caller-presented Hermes Selection Sheet or a dedicated picker sheet instead. Dialog is for a
  full-attention modal decision the user must resolve before continuing, not a trigger-anchored
  action list. Bottom Sheet is for forms, editable content, or a longer scrolling workflow — Popover
  Menu never scrolls past its own bounded action list and never accepts text input. Reaching for
  Popover Menu with more than a handful of simple actions, or with a decision needing the user's
  full attention, belongs on Dialog or Bottom Sheet instead.
- **Text Input's Default, Password, and Code variants** — Text Input has exactly three approved
  variants, Default, Password, and Code: `HermexTextField` is Default, `HermexSecureField` is
  Password, and `HermexCodeInput` is Code, each forwarding to exactly one native editor. Code takes
  a 4–8 digit caller-owned string, supports paste and one-time-code autofill, and never submits on
  its own — the caller decides when to act on a complete code.
- **Composer Toolbar** — `HermexComposerToolbar` is a new, foundation-available Components entry
  with zero production adoption: the current Chat/Bots composer toolbars keep their own separate,
  unmigrated `ComposerToolbarScroller` unchanged. It is one ordered, zero-or-more arbitrary-content
  slot — not a button-only concept — laid out in one horizontally scrollable row (elevated or
  transparent appearance), mixing generic views, controls, and display-only content (e.g. a Tag)
  freely; it never owns a Send/Stop-style action. The elevated appearance's radius is the explicit
  `HermesRadius.r24` token, and its all-around padding is `HermesSpacing.s8`.
- **Composer Chip** — documented inside the Composer pattern, not as a standalone component: it is
  production's real, already-adopted inline text-embedded reference subsystem
  (`ComposerChipToken`/`ComposerChipRendering`/`ComposerChipTextView`) for a recognized skill,
  workspace file, bot mention, or quote rendered inline with editable/transcript text. There is no
  standalone chip component to adopt — every reference renders through one uniform chip image today.
- **Native iOS patterns (Search) vs a Hermex-owned wrapper** — Hermex intentionally keeps some
  surfaces on the platform primitive (`.searchable`) rather than a custom component. Their
  `adoptionStatus` is `native-platform`, not `foundation-available` — there is no Hermex-owned
  alternative to adopt later, by design.

## Checking a decision mechanically

Before adding a new frontend literal, a new/customized component, or a lookalike of an existing one,
run `scripts/design-system-guide` (repo root) against the checked-in `hermex-manifest.json`:

```sh
scripts/design-system-guide "exclusive selection"                 # ranked human-readable lookup
scripts/design-system-guide --json "exclusive selection"          # same, machine-readable
scripts/design-system-guide --select "Hermes Radio"               # exact entry by id or display name
scripts/design-system-guide receipt \
  --query "exclusive selection" --select "Hermes Radio" \
  --reject "Segmented Control::Use for compact two-to-five option switching, not a longer form group." \
  --new-component no \
  --new-component-reason "Hermes Radio already models one choice from a mutually exclusive group."
```

The `receipt` subcommand's output — query, selected entry, every rejected alternative with a reason,
and whether a new token/component is actually needed — is what goes in the owning issue/PR/handoff
(see `AGENTS.md` § Design System). It is evidence a decision was checked against the catalog, not an
automatic approval gate: nothing blocks on it, and the maintainer can still override it.

## Reading an entry's `adoptionStatus`

Before recommending a component, check whether it is actually shipping. `foundation-available` means
the Swift exists and is tested but no production screen calls it yet — treat any "used in" screen
name in that entry as relevant *context* for how it would compose, never as a current production
call site. `production-adopted` and `native-platform` are real, current production behavior.
`partially-adopted` means part of the entry is adopted and part is not — read the `detail` string to
find out which part is which before making a claim either way. `reference-only` marks a
target-architecture/documentation pattern with no adoption claim to make.
