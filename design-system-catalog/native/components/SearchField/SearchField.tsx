import React, { forwardRef, useState } from 'react';
import {
  TextInput,
  StyleSheet,
  Platform,
  type TextInputProps,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import { FieldContainer } from '../FieldContainer';
import { InputClearButton } from '../InputClearButton';
import { Icon } from '../../../icons/Icon.native';
import type { IconName } from '../../../icons';
import { DS_SEMANTIC, DS_SPACING, DS_TYPOGRAPHY, DS_ICON_SIZE } from '../../../tokens';

export interface SearchFieldProps extends TextInputProps {
  /** Leading icon (defaults to the search glyph). */
  iconName?: IconName;
  /** Extra layout applied to the field container (e.g. margins). */
  containerStyle?: StyleProp<ViewStyle>;
  /** Disabled state — dimmed icon/text (a step past the hint/placeholder tone, so it reads as
   *  inactive rather than merely empty), non-interactive. Forces the field non-editable regardless
   *  of `editable`, matching InputField/TextArea. */
  disabled?: boolean;
}

/**
 * Single-line search input on the shared field chrome ({@link FieldContainer}): white fill, medium
 * radius, a 1px subtle border that **darkens to border.dark on focus**, 56px tall, with a leading search
 * icon. While the field is active (focused with text) a **clear (×) button** appears on the right and
 * wipes the input on tap. Forwards a ref to the underlying TextInput; all `TextInputProps` pass through.
 * Works controlled (`value` + `onChangeText`) or uncontrolled (`defaultValue`). Pick one mode per
 * mounted instance and stick with it.
 */
export const SearchField = forwardRef<TextInput, SearchFieldProps>(function SearchField(
  { iconName = 'search', containerStyle, style, value, defaultValue, onChangeText, onFocus, onBlur, disabled = false, editable, ...rest },
  ref,
) {
  const isControlled = value !== undefined;
  const [internal, setInternal] = useState(defaultValue ?? '');
  const [focused, setFocused] = useState(false);
  const text = isControlled ? value : internal;

  const change = (t: string) => {
    if (!isControlled) setInternal(t);
    onChangeText?.(t);
  };

  const showClear = !disabled && focused && !!text && text.length > 0;

  return (
    <FieldContainer focused={focused} disabled={disabled} style={[styles.container, containerStyle]}>
      <Icon
        name={iconName}
        size={DS_ICON_SIZE.sm}
        color={disabled ? DS_SEMANTIC.text.disabled : focused ? DS_SEMANTIC.text.regular : DS_SEMANTIC.text.muted}
      />
      <TextInput
        ref={ref}
        style={[styles.input, disabled && styles.inputDisabled, style]}
        placeholderTextColor={disabled ? DS_SEMANTIC.text.disabled : DS_SEMANTIC.text.muted}
        value={text}
        onChangeText={change}
        onFocus={(e) => { setFocused(true); onFocus?.(e); }}
        onBlur={(e) => { setFocused(false); onBlur?.(e); }}
        editable={disabled ? false : editable}
        {...rest}
      />
      {showClear ? <InputClearButton onPress={() => change('')} accessibilityLabel="Clear search" /> : null}
    </FieldContainer>
  );
});

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[800],
    height: DS_SPACING[2800],
    paddingHorizontal: DS_SPACING[800],
  },
  input: {
    flex: 1,
    minWidth: 0,
    // Just the token's size, not the full bodyMd (a TextInput mishandles lineHeight's vertical centering).
    fontSize: DS_TYPOGRAPHY.bodyMd.fontSize,
    color: DS_SEMANTIC.text.regular,
    padding: 0,
    margin: 0,
    includeFontPadding: false,
    ...Platform.select({ android: { textAlignVertical: 'center' as const }, default: {} }),
  },
  // A step lighter than the placeholder's muted tone — see DS_SEMANTIC.text.disabled's own doc
  // comment on why disabled text shouldn't just reuse the hint color.
  inputDisabled: {
    color: DS_SEMANTIC.text.disabled,
  },
});
