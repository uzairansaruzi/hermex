import type { StyleProp, ViewStyle } from 'react-native';

export type ShimmerVariant = 'text' | 'container' | 'circle';

export interface ShimmerProps {
  /** Which shape this placeholder stands in for:
   *  - `'text'` (default) — **one line of text**. A real element with 3 lines of text gets 3
   *    stacked `text` Shimmers, not one tall one — a skeleton should mirror the real line count.
   *    When stacking 2+ lines, give the last one ~70% of the others' width — real text rarely fills
   *    every line edge-to-edge, and a shorter final line reads as "this is where the paragraph
   *    naturally ends," not a loading glitch.
   *  - `'circle'` — always a circular element (an Avatar, an icon-only Pill/Button, a status dot) —
   *    never used for anything that isn't actually round in its loaded state.
   *  - `'container'` — everything else: a Card, a Banner, an image, any non-text/non-circular UI
   *    element. Its `width`/`height` should match the real element it's replacing (a Card skeleton
   *    should be Card-shaped, not an arbitrary block), so the skeleton reserves the same layout
   *    space the loaded content will actually occupy — no jump when it swaps in. */
  variant?: ShimmerVariant;
  /** Width (text and container). Defaults to 100%. */
  width?: number | `${number}%`;
  /** Height (text and container). Defaults: text 16, container 80 — override to match the real
   *  element this stands in for. */
  height?: number;
  /** Diameter for `circle` variant. Default 40. */
  size?: number;
  style?: StyleProp<ViewStyle>;
}
