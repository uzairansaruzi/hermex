import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  View,
  Text,
  TextInput,
  Animated,
  Pressable,
  StyleSheet,
  Platform,
  type StyleProp,
  type ViewStyle,
  type TextInputProps,
} from 'react-native';
import { InputClearButton } from '../InputClearButton';
import { useSurfaceTone } from '../Surface';
import { DS_SEMANTIC, DS_SPACING, DS_RADIUS, DS_TYPOGRAPHY, DS_FONT_WEIGHT } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import type { IconName } from '../../../icons';

/**
 * The label shown at the head of the field. Text variants render as a word; `'icon'` renders a
 * leading icon instead (supply `labelIcon`).
 */
export type InputFieldLabelVariant = 'To' | 'From' | 'Walk time' | 'Arrive by' | 'Name' | 'icon';

const LABEL_TEXT: Record<Exclude<InputFieldLabelVariant, 'icon'>, string> = {
  To: 'To',
  From: 'From',
  'Walk time': 'Walk time',
  'Arrive by': 'Arrive by',
  Name: 'Name',
};

// Float / border cross-fade duration. JS-driven (useNativeDriver:false) so the label size cross-fade
// and the border-colour fade both render in the web preview too — native-driver opacity doesn't.
const ANIM_MS = 170;

export interface InputFieldProps {
  label?: InputFieldLabelVariant;
  /** Icon for the `label="icon"` variant. */
  labelIcon?: IconName;
  value?: string;
  /** Trailing icon rendered after the value text. Also tints the value text with the accent colour,
   *  so the two always match. */
  valueIcon?: IconName;
  /** Tint the value text with the accent (info) colour. Overridden by valueIcon's tint when both are set. */
  valueAccent?: boolean;
  placeholder?: string;
  onPress?: () => void;
  onChangeText?: (text: string) => void;
  editable?: boolean;
  /** Force the active (floated label + border) look — for a picker field whose external picker (e.g.
   *  a Dropdown's sheet) is open. Editable fields derive this from focus and ignore it. */
  active?: boolean;
  /** Appends " (Optional)" to the RESTING label only — it drops off once the label floats, so the
   *  marker reads at a glance before the field is touched without cluttering the active hint. */
  optional?: boolean;
  /** Disabled state — dimmed label/value text (a step lighter than the hint/placeholder tone),
   *  non-interactive, no border. */
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
  inputProps?: Omit<TextInputProps, 'value' | 'onChangeText' | 'placeholder' | 'editable'>;
}

/**
 * Floating-label field. Three states:
 *  - Resting: only the muted label, body-sized and vertically centred (no border).
 *  - Active: the label shrinks/rises to a small top label; row 2 shows the value/hint (+ a clear
 *    button for editable fields); a border wraps the whole field (editable → while focused; picker
 *    → while `active`).
 *  - Filled: same two-row layout with the entered value on row 2, and the border removed.
 */
export function InputField({
  label = 'To',
  labelIcon,
  value,
  valueIcon,
  valueAccent = false,
  placeholder,
  onPress,
  onChangeText,
  editable = false,
  active = false,
  optional = false,
  disabled = false,
  style,
  inputProps,
}: InputFieldProps) {
  const [focused, setFocused] = useState(false);
  const [pressed, setPressed] = useState(false);
  const inputRef = useRef<TextInput>(null);
  const onWhite = useSurfaceTone() === 'white';

  const hasValue = Boolean(value?.trim());
  const isEditable = editable && !disabled;
  // Border-showing "active": an editable field while focused; a picker field while its external
  // picker is open (`active`) or being pressed. Never for a disabled field.
  const isActive = !disabled && (isEditable ? focused : (active || pressed));
  // Label floats to the top whenever the field is active or already holds a value.
  const isFloated = isActive || hasValue;

  const floatAnim = useRef(new Animated.Value(isFloated ? 1 : 0)).current;
  const activeAnim = useRef(new Animated.Value(isActive ? 1 : 0)).current;
  useEffect(() => {
    Animated.timing(floatAnim, { toValue: isFloated ? 1 : 0, duration: ANIM_MS, useNativeDriver: false }).start();
  }, [isFloated, floatAnim]);
  useEffect(() => {
    Animated.timing(activeAnim, { toValue: isActive ? 1 : 0, duration: ANIM_MS, useNativeDriver: false }).start();
  }, [isActive, activeAnim]);

  const borderColor = activeAnim.interpolate({
    inputRange: [0, 1],
    outputRange: ['rgba(0,0,0,0)', DS_SEMANTIC.border.dark],
  });
  const restOpacity = floatAnim.interpolate({ inputRange: [0, 1], outputRange: [1, 0] });
  const floatTranslate = floatAnim.interpolate({ inputRange: [0, 1], outputRange: [6, 0] });
  // The label morphs as ONE element (position + size) between its resting and floated look, rather
  // than cross-fading two separately-positioned copies — animating `top`/`fontSize` directly (not a
  // `scale` transform) sidesteps needing a left-anchored transform-origin, which RN doesn't support
  // consistently across native/web. Safe because this whole animation is already JS-driven
  // (`useNativeDriver:false` — see ANIM_MS above), which allows animating arbitrary style numbers,
  // not just transform/opacity.
  const REST_LABEL_TOP = (FIELD_MIN_HEIGHT - 20) / 2; // vertically centers the rest-sized (20 lineHeight) label
  const labelTop = floatAnim.interpolate({ inputRange: [0, 1], outputRange: [REST_LABEL_TOP, PAD] });
  const labelFontSize = floatAnim.interpolate({ inputRange: [0, 1], outputRange: [DS_TYPOGRAPHY.bodyMd.fontSize, DS_TYPOGRAPHY.labelXs.fontSize] });
  const labelLineHeight = floatAnim.interpolate({ inputRange: [0, 1], outputRange: [20, 16] });

  const handleFocus = useCallback(
    (event: Parameters<NonNullable<TextInputProps['onFocus']>>[0]) => {
      setFocused(true);
      inputProps?.onFocus?.(event);
    },
    [inputProps],
  );
  const handleBlur = useCallback(
    (event: Parameters<NonNullable<TextInputProps['onBlur']>>[0]) => {
      setFocused(false);
      inputProps?.onBlur?.(event);
    },
    [inputProps],
  );
  const handlePress = useCallback(() => {
    if (disabled) return;
    if (isEditable) inputRef.current?.focus();
    else onPress?.();
  }, [disabled, isEditable, onPress]);
  // Clear the entry and keep the caret in the field so the user can retype straight away.
  const handleClear = useCallback(() => {
    onChangeText?.('');
    inputRef.current?.focus();
  }, [onChangeText]);

  // A clear button belongs on any field that's both active AND already holds a value — an editable
  // field while focused, or a picker field while its external picker is open (`active`) — but stays
  // out of the resting/filled state either way (clearing a field the user isn't currently looking at
  // would be a surprising action to expose).
  const showClear = !disabled && hasValue && (isEditable ? focused : active);

  // The label is muted in both states, so — unlike the icon variant below — a text label needs no
  // per-state node at all; it's one continuously-morphing element (see `fieldBody`). The "(Optional)"
  // marker fades out on its own as the field floats, since it only makes sense at rest.
  const labelBase = label === 'icon' ? '' : LABEL_TEXT[label];
  // Disabled dims the label along with the value (see `styles.disabledText`) so the whole field
  // reads as one washed-out unit, not just its value text.
  const labelIconColor = disabled ? DS_SEMANTIC.text.disabled : DS_SEMANTIC.text.muted;
  const restIconNode = label === 'icon' ? <Icon name={labelIcon ?? 'flag'} color={labelIconColor} /> : null;
  const floatIconNode = label === 'icon' ? <Icon name={labelIcon ?? 'flag'} size={12} color={labelIconColor} /> : null;

  // Row 2 content: the text input (editable) or the value / placeholder-hint (picker & display).
  let valueRow: React.ReactNode;
  if (isEditable) {
    valueRow = (
      <TextInput
        ref={inputRef}
        {...inputProps}
        style={[styles.value, styles.valueInput, inputProps?.style]}
        value={value}
        placeholder={placeholder}
        // text.muted (grey600), not the lighter grey500 hint tone this used when the field's own
        // background was surface.white — grey500 falls short of AA (~4.34:1) on surface.main, the
        // field's current background (see DS_SEMANTIC.text.muted's own doc comment).
        placeholderTextColor={DS_SEMANTIC.text.muted}
        onChangeText={onChangeText}
        onFocus={handleFocus}
        onBlur={handleBlur}
        editable
      />
    );
  } else if (hasValue && valueIcon) {
    // Icon-paired value: tight icon+text pairing, tinted with the accent colour.
    valueRow = (
      <View style={styles.valueIconGroup}>
        <Text style={[styles.value, styles.valueName, styles.valueAccent]} numberOfLines={1}>
          {value}
        </Text>
        <Icon name={valueIcon} size={16} color={DS_SEMANTIC.emphasis.info} />
      </View>
    );
  } else {
    const showPlaceholder = !hasValue;
    valueRow = (
      <Text
        style={[
          styles.value,
          styles.valueName,
          disabled && styles.disabledText,
          showPlaceholder && !disabled && styles.hintText,
          hasValue && !disabled && valueAccent && styles.valueAccent,
        ]}
        numberOfLines={1}
      >
        {hasValue ? value : placeholder}
      </Text>
    );
  }

  const fieldBody = (
    <Animated.View style={[styles.field, { backgroundColor: onWhite ? DS_SEMANTIC.surface.recessed : DS_SEMANTIC.surface.white }, { borderColor }]}>
      {label === 'icon' ? (
        <>
          {/* Icon label has no in-between size to morph through — it still cross-fades between its
              two fixed sizes, same as before. */}
          <Animated.View style={[styles.restLabelWrap, { opacity: restOpacity }]} pointerEvents="none">
            {restIconNode}
          </Animated.View>
          <Animated.View
            style={[styles.floatLabelWrap, { opacity: floatAnim, transform: [{ translateY: floatTranslate }] }]}
            pointerEvents="none"
          >
            {floatIconNode}
          </Animated.View>
        </>
      ) : (
        // One continuously-morphing label: `top`/`fontSize`/`lineHeight` animate directly between the
        // resting and floated look, rather than cross-fading two separately-positioned copies.
        <Animated.View style={[styles.morphLabelWrap, { top: labelTop }]} pointerEvents="none">
          <Animated.Text
            style={[styles.morphLabel, { fontSize: labelFontSize, lineHeight: labelLineHeight }, disabled && styles.disabledText]}
            numberOfLines={1}
          >
            {labelBase}
          </Animated.Text>
          {optional && (
            <Animated.Text style={[styles.optionalMark, { opacity: restOpacity }, disabled && styles.disabledText]}> (Optional)</Animated.Text>
          )}
        </Animated.View>
      )}
      {/* Value row — hint/value/input; fades in with the float. Trailing space reserved when the
          clear button shows, so long text never runs under it. */}
      <Animated.View style={[styles.valueRow, showClear && styles.valueRowClear, { opacity: floatAnim }]}>
        {valueRow}
      </Animated.View>
      {/* Clear button — vertically centred over the whole field (not just the value row). */}
      {showClear && (
        <View style={styles.clearButton}>
          <InputClearButton onPress={handleClear} accessibilityLabel={`Clear ${labelBase || 'field'}`} />
        </View>
      )}
    </Animated.View>
  );

  // In picker mode (not editable, driven by `onPress`) the field is really a button — the inner
  // TextInput branch gets accessibility for free from the real `<TextInput>`, but this Pressable
  // otherwise has no name/role of its own for a screen reader to announce. Suppressed while
  // `showClear` is up: the clear button rendered inside `fieldBody` is itself an
  // accessibilityRole="button" Pressable, and nesting one button-role element inside another is
  // invalid HTML (and a confusing screen-reader target either way) — so this outer role steps aside
  // for that one state rather than wrapping the inner button.
  const isPicker = !isEditable;
  const announceAsButton = isPicker && !showClear;

  return (
    <Pressable
      onPress={handlePress}
      onPressIn={() => {
        if (!isEditable && !disabled) setPressed(true);
      }}
      onPressOut={() => setPressed(false)}
      disabled={disabled || (!isEditable && !onPress)}
      accessibilityRole={announceAsButton ? 'button' : undefined}
      accessibilityLabel={announceAsButton ? [labelBase, hasValue ? value : undefined].filter(Boolean).join(', ') : undefined}
      accessibilityState={announceAsButton ? { disabled } : undefined}
      style={[styles.wrap, style]}
    >
      {fieldBody}
    </Pressable>
  );
}

const FIELD_MIN_HEIGHT = 63;
const PAD = DS_SPACING[600]; // 12
const CLEAR_SIZE = 24;
// Trailing inset for the value row when the clear button is shown: field padding + the button + a gap.
const CLEAR_RIGHT_INSET = PAD + CLEAR_SIZE + DS_SPACING[400];

const styles = StyleSheet.create({
  wrap: {
    width: '100%',
  },
  field: {
    // backgroundColor is applied inline at the call site — it depends on the ambient useSurfaceTone()
    // (recessed on white, opaque white on a muted surface — same mechanism FieldContainer uses;
    // InputField predates FieldContainer and still owns its own styles for its label-morph animation).
    borderRadius: DS_RADIUS.medium,
    // 1px reserved always (transparent when inactive) so the field never resizes when the border fades in.
    borderWidth: 1,
    borderColor: 'rgba(0,0,0,0)',
    minHeight: FIELD_MIN_HEIGHT,
    width: '100%',
    position: 'relative',
    justifyContent: 'center',
  },
  restLabelWrap: {
    position: 'absolute',
    left: PAD,
    right: PAD,
    top: 0,
    bottom: 0,
    justifyContent: 'center',
    alignItems: 'flex-start',
  },
  floatLabelWrap: {
    position: 'absolute',
    left: PAD,
    // `right` gives the floated label a real width — without it, an absolute Text with only `left`
    // collapses to its first child's width on iOS/Fabric and drops the trailing "(Optional)" node.
    right: PAD,
    top: PAD,
  },
  // Text-label case: one row, `top` animates between the resting/floated position (see `labelTop`
  // in the component body). Same `right`-needs-a-real-width reasoning as `floatLabelWrap` above.
  morphLabelWrap: {
    position: 'absolute',
    left: PAD,
    right: PAD,
    flexDirection: 'row',
    alignItems: 'flex-end',
  },
  morphLabel: {
    fontWeight: DS_FONT_WEIGHT.semibold,
    color: DS_SEMANTIC.text.muted,
    includeFontPadding: false,
    ...Platform.select({ android: { textAlignVertical: 'center' as const }, default: {} }),
  },
  // Logical start/end (not left/right) so the clear-button inset override below (`valueRowClear`)
  // composes on the same trailing edge in both LTR and RTL.
  valueRow: {
    position: 'absolute',
    start: PAD,
    end: PAD,
    bottom: PAD,
    minHeight: 21,
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[400],
  },
  // Only ever shown at rest (fades out with `restOpacity`), so it keeps the resting label's own
  // fontSize rather than tracking the morph — by the time that'd matter, it's already invisible.
  optionalMark: { ...DS_TYPOGRAPHY.bodyMd, color: DS_SEMANTIC.text.muted },
  value: {
    ...DS_TYPOGRAPHY.bodyMd,
    color: DS_SEMANTIC.text.regular,
    lineHeight: 20,
    padding: 0,
    margin: 0,
    flexShrink: 1,
    minWidth: 0,
    includeFontPadding: false,
    ...Platform.select({ android: { textAlignVertical: 'center' as const }, default: {} }),
  },
  // Editable input fills the row so the clear button is pushed to the far right edge.
  valueInput: {
    flex: 1,
  },
  valueName: {
    flexShrink: 1,
    minWidth: 0,
  },
  // Disabled label/value text — a step lighter than `hintText`'s muted tone, so a disabled field
  // reads as inactive rather than merely empty (see DS_SEMANTIC.text.disabled's own doc comment).
  disabledText: {
    color: DS_SEMANTIC.text.disabled,
  },
  // Picker-mode placeholder — same text.muted rationale as the TextInput's placeholderTextColor above.
  hintText: {
    color: DS_SEMANTIC.text.muted,
  },
  valueAccent: {
    color: DS_SEMANTIC.emphasis.info,
  },
  valueIconGroup: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[200],
    flexShrink: 1,
    minWidth: 0,
  },
  // Pinned to the trailing edge (logical `end`, so it mirrors in RTL) and centred over the FULL
  // field height (top:0/bottom:0), so it sits at the field's vertical middle rather than aligning
  // with the bottom-anchored value row.
  clearButton: {
    position: 'absolute',
    end: PAD,
    top: 0,
    bottom: 0,
    width: CLEAR_SIZE,
    alignItems: 'center',
    justifyContent: 'center',
  },
  valueRowClear: {
    end: CLEAR_RIGHT_INSET,
  },
});
