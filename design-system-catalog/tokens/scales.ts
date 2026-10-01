/**
 * Numeric scales — spacing, radius, icon size. Values are in px/points (identical on RN and web).
 *
 * Spacing keys mirror a Figma-style scale where the token number ÷ 50 = px (800 → 16). Reference
 * tokens directly at call sites (`DS_SPACING[800]`, `DS_RADIUS.medium`) — the convention every
 * component here follows; the key unions are typo-safe already, so no accessor wrapper is needed.
 */

// ─── Spacing ────────────────────────────────────────────────────────────────
export const DS_SPACING_STEPS = [
  'none',
  100, 200, 300, 400, 600, 800, 1200, 1600, 2000, 2400, 2800, 3200,
] as const;
export type SpacingStep = (typeof DS_SPACING_STEPS)[number];

export const DS_SPACING = {
  none: 0,
  100: 2,
  200: 4,
  300: 6,
  400: 8,
  600: 12,
  800: 16,
  1200: 24,
  1600: 32,
  2000: 40,
  2400: 48,
  2800: 56,
  3200: 64,
} as const;

/**
 * When to reach for each spacing step — grounded in how the existing components actually use them
 * (surveyed across native/components + the source app), not aspirational. Meant to be read by
 * whoever (human or AI) is deciding which step fits a new layout; also rendered in the catalog's
 * Spacing page. When in doubt, reach for 800 first — it's what most components converge on.
 */
export const DS_SPACING_USE: Record<SpacingStep, string> = {
  none: 'Flush — no gap, e.g. an icon glued directly to adjacent content.',
  100: "Micro-gap inside a tightly clustered pair — a ghost button's icon+label, a segmented toggle's track inset/segment gap.",
  200: "Tight gap between closely related elements — a section header's icon+title, a tab's icon+label, a pill's internal gap.",
  300: "A small nudge, rarely needed — e.g. a toast's icon-to-text gap when 200 reads cramped and 400 too loose.",
  400: "Compact standard gap/padding — a status dot to its label, a pill's tight horizontal padding.",
  600: "Medium gap/padding — a nested card's internal gap, a pill row's spacing, a row's horizontal padding.",
  800: "The default — card padding, a button's vertical padding, most rows' gap. Reach for this first.",
  1200: "Large horizontal padding — e.g. a large button's side padding.",
  1600: 'Section-level spacing between stacked blocks on a screen (margin/gap between sections, not inside a component).',
  2000: "A fixed control dimension, not a gap — e.g. an icon-only pill's height.",
  2400: "Bottom padding for a scrollable screen's content.",
  2800: 'Reserved — no current consumer; a step between 2400 and 3200 if both read wrong.',
  3200: 'Large bottom padding for sheets/scroll content that must clear a safe area or tab bar.',
};

// ─── Radius ─────────────────────────────────────────────────────────────────
export const DS_RADIUS_STEPS = ['none', 'xs', 'small', 'medium', 'large', 'round'] as const;
export type RadiusStep = (typeof DS_RADIUS_STEPS)[number];

export const DS_RADIUS = {
  none: 0,
  xs: 4,
  small: 8,
  medium: 12,
  large: 24,
  round: 999,
} as const;

/**
 * When to reach for each radius step — grounded in how the existing components actually use them
 * (surveyed across native/components), not aspirational.
 */
export const DS_RADIUS_USE: Record<RadiusStep, string> = {
  none: 'Flush corners — no rounding.',
  xs: "Small corner softening — a banner's small action button, tiny placeholder blocks.",
  small: "Compact rounding — a ghost button, a text-shimmer placeholder, UnderlineTabs' sliding indicator.",
  medium: "The default card/field radius — Banner's callout, FieldContainer's input chrome, Toast, a container shimmer.",
  large: "Prominent rounding for large surfaces — Dialog, BottomSheet's top corners.",
  round: "Fully circular/pill — Button, Pill, Badge, Status dot, SegmentedToggle's track/thumb. Reach for this on anything meant to read as a chip, dot, or pill.",
};

// ─── Icon size ────────────────────────────────────────────────────────────────
/**
 * Icon sizes pair with text scales — use the same step as the text beside the icon.
 *   xxs (12) tight badges · xs (14) small label rows · sm (16) standard inline (default)
 *   md (20) prominent inline / tabs · lg (24) nav / actions · xl (32) section leads · 2xl (40) hero
 */
export const DS_ICON_SIZE_STEPS = ['xxs', 'xs', 'sm', 'md', 'lg', 'xl', '2xl'] as const;
export type IconSizeStep = (typeof DS_ICON_SIZE_STEPS)[number];

export const DS_ICON_SIZE: Record<IconSizeStep, number> = {
  xxs: 12,
  xs: 14,
  sm: 16,
  md: 20,
  lg: 24,
  xl: 32,
  '2xl': 40,
} as const;

// ─── Accessibility ──────────────────────────────────────────────────────────────
/**
 * Minimum tappable width/height (iOS's own 44pt guideline) — every control smaller than this pads
 * its touch target out to it via `hitSlop` (small controls: Checkbox, Radio, Switch) or `minHeight`
 * (row-shaped controls: ListItem, SegmentedToggle, UnderlineTabs, TopNav's icon slots), rather than
 * each one hardcoding the number `44` independently.
 */
export const DS_A11Y_MIN_TOUCH_TARGET = 44;
