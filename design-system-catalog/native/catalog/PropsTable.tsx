import { useState } from 'react';
import { View, Text, Pressable, StyleSheet } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE } from './tokens';
import type { PropDef } from './types';

// A prop's rendered desc/default text shows at most this many lines before it needs an expand
// control. Deliberately a rendered-line cap, not a character count — a short string can still wrap
// to many lines in the table's own narrow column, and a long one can still fit in five wide ones.
const CLAMPED_LINES = 5;

/** Clamps `text` to `CLAMPED_LINES` lines and exposes a keyboard/touch expand/collapse control
 *  — but only once an initial measurement pass proves the real content actually needs more than
 *  that; short content never grows a control it doesn't need. The first render measures unclamped
 *  (via `onTextLayout`, RN's own line-count callback) before committing to either the clamp or "no
 *  control needed", so the exposed control's `expanded` state is always the literal truth about
 *  what's on screen, never a guess from a character-count heuristic. */
function ClampedPropText({ text, style }: { text: string; style: object }) {
  const [measured, setMeasured] = useState(false);
  const [canExpand, setCanExpand] = useState(false);
  const [expanded, setExpanded] = useState(false);

  // Unmeasured: render one line over the clamp (CLAMPED_LINES + 1) purely to observe whether the
  // real content needs a line beyond the clamp — content that fits in the clamp renders identically
  // either way, so there is no visible flash for the common (non-overflowing) case.
  const numberOfLines = !measured ? CLAMPED_LINES + 1 : expanded ? undefined : canExpand ? CLAMPED_LINES : undefined;

  return (
    <View>
      <Text
        style={style}
        numberOfLines={numberOfLines}
        onTextLayout={(e) => {
          if (measured) return;
          setCanExpand((e.nativeEvent.lines?.length ?? 0) > CLAMPED_LINES);
          setMeasured(true);
        }}
      >
        {text}
      </Text>
      {measured && canExpand && (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={expanded ? 'Show less' : 'Show more'}
          accessibilityState={{ expanded }}
          onPress={() => setExpanded((v) => !v)}
          style={styles.toggle}
        >
          <Text style={styles.toggleText}>{expanded ? 'Show less' : 'Show more'}</Text>
        </Pressable>
      )}
    </View>
  );
}

/** Renders a component's real prop interface as a table: each row holds name + type in a fixed-width
 *  first column, with the description (and default, if any) in a second column beside it. The table
 *  lives in SectionBlock's narrower reference column, so both cells flex within that bounded space.
 *  A description that actually exceeds five rendered lines clamps behind `ClampedPropText`'s own
 *  expand/collapse control; one that fits shows in full with no control at all. */
export function PropsTable({ props }: { props: PropDef[] }) {
  return (
    <View style={styles.table}>
      {props.map((prop, i) => (
        <View
          key={prop.name}
          style={[styles.row, i === 0 && styles.rowFirst, i === props.length - 1 && styles.rowLast]}
        >
          <View style={styles.header}>
            <Text style={styles.name}>
              {prop.name}
              <Text style={styles.optionalMark}>{prop.required ? '' : '?'}</Text>
            </Text>
            <Text style={styles.type}>{prop.type}</Text>
          </View>
          <View style={styles.body}>
            <ClampedPropText text={prop.desc} style={styles.desc} />
            {prop.default != null && (
              <Text style={styles.default}>
                Default: <Text style={styles.defaultVal}>{prop.default}</Text>
              </Text>
            )}
          </View>
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  table: { gap: 0 },
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: CATALOG_SPACE.md,
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: CATALOG_COLOR.borderHairline,
  },
  rowFirst: { paddingTop: 0 },
  rowLast: { borderBottomWidth: 0, paddingBottom: 0 },
  header: { width: 140, gap: 2 },
  name: { fontSize: CATALOG_TYPE.sm, fontFamily: CATALOG_COLOR.code, fontWeight: '700', color: CATALOG_COLOR.text },
  optionalMark: { fontWeight: '400', color: CATALOG_COLOR.textMuted },
  type: { fontSize: CATALOG_TYPE.xs, fontFamily: CATALOG_COLOR.code, color: CATALOG_COLOR.accent },
  // The second column — description + default — sized by the row's remaining width.
  body: { flex: 1, gap: 2 },
  desc: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, lineHeight: 17 },
  default: { fontSize: CATALOG_TYPE.xs, color: CATALOG_COLOR.textMuted },
  defaultVal: { fontFamily: CATALOG_COLOR.code, color: CATALOG_COLOR.textMuted },
  toggle: { marginTop: 2, alignSelf: 'flex-start' },
  toggleText: { fontSize: CATALOG_TYPE.xs, fontWeight: '700', color: CATALOG_COLOR.accent },
});
