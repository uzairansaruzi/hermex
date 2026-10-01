/**
 * Hermex normalized token proposal — presentation layer.
 *
 * Renders every fact in `hermesTokenProposal.ts` through the retained template's own presentation
 * seams (`Swatch`, `VariantGroup`, `DividedStack`, `TypeScaleGallery`, `TokenRow`,
 * `SpacingScaleGallery`) — no new/custom gallery primitives. `hermesSections.tsx` keeps rendering
 * Hermex's actual source-backed evidence (HeaderLogoColor, ProjectCreationPalette, ChatMotion,
 * SessionListMotion, the named geometry constants); everything here is the separate, explicitly
 * labeled normalized proposal — never presented as already adopted.
 */
import { View, Text, StyleSheet, type TextStyle } from 'react-native';
import { DividedStack } from '../DividedStack';
import { VariantGroup } from '../VariantGroup';
import { TokenRow } from '../TokenRow';
import { TypeScaleGallery } from '../TypeScaleGallery';
import { SpacingScaleGallery } from '../SpacingScaleGallery';
import {
  type ProposalClassification,
  HERMES_TYPE_PRIMITIVES,
  HERMES_TYPE_PREVIEW_DISCLAIMER,
  HERMES_TYPE_ALIASES,
  HERMES_TYPE_TITLE_ALIASES,
  HERMES_TYPE_MIGRATION,
  HERMES_MOTION_DURATIONS,
  HERMES_MOTION_EASING,
  HERMES_MOTION_PROPERTIES,
  HERMES_MOTION_SPRINGS,
  HERMES_MOTION_BUNDLES,
  HERMES_MOTION_CURRENT_MAPPING,
  HERMES_MOTION_REDUCE_MOTION,
  HERMES_MOTION_DEFERRED,
  HERMES_SPACING_STEPS,
  HERMES_SPACING,
  HERMES_SPACING_USE,
  HERMES_SPACING_MIGRATION,
  HERMES_SPACING_NOTE,
  HERMES_SPACING_PREVIEW_NOTE,
  HERMES_DEFERRED_FOUNDATIONS,
} from './hermesTokenProposal';

// Same web-only word-break/overflow-wrap escape hatch used elsewhere in this catalog (SectionBlock's
// `pathWrapStyle`, VariantGroup's `descWrapStyle`) — a long unbroken token name has no RN `TextStyle`
// equivalent to force a mid-word break.
const wrapStyle = { overflowWrap: 'anywhere', wordBreak: 'break-word' } as unknown as TextStyle;

const styles = StyleSheet.create({
  stack: { gap: 12 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 12, maxWidth: '100%' },
  rowTight: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: 8, maxWidth: '100%' },
  caption: { fontSize: 11, color: '#8a8a8a', lineHeight: 16, maxWidth: '100%', flexShrink: 1 },
  tokenName: { fontSize: 12, fontWeight: '700', color: '#1c1c1e', flexShrink: 1, maxWidth: '100%', flexWrap: 'wrap' },
  tokenValue: { fontSize: 11, color: '#3a3a3c', fontFamily: 'Menlo', flexShrink: 1, maxWidth: '100%', flexWrap: 'wrap' },
  migrationList: { gap: 4 },
  migrationLine: { fontSize: 12, color: '#3a3a3c', lineHeight: 17, flexShrink: 1, maxWidth: '100%' },
});

// ─── Shared proposal-status callout (Step 1) ─────────────────────────────────
// Status is expressed with position, weight, and a border/background — not color alone — so it
// reads correctly even without color perception.
const STATUS_META: Record<ProposalClassification, { border: string; bg: string }> = {
  'Current production evidence': { border: '#0a7d33', bg: '#e3f6e8' },
  'Proposed — not yet adopted': { border: '#b45309', bg: '#fef3c7' },
  'Migration candidate': { border: '#7c3aed', bg: '#f1e9fe' },
  'Retained component exception': { border: '#0369a1', bg: '#e0f2fe' },
  'Platform-owned adaptive token': { border: '#4b5563', bg: '#eef0f2' },
};

function ProposalStatus({ classification, note }: { classification: ProposalClassification; note?: string }) {
  const meta = STATUS_META[classification];
  return (
    <View style={[callout.box, { borderLeftColor: meta.border, backgroundColor: meta.bg }]}>
      <Text style={callout.label}>{classification}</Text>
      {!!note && <Text style={[callout.note, wrapStyle]}>{note}</Text>}
    </View>
  );
}

const callout = StyleSheet.create({
  box: { borderLeftWidth: 3, paddingVertical: 6, paddingHorizontal: 10, borderRadius: 4, gap: 2, maxWidth: '100%' },
  label: { fontSize: 11, fontWeight: '800', color: '#1c1c1e', textTransform: 'uppercase', letterSpacing: 0.4 },
  note: { fontSize: 11, color: '#3a3a3c', lineHeight: 15 },
});

// ─── Typography (spec §4) ─────────────────────────────────────────────────────

const CORE_ALIASES = Object.keys(HERMES_TYPE_ALIASES) as (keyof typeof HERMES_TYPE_ALIASES)[];
const TITLE_ALIASES = Object.keys(HERMES_TYPE_TITLE_ALIASES) as (keyof typeof HERMES_TYPE_TITLE_ALIASES)[];
type ProposedTypeStep = `${(typeof CORE_ALIASES)[number]}.${'regular' | 'bold'}` | (typeof TITLE_ALIASES)[number];

const PROPOSED_TYPE_STEPS: ProposedTypeStep[] = [
  ...CORE_ALIASES.flatMap((alias) => [`${alias}.regular`, `${alias}.bold`] as ProposedTypeStep[]),
  ...TITLE_ALIASES,
];

function typeSampleStyle(step: ProposedTypeStep): TextStyle {
  const titleAlias = (HERMES_TYPE_TITLE_ALIASES as Record<string, { sizePt: number }>)[step];
  if (titleAlias) return { fontSize: titleAlias.sizePt, fontWeight: '700' };
  const [alias, weight] = step.split(/\.(regular|bold)$/) as [keyof typeof HERMES_TYPE_ALIASES, 'regular' | 'bold'];
  const primitive = HERMES_TYPE_PRIMITIVES[HERMES_TYPE_ALIASES[alias].primitive];
  return { fontSize: primitive.sizePt, fontWeight: weight === 'bold' ? '700' : '400' };
}

function typeMeta(step: ProposedTypeStep): string {
  const titleAlias = (HERMES_TYPE_TITLE_ALIASES as Record<string, { sizePt: number; lineHeightPt: number }>)[step];
  if (titleAlias) return `${titleAlias.sizePt}pt / ${titleAlias.lineHeightPt}pt line height, bold — Proposed`;
  const [alias, weight] = step.split(/\.(regular|bold)$/) as [keyof typeof HERMES_TYPE_ALIASES, 'regular' | 'bold'];
  const primitive = HERMES_TYPE_PRIMITIVES[HERMES_TYPE_ALIASES[alias].primitive];
  return `${primitive.sizePt}pt / ${primitive.lineHeightPt}pt line height, ${weight} — Proposed`;
}

// Fable review fix (2026-09-18): at 390px, TypeScaleGallery's own one-line sample clamp truncates a
// full proposed identifier (e.g. "type.caption.regular" renders as "type.caption.reg…"), and
// typeMeta() never repeats it — so leading every use note with its own full `step` identifier is the
// only place in the row the full proposed token name stays readable once the sample clips.
const TYPE_USE_NOTES: Record<ProposedTypeStep, string> = Object.fromEntries(
  PROPOSED_TYPE_STEPS.map((step) => [
    step,
    `${step} — Proposed — not yet adopted. ${HERMES_TYPE_PREVIEW_DISCLAIMER}`,
  ]),
) as Record<ProposedTypeStep, string>;

export function AppFontProposalGallery() {
  return (
    <View style={styles.stack}>
      <ProposalStatus classification="Proposed — not yet adopted" note={HERMES_TYPE_PREVIEW_DISCLAIMER} />
      <DividedStack>
        <VariantGroup name="Core primitive scale + semantic aliases" desc="font.12/14/16/18 — regular and bold" align="left">
          <TypeScaleGallery steps={PROPOSED_TYPE_STEPS} sampleStyle={typeSampleStyle} meta={typeMeta} useNotes={TYPE_USE_NOTES} />
        </VariantGroup>
        <VariantGroup name="Migration guidance" desc="Current-to-proposed consolidation statements" align="left">
          <View style={styles.migrationList}>
            {HERMES_TYPE_MIGRATION.map((line) => (
              <Text key={line} style={[styles.migrationLine, wrapStyle]}>· {line}</Text>
            ))}
          </View>
        </VariantGroup>
      </DividedStack>
    </View>
  );
}

// ─── Motion (spec §5) ─────────────────────────────────────────────────────────

export function HermesMotionProposalGallery() {
  const durations = Object.entries(HERMES_MOTION_DURATIONS);
  const easings = Object.entries(HERMES_MOTION_EASING);
  const bundles = Object.entries(HERMES_MOTION_BUNDLES);
  return (
    <View style={styles.stack}>
      <ProposalStatus classification="Proposed — not yet adopted" />
      <DividedStack>
        <VariantGroup name="Duration primitives" desc="motion.duration.*" align="left">
          <View style={styles.migrationList}>
            {durations.map(([name, ms], i) => (
              <TokenRow key={name} use={`motion.duration.${name}`} last={i === durations.length - 1}>
                <View style={styles.rowTight}>
                  <Text style={styles.tokenName}>motion.duration.{name}</Text>
                  <Text style={styles.tokenValue}>{ms} ms</Text>
                </View>
              </TokenRow>
            ))}
          </View>
        </VariantGroup>
        <VariantGroup name="Easing" desc="motion.easing.*" align="left">
          <View style={styles.migrationList}>
            {easings.map(([name, value], i) => (
              <TokenRow key={name} use={`motion.easing.${name}`} last={i === easings.length - 1}>
                <View style={styles.rowTight}>
                  <Text style={styles.tokenName}>motion.easing.{name}</Text>
                  <Text style={styles.tokenValue}>{value}</Text>
                </View>
              </TokenRow>
            ))}
          </View>
        </VariantGroup>
        <VariantGroup name="Property and spring primitives" desc="opacity, scale, distance, direction, springs" align="left">
          <View style={styles.migrationList}>
            <TokenRow use="motion.opacity.hidden / motion.opacity.visible">
              <Text style={styles.tokenValue}>motion.opacity.hidden = {HERMES_MOTION_PROPERTIES['motion.opacity.hidden']} · motion.opacity.visible = {HERMES_MOTION_PROPERTIES['motion.opacity.visible']}</Text>
            </TokenRow>
            <TokenRow use="motion.scale.press / motion.scale.enter">
              <Text style={styles.tokenValue}>motion.scale.press = {HERMES_MOTION_PROPERTIES['motion.scale.press']} · motion.scale.enter = {HERMES_MOTION_PROPERTIES['motion.scale.enter']}</Text>
            </TokenRow>
            <TokenRow use="motion.distance.short">
              <Text style={styles.tokenValue}>motion.distance.short = {HERMES_MOTION_PROPERTIES['motion.distance.short']}</Text>
            </TokenRow>
            <TokenRow use="motion.direction.edge — supported edges">
              <Text style={styles.tokenValue}>motion.direction.edge = {HERMES_MOTION_PROPERTIES['motion.direction.edge'].join(', ')}</Text>
            </TokenRow>
            <TokenRow use="motion.spring.responsive">
              <Text style={styles.tokenValue}>response {HERMES_MOTION_SPRINGS['motion.spring.responsive'].response} / damping {HERMES_MOTION_SPRINGS['motion.spring.responsive'].damping}</Text>
            </TokenRow>
            <TokenRow use="motion.spring.settle" last>
              <Text style={styles.tokenValue}>response {HERMES_MOTION_SPRINGS['motion.spring.settle'].response} / damping {HERMES_MOTION_SPRINGS['motion.spring.settle'].damping}</Text>
            </TokenRow>
          </View>
        </VariantGroup>
        <VariantGroup name="Semantic bundles" desc="Named duration + easing + property combinations" align="left">
          <View style={styles.migrationList}>
            {bundles.map(([name, bundle], i) => (
              <TokenRow key={name} use={bundle.detail || `${bundle.durationMs} ms, ${bundle.easing} easing`} last={i === bundles.length - 1}>
                <View style={styles.rowTight}>
                  <Text style={styles.tokenName}>{name}</Text>
                  <Text style={styles.tokenValue}>{bundle.durationMs} ms · {bundle.easing} easing</Text>
                </View>
              </TokenRow>
            ))}
          </View>
        </VariantGroup>
        <VariantGroup name="Current-to-proposed duration mapping" desc="Current ad-hoc durations consolidate to these primitives" align="left">
          <View style={styles.migrationList}>
            {HERMES_MOTION_CURRENT_MAPPING.map((row) => (
              <Text key={row.current} style={styles.migrationLine}>· {row.current} → {row.proposed}</Text>
            ))}
          </View>
        </VariantGroup>
        <VariantGroup name="Reduce Motion" desc="Behavior under the Reduce Motion accessibility setting" align="left">
          <View style={styles.migrationList}>
            {HERMES_MOTION_REDUCE_MOTION.map((line) => (
              <Text key={line} style={[styles.migrationLine, wrapStyle]}>· {line}</Text>
            ))}
          </View>
        </VariantGroup>
        <VariantGroup name="Deferred motion tokens" desc="Deliberately not added without later evidence" align="left">
          <View style={styles.migrationList}>
            {HERMES_MOTION_DEFERRED.map((line) => (
              <Text key={line} style={[styles.migrationLine, wrapStyle]}>· {line}</Text>
            ))}
          </View>
        </VariantGroup>
      </DividedStack>
    </View>
  );
}

// ─── Spacing (spec §6) ────────────────────────────────────────────────────────

export function HermesSpacingProposalGallery() {
  return (
    <View style={styles.stack}>
      <ProposalStatus classification="Proposed — not yet adopted" note={`${HERMES_SPACING_PREVIEW_NOTE} ${HERMES_SPACING_NOTE}`} />
      <DividedStack>
        <VariantGroup name="Spacing primitives" desc="space.0 / 2 / 4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 48 / 64" align="left">
          <SpacingScaleGallery steps={HERMES_SPACING_STEPS} values={HERMES_SPACING} useNotes={HERMES_SPACING_USE} />
        </VariantGroup>
        <VariantGroup name="Migration guidance" align="left">
          <View style={styles.migrationList}>
            {HERMES_SPACING_MIGRATION.map((line) => (
              <Text key={line} style={[styles.migrationLine, wrapStyle]}>· {line}</Text>
            ))}
          </View>
        </VariantGroup>
      </DividedStack>
    </View>
  );
}

// ─── Token coverage — current vs. proposed status (spec §10, Task 4) ──────────

export function HermesTokenCoverageGallery() {
  return (
    <View style={styles.stack}>
      <ProposalStatus classification="Proposed — not yet adopted" note="This page states current production status alongside what the catalog now proposes." />
      <Text style={styles.migrationLine}>
        Production has adopted global HermesSpacing, HermesRadius, and HermesShadow token families (see
        the Hermex Spacing and Hermex Radius & Geometry pages, and HermesMobile/Config/HermesShadow.swift
        for HermesShadow's exact case values); HermesShadow's own dedicated catalog documentation is
        added separately. Production still has no owned icon set and no semantic-color token family —
        see below.
      </Text>
      <Text style={styles.migrationLine}>· No owned icon set — Hermex draws its icons from Apple's own SF Symbols, not a Hermex-authored icon library.</Text>
      <Text style={styles.migrationLine}>· No semantic surface/text/border color layer in production — SwiftUI's own semantic Color values are used directly at each call site.</Text>
      <Text style={styles.migrationLine}>· Dynamic Type owns type sizes and line heights — AppFont supplies named styles, not point sizes.</Text>
      <VariantGroup name="Deferred foundations" desc="Explicitly not proposed yet, pending later evidence" align="left">
        <View style={styles.migrationList}>
          {HERMES_DEFERRED_FOUNDATIONS.map((line) => (
            <Text key={line} style={[styles.migrationLine, wrapStyle]}>· {line}</Text>
          ))}
        </View>
      </VariantGroup>
      <Text style={[styles.migrationLine, wrapStyle]}>
        Repeated literals found during this audit remain component-level findings on their own
        catalog entries — they are deliberately not promoted into a token here, since a shared value
        used by coincidence is not the same claim as a shared value used by design.
      </Text>
    </View>
  );
}
