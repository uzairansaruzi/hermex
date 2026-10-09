/**
 * Design tokens — the single source of truth for the native component tree.
 *
 * Nothing here is platform-specific: values are plain hexes, numbers, and font-weight strings. The
 * RN components import these directly. Kept platform-neutral on purpose so a future non-native
 * platform (web, desktop, …) can consume the same values — see the repo README.
 */
export {
  PALETTE_STEPS,
  DS_PALETTE,
  paletteTokenForColor,
  colorValueLabel,
} from './palette';
export type { PaletteName, PaletteStep } from './palette';

export { DS_SEMANTIC } from './semantic';

export {
  DS_SPACING,
  DS_SPACING_STEPS,
  DS_SPACING_USE,
  DS_RADIUS,
  DS_RADIUS_STEPS,
  DS_RADIUS_USE,
  DS_ICON_SIZE,
  DS_ICON_SIZE_STEPS,
  DS_A11Y_MIN_TOUCH_TARGET,
} from './scales';
export type { SpacingStep, RadiusStep, IconSizeStep } from './scales';

export { DS_FONT_WEIGHT, DS_FONT_WEIGHT_USE, DS_TYPOGRAPHY, DS_TYPOGRAPHY_USE } from './typography';
export type { FontWeightName, TypographyToken } from './typography';

export { DS_SHADOW, DS_SHADOW_USE } from './shadow';
export type { ShadowToken } from './shadow';

export {
  DS_MOTION_DURATION,
  DS_MOTION_DURATION_STEPS,
  DS_MOTION_DURATION_USE,
  DS_MOTION_EASING,
  DS_MOTION_EASING_STEPS,
  DS_MOTION_EASING_USE,
  DS_MOTION_SPRING,
  DS_MOTION_SPRING_USE,
  DS_MOTION_LOOP_DURATION,
  DS_MOTION_LOOP_DURATION_STEPS,
  DS_MOTION_LOOP_DURATION_USE,
} from './motion';
export type { MotionDurationStep, MotionEasingStep, MotionSpringConfig, MotionLoopDurationStep } from './motion';
