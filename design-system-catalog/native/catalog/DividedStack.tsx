import React from 'react';
import { View, StyleSheet } from 'react-native';
import { CATALOG_COLOR, CATALOG_SPACE } from './tokens';

/**
 * Stacks its children vertically with a hairline divider automatically inserted between each
 * consecutive pair — never after the last. Use this instead of a plain gap-only wrapper whenever
 * an Examples card holds multiple distinct items (e.g. several VariantGroups), so the divider is
 * guaranteed by construction rather than something each call site has to remember to add (or get
 * an off-by-one wrong on, the way a hand-rolled `last === i` check can).
 *
 * `gap` controls the space around each divider (default `CATALOG_SPACE.xl`); pass a smaller value
 * for denser content.
 */
export function DividedStack({ children, gap = CATALOG_SPACE.xl }: { children: React.ReactNode; gap?: number }) {
  const items = React.Children.toArray(children).filter(Boolean);
  return (
    <View style={[styles.stack, { gap }]}>
      {items.map((child, i) => (
        <React.Fragment key={i}>
          {child}
          {i < items.length - 1 && <View style={styles.divider} />}
        </React.Fragment>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  stack: {},
  divider: { height: StyleSheet.hairlineWidth, backgroundColor: CATALOG_COLOR.borderHairline },
});
