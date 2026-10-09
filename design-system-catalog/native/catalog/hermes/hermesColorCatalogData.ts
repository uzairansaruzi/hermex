/**
 * Hermex Design System color-ramp and semantic-color catalog data (accepted into the Design System;
 * the ramps have no production caller yet).
 *
 * Ramp data moved here from `hermesTokenProposal.ts` once family plan 02's CO-1 added
 * `HermesColorRamp` to the app's Swift source (`HermesMobile/Config/HermesColor.swift`, pinned
 * exactly by `HermesColorTests`; no production screen reads it yet) — these 99 values are display data for the accepted `Hermex Colors`
 * catalog page, not a proposal. `hermesTokenProposal.ts` no longer defines or exports any Color
 * data, and this module does not import anything from it — not even a type — so the Color
 * data has no dependency on the proposal module at all.
 *
 * Semantic-color roles: only the 13 roles genuinely true today are kept here — the 11 roles
 * protected spec §4.2 names as platform-owned/documentation-only, plus `color.background.elevated`
 * (also genuinely platform-owned in source) and `color.action.accent` (current production evidence,
 * not a platform mapping). `color.text.inverse`, `color.focus.ring`, and `color.overlay.scrim`
 * (including the specific scrim-opacity fact it once documented) are deliberately NOT carried
 * forward here: all three remain `'Proposed — not yet adopted'` in source, no slice in this plan
 * adopts them, and spec §2.3 forbids rendering a still-proposed role inside an adopted family
 * section. This is an explicit, disclosed retirement (see CO-3's own task body and self-review),
 * not a silent drop.
 */

export const HERMES_COLOR_RAMP_STEPS = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950] as const;
export type HermesColorRampStep = (typeof HERMES_COLOR_RAMP_STEPS)[number];
export type HermesColorRamp = Record<HermesColorRampStep, string>;

export const HERMES_COLOR_RAMPS: Record<string, HermesColorRamp> = {
  Neutral: { 50: '#F9F9FA', 100: '#F1F1F2', 200: '#DFDFE1', 300: '#C9C9CB', 400: '#AEAEB1', 500: '#8E8E93', 600: '#808084', 700: '#6D6D71', 800: '#58585B', 900: '#434345', 950: '#2D2D2F' },
  Gold: { 50: '#FFFDF2', 100: '#FFFAE0', 200: '#FFF4B8', 300: '#FFEC85', 400: '#FFE247', 500: '#FFD700', 600: '#E6C200', 700: '#C4A600', 800: '#9E8500', 900: '#786500', 950: '#524500' },
  Blue: { 50: '#F7F8FF', 100: '#EBEFFF', 200: '#D1DAFF', 300: '#B0C0FF', 400: '#89A1FF', 500: '#5B7CFF', 600: '#5270E6', 700: '#465FC4', 800: '#384D9E', 900: '#2B3A78', 950: '#1D2852' },
  Purple: { 50: '#FBF6FD', 100: '#F5EAFB', 200: '#E9CFF6', 300: '#D9ACEF', 400: '#C582E7', 500: '#AF52DE', 600: '#9E4AC8', 700: '#873FAB', 800: '#6C338A', 900: '#522768', 950: '#381A47' },
  Red: { 50: '#FFF5F5', 100: '#FFE7E6', 200: '#FFC8C5', 300: '#FFA19C', 400: '#FF726A', 500: '#FF3B30', 600: '#E6352B', 700: '#C42D25', 800: '#9E251E', 900: '#781C17', 950: '#52130F' },
  Green: { 50: '#F5FCF7', 100: '#E7F8EB', 200: '#C6EFD1', 300: '#9EE4AF', 400: '#6DD787', 500: '#34C759', 600: '#2FB350', 700: '#289945', 800: '#207B37', 900: '#185E2A', 950: '#11401C' },
  Orange: { 50: '#FFFAF5', 100: '#FFF2E8', 200: '#FEE0C8', 300: '#FDCBA1', 400: '#FCB173', 500: '#FB923C', 600: '#E28336', 700: '#C1702E', 800: '#9C5B25', 900: '#76451C', 950: '#502F13' },
  Cyan: { 50: '#F7FEFF', 100: '#EDFCFE', 200: '#D4F9FD', 300: '#B6F4FC', 400: '#92EEFB', 500: '#67E8F9', 600: '#5DD1E0', 700: '#4FB3C0', 800: '#40909A', 900: '#306D75', 950: '#214A50' },
  Pink: { 50: '#FEF8FB', 100: '#FEEEF6', 200: '#FCD8EB', 300: '#FABBDC', 400: '#F799CA', 500: '#F472B6', 600: '#DC67A4', 700: '#BC588C', 800: '#974771', 900: '#733656', 950: '#4E243A' },
};

// Spec §4.1: every non-500 ramp step is a generated value. This restriction is still true and still
// binding after adoption — CO-1 pins the constants byte-for-byte (HermesColorTests); it does not,
// by itself, perform per-pairing contrast validation. "Pinned exactly" and "not yet validated for a
// specific UI pairing" are two separate, both-still-true facts (Finding N6) — an unused, correctly-
// valued constant is compliant; a consumed, unvalidated one is not.
export const HERMES_COLOR_GENERATED_STEP_CONSUMPTION_RESTRICTION =
  'Every non-500 ramp step is a generated value, pinned exactly by HermesColorTests. No production UI pairing may consume a generated (non-500) step until that specific pairing has passed contrast validation, in both light and dark appearance and under Increased Contrast (spec §4.1). An unused, correctly-valued constant is compliant; a consumed, unvalidated one is not.';

// A new, local, Color-only classification — deliberately not the proposal module's own
// classification type (Finding N7/N8): the Color data module has no dependency, not even a
// type-only one, on the proposal module.
export type HermesColorCatalogClassification = 'Platform-owned adaptive token' | 'Current production evidence';

/** Which grouped heading a semantic role renders under in `HermesSemanticColorReference`. */
export type HermesSemanticColorPurpose = 'Surfaces' | 'Text' | 'Borders' | 'Actions' | 'Statuses' | 'Disabled content';

/** Which sample shape/status glyph a role's light/dark example frame renders — status roles carry
 *  a label plus a checkmark/triangle/mark/letter so meaning never depends on color alone. */
export type HermesSemanticColorSample =
  | 'surface'
  | 'text'
  | 'border'
  | 'action'
  | 'status-success'
  | 'status-warning'
  | 'status-danger'
  | 'status-info'
  | 'disabled';

export interface HermesSemanticColorFact {
  binding: string;
  classification: HermesColorCatalogClassification;
  /** Grouped heading this role renders under in `HermesSemanticColorReference`. */
  purpose: HermesSemanticColorPurpose;
  /** One-sentence use, shown beside the role's light/dark sample. */
  use: string;
  /** Catalog-only approximate adaptive preview — not a new Hermex production token; see this
   *  file's module note below. */
  previewLight: string;
  previewDark: string;
  sample: HermesSemanticColorSample;
  note?: string;
}

// Every previewLight/previewDark value below is a browser-documentation approximation of Apple's
// real adaptive system color for that binding, for visual reference only — it does not introduce a
// new Hermex production token, and no production call site reads it.

// Exactly the 13 roles genuinely true today (Finding N7) — the 11 protected-spec-§4.2-named
// platform-owned roles, plus `color.background.elevated` (also genuinely platform-owned in source)
// and `color.action.accent` (current production evidence). `color.text.inverse`, `color.focus.ring`,
// and `color.overlay.scrim` are deliberately retired, not included — see this file's own header
// comment above for why.
export const HERMES_SEMANTIC_COLORS: Record<string, HermesSemanticColorFact> = {
  'color.background.canvas': {
    binding: 'systemBackground', classification: 'Platform-owned adaptive token',
    purpose: 'Surfaces', use: 'Base background behind a full screen.',
    previewLight: '#F2F2F7', previewDark: '#000000', sample: 'surface',
  },
  'color.background.surface': {
    binding: 'secondarySystemBackground', classification: 'Platform-owned adaptive token',
    purpose: 'Surfaces', use: 'Standard grouped card or secondary surface.',
    previewLight: '#FFFFFF', previewDark: '#1C1C1E', sample: 'surface',
  },
  'color.background.elevated': {
    binding: 'tertiarySystemBackground', classification: 'Platform-owned adaptive token',
    purpose: 'Surfaces', use: 'Elevated platform surface above the base layer.',
    previewLight: '#FFFFFF', previewDark: '#2C2C2E', sample: 'surface',
    note: 'Adaptive Glass materials remain a separate token family.',
  },
  'color.text.primary': {
    binding: 'label', classification: 'Platform-owned adaptive token',
    purpose: 'Text', use: 'Primary labels and body content.',
    previewLight: '#000000', previewDark: '#FFFFFF', sample: 'text',
  },
  'color.text.secondary': {
    binding: 'secondaryLabel', classification: 'Platform-owned adaptive token',
    purpose: 'Text', use: 'Supporting labels and metadata.',
    previewLight: '#3C3C4399', previewDark: '#EBEBF599', sample: 'text',
  },
  'color.text.tertiary': {
    binding: 'tertiaryLabel', classification: 'Platform-owned adaptive token',
    purpose: 'Text', use: 'Low-emphasis helper content.',
    previewLight: '#3C3C434D', previewDark: '#EBEBF54D', sample: 'text',
  },
  'color.border.default': {
    binding: 'separator', classification: 'Platform-owned adaptive token',
    purpose: 'Borders', use: 'Separators and subtle boundaries.',
    previewLight: '#3C3C434A', previewDark: '#54545899', sample: 'border',
  },
  'color.action.accent': {
    binding: 'Active user-selected HeaderLogoColor', classification: 'Current production evidence',
    purpose: 'Actions', use: 'Active controls using the selected header accent.',
    previewLight: '#5B7CFF', previewDark: '#5B7CFF', sample: 'action',
  },
  'color.status.success': {
    binding: 'adaptive systemGreen', classification: 'Platform-owned adaptive token',
    purpose: 'Statuses', use: 'Successful or completed state.',
    previewLight: '#34C759', previewDark: '#30D158', sample: 'status-success',
  },
  'color.status.warning': {
    binding: 'adaptive systemOrange', classification: 'Platform-owned adaptive token',
    purpose: 'Statuses', use: 'Warning or offline state.',
    previewLight: '#FF9500', previewDark: '#FF9F0A', sample: 'status-warning',
  },
  'color.status.danger': {
    binding: 'adaptive systemRed', classification: 'Platform-owned adaptive token',
    purpose: 'Statuses', use: 'Error or destructive state.',
    previewLight: '#FF3B30', previewDark: '#FF453A', sample: 'status-danger',
  },
  'color.status.info': {
    binding: 'adaptive systemBlue', classification: 'Platform-owned adaptive token',
    purpose: 'Statuses', use: 'Informational status or neutral progress.',
    previewLight: '#007AFF', previewDark: '#0A84FF', sample: 'status-info',
  },
  'color.content.disabled': {
    binding: 'tertiaryLabel / tertiarySystemFill pairing', classification: 'Platform-owned adaptive token',
    purpose: 'Disabled content', use: 'Disabled foreground and fill pairing.',
    previewLight: '#3C3C434D', previewDark: '#EBEBF54D', sample: 'disabled',
  },
};
