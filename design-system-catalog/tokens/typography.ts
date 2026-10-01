/**
 * Type scale + font weights.
 *
 * DS_TYPOGRAPHY entries are RN-shaped (fontSize/fontWeight/lineHeight numbers). On web the same
 * numbers apply as `font-size`/`font-weight`/`line-height` (px). Naming: `label*` are semibold UI
 * labels, `body*` are regular reading text, `emphasis*`/`display`/`title` are headline weights.
 */
export const DS_FONT_WEIGHT = {
  normal: '400' as const,
  medium: '500' as const,
  semibold: '600' as const,
  bold: '700' as const,
  extrabold: '800' as const,
  black: '900' as const,
};
export type FontWeightName = keyof typeof DS_FONT_WEIGHT;

/**
 * When to reach for each font weight — grounded in real usage. Most components get their weight
 * via a spread `DS_TYPOGRAPHY` token (`label*` tokens embed `semibold`, `emphasis*`/`display`/`title`
 * embed `bold`) rather than referencing `DS_FONT_WEIGHT` directly — noted below where that's the case.
 */
export const DS_FONT_WEIGHT_USE: Record<FontWeightName, string> = {
  normal: "Regular body text — every DS_TYPOGRAPHY `body*` token embeds this; rarely referenced directly.",
  medium: "A touch heavier than body text without reading as a full label — Toast's message text.",
  semibold: "Standard UI label weight — Button's label, SectionHeader's title; embedded in every DS_TYPOGRAPHY `label*` token.",
  bold: "Headline weight — embedded in every DS_TYPOGRAPHY `emphasis*`/`display`/`title` token; no component references it directly outside those.",
  extrabold: 'Reserved — no current consumer.',
  black: 'Reserved — no current consumer.',
};

// Every token now carries an explicit lineHeight — before this, labelXs/Sm/Md and emphasisSm/Md/
// display/title fell back to each platform's own implicit default, which differs between iOS,
// Android, and web and was a real source of inconsistent vertical rhythm. Two rules set the values:
//  - label* matches its same-fontSize body* counterpart (12→16, 14→20, 16→22) — a label and body
//    line sitting next to each other should land on the same baseline grid regardless of weight.
//  - emphasis*/display/title (no body-scale equivalent to borrow from) extend emphasisLg's own
//    already-established +8 relationship (48→56).
export const DS_TYPOGRAPHY = {
  labelXs: { fontSize: 12, fontWeight: '600' as const, lineHeight: 16 },
  labelSm: { fontSize: 14, fontWeight: '600' as const, lineHeight: 20 },
  labelMd: { fontSize: 16, fontWeight: '600' as const, lineHeight: 22 },
  bodyXs: { fontSize: 12, fontWeight: '400' as const, lineHeight: 16 },
  bodySm: { fontSize: 14, fontWeight: '400' as const, lineHeight: 20 },
  bodyMd: { fontSize: 16, fontWeight: '400' as const, lineHeight: 22 },
  emphasisSm: { fontSize: 32, fontWeight: '700' as const, lineHeight: 40 },
  emphasisMd: { fontSize: 40, fontWeight: '700' as const, lineHeight: 48 },
  emphasisLg: { fontSize: 48, fontWeight: '700' as const, lineHeight: 56 },
  display: { fontSize: 88, fontWeight: '700' as const, lineHeight: 96 },
  title: { fontSize: 24, fontWeight: '700' as const, lineHeight: 32 },
} as const;

export type TypographyToken = keyof typeof DS_TYPOGRAPHY;

/**
 * When to reach for each type token — grounded in how the source app actually uses them, not
 * aspirational. Meant to be read by whoever (human or AI) is deciding which token fits a new piece
 * of UI text; also rendered in the catalog's Typography page.
 */
export const DS_TYPOGRAPHY_USE: Record<TypographyToken, string> = {
  labelXs: "Smallest UI label — tab labels, a status row's label, a section header's trailing button text.",
  labelSm: "Small UI label — a pill's text, a small button's label, a banner's title.",
  labelMd: "Standard UI label — a large button's label, an emphasized banner title.",
  bodyXs: "Fine print / secondary meta text — settings captions, a bug-report hint, a train-info row's footnote.",
  bodySm: "Small reading text — a toast's message, a text area's input, a banner's description.",
  bodyMd: "Standard reading text — a search field's input, an input field's value, a screen's body copy.",
  emphasisSm: "A prominent standalone number — a train countdown, a success sheet's headline number.",
  emphasisMd: 'A bigger emphasis number/headline — onboarding hero screens, a key stat on a saved/map screen.',
  emphasisLg: "The largest 'big number' emphasis — an onboarding welcome hero, a live arrival countdown.",
  display: 'Reserved for a true hero/display moment — the largest size on the scale; no current consumer.',
  title: "A screen/page title — a settings screen's heading, an error state's title.",
};
