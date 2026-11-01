import React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE } from './tokens';

/**
 * Wraps one token's rendered example with a grounded "when to use this" note beneath it — the
 * shared shape behind every token-gallery row (Spacing, Type Scale, …) in both CatalogExample.tsx
 * and CatalogFrameworkExample.tsx. The row's own content (a spacing bar, a type sample, …) is
 * freeform `children`; only the value-plus-use-note stacking is standardized here.
 *
 * Draws a bottom divider by default (same hairline as PropsTable's rows) so a stack of TokenRows
 * reads as a list, not a loose pile of paragraphs. Pass `last` on the final row in a stack to drop
 * the divider, matching PropsTable's own `rowLast` convention.
 */
export function TokenRow({ children, use, last = false }: { children: React.ReactNode; use: string; last?: boolean }) {
  return (
    <View style={[styles.item, !last && styles.itemDivider]}>
      {children}
      <Text style={styles.use}>{use}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  item: { gap: CATALOG_SPACE.xs },
  itemDivider: {
    paddingBottom: CATALOG_SPACE.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: CATALOG_COLOR.borderHairline,
  },
  use: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted },
});
