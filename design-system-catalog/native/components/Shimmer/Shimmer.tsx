import React, { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { View, Animated, Easing, AccessibilityInfo, type StyleProp, type ViewStyle } from 'react-native';
import { DS_RADIUS, DS_SPACING, DS_MOTION_LOOP_DURATION } from '../../../tokens';
import type { ShimmerProps, ShimmerVariant } from './Shimmer.types';

// True for any Shimmer rendered inside a <SkeletonGroup>. When set, individual blocks drop their own
// "Loading" announcement — the group announces once for the whole skeleton instead (see below).
const SkeletonGroupContext = createContext(false);

export const SHIMMER_TEXT_HEIGHT = DS_SPACING[800];

// Plain Shimmer blocks pulse between these two values. Translucent black (not an opaque grey) so the
// shimmer reads correctly as a wash over whatever surface it's placed on — light, dark, or coloured —
// the same convention DS uses for its other "works on any surface" overlays. Interpolating the colour
// itself (not a separate `opacity` style) keeps each independent block visually equivalent to a plain
// alpha wash.
const PULSE_LOW  = 'rgba(0, 0, 0, 0.02)';
const PULSE_HIGH = 'rgba(0, 0, 0, 0.05)';

// One pulse cycle, shared by every Shimmer instance.
const PULSE_CYCLE_MS = DS_MOTION_LOOP_DURATION.pulse;

// A single module-level clock every Shimmer/Breathing instance reads from, instead of each starting
// its own timer at mount. Two independent per-instance timers would drift out of phase depending on
// the exact moment each mounted — sharing one clock means any shimmers visible together always pulse
// in lockstep. `useNativeDriver:false` is required because we interpolate `backgroundColor` (colour
// interpolation is JS-driven).
const sharedProgress = new Animated.Value(0);
let sharedProgressStarted = false;
function ensureSharedProgressStarted(): void {
  if (sharedProgressStarted || reduceMotionEnabled !== false) return;
  sharedProgressStarted = true;
  Animated.loop(
    Animated.timing(sharedProgress, {
      toValue: 1,
      duration: PULSE_CYCLE_MS,
      easing: Easing.linear,
      useNativeDriver: false,
    }),
  ).start();
}

// ─── Reduce Motion ────────────────────────────────────────────────────────────
// Same pattern as HermesMotionReference.tsx: read the system preference once via
// `AccessibilityInfo.isReduceMotionEnabled()`, then keep it current via the `reduceMotionChanged`
// event so a preference flipped while the app is open takes effect immediately — no new dependency,
// both calls are the existing `react-native` AccessibilityInfo API.
// `null` until `AccessibilityInfo.isReduceMotionEnabled()` resolves — an unresolved preference must
// never read as "not reduced", which would let ensureSharedProgressStarted() and Breathing's render
// briefly treat it as disabled before the preference actually resolves.
let reduceMotionEnabled: boolean | null = null;
const reduceMotionListeners = new Set<(enabled: boolean) => void>();

AccessibilityInfo.isReduceMotionEnabled().then((enabled) => {
  reduceMotionEnabled = enabled;
  reduceMotionListeners.forEach((listener) => listener(enabled));
});

AccessibilityInfo.addEventListener('reduceMotionChanged', (enabled) => {
  reduceMotionEnabled = enabled;
  if (enabled) {
    // Stop the shared clock immediately so no in-flight loop keeps animating after the preference
    // flips on; ensureSharedProgressStarted's own guard keeps it from restarting until it flips off.
    sharedProgress.stopAnimation();
    sharedProgress.setValue(0);
    sharedProgressStarted = false;
  }
  reduceMotionListeners.forEach((listener) => listener(enabled));
});

function useReduceMotion(): boolean | null {
  const [enabled, setEnabled] = useState<boolean | null>(reduceMotionEnabled);
  useEffect(() => {
    reduceMotionListeners.add(setEnabled);
    return () => {
      reduceMotionListeners.delete(setEnabled);
    };
  }, []);
  return enabled;
}

// ─── Shared animated primitive ────────────────────────────────────────────────
// A solid block that breathes between `low` and `high` on the shared progress value. Exported so any
// composite skeleton can reuse the same pulse (and stay in lockstep with plain Shimmers).
export function Breathing({
  phase = 0,
  low = PULSE_LOW,
  high = PULSE_HIGH,
  style,
  accessibilityRole,
  accessibilityLabel,
}: {
  phase?: number;
  /** Override the pulse's low/high colours. Defaults to the shared translucent pulse. */
  low?: string;
  high?: string;
  style?: StyleProp<ViewStyle>;
  accessibilityRole?: 'progressbar';
  accessibilityLabel?: string;
}) {
  const reduceMotion = useReduceMotion();

  useEffect(() => {
    if (reduceMotion === false) ensureSharedProgressStarted();
  }, [reduceMotion]);

  // (progress + phase) % 1, then a triangle wave: high at 0, low at 0.5, high at 1 — equivalent to the
  // cosine breathe, driven off the one shared linear clock so all instances stay phase-locked. Reduce
  // Motion drops the interpolation entirely for a flat, non-looping fill — never a paused animated
  // value, so there is no chance of it resuming mid-pulse if the preference flips back off later.
  const backgroundColor = useMemo(() => {
    if (reduceMotion !== false) return high;
    return Animated.modulo(Animated.add(sharedProgress, phase), 1).interpolate({
      inputRange: [0, 0.5, 1],
      outputRange: [high, low, high],
    });
  }, [phase, low, high, reduceMotion]);

  return (
    <Animated.View
      style={[style, { backgroundColor }]}
      accessibilityRole={accessibilityRole}
      accessibilityLabel={accessibilityLabel}
    />
  );
}

function dimensionsForVariant(
  variant: ShimmerVariant,
  width: ShimmerProps['width'],
  height: ShimmerProps['height'],
  size: number,
): ViewStyle {
  switch (variant) {
    case 'circle':
      return { width: size, height: size, borderRadius: DS_RADIUS.round };
    case 'container':
      return { width: width ?? '100%', height: height ?? 80, borderRadius: DS_RADIUS.medium };
    case 'text':
    default:
      return { width: width ?? '100%', height: height ?? SHIMMER_TEXT_HEIGHT, borderRadius: DS_RADIUS.small };
  }
}

// ─── Shimmer ──────────────────────────────────────────────────────────────────
/**
 * A single loading placeholder — see `ShimmerProps.variant` for what each shape stands in for.
 * A real composite skeleton (e.g. a list row: avatar + a two-line label) is built by stacking
 * multiple Shimmers of the right variant/count/dimensions, not by inventing one shape to cover
 * everything — see the "Circle + text" example in the catalog for exactly this composition.
 */
export function Shimmer({ variant = 'text', width, height, size = 40, style }: ShimmerProps) {
  // Inside a <SkeletonGroup>, the group owns the single "Loading" announcement — each block stays
  // silent so a composite skeleton (avatar + two text lines = 3 blocks) doesn't make a screen
  // reader read "Loading, Loading, Loading". A standalone Shimmer still announces on its own.
  const insideGroup = useContext(SkeletonGroupContext);
  return (
    <Breathing
      style={[dimensionsForVariant(variant, width, height, size), style]}
      accessibilityRole={insideGroup ? undefined : 'progressbar'}
      accessibilityLabel={insideGroup ? undefined : 'Loading'}
    />
  );
}

// ─── SkeletonGroup ──────────────────────────────────────────────────────────────
/**
 * Wraps a composite skeleton (several stacked Shimmers standing in for one real element — e.g. a
 * list row's avatar + two text lines) so assistive tech announces it as ONE "Loading" region
 * instead of once per block. Provides {@link SkeletonGroupContext} so every descendant Shimmer drops
 * its own announcement; the group itself carries the single `progressbar`/busy role. Pass your own
 * layout via `style` (the group is a plain View, so `flexDirection`/`gap` land where you'd expect) —
 * it adds no layout of its own.
 */
export function SkeletonGroup({
  label = 'Loading',
  style,
  children,
}: {
  /** Accessible name for the whole loading region. @default 'Loading' */
  label?: string;
  style?: StyleProp<ViewStyle>;
  children: ReactNode;
}) {
  return (
    <SkeletonGroupContext.Provider value>
      <View
        style={style}
        accessibilityRole="progressbar"
        accessibilityLabel={label}
        accessibilityState={{ busy: true }}
      >
        {children}
      </View>
    </SkeletonGroupContext.Provider>
  );
}
