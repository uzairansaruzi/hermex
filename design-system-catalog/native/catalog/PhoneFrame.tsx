import React from 'react';
import { View, StyleSheet } from 'react-native';
import { CATALOG_RADIUS, CATALOG_COLOR } from './tokens';

const WIDTH_CAP = 280;
const HEIGHT = 480;

/**
 * A bounded "phone screen" preview frame — contains a live demo (e.g. a BottomSheet or Dropdown's
 * picker) inside a fixed-size box instead of letting its absolutely-positioned overlay cover the
 * whole documentation page. Purely a documentation device: a real app screen never needs to fake
 * being a phone screen inside itself, since the actual device viewport already does that job — that's
 * why this lives in the catalog framework (like VariantGroup/TokenRow) rather than the host app's
 * own component library (a downstream app would never import this file).
 *
 * `width: '100%'` capped at 280 (not a fixed width) — a fixed px width could exceed the card's real
 * content width once the surrounding column shrinks below its own max-width cap (it does at common
 * viewport sizes), overflowing past the card's edge since the card itself doesn't clip.
 */
export function PhoneFrame({ children }: { children: React.ReactNode }) {
  return <View style={styles.frame}>{children}</View>;
}

const styles = StyleSheet.create({
  frame: {
    width: '100%',
    maxWidth: WIDTH_CAP,
    height: HEIGHT,
    borderRadius: CATALOG_RADIUS.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: CATALOG_COLOR.border,
    backgroundColor: CATALOG_COLOR.surfacePressed,
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
