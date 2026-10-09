/** Elevation tokens as React Native style objects (shadowColor/Offset/Opacity/Radius + Android elevation). */
export const DS_SHADOW = {
  /** Resting lift for cards / unselected pills — barely there. */
  resting: {
    shadowColor: '#000000',
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.02,
    shadowRadius: 4,
    elevation: 1,
  },
  /** Gentle drop shadow for card surfaces. */
  card: {
    shadowColor: '#000000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.08,
    shadowRadius: 8,
    elevation: 3,
  },
  /** Upward-cast shadow for bottom sheets — casts above the sheet edge. */
  bottomSheet: {
    shadowColor: '#000000',
    shadowOffset: { width: 0, height: -4 },
    shadowOpacity: 0.12,
    shadowRadius: 12,
    elevation: 8,
  },
} as const;

export type ShadowToken = keyof typeof DS_SHADOW;

/** When to reach for each shadow — grounded in real usage across native/components. */
export const DS_SHADOW_USE: Record<ShadowToken, string> = {
  resting: 'Barely-there lift for surfaces that sit at rest on the page — Card, Pill, SegmentedToggle. Reach for this first.',
  card: "A stronger, deliberate lift for a surface that floats above the page — Toast's bar.",
  bottomSheet: 'An upward-cast shadow (offset negative, casting above the element) for anything pinned to the bottom edge — a bottom sheet or Dock.',
};
