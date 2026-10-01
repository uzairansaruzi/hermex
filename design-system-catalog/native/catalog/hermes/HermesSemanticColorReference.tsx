/**
 * Complete visual reference for every Hermex semantic color role — grouped by purpose, each shown
 * as a meaningful light/dark UI sample rather than an isolated swatch. Status roles pair their label
 * with a checkmark/warning/error/info glyph so meaning never depends on color alone.
 */
import React from 'react';
import { View, Text, StyleSheet, useWindowDimensions } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE, CATALOG_RADIUS, CATALOG_NARROW_BREAKPOINT } from '../tokens';
import { HERMES_SEMANTIC_COLORS, type HermesSemanticColorPurpose, type HermesSemanticColorSample } from './hermesColorCatalogData';

const PURPOSE_ORDER: HermesSemanticColorPurpose[] = ['Surfaces', 'Text', 'Borders', 'Actions', 'Statuses', 'Disabled content'];

const STATUS_GLYPH: Partial<Record<HermesSemanticColorSample, string>> = {
  'status-success': '✓',
  'status-warning': '▲',
  'status-danger': '✕',
  'status-info': 'i',
};

const STATUS_LABEL: Partial<Record<HermesSemanticColorSample, string>> = {
  'status-success': 'Success',
  'status-warning': 'Warning',
  'status-danger': 'Error',
  'status-info': 'Info',
};

function SampleFrame({ scheme, hex, sample }: { scheme: 'Light' | 'Dark'; hex: string; sample: HermesSemanticColorSample }) {
  const dark = scheme === 'Dark';
  const glyph = STATUS_GLYPH[sample];
  const statusLabel = STATUS_LABEL[sample];
  return (
    <View style={[styles.frame, dark ? styles.frameDark : styles.frameLight]}>
      <Text style={[styles.frameLabel, dark && styles.frameLabelDark]}>{scheme}</Text>
      {sample === 'surface' && <View style={[styles.sampleSurface, { backgroundColor: hex }]} />}
      {sample === 'text' && <Text style={[styles.sampleText, { color: hex }]}>Aa</Text>}
      {sample === 'border' && <View style={[styles.sampleBorderBox, { borderColor: hex }]} />}
      {sample === 'action' && (
        <View style={[styles.sampleAction, { backgroundColor: hex }]}>
          <Text style={styles.sampleActionText}>Action</Text>
        </View>
      )}
      {sample === 'disabled' && (
        <View style={[styles.sampleAction, { backgroundColor: hex }]}>
          <Text style={styles.sampleDisabledText}>Disabled</Text>
        </View>
      )}
      {glyph && (
        <View style={[styles.sampleStatus, { borderColor: hex }]}>
          <Text style={[styles.sampleStatusGlyph, { color: hex }]}>{glyph}</Text>
          <Text style={[styles.sampleStatusLabel, dark && styles.frameLabelDark]}>{statusLabel}</Text>
        </View>
      )}
    </View>
  );
}

function RoleCard({ role, isNarrow }: { role: string; isNarrow: boolean }) {
  const fact = HERMES_SEMANTIC_COLORS[role];
  return (
    <View style={[styles.card, isNarrow && styles.cardNarrow]}>
      <Text style={styles.roleName}>{role}</Text>
      <Text style={styles.roleUse}>{fact.use}</Text>
      <View style={styles.samplesRow}>
        <SampleFrame scheme="Light" hex={fact.previewLight} sample={fact.sample} />
        <SampleFrame scheme="Dark" hex={fact.previewDark} sample={fact.sample} />
      </View>
      <Text style={styles.binding}>{fact.binding}</Text>
    </View>
  );
}

export function HermesSemanticColorReference() {
  const { width } = useWindowDimensions();
  const isNarrow = width < CATALOG_NARROW_BREAKPOINT;
  const rolesByPurpose = PURPOSE_ORDER.map((purpose) => ({
    purpose,
    roles: Object.keys(HERMES_SEMANTIC_COLORS).filter((role) => HERMES_SEMANTIC_COLORS[role].purpose === purpose),
  })).filter((group) => group.roles.length > 0);

  return (
    <View style={styles.stack}>
      {rolesByPurpose.map((group) => (
        <View key={group.purpose} style={styles.group}>
          <Text style={styles.groupHeading}>{group.purpose}</Text>
          <View style={styles.cardRow}>
            {group.roles.map((role) => (
              <RoleCard key={role} role={role} isNarrow={isNarrow} />
            ))}
          </View>
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  stack: { gap: CATALOG_SPACE.xl },
  group: { gap: CATALOG_SPACE.sm },
  groupHeading: {
    fontSize: CATALOG_TYPE.xs, fontWeight: '800', color: CATALOG_COLOR.textMuted,
    textTransform: 'uppercase', letterSpacing: 0.6,
  },
  cardRow: { flexDirection: 'row', flexWrap: 'wrap', gap: CATALOG_SPACE.md },
  card: {
    width: 220, gap: CATALOG_SPACE.xs, padding: CATALOG_SPACE.md,
    borderRadius: CATALOG_RADIUS.md, borderWidth: StyleSheet.hairlineWidth, borderColor: CATALOG_COLOR.border,
    backgroundColor: CATALOG_COLOR.surface,
  },
  cardNarrow: { width: '100%' },
  roleName: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.text },
  roleUse: { fontSize: CATALOG_TYPE.xs, color: CATALOG_COLOR.textMuted, lineHeight: 15 },
  samplesRow: { flexDirection: 'row', gap: CATALOG_SPACE.xs },
  frame: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 4, borderRadius: CATALOG_RADIUS.sm, padding: CATALOG_SPACE.sm, minHeight: 72 },
  frameLight: { backgroundColor: '#F2F2F7', borderWidth: StyleSheet.hairlineWidth, borderColor: 'rgba(0,0,0,0.08)' },
  frameDark: { backgroundColor: '#1C1C1E' },
  frameLabel: { fontSize: 9, fontWeight: '700', color: CATALOG_COLOR.textMuted, textTransform: 'uppercase', letterSpacing: 0.4 },
  frameLabelDark: { color: 'rgba(255,255,255,0.6)' },
  sampleSurface: { width: 48, height: 28, borderRadius: 6 },
  sampleText: { fontSize: 18, fontWeight: '700' },
  sampleBorderBox: { width: 48, height: 28, borderRadius: 6, borderWidth: 2 },
  sampleAction: { paddingHorizontal: CATALOG_SPACE.sm, paddingVertical: 4, borderRadius: 999 },
  sampleActionText: { fontSize: 11, fontWeight: '700', color: '#ffffff' },
  sampleDisabledText: { fontSize: 11, fontWeight: '700', color: 'rgba(0,0,0,0.35)' },
  sampleStatus: { alignItems: 'center', gap: 2, borderWidth: 1, borderRadius: 6, paddingHorizontal: 8, paddingVertical: 4 },
  sampleStatusGlyph: { fontSize: 13, fontWeight: '800' },
  sampleStatusLabel: { fontSize: 9, fontWeight: '700', color: CATALOG_COLOR.textMuted },
  binding: { fontSize: 10, color: CATALOG_COLOR.textMuted, fontFamily: CATALOG_COLOR.code },
});
