import React from 'react';
import { View, Text, StyleSheet, type TextStyle } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR } from './tokens';

// Same web-only word-break/overflow-wrap escape hatch as SectionBlock's own `pathWrapStyle` — a
// description holding a long, unbroken source-path token (e.g.
// "HermesMobile/Features/SessionList/ProjectCreationSheet.swift", no spaces) has no RN `TextStyle`
// equivalent to force a mid-word break; native text already wraps at any character once its box runs
// out of room. Cast once, locally, rather than widening `styles.desc`'s own type.
const descWrapStyle = { overflowWrap: 'anywhere', wordBreak: 'break-word' } as unknown as TextStyle;

/** Labels one example (or small group of examples) inside a section's Examples card — a bold
 *  uppercase name plus a one-line description stacked below it, sitting above whatever demo content
 *  is passed as children. Both are optional — omit for a plain, label-less group when the examples
 *  are self-explanatory. Centered by default; pass `align="left"` for content that reads better
 *  left-aligned (e.g. a wide token swatch grid). */
export function VariantGroup({
  name,
  desc,
  align = 'center',
  children,
}: {
  name?: string;
  desc?: string;
  align?: 'center' | 'left';
  children: React.ReactNode;
}) {
  const centered = align === 'center';
  const hasLabel = !!name || !!desc;
  return (
    <View style={[styles.group, centered ? styles.groupCenter : styles.groupLeft]}>
      {hasLabel && (
        <>
          {!!name && <Text style={[styles.name, centered && styles.textCenter]}>{name}</Text>}
          {!!desc && <Text style={[styles.desc, centered && styles.textCenter, descWrapStyle]}>{desc}</Text>}
        </>
      )}
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  // 6px sits between CATALOG_SPACE.xs (4) and .sm (8) — no scale step lands on it, so it's a literal
  // value here (same reasoning as SectionBlock's exampleItem gap).
  group: { gap: 6 },
  groupCenter: { alignItems: 'center' },
  groupLeft: { alignItems: 'flex-start' },
  name: {
    fontSize: CATALOG_TYPE.xs, fontWeight: '700', color: CATALOG_COLOR.text,
    textTransform: 'uppercase', letterSpacing: 0.4,
  },
  // `maxWidth`/`flexShrink` let this shrink below its own unwrapped content width — a left-aligned
  // group's `alignItems: 'flex-start'` otherwise refuses to shrink an auto-width text box past its
  // own (unwrapped) content size, the same `min-width: auto` flex default behind SectionBlock's own
  // path-chip fix — paired with `descWrapStyle` (applied at the call site; no typed `TextStyle`
  // equivalent exists) so a long unbroken source-path token actually has something small to shrink
  // its own minimum width down to.
  desc: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, maxWidth: '100%', flexShrink: 1 },
  textCenter: { textAlign: 'center' },
});
