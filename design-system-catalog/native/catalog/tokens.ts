/**
 * Catalog-only design tokens.
 *
 * Deliberately independent of any host app's design-system tokens — the catalog is a tool for
 * *documenting* a design system, not a consumer of it. Keeping its own chrome on its own tokens means:
 *   1. A change to the host app's tokens never accidentally changes how the catalog looks.
 *   2. This whole `catalog/` folder can be copied into a different app's repo and used to
 *      document that app's components without importing host-specific values.
 *
 * Every catalog-chrome font size (headings, labels, prop tables, nav, notes) should draw from
 * CATALOG_TYPE. The one exception is intentional: a section that renders a host app's own
 * typography tokens as *data* (e.g. a "Typography" token page) should render those at their real
 * sizes, since the point there is to show the actual values, not the catalog's chrome.
 */

export const CATALOG_TYPE = {
  xs: 10,
  sm: 12,
  md: 14,
  lg: 16,
  xl: 20,
  '2xl': 24,
  '3xl': 32,
  '4xl': 40,
} as const;

export const CATALOG_SPACE = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  '2xl': 32,
  '3xl': 40,
} as const;

export const CATALOG_RADIUS = {
  sm: 8,
  md: 12,
} as const;

/** A regular max website content width — shared by `CatalogShell`'s page container and
 *  `SectionBlock`'s own column row, so the two can't drift apart (a page container narrower than
 *  this would just clip SectionBlock's row; a SectionBlock row wider than this would look
 *  inconsistent with everything else on the page). */
export const CATALOG_MAX_CONTENT_WIDTH = 1200;

/** Hermex's main canvas can present up to three ordinary 402px specimens with two 40px
 *  (CATALOG_SPECIMEN_GRID_GAP) gaps. The extra 130px accounts for the desktop page inset (48px on
 *  each side) plus the Hermex card's 16px inset and 1px border on each side. Retained
 *  template/framework routes keep the 1200px cap above. */
export const CATALOG_HERMEX_MAX_CONTENT_WIDTH = 1416;

/** The one gap every Variants/States specimen grid uses — SectionBlock's itemized `exampleGrid` and
 *  HermesComponentFamiliesPreviews' custom `PreviewSpecimenGrid` both import this same constant, so
 *  the two catalogs' specimen grids can never drift apart. Resolves to the existing CATALOG_SPACE
 *  `3xl` step (40) rather than introducing a new magic number. */
export const CATALOG_SPECIMEN_GRID_GAP = CATALOG_SPACE['3xl'];

/** Below this viewport width, `CatalogShell`/`CatalogSidebar`/`SectionBlock` switch from the fixed
 *  240px-sidebar-plus-two-column desktop layout to a stacked narrow layout: the sidebar becomes a
 *  bounded, non-sticky top region, the main column's horizontal padding shrinks, and each section's
 *  visual-example and reference-content columns stack vertically instead of sharing one row. Chosen
 *  as a standard tablet-and-below cutoff — comfortably above phone widths (~390px) that hit this
 *  bug, comfortably below the 1200px desktop content cap so desktop is never affected. */
export const CATALOG_NARROW_BREAKPOINT = 768;

/** When to reach for each catalog-chrome type size — grounded in how the framework's own eleven
 *  files actually use them (not aspirational). Rendered in the Design System DS Catalog's Type
 *  Scale page. */
export const CATALOG_TYPE_USE: Record<keyof typeof CATALOG_TYPE, string> = {
  xs: "Smallest chrome text — an uppercase block label, a prop's type annotation, a sidebar group label.",
  sm: "Default chrome body size — prop names/descriptions, sidebar nav labels, a section's file-path chip, a note's body.",
  md: "Slightly larger body text — the search input's typed text, the page subtitle line.",
  lg: 'Prominent chrome text — the sidebar logo, the search-clear (×) glyph.',
  xl: 'Reserved — no current consumer; a step between lg and the section title if one is ever needed.',
  '2xl': "A section's own component title — the heading above each documented component.",
  '3xl': "The catalog's page title — the big heading at the top (e.g. \"Component Catalog\").",
  '4xl': 'Reserved — no current consumer; the next step up from the page title if a bigger heading is ever needed.',
};

/** When to reach for each catalog-chrome spacing step — same grounding approach as
 *  CATALOG_TYPE_USE. Rendered in the Design System DS Catalog's Spacing page. */
export const CATALOG_SPACE_USE: Record<keyof typeof CATALOG_SPACE, string> = {
  xs: "Tight gap — e.g. TokenRow's own internal gap between a token's rendered value and its use-note.",
  sm: "Small gap/padding — e.g. a section's description bottom margin, a block label's bottom margin.",
  md: "Medium padding — e.g. a card's own internal gap between its contents, TokenRow's divider bottom padding.",
  lg: "The default — a section's card padding, the sidebar's horizontal content padding, and the gap between rows in a token-scale gallery (SpacingScaleGallery/TypeScaleGallery).",
  xl: 'Gap between individual examples inside a Variants/States card, and DividedStack\'s default divider gap.',
  '2xl': "Gap between a section's major columns (Variants, States, Props+Accessibility), and between Props and Accessibility within that shared column.",
  '3xl': 'Reserved — no current consumer in the framework chrome.',
};

// Neutral greyscale + one accent, used only for the catalog's own chrome (sidebar, headings,
// prop tables, cards). Not meant to represent the host design system's palette.
//
// Two text tiers, not five: `text` covers both headings and primary content (the former separate
// `ink`/`text` values were visually indistinguishable — #000000 vs #171717 — so one token does both
// jobs). `textMuted` covers everything secondary — captions, type annotations, empty-state copy — down
// to its floor. A former third `textFaint` step (#9c9c9c) was dropped: at ≈2.75:1 on this file's white/
// surfaceMuted backgrounds it failed WCAG AA everywhere it was actually used for real text, and there's
// no meaningfully-lighter grey that both reads as "fainter" and still clears 4.5:1 on white.
export const CATALOG_COLOR = {
  text: '#000000',
  // #666666, not the previous #737373 — muted chrome text sits on every one of this file's surfaces,
  // and #737373 failed WCAG AA on two of them (≈4.35:1 on pageBackground, ≈4.09:1 on chip; the bar
  // for this 10-14px text is 4.5:1). #666666 clears it on all four (white ≈5.7:1, surfaceMuted
  // ≈5.5:1, pageBackground ≈5.3:1, chip ≈5.0:1).
  textMuted: '#666666',
  border: 'rgba(0,0,0,0.08)',
  borderHairline: 'rgba(0,0,0,0.1)',
  surface: '#ffffff',
  surfaceMuted: '#fafafa',
  surfacePressed: '#f0f0f0',
  // The page backdrop behind the (white) sidebar and (surfaceMuted) content cards — one step darker
  // than both, so the whole page reads as a distinct layer under everything else on it.
  pageBackground: '#f5f5f5',
  // Fill for a small inline tag/chip of static text (e.g. a section's file-path chip) — darker than
  // surfacePressed since it's a permanent label, not a hover/press feedback state.
  chip: '#eeeeee',
  accent: '#2563eb',
  code: 'Menlo',
} as const;
