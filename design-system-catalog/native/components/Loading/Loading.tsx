import React, { useEffect, useRef, useState } from 'react';
import { View, Animated, Easing, AccessibilityInfo, Platform, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import Svg, { Path } from 'react-native-svg';
import { DS_SEMANTIC, DS_MOTION_LOOP_DURATION } from '../../../tokens';

const AnimatedPath = Animated.createAnimatedComponent(Path);

// Same pattern as Shimmer.tsx/Button.tsx/HermesMotionReference.tsx: read the system preference once
// via `AccessibilityInfo.isReduceMotionEnabled()`, then keep it current via `reduceMotionChanged` —
// no new dependency, both calls are the existing `react-native` AccessibilityInfo API.
// `null` until `AccessibilityInfo.isReduceMotionEnabled()` resolves — an unresolved preference must
// never read as "not reduced", which would briefly start the loop below on a device that actually has
// Reduce Motion on.
function useReduceMotion(): boolean | null {
  const [reduceMotion, setReduceMotion] = useState<boolean | null>(null);
  useEffect(() => {
    let mounted = true;
    AccessibilityInfo.isReduceMotionEnabled().then((enabled) => {
      if (mounted) setReduceMotion(enabled);
    });
    const subscription = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotion);
    return () => {
      mounted = false;
      subscription.remove();
    };
  }, []);
  return reduceMotion;
}

// A 20×20 viewBox, ~292° arc (radius 9, centre 10,10), 2px stroke. The arc is a single stroke whose
// dash exactly covers its length, so animating the dash offset draws it on (fills) then off (empties).
const ARC_PATH =
  'M19 10C19 11.9289 18.3803 13.8067 17.2323 15.3567C16.0843 16.9067 14.4687 18.0468 12.6236 18.6091C10.7785 19.1714 8.8016 19.126 6.98426 18.4797C5.16692 17.8334 3.6053 16.6203 2.52959 15.0193C1.45388 13.4182 0.920996 11.514 1.00948 9.58714C1.09796 7.66032 1.80313 5.81291 3.02105 4.3172C4.23897 2.8215 5.9052 1.75664 7.77412 1.2796C9.64305 0.802556 11.6158 0.938564 13.4016 1.66758';
const ARC_LEN = 45.9;

export type LoadingVariant = 'circle' | 'linear';

export interface LoadingProps {
  /** Which shape to render. @default 'circle' */
  variant?: LoadingVariant;
  /** Diameter in px — circle only. @default 20 */
  size?: number;
  /** Track width — linear only. @default '100%' */
  width?: number | `${number}%`;
  /** Track/bar thickness — linear only. @default 4 */
  height?: number;
  /** Stroke (circle) / fill (linear) colour. Defaults to the regular text colour. */
  color?: string;
  /** Track (background) colour — linear only. */
  trackColor?: string;
  /** One fill→empty cycle duration in ms. @default DS_MOTION_LOOP_DURATION.spinner (1200) */
  duration?: number;
  style?: StyleProp<ViewStyle>;
}

/**
 * Indeterminate loader — the shape fills up, empties out, then fills again, seamlessly, in either of
 * two variants:
 *  - `circle` (default): a dash slides across the arc's own length over a 2× period, so a single
 *    continuous timing produces the fill→empty→fill motion.
 *  - `linear`: a bar's width animates 0→100%→0% explicitly (two phases — there's no dash-slide
 *    equivalent for a plain width fill).
 * Both are JS-driven (`useNativeDriver: false`), so Fabric-safe: a continuous loop on an
 * always-mounted view, no imperative setValue. Used internally by Button and Pill for their own
 * loading states (circle). Reduce Motion replaces the loop with a static half-drawn/half-filled
 * render — still visibly a loading indicator, never a repainting decorative loop.
 */
export function Loading({
  variant = 'circle',
  size = 20,
  width = '100%',
  height = 4,
  color = DS_SEMANTIC.text.regular,
  trackColor = DS_SEMANTIC.surface.muted,
  duration = DS_MOTION_LOOP_DURATION.spinner,
  style,
}: LoadingProps) {
  const reduceMotion = useReduceMotion();
  // Circle drives this directly as a dash offset (ARC_LEN..-ARC_LEN); linear reads it as 0..1 and
  // interpolates to a width percentage. Different ranges, same underlying value — each variant's own
  // effect below sets up the animation appropriate to it.
  const progress = useRef(new Animated.Value(variant === 'circle' ? ARC_LEN : 0)).current;

  useEffect(() => {
    if (reduceMotion !== false) {
      // Unresolved (null) or explicitly enabled (true): a static half-drawn arc / half-filled bar —
      // still reads as "loading", never an unconditional off-screen or always-repainting
      // Animated.loop, and never started before the preference explicitly resolves to disabled.
      progress.setValue(variant === 'circle' ? 0 : 0.5);
      return;
    }
    const loop =
      variant === 'circle'
        ? Animated.loop(
            Animated.timing(progress, {
              toValue: -ARC_LEN,
              duration,
              easing: Easing.inOut(Easing.ease),
              useNativeDriver: false,
            }),
          )
        : Animated.loop(
            Animated.sequence([
              Animated.timing(progress, { toValue: 1, duration, easing: Easing.inOut(Easing.ease), useNativeDriver: false }),
              Animated.timing(progress, { toValue: 0, duration, easing: Easing.inOut(Easing.ease), useNativeDriver: false }),
            ]),
          );
    loop.start();
    return () => loop.stop();
  }, [variant, duration, progress, reduceMotion]);

  if (variant === 'linear') {
    const fillWidth = progress.interpolate({ inputRange: [0, 1], outputRange: ['0%', '100%'] });
    return (
      <View
        style={[styles.track, { width, height, backgroundColor: trackColor, borderRadius: height / 2 }, style]}
        accessible
        accessibilityRole="progressbar"
        accessibilityLabel="Loading"
      >
        <Animated.View
          style={[styles.fill, { height, backgroundColor: color, width: fillWidth, borderRadius: height / 2 }]}
        />
      </View>
    );
  }

  const circleAccessibilityProps =
    Platform.OS === 'web'
      ? { 'aria-label': 'Loading', role: 'progressbar' as const }
      : { accessible: true, accessibilityRole: 'progressbar' as const, accessibilityLabel: 'Loading' };

  return (
    <Svg
      width={size}
      height={size}
      viewBox="0 0 20 20"
      fill="none"
      style={style}
      {...circleAccessibilityProps}
    >
      <AnimatedPath d={ARC_PATH} stroke={color} strokeWidth={2} strokeDasharray={ARC_LEN} strokeDashoffset={progress} />
    </Svg>
  );
}

const styles = StyleSheet.create({
  track: { overflow: 'hidden' },
  fill: { position: 'absolute', left: 0, top: 0 },
});
