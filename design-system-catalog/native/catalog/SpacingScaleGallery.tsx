import { View, Text, StyleSheet } from 'react-native';
import { TokenRow } from './TokenRow';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE, CATALOG_RADIUS } from './tokens';

/**
 * Renders a spacing scale as a stack of `TokenRow`s, each showing a step's name, a bar sized to its
 * real pixel value, and the value itself — the shared shape behind every Spacing gallery (this
 * framework's own, and any host app's). Generic over the step-name type so it works for any scale
 * (the host app's `DS_SPACING`, this framework's own `CATALOG_SPACE`, or a third-party one).
 */
export function SpacingScaleGallery<TStep extends string | number>({
  steps,
  values,
  useNotes,
}: {
  steps: readonly TStep[];
  values: Record<TStep, number>;
  useNotes: Record<TStep, string>;
}) {
  return (
    <View style={styles.tokenStack}>
      {steps.map((step, i) => {
        const px = values[step];
        return (
          <TokenRow key={String(step)} use={useNotes[step]} last={i === steps.length - 1}>
            <View style={styles.row}>
              <Text style={styles.label}>{String(step)}</Text>
              <View style={[styles.bar, { width: Math.max(px, 1) }]} />
              <Text style={styles.value}>{px}px</Text>
            </View>
          </TokenRow>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  // Wider gap than a plain gap-only stack — one row's use-note shouldn't crowd the next row's label.
  tokenStack: { gap: CATALOG_SPACE.lg },
  row: { flexDirection: 'row', alignItems: 'center', gap: CATALOG_SPACE.md },
  label: { width: 48, fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.text },
  bar: { height: 12, borderRadius: CATALOG_RADIUS.sm, backgroundColor: CATALOG_COLOR.accent },
  value: { fontSize: CATALOG_TYPE.xs, color: CATALOG_COLOR.textMuted },
});
