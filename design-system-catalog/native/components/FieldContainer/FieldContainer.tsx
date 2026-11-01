import React from 'react';
import { View, Pressable, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_RADIUS } from '../../../tokens';
import { useSurfaceTone } from '../Surface';
import type { FieldContainerProps } from './FieldContainer.types';

/**
 * The shared "field" chrome: medium radius, a 1px subtle border that darkens to border.dark on
 * focus, and a fill that contrasts with whatever it's actually placed on — reads the ambient
 * `useSurfaceTone()` (see `Surface`) rather than assuming one fixed background. On the default
 * white tone it's a translucent recessed fill (the same adaptive-overlay mechanism SegmentedToggle's
 * track and Button's own `secondary` variant use); on a `muted` surface (wrapped in
 * `<Surface tone="muted">`) it flips to opaque white instead, so it never goes invisible against
 * whatever's behind it either way. It owns *only* the container look — consumers (InputField,
 * TextArea, SearchField) supply their own layout (height, padding, content) via `style` and
 * children, so a single-line row and a multiline area stay visually consistent.
 */
export function FieldContainer({
  focused = false,
  disabled = false,
  onPress,
  pressed = false,
  accessibilityLabel,
  accessibilityState,
  style,
  children,
}: FieldContainerProps) {
  const onWhite = useSurfaceTone() === 'white';
  const toneStyle = onWhite ? stylesOnWhite : stylesOnMuted;

  const stylesFor = (isPressed: boolean) => [
    styles.base,
    toneStyle.rest,
    disabled && toneStyle.disabled,
    !disabled && focused && toneStyle.focused,
    !disabled && isPressed && toneStyle.pressed,
    style,
  ];

  if (onPress && !disabled) {
    // Pressable owns the pressed feedback; OR in the caller-driven `pressed` so both sources work.
    return (
      <Pressable
        onPress={onPress}
        accessibilityRole="button"
        accessibilityLabel={accessibilityLabel}
        accessibilityState={accessibilityState}
        style={({ pressed: p }) => stylesFor(p || pressed)}
      >
        {children}
      </Pressable>
    );
  }

  // Non-Pressable (e.g. editable, or a disabled picker) fields still honour the caller-driven
  // pressed treatment. When the caller gave this container a name/state, keep it an accessible
  // button element — a disabled picker must announce as "…, button, disabled", not vanish from
  // the accessibility tree just because it lost its Pressable.
  const stillAccessible = accessibilityLabel != null || accessibilityState != null;
  return (
    <View
      style={stylesFor(pressed)}
      accessible={stillAccessible || undefined}
      accessibilityRole={stillAccessible ? 'button' : undefined}
      accessibilityLabel={accessibilityLabel}
      accessibilityState={accessibilityState}
    >
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  base: {
    borderRadius: DS_RADIUS.medium,
    borderWidth: 1,
    borderColor: DS_SEMANTIC.border.subtle,
  },
});

// On a white surface: translucent recessed fill, tuned pressed/disabled versions of that same
// overlay (recessedPressed/recessedDisabled — not a second overlay stacked on top, see Button's own
// `secondary` variant for why).
const stylesOnWhite = StyleSheet.create({
  rest: { backgroundColor: DS_SEMANTIC.surface.recessed },
  focused: { borderColor: DS_SEMANTIC.border.dark },
  pressed: { backgroundColor: DS_SEMANTIC.surface.recessedPressed },
  disabled: { backgroundColor: DS_SEMANTIC.surface.recessedDisabled, borderColor: DS_SEMANTIC.border.subtle },
});

// On a muted surface: opaque white fill instead (recessed would barely read against an
// already-grey background) — pressed/disabled are the plain surface tokens for "a white
// surface, tapped" / "a white surface, muted-out", the same ones other white-fill surfaces use.
const stylesOnMuted = StyleSheet.create({
  rest: { backgroundColor: DS_SEMANTIC.surface.white },
  focused: { borderColor: DS_SEMANTIC.border.dark },
  pressed: { backgroundColor: DS_SEMANTIC.surface.onTap },
  disabled: { backgroundColor: DS_SEMANTIC.surface.muted, borderColor: DS_SEMANTIC.border.subtle },
});
