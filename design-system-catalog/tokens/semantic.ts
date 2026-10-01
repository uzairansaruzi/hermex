/**
 * Semantic color tokens — the layer app code should consume.
 *
 * Every value points at a palette step (or a deliberate one-off). Components reference these names
 * (surface.main, text.regular, emphasis.positive…) not raw hexes, so a rebrand is: edit palette.ts,
 * then re-point anything here you want to shift. Grouped by role: surface, text, element, interaction,
 * border, emphasis (saturated accents), shade (tinted fills).
 */
import { DS_PALETTE } from './palette';

const grey = DS_PALETTE.grey;
const green = DS_PALETTE.green;
const blue = DS_PALETTE.blue;
const red = DS_PALETTE.red;
const yellow = DS_PALETTE.yellow;
const purple = DS_PALETTE.purple;

export const DS_SEMANTIC = {
  surface: {
    main: grey[100],
    muted: grey[300],
    white: grey[0],
    onTap: grey[100],
    inverse: grey[800],
    /** Translucent secondary fill — secondary buttons, recessed tracks (SegmentedToggle), field
     *  chrome (FieldContainer/InputField). Adapts to whatever surface sits under it. */
    recessed: 'rgba(0, 0, 0, 0.10)',
    /** Pressed state for a `recessed`-filled surface — a deliberately tuned darker translucent
     *  value, not `interaction.pressed` stacked on top of `recessed`: two independently-chosen
     *  overlays compositing together produce whatever their alpha math happens to yield, not a
     *  value anyone actually looked at and picked. Every `recessed` surface's pressed state should
     *  point here instead, so it's one tuned, reusable, nameable value. */
    recessedPressed: 'rgba(0, 0, 0, 0.20)',
    /** Disabled state for a `recessed`-filled surface — same reasoning as `recessedPressed`: a
     *  deliberately tuned lighter translucent value (reads as washed-out/inactive) rather than a
     *  second overlay stacked on top. */
    recessedDisabled: 'rgba(0, 0, 0, 0.05)',
  },
  text: {
    regular: grey[800],
    /** Secondary/muted text. grey[500] alone falls just short of WCAG AA (4.5:1) for 12–14px text on
     *  the surface.main background (~4.34:1) — grey[600] is the next step up and clears it
     *  comfortably (~9.5:1), so every semantic colour traces to the palette. */
    muted: grey[600],
    /** Disabled field/value text — a step lighter than `muted` (which doubles as hint/placeholder
     *  text), so a disabled field's text doesn't just read as an empty hint. WCAG contrast isn't
     *  required for disabled UI (1.4.3 exempts inactive components), so this deliberately sits
     *  below the step `muted` was tuned to clear. */
    disabled: grey[500],
    inverse: grey[0],
    /** Inline text links — same value as emphasis.info, so a link and an "info" status read as the
     *  same accent, but named for what it's actually used for (Banner's `link` prop) rather than
     *  reusing the status-emphasis name at every call site. Clears WCAG AA (~5.6:1) against white
     *  and every `shade.*` tint a link might sit on (all near-white). */
    link: blue[600],
  },
  element: {
    divider: 'rgba(0, 0, 0, 0.12)',
    overlayBackdrop: 'rgba(0, 0, 0, 0.34)',
  },
  interaction: {
    /** Universal pressed overlay — apply on top of any light surface. */
    pressed: 'rgba(0, 0, 0, 0.08)',
    /** Lighter hover overlay (web). */
    hover: 'rgba(0, 0, 0, 0.04)',
    /** 2px focus ring color — visible on light surfaces. */
    focused: grey[800],
    /** Disabled opacity — apply to the whole tappable element. */
    disabledOpacity: 0.38,
  },
  border: {
    dark: grey[700],
    light: grey[400],
    /** Subtle UI separators — between divider opacity and border.light. */
    subtle: grey[300],
  },
  /** Saturated accents for text/icons that must read as a status. Each one is set to the step that
   *  clears WCAG AA (4.5:1) against its matching `shade` background — `positive`/`warning` need step
   *  700 for that (green/yellow are lighter hues than red/blue at the same step, so 600 falls short:
   *  ~4.39:1 and ~3.0:1 respectively); `negative`/`info` already clear it at 600. */
  emphasis: {
    neutral: grey[600],
    positive: green[700],
    warning: yellow[700],
    negative: red[600],
    info: blue[600],
    accent: purple[700],
  },
  /** Light tinted fills for badges/banners/cards of each status. */
  shade: {
    neutral: grey[0],
    positive: green[0],
    warning: yellow[0],
    negative: red[0],
    info: blue[0],
    accent: purple[100],
  },
} as const;
