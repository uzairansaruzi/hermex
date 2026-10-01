# Hermex Design System Catalog

This is the **Hermex in-repository Design System catalog**, versioned at `design-system-catalog/`
in the [Hermex](https://github.com/uzairansaruzi/hermex) repository — it is not maintained
separately. See [`DEVELOPMENT.md`](../DEVELOPMENT.md#design-system-catalog) for install/test/
typecheck/launch commands, and [`CONTRIBUTING.md`](../CONTRIBUTING.md) for when a PR must update it.

The catalog wraps a reusable **React Native / Expo** design-system starter — one token layer
feeding a native component tree, plus a browsable catalog.

Drop it into a new project, rebrand the tokens, and build.

```
design-system-template/
├── tokens/          ← ONE source of truth (colors, spacing, radius, type, shadow). Platform-neutral.
│   ├── palette.ts       raw color scale (0–800 per hue)
│   ├── semantic.ts      role tokens (surface / text / emphasis / shade / border …)
│   ├── scales.ts        spacing · radius · icon-size
│   ├── typography.ts    type scale + font weights
│   ├── shadow.ts        elevation (RN style objects)
│   └── index.ts         barrel
├── icons/           ← shared SVG path DATA + the native renderer
│   ├── paths.ts         platform-neutral icon geometry
│   ├── types.ts         IconName union
│   ├── Icon.native.tsx  react-native-svg renderer
│   └── index.ts         barrel (data + types only)
├── native/          ← React Native / Expo components + catalog
│   ├── components/…     one folder per component (Component.tsx, .types.ts, index.ts)
│   └── catalog/         app-agnostic catalog framework (RN) + CatalogExample.tsx
└── native-preview/  ← dev-only Expo shell for browsing the catalog in a browser (not part
                        of the reusable template — see "Browsing the catalog" below)
```

## Picking the right component

Several template components look alike but solve different problems (InputField vs. SearchField vs.
Dropdown, Toast vs. Banner, Dialog vs. BottomSheet, …). Each one's own `whenToUse` field (rendered
as its "VS" disambiguation note in the catalog header) names the deciding question against its
closest look-alike. For a component's exact props/variants/states as structured data (not prose),
see `native/catalog/manifest.ts`'s `buildComponentManifest()`, also rendered live at the template
catalog's (`?catalog=template`) own "Manifest" page. **[WHEN_TO_USE.md](./WHEN_TO_USE.md)** is the
Hermex catalog's own decision guide — see the section below.

## The one rule

**Components consume _semantic_ tokens, never raw hexes or magic numbers.** That is what makes a
rebrand a two-file edit. Read tokens directly: `import { DS_SEMANTIC } from '.../tokens'`.

## Peer dependencies

`react`, `react-native` assumed, plus: `react-native-svg` (icons + LoadingCircle),
`react-native-safe-area-context` (catalog shell only — not required by the components themselves).

## Rebranding (make it yours)

1. **Palette** — edit `tokens/palette.ts`: swap the six hue scales for your brand's (keep the 0–800
   shape).
2. **Semantic** — in `tokens/semantic.ts`, re-point any role you want to shift (e.g. make `emphasis.info`
   your brand blue). Every component re-themes automatically.
3. **Type** — adjust `tokens/typography.ts` (sizes/weights) and set your font family at the app root.

Nothing else needs touching — components reference roles, not values.

## Using the components

```tsx
import { Button } from '@ds/native/components/Button';
import { Badge } from '@ds/native/components/Badge';

<Button label="Save" variant="primary" onPress={save} />
<Badge variant="positive" label="On time" leadingIcon="check" />
```

## Browsing the catalog

`native/catalog/` is a framework-only package (`CatalogShell`, `SectionBlock`, `PropsTable`, …) —
it has no runnable app of its own. It ships two worked examples, both built the same way (drop
either behind a dev-only route in your Expo app):

- `native/catalog/CatalogExample.tsx` — **"Native App DS Template"**: documents this template's own
  DS components (Button, Card, Banner, …).
- `native/catalog/CatalogFrameworkExample.tsx` — **"Design System DS Catalog"**: documents the
  catalog framework's own eight pieces (`CatalogShell`, `CatalogSidebar`, `CatalogSearchInput`,
  `SectionBlock`, `PropsTable`, `VariantGroup`, `TokenRow`, `DividedStack`) plus its own
  Colors/Spacing/Type Scale token pages (`native/catalog/tokens.ts` — `CATALOG_*`, independent of
  the host app's DS tokens) — a catalog of the catalog tool itself, useful when you're extending the
  framework rather than the DS. `SectionBlock` renders one of two fixed layouts: a component section
  (title, description, file path, then two columns — a wide primary column stacking Variants above
  States / Configurations, and a narrow secondary column stacking Props above Accessibility. A block
  with nothing to show displays a plain sentence like "No additional states documented." instead of
  silently disappearing) or a `tokenGallery` section (a single "Tokens" column only — Colors/Spacing/
  Type Scale below are raw token data, not a component with its own states/props/accessibility to
  document, so those columns are skipped entirely rather than padded with "nothing to show" text).
  Whichever column is tallest sets the row's height, and the other column's final card stretches to
  match, so both bottom edges land flush; the same gap value is used between columns and between the
  stacked blocks within each column. Every individual variant/state item is
  captioned with its own `name` (e.g. "Primary", "Icon-only") so it's clear which value each instance
  demonstrates. `VariantGroup`/`DividedStack` aren't used by either layout (each slot gets its own
  card, so there's no in-card divider to draw) — they're still exported building blocks for a
  `render()` that needs an inline sub-heading or a divided list, like `ColorsGallery`'s own two
  swatch groups.

```tsx
import { CatalogExample } from '@ds/native/catalog/CatalogExample';
// or: import { CatalogFrameworkExample } from '@ds/native/catalog/CatalogFrameworkExample';
// e.g. render one from a `?ds=1` dev route, mirroring the pattern this template's source project used.
```

For a quick browser preview without a host app, see `native-preview/` — a minimal throwaway Expo
shell (not part of the reusable template) that renders all three catalogs via `npm run web`
(`expo start --web --port 8096`):
- `http://localhost:8096/` → **HermesDesignSystemCatalog** ("Hermex Design System") — the default route
- `http://localhost:8096/?catalog=template` → CatalogExample ("Native App DS Template", untouched)
- `http://localhost:8096/?catalog=framework` → CatalogFrameworkExample ("Design System DS Catalog")

## Hermex Design System catalog

`native/catalog/hermes/` documents the SwiftUI production app in this same repository
(`HermesMobile/`) — it is **not** part of the reusable template above, and it is the catalog's
**default route** (`http://localhost:8096/`). It reuses the catalog's React Native framework purely
as a documentation shell:

- `native/catalog/hermes/hermesSections.tsx` — the source of truth: `HermesOverview` (the
  intro/status callout, including the machine-readable manifest disclosure — see below) plus one
  `SectionDef` per Hermex-sourced entry (token group, material, native-iOS pattern, component, or
  pattern). Every entry carries `hermesReference` metadata (`native/catalog/types.ts`) — real
  verified destinations (`usedIn`) render on the entry's own main-canvas **Screens** card (screen
  name and navigation path only — never `effect`, a screenshot, or a fixture), with the exact copy
  `No production screens use this yet` when none are verified. The rest of the decision contract
  (`useWhen`, `avoidWhen`, a structured `alternatives` list, a closed-vocabulary `adoptionStatus`),
  `Props`, `Accessibility`, `Source`, and `Implementation notes` render in the one shared
  **Details inspector** every section header's single `Details` button opens — a 600px right-edge
  overlay (`CatalogDetailsInspector`, owned by `CatalogShell`) that never reflows the main canvas —
  in that exact flat order, via `HermesReferenceDetails`. Neither the main canvas nor the inspector
  repeats the other's content.
- `native/catalog/hermes/hermesTokenProposal.ts` — a separate, catalog-only **normalized token
  proposal** (approved 2026-09-18): consolidated motion primitives/bundles and spacing/radius/icon/
  control/stroke/layout scales Hermex's production Swift has not adopted — nothing here is imported
  by, or claims to describe, production Swift. Plain typed data only, no React UI.
- `native/catalog/hermes/HermesTokenProposalGalleries.tsx` — renders that proposal data through the
  same original template building blocks as the catalog's own token pages — `TypeScaleGallery`,
  `Swatch`, `TokenRow`, `VariantGroup`, `DividedStack`, `SpacingScaleGallery` — via the existing
  `tokenGallery`/`fullWidthLabel` seams on `SectionDef`. Every still-proposed value is visibly
  labeled "Proposed — not yet adopted".
- `native/catalog/hermes/HermesDesignSystemCatalog.tsx` — renders `hermesSections`/`hermesNav`
  directly through `CatalogShell`, under the five approved sidebar groups, in order: **Foundations**
  (the token galleries — Colors, Spacing, Typography, Font, Motion, Radius & Geometry, Shadow,
  Iconography), **Materials** (Adaptive Glass), **Native iOS** (TopNav),
  **Components** (alphabetized by display name — including Search, Text Input, Transcript Log Row,
  and the new zero-adoption Composer Toolbar), and **Patterns** (Content Unavailable, Pending
  Request, Transcript Activity, Composer). It never imports or merges the retained template
  catalog's own `sections`/`nav` — those stay fully intact on the separate `?catalog=template` route.
  There is no separate Overview or disposition-named sidebar group; `HermesOverview` renders once,
  above the first group, via `CatalogShell`'s optional `intro` slot instead. The default route has
  no sidebar Manifest entry — the machine-readable manifest lives inside `HermesOverview`'s own
  "Machine-readable manifest" disclosure instead (see below).
- **Machine-readable manifest** — every entry above, including every Foundations token gallery, is
  also available as plain JSON: `buildHermesManifestEnvelope(hermesSections, hermesNav)` in
  `native/catalog/manifest.ts` — a thin, always-`includeTokenGalleries`-on wrapper around the shared
  `buildComponentManifest()` that also states the catalog's one runtime-truth fact once
  (`HERMES_MANIFEST_RUNTIME`: production is SwiftUI, this catalog is a React Native documentation
  reconstruction) — rendered live (so it can't drift out of sync) behind `HermesOverview`'s own
  "Machine-readable manifest" disclosure. Each entry carries its own `useWhen`/`avoidWhen`/
  `alternatives`/`adoptionStatus`, non-empty `canonicalSymbols` and `usageExamples`, explicit
  `compositionSlots`/`compositionConstraints`, and — for a Foundations token group — structured
  `tokenFacts`, so a tool or agent gets the same decision contract a human reader sees, without
  guessing from prose. The template route's own
  Manifest entry (`?catalog=template` → "Reference" group) keeps its separate, component-only,
  token-galleries-excluded default — `includeTokenGalleries` is opt-in, so that entry's existing
  shape never changed.
- **Checked-in generated manifest + lookup/receipt CLI** — `hermex-manifest.json` (this directory)
  is a deterministic, generated snapshot of that same `buildHermesManifestEnvelope(hermesSections,
  hermesNav)` call, produced by `scripts/generate-hermex-manifest.mjs` (loads the real `.tsx`/`.ts`
  source through the `typescript` package already vendored under `native-preview/node_modules`, no
  new dependency, never renders UI) so a tool/agent can read the catalog's decision contract without
  running Expo or parsing TSX. Regenerate it with `node scripts/generate-hermex-manifest.mjs` in the
  same PR as any `hermesSections.tsx`/`types.ts`/`manifest.ts` change; `--check` fails nonzero (and
  is what PR CI runs) when the checked-in file is stale or missing. Never hand-edit the JSON. The
  repo-root `scripts/design-system-guide` (Python, stdlib only) reads only that file to answer
  `scripts/design-system-guide "<query>"` (ranked lookup, `--json` for machine-readable), `--select
  "<id or display name>"` (exact lookup), and `receipt --query ... --select ... --reject
  "<name>::<reason>" --new-component yes|no --new-component-reason "<reason>"` (a structured decision
  receipt to paste into an issue/PR/handoff — see `AGENTS.md` § Design System).

Hermex is SwiftUI; every live example in this catalog is an explicitly-captioned RN documentation
reconstruction of that SwiftUI source, not the production runtime. See the catalog's intro callout
(above the first sidebar group) for the branch-status summary, and each entry's own `adoptionStatus`
for that entry's specific, truthful adoption state.

### Running it locally

```sh
cd native-preview
npm install
npm run web          # expo start --web --port 8096 — the default route is the Hermex Design System catalog
```

`npm run web` first runs the icon generator in **best-effort mode** (skipped automatically once
the assets are already on disk — pass `--force` to re-render), which renders the "Hermex
Iconography" page's 202-symbol grid through the real iOS SF Symbols runtime —
`UIImage(systemName:)`, never a substitute icon library — on an iOS Simulator, via
`icon-renderer/` (a hostless SwiftPM XCTest bundle) and `scripts/generate-icon-previews.mjs`,
which extracts the rendered PNGs with `xcresulttool export attachments` into
`native-preview/public/generated-icons/` (gitignored, regenerated on demand, never committed).
Each glyph is one standardized size/weight/color for this catalog overview, not a reproduction of
every production call site's own size, weight, palette, or effects — those remain documented in
that component's own section.

Two ways to run it:

- `npm run web` (best-effort, `--optional`) — if Xcode/iOS Simulator prerequisites aren't
  available on this machine, generation logs one warning and is skipped; Expo still starts, and
  every icon tile falls back to its "Glyph unavailable in browser" text label instead of a PNG. A
  real render/data failure (a compile error, a missing SF Symbol, a wrong or partial glyph count,
  an export failure) is never swallowed by this mode — it still fails the command.
- `npm run generate:icons` (strict, from `native-preview/`) — always requires a working
  Xcode/Simulator toolchain and fails nonzero on any of the failures above, including missing
  prerequisites. Use this to actually produce the PNGs.

The destination Simulator is never hardcoded to one machine's device. Resolution order: an
explicit `HERMEX_ICON_SIMULATOR_UDID` environment variable, otherwise `simctl` discovery of an
available iPhone Simulator, preferring one named `Hermex Design System iPhone 17 Pro` and falling
back to another available iPhone.

### Tests / typecheck / production build

Run from the repo root (`design-system-catalog/`) unless noted:

```sh
# Contract test for the Hermex catalog (Node's built-in test runner — no extra dependency)
node --test test/hermes-catalog.test.mjs

# Typecheck (run from native-preview/; needs a `node_modules` symlink at the repo root — see note below)
cd native-preview && npx tsc --noEmit -p tsconfig.json

# Production web build
cd native-preview && CI=1 npx expo start --web --port 8099 &
curl -s -o dist/bundle.js "http://localhost:8099/index.bundle?platform=web&dev=false&minify=true"
# then stop the server; dist/index.html + dist/bundle.js is the static output.
```

**Known SDK 57 issue:** `npx expo export --platform web` currently fails in this repo's
`native/`-outside-`native-preview/` layout — its one-shot crawl doesn't pick up `metro.config.js`'s
`watchFolders` the way `expo start --web`'s dev server does, so it can't resolve any import that
reaches outside `native-preview/` (reproduced even for the pre-existing, untouched
`CatalogExample` import — not caused by the Hermex catalog code). Until that's fixed upstream, use
the `expo start --web` + `/index.bundle?dev=false&minify=true` route above for a production build.

**`node_modules` symlink:** `native/`'s own components (`import 'react'`, `import 'react-native'`,
…) only have a `node_modules` to resolve against inside `native-preview/`. TypeScript's ancestor
lookup for a file under `native/catalog/hermes/` never reaches `native-preview/node_modules` (a
sibling, not an ancestor), so `tsc` needs a `node_modules` symlink at the repo root (this
`design-system-catalog/` directory) pointing at `native-preview/node_modules`
(`ln -s native-preview/node_modules node_modules`, run once from this directory) before
`npx tsc --noEmit` will resolve those imports. It's a runtime-only seam: gitignored, never
committed, and created fresh each time (locally and in PR CI's Design System Contract job) after
`npm ci`. Metro doesn't need this — its own `metro.config.js` already points
`resolver.nodeModulesPaths` at `native-preview/node_modules` directly.

## Adding a component (the recipe)

Copy the shape of an existing pair, e.g. `native/components/Button/` or `native/components/Badge/`:
- `<Name>.tsx` — `StyleSheet.create`, import tokens from `../../../tokens`, icons from
  `../../../icons/Icon.native`.
- `<Name>.types.ts` — export `<Name>Props` (+ any `<Name>Variant`).
- `index.ts` — re-export.

Then add a `SectionDef` for it (id, path, description, props, a11y, and its content) to
`native/catalog/CatalogExample.tsx`, and to `native/components/index.ts`. `SectionBlock` always shows
four sections — Variants, States, Props, Accessibility — so give it whichever of these two fields
actually apply:
- `variants: { desc?, align?, itemsFill?, items: [{ key, name, node }] }` — one item per prop enum
  value (e.g. every `variant`). If the component has no `variant`-like prop at all, still include one
  item named `"Default"` showing its plain look — the Variants column should never be empty.
- `states: { desc?, align?, itemsFill?, items: [{ key, name, node }] }` — one item per meaningfully
  distinct boolean state (`loading`, `disabled`, icon-only, …). Fine to omit if there are none.

Every item's `name` is shown as a small caption under it (e.g. `"Primary"`, `"Icon-only"`) — use the
actual variant/state value, not a generic label. Omitting `states` shows "No additional states
documented." — don't invent items just to fill the column. Set `itemsFill: true` on a slot whose
items are wide, block-level components (Banner, Card, Toast, InputField) rather than small ones meant
to sit centered (Button, Badge, Pill). Reach for `render()` instead of `variants` only when the
content isn't a simple list of instances (a live demo with local state, a wrapping grid); its output
fills the Variants column as-is. For a token-gallery section with no component API at all (raw token
data, not a component — see `ColorsGallery`/`SpacingGallery`/`TypographyGallery`), set
`tokenGallery: true` instead of `props`/`a11y`/`states` — `SectionBlock` then renders a single
"Tokens" column around `render()`'s output and skips States/Props/Accessibility entirely.

## What's included

Tokens · Icons (44) · and generic components:
Button · Badge · Divider · LoadingCircle · Card · NestedCard · SectionHeader · Banner · Status ·
FieldContainer · InputField · TextArea · InputClearButton · SearchField · Pill · PillRow ·
SegmentedToggle · UnderlineTabs · Toast · ProgressDots · Shimmer · Collapsible · AnimatedChevron.

Deliberately **not** included (app/overlay-specific, port per project): gesture bottom sheets, nav
bars, modals, and any domain components. They depend on navigation/gesture stacks that vary by app.

## Porting to another platform later

The token layer (`tokens/`) and icon data (`icons/paths.ts`, `icons/types.ts`) are already
platform-neutral — no React Native or DOM imports. Only `native/` (components + catalog) and the
`Icon.native.tsx` renderer are RN-specific. When you need this design system on another platform
(web, desktop via Tauri/Electron, etc.), that's a translation of `native/` against those same
tokens and icon data — a `web/` (or other) tree was built this way once already for this exact
template and later removed to keep the template single-platform until it's actually needed; ask
for that port again when you're ready rather than maintaining an unused second tree in the meantime.
