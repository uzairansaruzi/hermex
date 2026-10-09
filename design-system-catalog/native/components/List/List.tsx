import React, { type ReactNode } from 'react';
import { ScrollView, View, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_RADIUS, DS_SEMANTIC } from '../../../tokens';
import { Divider } from '../Divider';

export interface ListProps {
  /** ListItem elements. `standard` stacks them with a Divider automatically inserted between each
   *  consecutive pair — never after the last. `compactOverlay` renders them with no separators. */
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
  /** `standard` (default) is the original, still-default rounded white surface with a Divider
   *  between each pair of rows. `compactOverlay` is a plain, transparent, separator-free variant for
   *  a floating menu that already supplies its own card surface/shadow — mirrors HermexList's own
   *  `.compactOverlay` style (HermexList.swift), which the shared Hermex Popover Menu composes. */
  variant?: 'standard' | 'compactOverlay';
  /** Caps the list's own height and scrolls internally once its rows overflow it. Only meaningful
   *  with `variant="compactOverlay"` — `standard` scrolls in whatever container hosts it instead. */
  maxHeight?: number;
}

/** `standard`: stacks ListItem rows on a rounded white surface, with a Divider between each pair —
 *  the same "insert a divider between, never after the last" mechanism the catalog's own
 *  DividedStack uses. `compactOverlay`: a transparent, separator-free variant that scrolls
 *  internally once bounded by `maxHeight` — for a caller (Popover Menu) that owns its own outer
 *  card surface and shadow. */
export function List({ children, style, variant = 'standard', maxHeight }: ListProps) {
  const items = React.Children.toArray(children).filter(Boolean);
  const rows = items.map((child, i) => (
    <React.Fragment key={i}>
      {child}
      {variant === 'standard' && i < items.length - 1 && <Divider />}
    </React.Fragment>
  ));

  if (variant === 'compactOverlay') {
    return (
      <ScrollView
        style={[styles.compactOverlayList, maxHeight != null && { maxHeight }, style]}
        contentContainerStyle={styles.compactOverlayContent}
      >
        {rows}
      </ScrollView>
    );
  }

  return <View style={[styles.list, style]}>{rows}</View>;
}

const styles = StyleSheet.create({
  list: {
    width: '100%',
    borderRadius: DS_RADIUS.medium,
    overflow: 'hidden',
    backgroundColor: DS_SEMANTIC.surface.white,
  },
  compactOverlayList: {
    width: '100%',
    backgroundColor: 'transparent',
  },
  compactOverlayContent: {
    backgroundColor: 'transparent',
  },
});
