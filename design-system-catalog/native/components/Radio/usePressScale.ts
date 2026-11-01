import { useEffect, useRef, useState } from 'react';
import { Animated } from 'react-native';
import { DS_MOTION_DURATION } from '../../../tokens';

/** How much a control's own touchable grows while pressed. */
export const PRESS_SCALE = 1.15;

/**
 * Shared by Radio, Checkbox, and Switch: "grow slightly while pressed, before release" tactile
 * feedback — the exact same state/animation mechanics were previously copy-pasted verbatim across
 * all three. `disabled` controls are inert; `onPressIn` won't start the grow for them (a disabled
 * control has no interaction to give feedback about).
 */
export function usePressScale(disabled: boolean) {
  const [pressed, setPressed] = useState(false);
  const pressScale = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    Animated.timing(pressScale, {
      toValue: pressed ? PRESS_SCALE : 1,
      // Grow-in at 100ms — deliberately snappier than any duration token (press feedback must feel
      // instant under the finger); the release settles at the standard fast duration.
      duration: pressed ? 100 : DS_MOTION_DURATION.fast,
      useNativeDriver: false,
    }).start();
  }, [pressed, pressScale]);

  return {
    pressScale,
    onPressIn: () => !disabled && setPressed(true),
    onPressOut: () => setPressed(false),
  };
}
