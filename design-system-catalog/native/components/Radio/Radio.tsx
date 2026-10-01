import React, { useEffect, useRef, useState } from 'react';
import { Pressable, Text, View, Animated, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_RADIUS, DS_TYPOGRAPHY, DS_A11Y_MIN_TOUCH_TARGET, DS_MOTION_DURATION } from '../../../tokens';
import { usePressScale } from './usePressScale';

export interface RadioProps {
  selected: boolean;
  onPress: () => void;
  /** Optional inline label rendered to the right of the circle. */
  label?: string;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
  /** Optional color override for the selected ring/dot and unselected border, consumed by the
   *  Hermex gallery to match native's Neutral color mapping. Omitted, the generic template default
   *  (DS_SEMANTIC.emphasis.info selected / DS_SEMANTIC.border.dark unselected) is unchanged. */
  colors?: { selected?: string; unselectedBorder?: string };
}

const CIRCLE_SIZE = 20;
const DOT_SIZE = 10;
// Pads the tappable area out to the accessibility minimum without growing the visual circle — same
// reasoning as Button's own `iconOnlyHitSlop`. Applied on all sides since a no-label Radio's row is
// exactly CIRCLE_SIZE tall/wide; a labelled row is already wider, where the extra hitSlop is
// harmless overlap into surrounding whitespace rather than another control.
const HIT_SLOP = Math.max(0, Math.ceil((DS_A11Y_MIN_TOUCH_TARGET - CIRCLE_SIZE) / 2));

/**
 * A single circular selection control — a filled dot appears in the ring when selected. A group of
 * mutually-exclusive Radios is just multiple instances sharing one "selected value" in the consumer
 * (the same way a native radio group works); this component itself only knows its own selected state.
 * The circle grows slightly while pressed, for tactile feedback before release, and the dot itself
 * pops in/out (scale + opacity) rather than snapping — both kept JS-driven (`useNativeDriver: false`)
 * for the same Fabric-safety reason.
 */
export function Radio({ selected, onPress, label, disabled = false, style, colors }: RadioProps) {
  const { pressScale, onPressIn, onPressOut } = usePressScale(disabled);
  const dotAnim = useRef(new Animated.Value(selected ? 1 : 0)).current;
  const [focused, setFocused] = useState(false);

  useEffect(() => {
    Animated.timing(dotAnim, {
      toValue: selected ? 1 : 0,
      duration: DS_MOTION_DURATION.fast,
      useNativeDriver: false,
    }).start();
  }, [selected, dotAnim]);

  return (
    <Pressable
      onPress={() => !disabled && onPress()}
      onPressIn={onPressIn}
      onPressOut={onPressOut}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      disabled={disabled}
      accessibilityRole="radio"
      accessibilityState={{ selected, disabled }}
      accessibilityLabel={label}
      hitSlop={HIT_SLOP}
      style={[styles.row, disabled && styles.disabled, style]}
    >
      <Animated.View
        style={[
          styles.circle,
          selected && styles.circleSelected,
          !selected && colors?.unselectedBorder ? { borderColor: colors.unselectedBorder } : null,
          selected && colors?.selected ? { borderColor: colors.selected } : null,
          { transform: [{ scale: pressScale }] },
        ]}
      >
        <Animated.View
          style={[
            styles.dot,
            colors?.selected ? { backgroundColor: colors.selected } : null,
            { opacity: dotAnim, transform: [{ scale: dotAnim }] },
          ]}
        />
        {/* Keyboard-focus ring — same interaction.focused treatment Button/Pill use; a zero-layout
            absolute overlay so focusing never shifts layout. */}
        {focused && !disabled && <View pointerEvents="none" style={styles.focusRing} />}
      </Animated.View>
      {!!label && <Text style={styles.label}>{label}</Text>}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[400],
  },
  circle: {
    width: CIRCLE_SIZE,
    height: CIRCLE_SIZE,
    borderRadius: DS_RADIUS.round,
    borderWidth: 2,
    borderColor: DS_SEMANTIC.border.dark,
    alignItems: 'center',
    justifyContent: 'center',
  },
  circleSelected: {
    borderColor: DS_SEMANTIC.emphasis.info,
  },
  dot: {
    width: DOT_SIZE,
    height: DOT_SIZE,
    borderRadius: DS_RADIUS.round,
    backgroundColor: DS_SEMANTIC.emphasis.info,
  },
  label: {
    ...DS_TYPOGRAPHY.bodyMd,
    color: DS_SEMANTIC.text.regular,
  },
  disabled: {
    opacity: DS_SEMANTIC.interaction.disabledOpacity,
  },
  // 2px air + 2px ring outside the circle; fully round to stay concentric.
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
