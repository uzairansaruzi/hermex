/**
 * Hermex normalized token proposal — approved design, catalog-only.
 *
 * This module holds catalog-only proposal/reference data for token families not yet retired from
 * it. A data block's continued presence here does not, by itself, indicate whether that block's
 * owning family's own catalog section is still presented as unadopted — each family's own
 * catalog-adoption task (e.g. TY-5, MO-3, SR-8) owns that determination independently. Color
 * (family plan 02's CO-3) is the first family to actually retire its own data block from this
 * module, rather than merely stop referencing it; its adopted-state data now lives in
 * `hermesColorCatalogData.ts`. Nothing exported from this file is imported by, or claims to
 * describe, production Swift for the families that remain — it is read only by
 * `HermesTokenProposalGalleries.tsx`. Existing source-backed evidence (HeaderLogoColor,
 * ProjectCreationPalette, ChatMotion, SessionListMotion, the named geometry constants) stays in
 * `hermesSections.tsx`; this module is the separate proposal layer.
 *
 * Spec: `.superpowers/brainstorm/63508-1789748146/2026-09-18-hermex-token-system-design.md`
 */

export type ProposalClassification =
  | 'Current production evidence'
  | 'Proposed — not yet adopted'
  | 'Migration candidate'
  | 'Retained component exception'
  | 'Platform-owned adaptive token';

export interface TokenFact {
  name: string;
  value: string;
  classification: ProposalClassification;
  use: string;
}

// ─── Typography (spec §4) ───────────────────────────────────────────────────

export interface TypePrimitive {
  sizePt: number;
  lineHeightPt: number;
  weights: readonly ['regular', 'bold'];
}

export const HERMES_TYPE_PRIMITIVES: Record<'font.12' | 'font.14' | 'font.16' | 'font.18', TypePrimitive> = {
  'font.12': { sizePt: 12, lineHeightPt: 16, weights: ['regular', 'bold'] },
  'font.14': { sizePt: 14, lineHeightPt: 20, weights: ['regular', 'bold'] },
  'font.16': { sizePt: 16, lineHeightPt: 22, weights: ['regular', 'bold'] },
  'font.18': { sizePt: 18, lineHeightPt: 24, weights: ['regular', 'bold'] },
};

export const HERMES_TYPE_PREVIEW_DISCLAIMER =
  'The web catalog renders the same numeric CSS pixel values only for relative preview — this is not a physical point-to-pixel conversion.';

export interface TypeAlias {
  primitive: keyof typeof HERMES_TYPE_PRIMITIVES;
  weights: readonly ['regular', 'bold'];
}

export const HERMES_TYPE_ALIASES: Record<
  'type.caption' | 'type.footnote' | 'type.subtext' | 'type.body' | 'type.headline' | 'type.title.4',
  TypeAlias
> = {
  'type.caption': { primitive: 'font.12', weights: ['regular', 'bold'] },
  'type.footnote': { primitive: 'font.12', weights: ['regular', 'bold'] },
  'type.subtext': { primitive: 'font.14', weights: ['regular', 'bold'] },
  'type.body': { primitive: 'font.16', weights: ['regular', 'bold'] },
  'type.headline': { primitive: 'font.18', weights: ['regular', 'bold'] },
  'type.title.4': { primitive: 'font.18', weights: ['regular', 'bold'] },
};

export interface TypeTitleAlias {
  sizePt: number;
  lineHeightPt: number;
  weights: readonly ['bold'];
}

/** The retained larger title hierarchy — bold only (spec §4.2). */
export const HERMES_TYPE_TITLE_ALIASES: Record<'type.title.3' | 'type.title.2' | 'type.title.1', TypeTitleAlias> = {
  'type.title.3': { sizePt: 20, lineHeightPt: 25, weights: ['bold'] },
  'type.title.2': { sizePt: 22, lineHeightPt: 28, weights: ['bold'] },
  'type.title.1': { sizePt: 28, lineHeightPt: 34, weights: ['bold'] },
};

export const HERMES_TYPE_MIGRATION = [
  'Caption 12, Caption 2 at 11, and Footnote 13 consolidate to 12.',
  'Subheadline 15 migrates to Subtext 14.',
  'Body 17 and Callout 16 consolidate to Body 16.',
  'Headline 17 semibold migrates to Headline 18.',
  'Core 12–18 roles use regular and bold only; medium/semibold remain documented exceptions where removal would change meaning.',
  'Fixed .system(size:) calls used for SF Symbols remain outside typography and map to future/current icon sizing.',
] as const;

// ─── Motion (spec §5) ───────────────────────────────────────────────────────

export const HERMES_MOTION_DURATIONS: Record<'0' | '100' | '150' | '200' | '250' | '300', number> = {
  '0': 0,
  '100': 100,
  '150': 150,
  '200': 200,
  '250': 250,
  '300': 300,
};

export const HERMES_MOTION_EASING: Record<'enter' | 'exit' | 'state' | 'spatial' | 'emphasized', string> = {
  enter: 'easeOut',
  exit: 'easeIn',
  state: 'easeInOut',
  spatial: 'smooth(extraBounce: 0)',
  emphasized: 'snappy',
};

export const HERMES_MOTION_PROPERTIES = {
  'motion.opacity.hidden': 0,
  'motion.opacity.visible': 1,
  'motion.scale.press': 0.975,
  'motion.scale.enter': 0.95,
  'motion.distance.short': '8 pt',
  'motion.direction.edge': ['top', 'bottom', 'leading', 'trailing'] as const,
};

export const HERMES_MOTION_SPRINGS = {
  'motion.spring.responsive': { response: 0.30, damping: 0.70 },
  'motion.spring.settle': { response: 0.35, damping: 0.80 },
};

export interface MotionBundleFact {
  durationMs: number;
  easing: keyof typeof HERMES_MOTION_EASING | 'easeOut';
  detail: string;
}

export const HERMES_MOTION_BUNDLES: Record<
  | 'motion.feedback.press'
  | 'motion.state.change'
  | 'motion.content.enter'
  | 'motion.content.exit'
  | 'motion.overlay.enter'
  | 'motion.overlay.exit'
  | 'motion.content.reposition'
  | 'motion.scroll.follow',
  MotionBundleFact
> = {
  'motion.feedback.press': { durationMs: 100, easing: 'state', detail: '0.975 scale' },
  'motion.state.change': { durationMs: 150, easing: 'state', detail: 'color/opacity' },
  'motion.content.enter': { durationMs: 200, easing: 'enter', detail: 'fade + 8 pt slide' },
  'motion.content.exit': { durationMs: 150, easing: 'exit', detail: 'fade + 8 pt slide' },
  'motion.overlay.enter': { durationMs: 250, easing: 'spatial', detail: 'directional overlays use fade + edge move, centered overlays use fade + 0.95→1 scale' },
  'motion.overlay.exit': { durationMs: 200, easing: 'exit', detail: 'directional overlays use fade + edge move, centered overlays use fade + 1→0.95 scale' },
  'motion.content.reposition': { durationMs: 250, easing: 'spatial', detail: 'transform' },
  'motion.scroll.follow': { durationMs: 200, easing: 'easeOut', detail: '' },
};

export const HERMES_MOTION_CURRENT_MAPPING = [
  { current: '100/120', proposed: 100 },
  { current: '150/160', proposed: 150 },
  { current: '180/200/220', proposed: 200 },
  { current: '240', proposed: 250 },
  { current: '280', proposed: 300 },
] as const;

export const HERMES_MOTION_REDUCE_MOTION = [
  'Focus, validation, assistive announcements, and critical state: immediate 0 ms.',
  'Press feedback: 100 ms opacity/color only; remove scale and spring.',
  'Spatial movement: fade or none.',
  'Preserve existing nil/identity semantics where motion is nonessential.',
  'BotFaceMotion remains a specialized component motion system.',
] as const;

export const HERMES_MOTION_DEFERRED = [
  'Do not add 50 ms hover, 400–700 ms interface durations, stagger/delay, haptic, top-level navigation, or character-animation tokens without later evidence.',
] as const;

// ─── Spacing (spec §6) ──────────────────────────────────────────────────────

export const HERMES_SPACING_STEPS = [0, 2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64] as const;
export type HermesSpacingStep = (typeof HERMES_SPACING_STEPS)[number];
export const HERMES_SPACING: Record<HermesSpacingStep, number> = Object.fromEntries(
  HERMES_SPACING_STEPS.map((step) => [step, step]),
) as Record<HermesSpacingStep, number>;
export const HERMES_SPACING_USE: Record<HermesSpacingStep, string> = {
  0: 'No gap.',
  2: 'Hairline-adjacent tight gap.',
  4: 'Tightest real gap between closely related elements.',
  8: 'Small gap/padding.',
  12: 'Medium padding.',
  16: 'Default card/section padding.',
  20: 'Slightly larger section padding.',
  24: 'Gap between major content groups.',
  32: 'Section-to-section spacing.',
  40: 'Large layout spacing.',
  48: 'Extra-large layout spacing.',
  64: 'Largest spacing primitive; values above this remain layout/component geometry.',
};
export const HERMES_SPACING_MIGRATION = ['6/10/14/18/22 migrate by semantic relationship to adjacent approved steps.'] as const;
export const HERMES_SPACING_NOTE = 'Values larger than 64 remain layout or component geometry.';
export const HERMES_SPACING_PREVIEW_NOTE = 'The catalog preview uses the same numeric CSS pixel value.';

// ─── Radius (spec §7) ───────────────────────────────────────────────────────

export const HERMES_RADIUS_STEPS = [0, 4, 8, 12, 16, 20, 24, 'full'] as const;
export type HermesRadiusStep = (typeof HERMES_RADIUS_STEPS)[number];

export const HERMES_RADIUS_ALIASES: Record<'radius.control' | 'radius.field' | 'radius.card' | 'radius.prominent' | 'radius.chrome' | 'radius.pill', number | string> = {
  'radius.control': 8,
  'radius.field': 12,
  'radius.card': 16,
  'radius.prominent': 20,
  'radius.chrome': 24,
  'radius.pill': 'Capsule',
};

export const HERMES_RADIUS_MIGRATION = [
  '3/6/7/9/10 normalize to 4 or 8 according to component role.',
  '12/14 normalize to field 12 or card 16.',
  '16/18/20/22 normalize to card 16 or prominent 20.',
  'Composer 26 normalizes to chrome 24.',
] as const;

// ─── Geometry (spec §8) ─────────────────────────────────────────────────────

export const HERMES_ICON_SIZES = [12, 16, 20, 24, 32] as const;
export const HERMES_CONTROL_SIZES = [32, 40, 44, 48] as const;
export const HERMES_CONTROL_MIN_HIT_TARGET_NOTE = 'A visually compact control must still preserve a 44 pt minimum hit target.';

export const HERMES_STROKES: Record<'stroke.1' | 'stroke.2', string> = {
  'stroke.1': 'default outline',
  'stroke.2': 'emphasized or focus outline',
};

export const HERMES_LAYOUT: Record<'layout.readable.800' | 'layout.readable.1000', string> = {
  'layout.readable.800': 'secondary destination',
  'layout.readable.1000': 'workspace',
};

/** A retained component-content-window exception, not a scale step — do not fold into spacing or
 *  radius. */
export const HERMES_RETAINED_BODY_WINDOW_HEIGHT: TokenFact = {
  name: 'TranscriptLogRowMetrics.bodyWindowHeight',
  value: '240pt',
  classification: 'Retained component exception',
  use: 'Fixed content-window cap an expanded transcript log body scrolls inside.',
};

export const HERMES_GEOMETRY_MIGRATION = [
  'Normalize composer inset 5→space.4 and transcript indent 26→space.24 in the migration map only.',
] as const;

export const HERMES_DEFERRED_FOUNDATIONS = [
  'Elevation/shadow requires a dedicated visual audit of the current ad-hoc calls.',
  'Opacity remains contextual to color/material roles.',
  'Z-index has no demonstrated cross-surface conflict.',
  'Native adaptive layout and readable widths remain preferable to a web-style breakpoint scale.',
] as const;
