import React, { createContext, useContext, type ReactNode } from 'react';
import { View, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC } from '../../../tokens';

export type SurfaceTone = 'white' | 'muted';

// Defaults to 'white' — a screen with no explicit <Surface> ancestor is assumed to sit on a white
// background, the common case (matches e.g. Card's own default fill).
const SurfaceToneContext = createContext<SurfaceTone>('white');

/** What background tone the nearest ancestor `<Surface>` declared (or 'white' if there isn't one).
 *  Components that need to contrast with whatever's actually behind them — FieldContainer/
 *  InputField today — read this instead of assuming one fixed background. */
export function useSurfaceTone(): SurfaceTone {
  return useContext(SurfaceToneContext);
}

export interface SurfaceProps {
  /** Which background this surface renders. Descendants read this via `useSurfaceTone()` to
   *  automatically pick a fill that contrasts with it (e.g. a field goes white on a muted page,
   *  recessed on a white one) instead of needing to be told individually. */
  tone: SurfaceTone;
  style?: StyleProp<ViewStyle>;
  children?: ReactNode;
}

/**
 * Declares "this subtree's background is `tone`" — renders a plain View filled with the matching
 * token (`surface.white` or `surface.main`) and provides that tone to descendants via context.
 * Wrap a screen (or any region) in this wherever its background isn't the default white — a page
 * with a muted/grey background, for instance — so anything inside that needs to contrast with its
 * background picks the right fill automatically rather than assuming white.
 */
export function Surface({ tone, style, children }: SurfaceProps) {
  return (
    <SurfaceToneContext.Provider value={tone}>
      <View style={[tone === 'white' ? styles.white : styles.muted, style]}>{children}</View>
    </SurfaceToneContext.Provider>
  );
}

const styles = StyleSheet.create({
  white: { backgroundColor: DS_SEMANTIC.surface.white },
  muted: { backgroundColor: DS_SEMANTIC.surface.main },
});
