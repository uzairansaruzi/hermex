import React, { useEffect, useState } from 'react';
import { View, Text, Pressable, Modal, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { FieldContainer } from '../FieldContainer';
import { BottomSheet, useInsideBottomSheetWarning } from '../BottomSheet';
import { TopNav } from '../TopNav';
import { Button } from '../Button';
import { Icon } from '../../../icons/Icon.native';
import { DS_SEMANTIC, DS_SPACING, DS_TYPOGRAPHY, DS_ICON_SIZE, DS_MOTION_DURATION, DS_A11Y_MIN_TOUCH_TARGET } from '../../../tokens';

export interface DropdownOption {
  value: string;
  label: string;
}

export interface DropdownProps {
  /** Field label shown above the value. Generic text (unlike InputField's fixed label set) since a
   *  dropdown's label is app-specific. */
  label?: string;
  /** Selected option's value. */
  value?: string;
  /** Shown when no option is selected. */
  placeholder?: string;
  options: DropdownOption[];
  /** Called with the newly selected option's value. */
  onChange: (value: string) => void;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
}

/**
 * A labelled field (on the shared {@link FieldContainer} chrome) that opens a {@link BottomSheet}
 * picker on tap — the "bottom sheet picker" interaction: tap the trigger, pick an option from the
 * sheet, it closes. Value/selection are controlled by the caller; the sheet's own open/closed state
 * is internal.
 */
export function Dropdown({ label, value, placeholder, options, onChange, disabled = false, style }: DropdownProps) {
  useInsideBottomSheetWarning('Dropdown');
  const [open, setOpen] = useState(false);
  // The picker is portaled through a Modal (see the render below) specifically so it covers the
  // whole screen even when Dropdown itself sits deep inside an arbitrary layout (a form row, a
  // card, …) — BottomSheet's own absolutely-positioned overlay only fills whichever immediate
  // parent View hosts it, which is wrong the moment that parent isn't already the full screen.
  // `sheetMounted` keeps the Modal (and thus BottomSheet) around for BottomSheet's own exit
  // animation instead of yanking it out of the DOM the instant `open` goes false.
  const [sheetMounted, setSheetMounted] = useState(false);
  useEffect(() => {
    if (open) {
      setSheetMounted(true);
      return undefined;
    }
    const timer = setTimeout(() => setSheetMounted(false), DS_MOTION_DURATION.fast);
    return () => clearTimeout(timer);
  }, [open]);
  const selected = options.find((o) => o.value === value);
  const hasValue = !!selected;

  const handleSelect = (optionValue: string) => {
    onChange(optionValue);
    setOpen(false);
  };

  const triggerAccessibilityLabel = [label, hasValue ? selected.label : placeholder].filter(Boolean).join(', ');

  return (
    <>
      <FieldContainer
        disabled={disabled}
        onPress={disabled ? undefined : () => setOpen(true)}
        // Label + state stay on even when disabled — FieldContainer keeps its View branch accessible,
        // so a disabled dropdown still announces as "…, button, disabled" instead of vanishing.
        accessibilityLabel={triggerAccessibilityLabel}
        accessibilityState={{ disabled, expanded: open }}
        style={[styles.trigger, style]}
      >
        <View style={styles.inner}>
          <View style={styles.textColumn}>
            {!!label && <Text style={[styles.label, disabled && styles.disabledText]}>{label}</Text>}
            {/* Hint (empty) and disabled are DIFFERENT states with different colors — hint keeps the
                text.muted placeholder tone; disabled goes a step lighter (text.disabled) so a
                disabled dropdown holding a real value never reads as merely empty. */}
            <Text
              style={[styles.value, !hasValue && !disabled && styles.hint, disabled && styles.disabledText]}
              numberOfLines={1}
            >
              {hasValue ? selected.label : placeholder}
            </Text>
          </View>
          {/* Centred against the whole field (label + value stacked), not just the value line — this
              row spans the full trigger height via `inner`'s own alignItems:'center'. */}
          <Icon name="chevron-down" size={DS_ICON_SIZE.sm} color={disabled ? DS_SEMANTIC.text.disabled : DS_SEMANTIC.text.regular} />
        </View>
      </FieldContainer>
      {sheetMounted && (
        <Modal transparent animationType="none" onRequestClose={() => setOpen(false)}>
          <BottomSheet
            visible={open}
            onDismiss={() => setOpen(false)}
            header={
              <TopNav
                title={label ?? 'Select an option'}
                trailing={
                  <Button variant="secondary" size="small" showIcon showLabel={false} iconName="clear" accessibilityLabel="Close" onPress={() => setOpen(false)} />
                }
              />
            }
          >
            <View style={styles.options} accessibilityRole="radiogroup">
              {options.map((option) => {
                const isSelected = option.value === value;
                return (
                  <Pressable
                    key={option.value}
                    onPress={() => handleSelect(option.value)}
                    accessibilityRole="radio"
                    accessibilityState={{ checked: isSelected }}
                    style={({ pressed }) => [styles.option, pressed && styles.optionPressed]}
                  >
                    <Text style={[styles.optionLabel, isSelected && styles.optionLabelSelected]}>{option.label}</Text>
                    {isSelected && <Icon name="check" size={DS_ICON_SIZE.sm} color={DS_SEMANTIC.emphasis.info} />}
                  </Pressable>
                );
              })}
            </View>
          </BottomSheet>
        </Modal>
      )}
    </>
  );
}

const styles = StyleSheet.create({
  trigger: {
    width: '100%',
    paddingHorizontal: DS_SPACING[800],
    paddingVertical: DS_SPACING[400],
    // A labelled trigger is ~56pt already; this floor covers the label-less case, which would
    // otherwise land under the 44pt minimum touch target.
    minHeight: DS_A11Y_MIN_TOUCH_TARGET,
    justifyContent: 'center',
  },
  inner: { flexDirection: 'row', alignItems: 'center', gap: DS_SPACING[400] },
  textColumn: { flex: 1, gap: DS_SPACING[100] },
  label: { ...DS_TYPOGRAPHY.labelXs, color: DS_SEMANTIC.text.muted },
  value: { ...DS_TYPOGRAPHY.bodyMd, color: DS_SEMANTIC.text.regular },
  // Placeholder tone for the empty state.
  hint: { color: DS_SEMANTIC.text.muted },
  // Disabled text — one step lighter than `hint` (see DS_SEMANTIC.text.disabled's doc comment).
  disabledText: { color: DS_SEMANTIC.text.disabled },
  // No padding here — BottomSheet's own content area now supplies the standard 16px on all sides.
  options: {},
  option: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: DS_SPACING[600],
  },
  optionPressed: { backgroundColor: DS_SEMANTIC.interaction.pressed },
  optionLabel: { ...DS_TYPOGRAPHY.bodyMd, color: DS_SEMANTIC.text.regular },
  optionLabelSelected: { color: DS_SEMANTIC.emphasis.info },
});
