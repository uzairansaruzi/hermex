import React, { useEffect, useRef, useState } from 'react';
import { Pressable, Text, View, Animated, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_RADIUS, DS_TYPOGRAPHY, DS_A11Y_MIN_TOUCH_TARGET, DS_MOTION_DURATION, DS_ICON_SIZE } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import { usePressScale } from '../Radio/usePressScale';

export interface CheckboxProps {
  checked: boolean;
  /** Omit when a containing row already owns the tap (e.g. a multi-select list row) — the box then
   *  renders the same visual as a non-interactive, accessibility-hidden indicator instead of a second,
   *  nested interactive control. Pass it to make the checkbox itself the tap target. */
  onChange?: (checked: boolean) => void;
  /** Optional inline label rendered to the right of the box. Ignored (and not announced) in the
   *  row-owned indicator mode — the owning row supplies its own accessible name/state instead. */
  label?: string;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
  /** Optional color override for the checked fill/border and the checkmark's inverse foreground,
   *  consumed by the Hermex gallery to match native's Neutral color mapping. Omitted, the generic
   *  template default (DS_SEMANTIC.emphasis.info selected / DS_SEMANTIC.surface.white foreground /
   *  DS_SEMANTIC.border.dark unselected) is unchanged. */
  colors?: { selected?: string; selectedForeground?: string; unselectedBorder?: string };
}

const BOX_SIZE = 20;
const ANIM_MS = DS_MOTION_DURATION.fast;
// Pads the tappable area out to the accessibility minimum without growing the visual box — same
// reasoning as Button's own `iconOnlyHitSlop` and Radio's `HIT_SLOP`.
const HIT_SLOP = Math.max(0, Math.ceil((DS_A11Y_MIN_TOUCH_TARGET - BOX_SIZE) / 2));

/** A square selection control — the box fills with the accent colour and the checkmark pops in
 *  (scale + opacity) when checked, and back out when unchecked — kept JS-driven
 *  (`useNativeDriver: false`) since the box's own border/background colour animate too. The box
 *  also grows slightly while pressed, before release — the same tactile feedback Radio and Switch
 *  already give, so all three selection controls feel consistent.
 *
 *  Omitting `onChange` switches the whole control into a row-owned indicator: a plain, non-focusable
 *  View rendering the identical box/checkmark visual, hidden from assistive tech so a containing
 *  row's own Pressable stays the only interactive/accessible control — never a checkbox nested inside
 *  another control. */
export function Checkbox({ checked, onChange, label, disabled = false, style, colors }: CheckboxProps) {
  const checkAnim = useRef(new Animated.Value(checked ? 1 : 0)).current;
  const { pressScale, onPressIn, onPressOut } = usePressScale(disabled);
  const [focused, setFocused] = useState(false);

  useEffect(() => {
    const anim = Animated.timing(checkAnim, { toValue: checked ? 1 : 0, duration: ANIM_MS, useNativeDriver: false });
    anim.start();
    return () => anim.stop();
  }, [checked, checkAnim]);

  const selectedColor = colors?.selected ?? DS_SEMANTIC.emphasis.info;
  const unselectedBorderColor = colors?.unselectedBorder ?? DS_SEMANTIC.border.dark;
  const selectedForegroundColor = colors?.selectedForeground ?? DS_SEMANTIC.surface.white;

  const boxBackground = checkAnim.interpolate({ inputRange: [0, 1], outputRange: ['rgba(0,0,0,0)', selectedColor] });
  const boxBorderColor = checkAnim.interpolate({ inputRange: [0, 1], outputRange: [unselectedBorderColor, selectedColor] });

  const box = (
    <Animated.View style={[styles.box, { backgroundColor: boxBackground, borderColor: boxBorderColor, transform: [{ scale: pressScale }] }]}>
      <Animated.View style={{ opacity: checkAnim, transform: [{ scale: checkAnim }] }}>
        <Icon name="check" size={DS_ICON_SIZE.xs} color={selectedForegroundColor} strokeWidth={3} />
      </Animated.View>
      {/* Keyboard-focus ring — the same interaction.focused treatment Button/Pill use, drawn as a
          zero-layout absolute overlay around the box so focusing never shifts layout. */}
      {focused && !disabled && <View pointerEvents="none" style={styles.focusRing} />}
    </Animated.View>
  );

  if (!onChange) {
    return (
      <View
        style={[styles.row, disabled && styles.disabled, style]}
        accessibilityElementsHidden
        importantForAccessibility="no-hide-descendants"
      >
        {box}
        {!!label && <Text style={styles.label}>{label}</Text>}
      </View>
    );
  }

  return (
    <Pressable
      onPress={() => !disabled && onChange(!checked)}
      onPressIn={onPressIn}
      onPressOut={onPressOut}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      disabled={disabled}
      accessibilityRole="checkbox"
      accessibilityState={{ checked, disabled }}
      accessibilityLabel={label}
      hitSlop={HIT_SLOP}
      style={[styles.row, disabled && styles.disabled, style]}
    >
      {box}
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
  box: {
    width: BOX_SIZE,
    height: BOX_SIZE,
    borderRadius: DS_RADIUS.xs,
    borderWidth: 2,
    borderColor: DS_SEMANTIC.border.dark,
    alignItems: 'center',
    justifyContent: 'center',
  },
  label: {
    ...DS_TYPOGRAPHY.bodyMd,
    color: DS_SEMANTIC.text.regular,
  },
  disabled: {
    opacity: DS_SEMANTIC.interaction.disabledOpacity,
  },
  // 2px air + 2px ring outside the box, radius grown by the same offset to stay concentric.
  focusRing: {
    position: 'absolute',
    top: -4,
    bottom: -4,
    left: -4,
    right: -4,
    borderWidth: 2,
    borderColor: DS_SEMANTIC.interaction.focused,
    borderRadius: DS_RADIUS.xs + 4,
  },
});
