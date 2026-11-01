import { View, Text, StyleSheet } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE, CATALOG_RADIUS } from './tokens';

/** One token swatch: its rendered value (a colour chip) plus name/value as data — the shared shape
 *  behind every Colors gallery (this framework's own, and any host app's, e.g. the Native App DS
 *  Template's). `width` defaults to fit a typical semantic/palette name; widen it for a gallery whose
 *  longest name needs more room (e.g. `borderHairline`). `valueLabel` overrides only the displayed
 *  text (e.g. a resolved palette token like `green.700`) — the chip itself always renders `value`
 *  directly, since that's the real, renderable colour. */
export function Swatch({
  name,
  value,
  valueLabel,
  width = 84,
}: {
  name: string;
  value: string;
  valueLabel?: string;
  width?: number;
}) {
  return (
    <View style={[styles.swatch, { width }]}>
      <View style={[styles.chip, { backgroundColor: value }]} />
      <Text style={styles.name} numberOfLines={1}>{name}</Text>
      <Text style={styles.value} numberOfLines={1}>{valueLabel ?? value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  swatch: { gap: CATALOG_SPACE.xs },
  chip: {
    height: 40,
    borderRadius: CATALOG_RADIUS.sm,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: CATALOG_COLOR.border,
  },
  name: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.text },
  value: { fontSize: CATALOG_TYPE.xs, color: CATALOG_COLOR.textMuted },
});
