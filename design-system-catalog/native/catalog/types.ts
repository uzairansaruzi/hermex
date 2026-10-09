import type React from 'react';

/** One documented prop of a component, shown in its Props table. */
export interface PropDef {
  name: string;
  /** TypeScript type, kept short/readable (e.g. `'primary' | 'secondary'`, `() => void`). */
  type: string;
  /** True when the prop has no `?` in the interface — the caller must pass it. */
  required?: boolean;
  /** The value actually used when the component destructures a default for this prop. */
  default?: string;
  desc: string;
}

/** One individual example inside a variant/state cluster — e.g. one Button instance. */
export interface VariantExample {
  /** React key; keep stable and unique within its group. */
  key: string;
  /** Shown as a small caption under this item — the actual variant/state value it demonstrates
   *  (e.g. "Primary", "Icon-only"), not a generic label like "Example 1". */
  name: string;
  node: React.ReactNode;
  /** Stretch *this item's* wrapper to the row's full width, instead of shrinking to its own content
   *  width — for a single wide-format instance (e.g. a `fullWidth` Button) sitting among otherwise
   *  compact, centered siblings in the same slot. Without this, a `fullWidth`/stretch-based prop on
   *  the instance itself has nothing to stretch into — its wrapper still shrinks to content, so the
   *  instance renders at its natural size regardless of the prop. Independent of the slot's own
   *  `itemsFill` (which applies to every item uniformly); this is a per-item override. @default false */
  fill?: boolean;
  /** Catalog-authored explanation/caption for this instance — rendered only inside its own anchored
   *  Details popover (`CatalogSpecimenHeader`), never inline on the main gallery surface. Optional:
   *  an instance with no explanation renders no Details button at all. */
  description?: React.ReactNode;
  /** Which real prop value(s) this instance demonstrates, e.g. `{ variant: 'primary' }` or
   *  `{ size: 'large', disabled: true }` — mirrors the actual props passed to `node`. Optional and
   *  additive: SectionBlock only cross-checks a section's enum props against this metadata once at
   *  least one item in that section has started tagging them, so annotating is opt-in/gradual rather
   *  than an all-or-nothing migration. Once a section opts in, SectionBlock warns (dev console) about
   *  any enum value from `SectionDef.props` that no tagged item covers — the mechanical version of
   *  the completeness policy documented on `states` below. */
  props?: Record<string, unknown>;
}

/** The content of the "Variants" or "States / Configurations" column — every value of a single prop's
 *  enum, or every distinct boolean/flag state, as individual instances. */
export interface VariantSlot {
  /** @default 'center' */
  align?: 'center' | 'left';
  /** When true, each item stretches to fill the available width instead of shrinking to its own
   *  content width — for wide block-level components (Banner, Card, Toast, InputField) rather than
   *  small instances meant to sit centered (Button, Badge, Pill). @default false */
  itemsFill?: boolean;
  items: VariantExample[];
}

/** One entry in the catalog — a documented component or token group. `TId` is the app's own
 *  union of section ids (e.g. `'Button' | 'Card' | ...'`), so the sidebar/scroll-spy stay typed
 *  to the app's real section list without this file needing to know what they are. */
export interface SectionDef<TId extends string = string> {
  id: TId;
  /** Overrides the text shown as this section's page title and sidebar nav label (default: `id`
   *  itself). Needed when `id` must stay unique across a combined multi-catalog `sections` array
   *  (e.g. disambiguated from an unrelated same-named template entry) but the reader-facing name
   *  should be the plain component name with no disambiguating prefix. */
  displayName?: string;
  description: string;
  path?: string;
  /** One sentence disambiguating this component from its closest look-alike(s) — the deciding
   *  question a reader (human or AI) would otherwise have to guess at when two components could
   *  plausibly fit the same spot (InputField vs SearchField vs Dropdown, Toast vs Banner, …). Omit
   *  for components with no real look-alike. Keep it to the one sentence that actually decides —
   *  the full reasoning lives in the repo's WHEN_TO_USE.md; this is a pointer, not a copy of it. */
  whenToUse?: string;
  /** The component's real prop interface, shown as a table above the live examples. Token/token-group
   *  sections (Colors, Spacing, etc.) have no component props, so this is omitted for those. */
  props?: PropDef[];
  /** What's actually true about this component's accessibility behavior, grounded in its source —
   *  not a generic disclaimer. Say plainly when a component has no explicit handling beyond the
   *  host element's default semantics, rather than inventing coverage that isn't there. */
  a11y?: string;
  /** Every value of the component's primary enum prop (e.g. `variant`), as individual instances —
   *  **including whichever value that prop defaults to** (e.g. Button's Variants starts with
   *  "Primary" since `variant` defaults to `'primary'`; Card's single instance is named "Default"
   *  since it has no enum at all). Never skip the default on the assumption it's obvious from source.
   *  SectionBlock always renders a "Variants" column — omit this and it shows "No variants
   *  documented." instead of just not appearing, so every section has the same fixed shape. If
   *  neither this nor `render` is set, that's what shows; if `render` is set instead, its output
   *  fills this column (for content that isn't a simple list of instances — see `render` below). */
  variants?: VariantSlot;
  /** Every meaningfully distinct boolean/flag state (`loading`, `disabled`, icon-only, …) **and** any
   *  other optional, prop-driven configuration worth showing that isn't the primary enum (an optional
   *  content slot like Banner's `action`/`link`, a structural mode like its status-row layout, …) — the
   *  column is titled "States / Configurations" precisely because not everything that belongs here is
   *  a strict boolean toggle. Two rules, checked against the component's real prop interface (not just
   *  whichever states come to mind):
   *  1. **No real prop left undemonstrated** — every prop that visibly changes the component's look
   *     needs at least one instance somewhere in the section (here or in `variants`). A prop that
   *     only ever appears in the Props table, with no live example anywhere, is a documentation gap.
   *  2. **Show both sides of a toggle, not just the special one** — when a state is one half of a
   *     binary look (icon-only vs. icon+text, disabled vs. enabled, expanded vs. collapsed), include
   *     *both* instances here rather than assuming the reader will cross-reference `variants` for the
   *     baseline. The States / Configurations column should read on its own.
   *  3. **Duplication across columns is fine, and often correct** — don't withhold an instance from
   *     here merely because the same configuration already appears in `variants` (or vice versa). Each
   *     column should be independently complete: a reader looking only at States / Configurations
   *     shouldn't have to flip to Variants (or back) to see the full picture.
   *  4. **A continuous prop (`size: number`, a colour string, …) has no fixed enum to sweep — show an
   *     explicit small / medium / large (or similarly-spaced) trio anyway, and label the one that
   *     matches the component's own default as "Medium" or "Default", even if that same default
   *     value already appears, unlabeled, somewhere else in the section (e.g. an unsized instance in
   *     `variants`). An instance the reader can't identify as "this is what a smaller/larger one looks
   *     like" doesn't count as demonstrating the range — this is the same rule as #3, but continuous
   *     props are exactly where it's easiest to skip a middle value because "the default is shown
   *     elsewhere anyway."
   *  SectionBlock always renders a "States / Configurations" column; omit this and it shows "No
   *  additional states or configurations documented." instead of just not appearing. */
  states?: VariantSlot;
  /** Escape hatch for "Variants" column content that isn't a simple list of instances — token
   *  galleries, live interactive demos with local state, structure diagrams, wrapping grids. Ignored
   *  when `variants` is set. */
  render?: () => React.ReactNode;
  /** Marks this as a token-gallery section (raw token data, not a component with its own API) —
   *  SectionBlock skips the States/Configurations, Props, and Accessibility columns entirely (there's
   *  no component behavior to document) and renders a single column titled "Tokens" instead of
   *  "Variants". */
  tokenGallery?: boolean;
  /** Overrides the `tokenGallery` column's label (default `'Tokens'`) — e.g. `'Preview'` for a page
   *  that's a composed, realistic usage example rather than a list of raw token values. Ignored
   *  unless `tokenGallery` is also set. */
  fullWidthLabel?: string;
  /** Hide specific cards entirely for this section, rather than showing an empty-state placeholder
   *  sentence ("No additional states or configurations documented.", etc.) — for a catalog whose
   *  sections genuinely have no meaningful states/props/accessibility story to tell (e.g. a
   *  framework's own building-block pages). Hidden columns free up the row's width for whatever
   *  remains; if only one column is left standing, it fills the whole row, the same way a
   *  `tokenGallery` section does. */
  hide?: {
    variants?: boolean;
    states?: boolean;
    props?: boolean;
    accessibility?: boolean;
  };
  /** Reference-oriented Hermex metadata — plain-English usage guidance and destinations, shown on
   *  the main canvas (Screens) and in the shared 600px Details inspector (`CatalogDetailsInspector`,
   *  rendered via `HermesReferenceDetails`), never rendered inline on the main canvas itself. */
  hermesReference?: HermesReferenceMeta;
}

/** One real destination in Hermex where a reference entry's token/component actually appears. Only
 *  `screen`/`path` are shown, in the main canvas's Screens card — `effect` is available to the
 *  machine-readable manifest but is not rendered in the catalog UI (main canvas or inspector), to
 *  avoid repeating the same destination fact in two places. */
export interface HermesReferenceDestination {
  /** The user-visible screen name, e.g. "Settings", "Sessions". */
  screen: string;
  /** How to reach it, e.g. "Settings → Appearance". Omit when the screen name alone is enough. */
  path?: string;
  /** What the reader can see there. Manifest-only; not rendered by the catalog UI. */
  effect: string;
}

/** Technical provenance for a Hermex reference entry — rendered as the Details inspector's own
 *  "Source" (sourcePaths) and "Implementation notes" (status/notes) sections, never part of the
 *  main canvas. `sourcePaths` names the native Swift file(s) this catalog entry documents, so a
 *  tool can tell a React Native browser reconstruction apart from the production Swift source it
 *  describes. */
export interface HermesImplementationNotes {
  status?: string;
  sourcePaths?: string[];
  notes?: string[];
}

/** The closed vocabulary for what kind of content one `HermesCompositionSlot` accepts — structured
 *  so a tool can tell a single-value slot (a title, an icon) from a generic, ordered, zero-or-more
 *  content slot (Composer Toolbar's `content`) without parsing prose. */
export type HermesCompositionContentKind =
  | 'text'
  | 'icon'
  | 'control'
  | 'display-only-tag'
  | 'generic-view'
  | 'future-component';

/** The semantic region a composition slot plays within its component's anatomy — closed so a tool
 *  can group or compare slots across different entries (e.g. every entry's leading icon) without
 *  parsing each slot's free-text `description`. */
export type HermesCompositionSlotRole =
  | 'leading-icon'
  | 'leading-accessory'
  | 'leading-action'
  | 'inline-accessory'
  | 'primary-text'
  | 'secondary-text'
  | 'caption'
  | 'metadata'
  | 'body-content'
  | 'header'
  | 'center-content'
  | 'footer'
  | 'trailing-action'
  | 'trailing-accessory'
  | 'trigger'
  | 'surface-content';

/** Who positions a composition slot within its component's layout, and along which axis — e.g. a
 *  component docks a fixed-position action slot at its own trailing edge, versus arranging a
 *  caller-ordered generic content slot along one scrolling axis. */
export interface HermesCompositionSlotLayout {
  /** `'component-fixed'` for a named anatomy position the component itself docks (e.g. Banner's
   *  `icon`); `'caller-ordered'` for a generic slot whose own content order the caller controls
   *  (e.g. Composer Toolbar's `content`). */
  placement: 'component-fixed' | 'caller-ordered';
  /** The axis this slot's own content runs along, when the slot itself arranges more than one
   *  child (e.g. Composer Toolbar's horizontal scrolling row). `'none'` for a single-value slot
   *  with no internal axis of its own. */
  axis: 'horizontal' | 'vertical' | 'none';
  /** Where the component docks this slot relative to its anatomy, in the component's own terms
   *  (e.g. `'leading edge of the header row'`, `'trailing edge'`, `'centered'`) — source-backed,
   *  not a generic guess. */
  position: string;
}

/** How a composition slot's content behaves once it exceeds the space the component gives it —
 *  closed so a tool can tell a slot that scrolls from one that silently clips or truncates,
 *  without parsing prose. `'not-applicable'` is for a slot whose content has no meaningful overflow
 *  behavior (a fixed-size icon, a single fixed-size control). */
export type HermesCompositionOverflow = 'wrap' | 'clip' | 'scroll' | 'truncate' | 'not-applicable';

/** Who drives a composition slot's interaction: the component itself (e.g. Accordion's own
 *  expand/collapse on its `header` slot), each child/caller content independently (e.g. Composer
 *  Toolbar's children), or `'none'` because the slot is non-interactive, display-only content. */
export type HermesCompositionInteractionOwnership = 'component-owned' | 'child-owned' | 'none';

/** Who supplies a composition slot's accessibility label/role/grouping: the component itself
 *  (e.g. Banner hiding a decorative icon from VoiceOver), each child independently (its own default
 *  accessibility stands unmodified), or `'combined-element'` when this slot merges into one larger
 *  combined accessible element together with sibling slots (e.g. Content Unavailable's icon+title+
 *  description). */
export type HermesCompositionAccessibilityOwnership = 'component-owned' | 'child-owned' | 'combined-element';

/** One named content region/slot in a component's composition — e.g. Banner's title/description/
 *  icon/action regions, or Composer Toolbar's single ordered generic content slot. Structured so a
 *  tool can enumerate what a component actually accepts, in what order, who lays it out, how it
 *  behaves on overflow, and who owns what within it — all without parsing prose. */
export interface HermesCompositionSlot {
  /** The region's name, e.g. `'title'`, `'description'`, `'content'`. */
  name: string;
  /** One sentence describing what this region is for. */
  description: string;
  /** Whether a caller must always supply this region on its own — false for a region that is only
   *  conditionally required via a `HermesCompositionConstraint` (e.g. Banner's title/description).
   *  @default false */
  required?: boolean;
  /** How many instances this slot accepts: `'one'` for a single region/value, `'zero-or-more'` for
   *  an ordered list of arbitrary content (e.g. Composer Toolbar's `content` slot). @default 'one' */
  cardinality?: 'one' | 'zero-or-more';
  /** What kind(s) of content this slot accepts, in the closed `HermesCompositionContentKind`
   *  vocabulary — a generic content slot lists every kind it mixes freely (e.g. `['generic-view',
   *  'control', 'display-only-tag', 'future-component']`). */
  acceptedContent: HermesCompositionContentKind[];
  /** This slot's 0-based position in the component's own documented reading/composition order
   *  among its sibling slots — stable so a tool can reconstruct composition order without
   *  re-deriving it from prose. */
  order: number;
  /** The semantic region this slot plays, from the closed `HermesCompositionSlotRole` vocabulary. */
  role: HermesCompositionSlotRole;
  /** Who positions this slot and along which axis — see `HermesCompositionSlotLayout`. */
  layout: HermesCompositionSlotLayout;
  /** How this slot's content behaves once it exceeds its given space — see
   *  `HermesCompositionOverflow`. */
  overflow: HermesCompositionOverflow;
  /** Who drives this slot's interaction — see `HermesCompositionInteractionOwnership`. */
  interactionOwnership: HermesCompositionInteractionOwnership;
  /** Who supplies this slot's accessibility label/role/grouping — see
   *  `HermesCompositionAccessibilityOwnership`. */
  accessibilityOwnership: HermesCompositionAccessibilityOwnership;
  /** Free-text ownership note for a generic/zero-or-more slot where the structured fields above
   *  don't fully capture the parent/child responsibility split — kept alongside, not replaced by,
   *  `interactionOwnership`/`accessibilityOwnership`. Omit for a single-value slot with no such
   *  split to describe. */
  ownership?: string;
}

/** The closed vocabulary for a structured cross-slot composition rule — currently only the
 *  "at least one of these slots must be present" shape Banner's title/description pairing needs.
 *  Closed rather than open-ended prose so a tool can check a proposed composition mechanically. */
export type HermesCompositionConstraintKind = 'at-least-one-of';

/** One structured constraint across a component's composition slots — e.g. Banner's "at least one
 *  of title or description" requirement. Kept structured (not prose) so a tool can check a proposed
 *  composition against it mechanically, referencing slots by `HermesCompositionSlot.name`. */
export interface HermesCompositionConstraint {
  kind: HermesCompositionConstraintKind;
  /** The slot names this constraint governs, by `HermesCompositionSlot.name`. */
  slots: string[];
  /** One sentence stating the constraint in plain English. */
  detail: string;
}

/** One canonical Swift usage example for a Hermex entry — the smallest source-backed snippet an
 *  agent can pattern-match against when deciding how to call the real API. `name` is a stable,
 *  human-readable title (e.g. "Description-only banner"); `code` is Swift reflecting the entry's own
 *  documented prop/initializer shape. Showing a usage example is not a production-adoption claim —
 *  `HermesAdoptionStatus` alone carries that fact. */
export interface HermesUsageExample {
  name: string;
  language: 'swift';
  code: string;
}

/** One JSON-safe behavioral configuration/example descriptor for a Hermex entry whose live catalog
 *  renders through a custom `render()` function rather than data-driven `variants`/`states` — so the
 *  manifest still exposes at least one machine-readable configuration instead of an empty surface,
 *  without the gallery's React elements themselves needing to be JSON-serializable. `props` mirrors
 *  the real prop values the named configuration demonstrates, in the same spirit as `VariantExample.
 *  props` in types.ts above. */
export interface HermesMachineConfiguration {
  name: string;
  description?: string;
  props?: Record<string, unknown>;
}

/** One structured token fact for a Hermex Foundations entry (Colors, Spacing, Typography, Font,
 *  Motion, Radius & Geometry, Shadow, Iconography) — reusing this catalog's own existing typed
 *  token/reference data (e.g. `hermesColorCatalogData.ts`, `hermesTokenProposal.ts`,
 *  `hermesIconSize.ts`) rather than hand-maintaining a second, independent token catalogue.
 *  `purpose` is omitted only when the source data carries no separate purpose/classification beyond
 *  the name/value pair itself. */
export interface HermesTokenFact {
  name: string;
  value: string;
  purpose?: string;
}

/** One alternative to reach for instead of this entry — structured so a human or AI can tell
 *  *what* to choose instead and *under what condition*, rather than a single prose blob a reader
 *  has to parse apart themselves. */
export interface HermesAlternative {
  /** The alternative entry's own display name (e.g. "Hermes Toast", "Native ContentUnavailableView"). */
  name: string;
  /** The deciding condition under which to reach for that alternative instead of this entry. */
  useWhen: string;
}

/** The closed adoption-state vocabulary every Hermex reference entry's `adoptionStatus` must use —
 *  the smallest set that still distinguishes every state this catalog actually needs to tell apart:
 *  - `foundation-available` — implemented in this branch's foundation layer; no production screen
 *    calls it yet.
 *  - `production-adopted` — real, existing, verified production-adopted behavior.
 *  - `partially-adopted` — some real production call site exists, but not the whole family/entry
 *    (e.g. one token consumer while the rest of the scale has none, or an umbrella entry combining
 *    one adopted piece with one unadopted candidate).
 *  - `native-platform` — platform-native iOS behavior intentionally used instead of a Hermex
 *    wrapper; there is no Hermex-owned component to adopt.
 *  - `reference-only` — documentation/reference-only material (a target-architecture pattern, a
 *    catalog-only reconstruction) with no adoption claim to make either way. */
export type HermesAdoptionState =
  | 'foundation-available'
  | 'production-adopted'
  | 'partially-adopted'
  | 'native-platform'
  | 'reference-only';

/** One entry's adoption state, in the closed vocabulary above, plus the truthful plain-English
 *  detail that vocabulary alone can't carry (which files, which screens, what's still missing). */
export interface HermesAdoptionStatus {
  state: HermesAdoptionState;
  detail: string;
}

/** Reference-oriented metadata for one Hermex catalog entry — verified destinations (`usedIn`) drive
 *  the main canvas's Screens card; the decision contract (`useWhen`/`avoidWhen`/`alternatives`/
 *  `adoptionStatus`) plus technical provenance render in the shared Details inspector instead. */
export interface HermesReferenceMeta {
  /** The deciding condition under which a human or AI should reach for this entry. */
  useWhen?: string;
  /** The deciding condition under which this entry is the wrong choice, even though it might look
   *  applicable at a glance. */
  avoidWhen?: string;
  /** Structured alternatives — omit or leave empty only when no other entry genuinely applies;
   *  never populated solely to satisfy a count. */
  alternatives?: HermesAlternative[];
  /** This entry's adoption state in the closed vocabulary, plus truthful detail. */
  adoptionStatus?: HermesAdoptionStatus;
  useSummary?: string;
  usedIn?: HermesReferenceDestination[];
  implementationNotes?: HermesImplementationNotes;
  /** This component's named content regions/slots, structured so a tool can enumerate what it
   *  actually accepts (and who owns what within a generic slot) without parsing prose. Every one of
   *  this catalog's 37 Hermex entries sets this explicitly (enforced by hermes-catalog.test.mjs) — an
   *  empty array for a genuinely atomic/token/native entry with no caller-provided content region,
   *  never an omitted field; kept optional here only because `HermesReferenceMeta` is also reused by
   *  the catalog overview's own non-entry implementation-notes panel (`HermesOverviewImplementationDetails`). */
  compositionSlots?: HermesCompositionSlot[];
  /** Structured cross-slot rules this component's composition must satisfy — e.g. Banner's "at
   *  least one of title or description". Every entry sets this explicitly (see `compositionSlots`
   *  above) — an empty array when there is no such rule, never an omitted field. */
  compositionConstraints?: HermesCompositionConstraint[];
  /** Non-empty list of the native Swift API/type/token/pattern symbols an agent should search for to
   *  find this entry's real implementation — e.g. `['HermexBanner', 'HermexBanner.Action']`. A
   *  platform/reference-only entry names the platform API or documented composition it stands for
   *  instead of inventing a Hermex wrapper (e.g. `['.popover(isPresented:)']` for Tooltip). Required
   *  (non-empty) for every entry, enforced by hermes-catalog.test.mjs. */
  canonicalSymbols?: string[];
  /** At least one concise, source-backed canonical Swift usage example — see `HermesUsageExample`.
   *  Showing usage is not itself a production-adoption claim; `adoptionStatus` carries that fact.
   *  Required (non-empty) for every entry, enforced by hermes-catalog.test.mjs. */
  usageExamples?: HermesUsageExample[];
  /** JSON-safe behavioral configuration descriptors for an entry whose live catalog renders through
   *  a custom `render()` function rather than data-driven `variants`/`states` — see
   *  `HermesMachineConfiguration`. Omit for an entry whose `variants`/`states` arrays already serialize
   *  into the manifest, or whose `tokenFacts` already supplies a machine-readable surface. */
  machineConfigurations?: HermesMachineConfiguration[];
  /** Structured token facts for a Foundations token-gallery entry — see `HermesTokenFact`. Required
   *  (non-empty) for all 8 Foundations entries; omitted for a non-Foundations entry. */
  tokenFacts?: HermesTokenFact[];
}

/** A labeled group of section ids in the sidebar (e.g. "Components" vs "Tokens"). */
export interface NavGroup<TId extends string = string> {
  label: string;
  ids: readonly TId[];
  /** Alphabetize this group's ids by each section's own visible display name (its `displayName`,
   *  falling back to its id) rather than by raw id — for a component-family group where a reader
   *  alphabetizes by the name actually shown, not an internal lookup key. Omit (default false) for
   *  a group with its own intentional, non-alphabetical sequence — a Foundations/token gallery, a
   *  narrative Patterns group, or Native iOS — so `sortIds` keeps sorting by raw id there, unchanged.
   *  @default false */
  alphabetizeByLabel?: boolean;
}

/** THE canonical within-group ordering of section ids — every place that walks a group's ids
 *  (the sidebar's link list, the main column's render order, scroll-spy's offset scan) MUST order
 *  them through this one helper. A previous bug came from exactly this sort being written out
 *  independently in two of those places and drifting: the sidebar's visual order disagreed with
 *  the main column's actual render order, so clicking a link scrolled to the wrong section.
 *  `keyFor` is the sort key for each id — omit it (every existing call site but a group with
 *  `alphabetizeByLabel: true`) to keep sorting by the raw id itself, unchanged. */
export function sortIds<TId extends string>(ids: readonly TId[], keyFor?: (id: TId) => string): TId[] {
  const key = keyFor ?? ((id: TId) => id);
  return ids.slice().sort((a, b) => key(a).localeCompare(key(b)));
}
