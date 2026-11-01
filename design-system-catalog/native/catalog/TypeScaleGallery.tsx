import { View, Text, StyleSheet, type TextStyle } from 'react-native';
import { TokenRow } from './TokenRow';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE } from './tokens';

/**
 * Renders a type scale as a stack of `TokenRow`s, each showing a step's name (rendered at its own
 * real style, not the catalog's chrome font) plus a short meta caption — the shared shape behind
 * every Typography/Type Scale gallery. `sampleStyle`/`meta` are per-step accessors rather than plain
 * maps because different scales show different things at a glance: a full typography token (like the
 * host app's `DS_TYPOGRAPHY`) has a font-weight worth calling out ("16/600"); a bare size scale (like
 * this framework's own `CATALOG_TYPE`) doesn't ("16px").
 */
export function TypeScaleGallery<TStep extends string>({
  steps,
  sampleStyle,
  meta,
  useNotes,
}: {
  steps: readonly TStep[];
  sampleStyle: (step: TStep) => TextStyle;
  meta: (step: TStep) => string;
  useNotes: Record<TStep, string>;
}) {
  return (
    <View style={styles.tokenStack}>
      {steps.map((step, i) => (
        <TokenRow key={String(step)} use={useNotes[step]} last={i === steps.length - 1}>
          <View style={styles.row}>
            <Text style={[sampleStyle(step), styles.sample]} numberOfLines={1}>
              {String(step)}
            </Text>
            <Text style={styles.meta}>{meta(step)}</Text>
          </View>
        </TokenRow>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  // Wider gap than a plain gap-only stack — one row's use-note shouldn't crowd the next row's label.
  tokenStack: { gap: CATALOG_SPACE.lg },
  // Size/weight meta sits directly beside the sample name, not flushed to the row's far edge, so the
  // two read as one unit at a glance.
  row: { flexDirection: 'row', alignItems: 'baseline', gap: CATALOG_SPACE.sm },
  sample: { color: CATALOG_COLOR.text },
  meta: { fontSize: CATALOG_TYPE.xs, color: CATALOG_COLOR.textMuted },
});
