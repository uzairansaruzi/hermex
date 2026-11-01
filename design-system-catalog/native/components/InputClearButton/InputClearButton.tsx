import React, { useState } from 'react';
import { Pressable, StyleSheet, Platform } from 'react-native';
import { DS_SEMANTIC, DS_RADIUS } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';

/** Matches iOS search-field clear control (circle + ×). */
const CLEAR_ICON_SIZE = 20;

export interface InputClearButtonProps {
  onPress: () => void;
  accessibilityLabel?: string;
}

// Web-only: this button only ever renders while its paired field is focused/active — but this
// Pressable is a plain (non-focusable) element, so the browser's default mousedown behaviour blurs
// the field the instant the press starts. That blur triggers InputField/SearchField's own
// `focused` state to flip synchronously, which unmounts THIS Pressable before its own press event
// ever gets to fire — the clear action is silently dropped (confirmed: neither onPress nor
// onPressIn ran). Blocking the browser's default mousedown behaviour keeps the field focused
// through the whole press, so this Pressable is still mounted by the time onPress fires. Native has
// no such default-focus-shift-on-press behaviour, so this is web-only.
const preventFocusSteal = Platform.OS === 'web' ? { onMouseDown: (e: { preventDefault: () => void }) => e.preventDefault() } : null;

export function InputClearButton({
  onPress,
  accessibilityLabel = 'Clear field',
}: InputClearButtonProps) {
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      onPress={onPress}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      {...preventFocusSteal}
      // 24x24 visual + 10 on every side reaches the 44pt touch-target minimum.
      hitSlop={10}
      // Keyboard focus shows the same highlight as a press (same policy as ListItem/SegmentedToggle).
      style={({ pressed }) => [styles.button, (pressed || focused) && styles.buttonPressed]}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
    >
      {/* A solid filled icon reads much heavier than the old stroke ×  — muted keeps it a quiet
          utility action rather than competing with the field's own value text. */}
      <Icon name="circle-x" size={CLEAR_ICON_SIZE} color={DS_SEMANTIC.text.muted} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    width: 24,
    height: 24,
    borderRadius: DS_RADIUS.round,
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
  },
  buttonPressed: {
    backgroundColor: DS_SEMANTIC.interaction.pressed,
  },
});
