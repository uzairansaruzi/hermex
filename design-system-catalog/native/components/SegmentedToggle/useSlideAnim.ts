import { useEffect, useRef } from 'react';
import { Animated, Easing } from 'react-native';
import { DS_MOTION_DURATION, DS_MOTION_EASING } from '../../../tokens';

/** How long the selection indicator takes to slide to its new position. */
export const SLIDE_ANIM_MS = DS_MOTION_DURATION.base;

/**
 * Shared by SegmentedToggle and UnderlineTabs: an Animated.Value that eases to `selectedIndex`
 * whenever it changes. Each component still does its own position math (SegmentedToggle computes
 * fixed equal-width segments analytically; UnderlineTabs measures each tab's real width via onLayout)
 * — those differ enough between the two that unifying them isn't safe to do blindly, but the "animate
 * to the new index" mechanics underneath were byte-identical, so that part is shared here.
 */
export function useSlideAnim(selectedIndex: number, useNativeDriver: boolean) {
  const anim = useRef(new Animated.Value(selectedIndex)).current;

  useEffect(() => {
    Animated.timing(anim, {
      toValue: selectedIndex,
      duration: SLIDE_ANIM_MS,
      // `standard` — a move that starts and ends on screen (a toggle/swap), per DS_MOTION_EASING_USE.
      easing: Easing.bezier(...DS_MOTION_EASING.standard),
      useNativeDriver,
    }).start();
  }, [selectedIndex, anim, useNativeDriver]);

  return anim;
}
