import React, { useState } from 'react';
import { Pressable, Text, View, Animated, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_RADIUS, DS_SHADOW, DS_TYPOGRAPHY, DS_A11Y_MIN_TOUCH_TARGET } from '../../../tokens';
import { useSlideAnim } from '../SegmentedToggle/useSlideAnim';
import { usePressScale } from '../Radio/usePressScale';

export interface SwitchProps {
  value: boolean;
  onValueChange: (value: boolean) => void;
  /** Optional inline label rendered to the left of the track, at the same bodyMd size/weight
   *  Checkbox/Radio use for their own labels — tapping it toggles the switch too. */
  label?: string;
  disabled?: boolean;
  /** Accessible name. Defaults to `label` when set — pass this separately only when the switch
   *  needs a different (or the only) spoken name, e.g. no visible label at all. */
  accessibilityLabel?: string;
  style?: StyleProp<ViewStyle>;
}

const TRACK_WIDTH = 51;
const TRACK_HEIGHT = 31;
// Sized so (TRACK_HEIGHT - THUMB_SIZE) / 2 lands on 4 — the same total inset SegmentedToggle's own
// thumb gets (its TRACK_PADDING + THUMB_INSET, both DS_SPACING[100]) — so the two sliding controls'
// thumbs read with the same amount of breathing room around them.
const THUMB_SIZE = 23;
// Horizontal inset for the thumb's off/on positions — matched to the vertical gap the track's own
// `justifyContent: 'center'` already gives it ((TRACK_HEIGHT - THUMB_SIZE) / 2 = 4), so the padding
// around the thumb reads as an even ring on every side, not tighter left/right than top/bottom.
const THUMB_INSET = (TRACK_HEIGHT - THUMB_SIZE) / 2;
// Pads the tappable area vertically out to the accessibility minimum — same reasoning as Button's
// own `iconOnlyHitSlop`. TRACK_WIDTH (51) already clears the minimum horizontally, so only the
// vertical sides need it.
const HIT_SLOP = {
  top: Math.ceil((DS_A11Y_MIN_TOUCH_TARGET - TRACK_HEIGHT) / 2),
  bottom: Math.ceil((DS_A11Y_MIN_TOUCH_TARGET - TRACK_HEIGHT) / 2),
};

/**
 * A boolean on/off toggle. The thumb slides between its two resting positions and the track fades
 * between its off/on colours together, driven by the same shared slide animation SegmentedToggle and
 * UnderlineTabs use (JS-driven here, since the track colour crossfade needs it) for a consistent
 * motion feel across the DS's sliding controls. The thumb also grows slightly while pressed, for
 * tactile feedback before release. Kept on the same JS-driven pipeline as the slide/colour (not
 * `useNativeDriver: true`) — mixing native- and JS-driven animations on the same Animated.View's
 * transform is unreliable in RN, and this component's slide already has to be JS-driven anyway.
 */
export function Switch({ value, onValueChange, label, disabled = false, accessibilityLabel, style }: SwitchProps) {
  const anim = useSlideAnim(value ? 1 : 0, false);
  const { pressScale, onPressIn, onPressOut } = usePressScale(disabled);
  const [focused, setFocused] = useState(false);

  const trackColor = anim.interpolate({
    inputRange: [0, 1],
    outputRange: [DS_SEMANTIC.surface.recessed, DS_SEMANTIC.emphasis.positive],
  });
  const thumbX = anim.interpolate({
    inputRange: [0, 1],
    outputRange: [THUMB_INSET, TRACK_WIDTH - THUMB_SIZE - THUMB_INSET],
  });

  return (
    <Pressable
      onPress={() => !disabled && onValueChange(!value)}
      onPressIn={onPressIn}
      onPressOut={onPressOut}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      disabled={disabled}
      accessibilityRole="switch"
      accessibilityState={{ checked: value, disabled }}
      accessibilityLabel={accessibilityLabel ?? label}
      hitSlop={HIT_SLOP}
      style={[styles.row, disabled && styles.disabled, style]}
    >
      {/* Label sits before the track (unlike Checkbox/Radio's control-then-label) — matches the
          near-universal settings-row convention (description left, toggle right), while still
          sharing their bodyMd label typography. */}
      {!!label && <Text style={styles.label}>{label}</Text>}
      <Animated.View style={[styles.track, { backgroundColor: trackColor }]}>
        <Animated.View style={[styles.thumb, { transform: [{ translateX: thumbX }, { scale: pressScale }] }]} />
        {/* Keyboard-focus ring — same interaction.focused treatment Button/Pill use; a zero-layout
            absolute overlay so focusing never shifts layout. */}
        {focused && !disabled && <View pointerEvents="none" style={styles.focusRing} />}
      </Animated.View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[400],
  },
  label: {
    ...DS_TYPOGRAPHY.bodyMd,
    color: DS_SEMANTIC.text.regular,
  },
  track: {
    width: TRACK_WIDTH,
    height: TRACK_HEIGHT,
    borderRadius: DS_RADIUS.round,
    justifyContent: 'center',
  },
  thumb: {
    width: THUMB_SIZE,
    height: THUMB_SIZE,
    borderRadius: DS_RADIUS.round,
    backgroundColor: DS_SEMANTIC.surface.white,
    ...DS_SHADOW.resting,
  },
  disabled: {
    opacity: DS_SEMANTIC.interaction.disabledOpacity,
  },
  // 2px air + 2px ring outside the track; fully round to stay concentric.
  focusRing: {
    position: 'absolute',
    top: -4,
    bottom: -4,
    left: -4,
    right: -4,
    borderWidth: 2,
    borderColor: DS_SEMANTIC.interaction.focused,
    borderRadius: DS_RADIUS.round,
  },
});
