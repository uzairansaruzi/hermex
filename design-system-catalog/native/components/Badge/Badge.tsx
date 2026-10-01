import React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { DS_RADIUS, DS_SPACING, DS_TYPOGRAPHY, DS_ICON_SIZE } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import { STATUS_BG, STATUS_FG } from '../statusColors';
import type { BadgeProps } from './Badge.types';

/**
 * A small status pill. Composable: label-only, icon-only (a single icon, no label), or a label with
 * a leading and/or trailing icon. Text + icons sit on the variant background in the variant's own
 * emphasis colour.
 */
export function Badge({ variant = 'neutral', label, leadingIcon, trailingIcon, accessibilityLabel, style }: BadgeProps) {
  const hasLabel = label != null && label !== '';
  // Dev-console check (same policy as ButtonGroup's checkConsistency): the docs require an
  // accessible name for an icon-only badge, but the type can't enforce it — warn instead of
  // silently rendering an unnameable status glyph.
  if (__DEV__ && !hasLabel && !accessibilityLabel) {
    console.warn('[Badge] Icon-only badge (no `label`) needs an `accessibilityLabel` — without one it has no accessible name.');
  }
  const fg = STATUS_FG[variant];

  return (
    <View
      style={[styles.badge, !hasLabel && styles.iconOnly, { backgroundColor: STATUS_BG[variant] }, style]}
      accessibilityRole="text"
      accessibilityLabel={accessibilityLabel}
    >
      {leadingIcon ? <Icon name={leadingIcon} size={DS_ICON_SIZE.xs} color={fg} /> : null}
      {hasLabel ? (
        <Text style={[styles.label, { color: fg }]} numberOfLines={1}>
          {label}
        </Text>
      ) : null}
      {trailingIcon ? <Icon name={trailingIcon} size={DS_ICON_SIZE.xs} color={fg} /> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[100],
    paddingVertical: DS_SPACING[200],
    paddingHorizontal: DS_SPACING[400],
    borderRadius: DS_RADIUS.round,
    alignSelf: 'flex-start',
  },
  iconOnly: {
    paddingHorizontal: DS_SPACING[200],
  },
  label: {
    ...DS_TYPOGRAPHY.labelXs,
  },
});
