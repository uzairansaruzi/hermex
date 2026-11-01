import React, { useEffect, useRef } from 'react';
import { Animated, Easing } from 'react-native';
import { Icon } from '../../../icons/Icon.native';
import { DS_MOTION_DURATION, DS_MOTION_EASING } from '../../../tokens';

export interface AnimatedChevronProps {
  /** When true the chevron points up; when false it points down. */
  expanded: boolean;
  size?: number;
  color?: string;
  /** Morph duration in ms. Defaults to DS_MOTION_DURATION.base (240). */
  duration?: number;
}

/**
 * A chevron that morphs between down (collapsed) and up (expanded) by flipping vertically in place
 * (`scaleY` 1 → 0 → -1) rather than rotating through a sideways-pointing intermediate angle — a
 * plain chevron-down glyph mirrored on its own vertical centre (`scaleY: -1`) is exactly chevron-up,
 * so no second icon or path swap is needed. Uses the core `Animated` API with `useNativeDriver:
 * true` (transform-only), so it's smooth on the New Architecture in dev and release.
 */
export function AnimatedChevron({ expanded, size = 16, color, duration = DS_MOTION_DURATION.base }: AnimatedChevronProps) {
  const progress = useRef(new Animated.Value(expanded ? 1 : 0)).current;

  useEffect(() => {
    const anim = Animated.timing(progress, {
      toValue: expanded ? 1 : 0,
      duration,
      // `standard` — an in-place morph (a swap), per DS_MOTION_EASING_USE.
      easing: Easing.bezier(...DS_MOTION_EASING.standard),
      useNativeDriver: true,
    });
    anim.start();
    return () => anim.stop();
  }, [expanded, duration, progress]);

  const scaleY = progress.interpolate({ inputRange: [0, 1], outputRange: [1, -1] });

  return (
    <Animated.View style={{ transform: [{ scaleY }] }}>
      <Icon name="chevron-down" size={size} color={color} />
    </Animated.View>
  );
}
