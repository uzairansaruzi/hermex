import React, { useCallback, useState } from 'react';
import {
  TextInput,
  StyleSheet,
  type StyleProp,
  type ViewStyle,
  type TextInputProps,
} from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_TYPOGRAPHY } from '../../../tokens';
import { FieldContainer } from '../FieldContainer';

export interface TextAreaProps {
  value: string;
  onChangeText: (text: string) => void;
  placeholder?: string;
  /** Min height of the field before it grows with content (default 96). */
  minHeight?: number;
  editable?: boolean;
  autoFocus?: boolean;
  inputRef?: React.Ref<TextInput>;
  style?: StyleProp<ViewStyle>;
  /** Extra TextInput props (e.g. maxLength, accessibilityLabel, onFocus). */
  inputProps?: Omit<
    TextInputProps,
    'value' | 'onChangeText' | 'placeholder' | 'editable' | 'multiline' | 'autoFocus'
  >;
}

/**
 * A multiline free-text field — built on {@link FieldContainer} (white surface, medium radius, border
 * that darkens on focus) with top-aligned text that grows from `minHeight`. For single-line labelled
 * rows use {@link InputField} — both share the same FieldContainer chrome.
 */
export function TextArea({
  value,
  onChangeText,
  placeholder,
  minHeight = 96,
  editable = true,
  autoFocus = false,
  inputRef,
  style,
  inputProps,
}: TextAreaProps) {
  const [focused, setFocused] = useState(false);

  const handleFocus = useCallback(
    (e: Parameters<NonNullable<TextInputProps['onFocus']>>[0]) => {
      setFocused(true);
      inputProps?.onFocus?.(e);
    },
    [inputProps],
  );
  const handleBlur = useCallback(
    (e: Parameters<NonNullable<TextInputProps['onBlur']>>[0]) => {
      setFocused(false);
      inputProps?.onBlur?.(e);
    },
    [inputProps],
  );

  return (
    <FieldContainer focused={focused} disabled={!editable} style={style}>
      <TextInput
        {...inputProps}
        ref={inputRef}
        style={[styles.input, { minHeight }, !editable && styles.inputDisabled]}
        value={value}
        onChangeText={onChangeText}
        placeholder={placeholder}
        placeholderTextColor={editable ? DS_SEMANTIC.text.muted : DS_SEMANTIC.text.disabled}
        editable={editable}
        autoFocus={autoFocus}
        onFocus={handleFocus}
        onBlur={handleBlur}
        multiline
        textAlignVertical="top"
      />
    </FieldContainer>
  );
}

const styles = StyleSheet.create({
  // The chrome (surface/border/radius) lives on FieldContainer; the input owns the text style + padding
  // so a tap anywhere over the padded area still focuses it.
  input: {
    ...DS_TYPOGRAPHY.bodySm,
    color: DS_SEMANTIC.text.regular,
    padding: DS_SPACING[400],
  },
  // A step lighter than the hint tone so a non-editable area reads as inactive, not just filled —
  // same convention as InputField/SearchField (see DS_SEMANTIC.text.disabled's own doc comment).
  inputDisabled: {
    color: DS_SEMANTIC.text.disabled,
  },
});
