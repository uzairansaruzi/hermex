/**
 * Motion tokens — duration and easing curves for transitions/animations.
 *
 * Easing curves are plain cubic-bezier tuples (`[x1, y1, x2, y2]`, matching CSS `cubic-bezier()` /
 * RN `Easing.bezier()`) rather than `Easing` function objects, so this file stays free of any
 * `react-native` import — the same platform-neutral shape every other token file follows. Convert
 * at the call site: `Easing.bezier(...DS_MOTION_EASING.standard)`.
 */
export const DS_MOTION_DURATION_STEPS = ['fast', 'base', 'slow'] as const;
export type MotionDurationStep = (typeof DS_MOTION_DURATION_STEPS)[number];

export const DS_MOTION_DURATION: Record<MotionDurationStep, number> = {
  fast: 150,
  base: 240,
  slow: 400,
};

export const DS_MOTION_EASING_STEPS = ['standard', 'decelerate', 'accelerate'] as const;
export type MotionEasingStep = (typeof DS_MOTION_EASING_STEPS)[number];

export const DS_MOTION_EASING: Record<MotionEasingStep, readonly [number, number, number, number]> = {
  standard: [0.4, 0.0, 0.2, 1],
  decelerate: [0.0, 0.0, 0.2, 1],
  accelerate: [0.4, 0.0, 1, 1],
};

/**
 * When to reach for each duration/easing step — grounded in this template's own real animations
 * (AnimatedChevron's 240ms rotate, CollapsibleSwap's 240ms default) where a value already exists;
 * `fast`/`accelerate`/`decelerate` are the standard Material-motion counterparts alongside it, for
 * the short taps and exits this template doesn't yet have a named constant for.
 */
export const DS_MOTION_DURATION_USE: Record<MotionDurationStep, string> = {
  fast: 'A quick, barely-there transition — a pressed-state feedback flash, a small icon swap.',
  base: "The default — AnimatedChevron's rotate and CollapsibleSwap's expand/collapse both already run at 240ms. Reach for this first.",
  slow: 'A deliberate, noticeable transition — a sheet or panel entering/exiting the screen.',
};

export const DS_MOTION_EASING_USE: Record<MotionEasingStep, string> = {
  standard: 'The default for most transitions — eases in and out symmetrically, for a move that starts and ends in the same place (a toggle, a swap).',
  decelerate: 'Fast start, gentle stop — for something entering the screen (a sheet sliding up, a toast appearing).',
  accelerate: 'Gentle start, fast finish — for something leaving the screen (a sheet dismissing, a toast exiting).',
};

/** Spring physics config, shaped for `Animated.spring(value, DS_MOTION_SPRING)` (or Reanimated's
 *  `withSpring`). Grounded in the metro-native app this template was extracted from, where this exact
 *  config (there, `SHEET_SPRING_CONFIG`) drives its BottomSheet's snap-point transitions — a
 *  near-critically-damped spring (high damping relative to stiffness, `overshootClamping` on) that
 *  settles quickly with no bounce, unlike a playful/bouncy spring. */
export interface MotionSpringConfig {
  stiffness: number;
  damping: number;
  mass: number;
  overshootClamping: boolean;
  restDisplacementThreshold: number;
  restSpeedThreshold: number;
}

export const DS_MOTION_SPRING: MotionSpringConfig = {
  stiffness: 1000,
  damping: 500,
  mass: 3,
  overshootClamping: true,
  restDisplacementThreshold: 1,
  restSpeedThreshold: 1,
};

export const DS_MOTION_SPRING_USE =
  'A snappy, near-critically-damped spring for programmatic snap-point transitions — e.g. a bottom sheet or panel settling into position after a drag, rather than a fixed-duration timing curve.';

/**
 * Durations for continuous, indeterminate loops (a spinner's fill→empty cycle, a shimmer's pulse) —
 * a distinct category from `DS_MOTION_DURATION`'s one-shot transitions, and generally slower: a loop
 * has to read as calm and ongoing rather than a quick state change. Grounded in this template's own
 * two existing loops: Loading's circle/linear fill-cycle (`duration` prop, default 1200) and
 * Shimmer's shared pulse clock (`PULSE_CYCLE_MS`, 1800 — deliberately slower and calmer than the
 * spinner, since a shimmer stands in for content that just hasn't loaded yet, not an active process).
 */
export const DS_MOTION_LOOP_DURATION_STEPS = ['spinner', 'pulse'] as const;
export type MotionLoopDurationStep = (typeof DS_MOTION_LOOP_DURATION_STEPS)[number];

export const DS_MOTION_LOOP_DURATION: Record<MotionLoopDurationStep, number> = {
  spinner: 1200,
  pulse: 1800,
};

export const DS_MOTION_LOOP_DURATION_USE: Record<MotionLoopDurationStep, string> = {
  spinner: "An active, ongoing process the user is waiting on — Loading's own default for both its circle and linear variants.",
  pulse: "Content that hasn't loaded yet, not an active process — deliberately slower/calmer than spinner. Shimmer's shared pulse clock runs at this rate so every visible shimmer stays in lockstep.",
};
