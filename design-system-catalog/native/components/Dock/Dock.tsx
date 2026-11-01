import React, { type ReactNode } from 'react';
import { View, Text, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { DS_SEMANTIC, DS_SPACING, DS_TYPOGRAPHY, DS_SHADOW } from '../../../tokens';

const MAX_BUTTONS = 3;
const TOP_PAD = DS_SPACING[800];
const BOTTOM_PAD = DS_SPACING[400];
const H_PAD = DS_SPACING[800];

export interface DockProps {
  /** Up to three full-width Button elements, stacked vertically. Extra children are dropped. */
  children: ReactNode;
  /** Small caption shown above the top button — e.g. a trip summary. */
  caption?: ReactNode;
  /** Hides the caption row without unmounting `caption`. @default true */
  showCaption?: boolean;
  /** Shows the upward-cast `bottomSheet` shadow, visually separating the Dock from scrollable
   *  content sitting above it. Off by default — turn it on when that content actually overflows
   *  (is scrolled/scrollable), since Dock has no visibility into sibling content on its own; the
   *  caller (e.g. BottomSheet, which measures its own content area) decides when that's true.
   *  @default false */
  elevated?: boolean;
  style?: StyleProp<ViewStyle>;
}

/**
 * Pinned to the bottom of the screen, above the home indicator — holds up to three full-width
 * Buttons stacked vertically, with an optional small caption area above them that can be shown or
 * hidden independently of whether `caption` content is passed. Not absolutely positioned itself —
 * the screen composing this decides whether to pin it (`position: 'absolute', bottom: 0`) or lay
 * it out inline at the end of a flex column, which also keeps it usable inside a bounded container
 * like this catalog's own example cards.
 */
export function Dock({ children, caption, showCaption = true, elevated = false, style }: DockProps) {
  const insets = useSafeAreaInsets();
  const buttons = React.Children.toArray(children).slice(0, MAX_BUTTONS);

  return (
    <View style={[styles.dock, elevated && styles.dockElevated, { paddingBottom: BOTTOM_PAD + insets.bottom }, style]}>
      {caption != null && showCaption && <Text style={styles.caption}>{caption}</Text>}
      <View style={styles.buttons}>{buttons}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  dock: {
    width: '100%',
    backgroundColor: DS_SEMANTIC.surface.white,
    paddingTop: TOP_PAD,
    paddingHorizontal: H_PAD,
    gap: DS_SPACING[300],
  },
  dockElevated: { ...DS_SHADOW.bottomSheet },
  caption: { ...DS_TYPOGRAPHY.bodyXs, color: DS_SEMANTIC.text.muted, textAlign: 'center' },
  buttons: { gap: DS_SPACING[400] },
});
