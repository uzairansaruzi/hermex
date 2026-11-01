/**
 * Catalog-owned component for a Hermex reference entry's supporting content — since DSR3-03, the
 * flat vertical content the shared `CatalogDetailsInspector` renders once a reader opens a section's
 * one `Details` button (see `CatalogShell`), in this exact order: Use when, Avoid when, Alternatives,
 * Props, Accessibility, Adoption status, Source, Implementation notes. Replaces the earlier three
 * side-by-side reference/provenance/accessibility cards rendered inline below a section's own
 * Variants/States/Props specimen row — that inline
 * placement, and the per-card measured-overflow expand/collapse control each of those three used,
 * are both removed; the inspector itself owns scrolling. Verified production destinations
 * (`usedIn`) are shown once, on the main canvas's own Screens card (`SectionBlock`) — never
 * repeated here.
 */
import React, { useState, type ComponentProps, type ComponentType } from 'react';
import { View, Text, StyleSheet, Pressable, type TextStyle } from 'react-native';
import { AnimatedChevron } from '../../components';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE } from '../tokens';
import { PropsTable } from '../PropsTable';
import type { HermesAdoptionState, HermesAlternative, HermesReferenceMeta, PropDef } from '../types';

// Same web-only word-break/overflow-wrap escape hatch used throughout the catalog (SectionBlock's
// own `pathWrapStyle`) — a long, unbroken source-path token has no RN `TextStyle` equivalent to
// force a mid-word break.
const wrapStyle = { overflowWrap: 'anywhere', wordBreak: 'break-word' } as unknown as TextStyle;

// `aria-expanded` has no equivalent in React Native's own (native-targeting) `Pressable` props, and
// unlike `accessibilityState.disabled`/`checked`/`busy`/`selected`, react-native-web's own
// accessibility-prop mapping has no case for `accessibilityState.expanded` at all — so it never
// reaches the DOM on its own. Same narrow, explicitly-typed escape hatch as CatalogSidebar's own
// `aria-current` cast.
const DisclosureTrigger = Pressable as unknown as ComponentType<ComponentProps<typeof Pressable> & { 'aria-expanded'?: boolean }>;

interface DisclosureProps {
  label: 'Implementation notes';
  children: React.ReactNode;
}

/** A single collapsible control — kept only for `HermesOverviewImplementationDetails`'s own compact,
 *  catalog-overview-level evidence (see that component below); a per-entry Details section (below)
 *  never gates its content behind one — the inspector itself owns scrolling for all eight. */
function Disclosure({ label, children }: DisclosureProps) {
  const [expanded, setExpanded] = useState(false);
  const [focused, setFocused] = useState(false);

  return (
    <View style={styles.disclosure}>
      <DisclosureTrigger
        onPress={() => setExpanded((value) => !value)}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        accessibilityRole="button"
        accessibilityState={{ expanded }}
        aria-expanded={expanded}
        style={({ pressed }) => [styles.trigger, focused && styles.triggerFocused, pressed && styles.triggerPressed]}
      >
        <Text style={styles.triggerLabel}>{label}</Text>
        <AnimatedChevron expanded={expanded} size={16} color={CATALOG_COLOR.textMuted} />
      </DisclosureTrigger>
      {expanded ? <View style={styles.disclosureBody}>{children}</View> : null}
    </View>
  );
}

function AlternativeRow({ alternative }: { alternative: HermesAlternative }) {
  return (
    <View style={styles.alternativeRow}>
      <Text style={styles.alternativeName}>{alternative.name}</Text>
      <Text style={styles.alternativeUseWhen}>{alternative.useWhen}</Text>
    </View>
  );
}

const ADOPTION_STATE_LABEL: Record<HermesAdoptionState, string> = {
  'foundation-available': 'Foundation available',
  'production-adopted': 'Production adopted',
  'partially-adopted': 'Partially adopted',
  'native-platform': 'Native platform',
  'reference-only': 'Reference only',
};

/** One section of the flat Details inspector flow — a plain uppercase label heading followed by its
 *  content, stacked with `CATALOG_SPACE.xl` between sections (no card chrome, no disclosure — the
 *  inspector panel itself is the scrollable surface). */
function DetailsSection({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <View style={styles.detailsSection}>
      <Text style={styles.detailsSectionLabel}>{label}</Text>
      {children}
    </View>
  );
}

function ImplementationNotesContent({
  meta,
  implementationContent,
}: {
  meta: HermesReferenceMeta;
  implementationContent?: React.ReactNode;
}) {
  const hasImplementationNotes = Boolean(
    meta.implementationNotes?.status ||
      meta.implementationNotes?.sourcePaths?.length ||
      meta.implementationNotes?.notes?.length ||
      implementationContent,
  );

  if (!hasImplementationNotes) {
    return <Text style={styles.emptyText}>No implementation notes documented.</Text>;
  }

  return (
    <View style={styles.implementationBlock}>
      {meta.implementationNotes?.status ? (
        <Text style={styles.implementationStatus}>{meta.implementationNotes.status}</Text>
      ) : null}
      {meta.implementationNotes?.sourcePaths?.length ? (
        <View style={styles.sourcePathList}>
          {meta.implementationNotes.sourcePaths.map((sourcePath) => (
            <Text key={sourcePath} style={[styles.sourcePath, wrapStyle]}>
              {sourcePath}
            </Text>
          ))}
        </View>
      ) : null}
      {meta.implementationNotes?.notes?.length ? (
        <View style={styles.notesList}>
          {meta.implementationNotes.notes.map((note, i) => (
            <Text key={i} style={[styles.implementationNote, wrapStyle]}>
              · {note}
            </Text>
          ))}
        </View>
      ) : null}
      {implementationContent}
    </View>
  );
}

/** Compact implementation-only disclosure for the catalog overview's maintainer evidence. The
 * overview is not a SectionDef reference entry, so it must not inherit the entry-level Details
 * inspector's full eight-section flow (empty Use when/Avoid when/Props/Accessibility/Adoption status
 * sections it has no data for) — it keeps its own separate, compact, collapsible path instead. */
export function HermesOverviewImplementationDetails({
  meta,
  implementationContent,
}: {
  meta: HermesReferenceMeta;
  implementationContent?: React.ReactNode;
}) {
  return (
    <Disclosure label="Implementation notes">
      <ImplementationNotesContent meta={meta} implementationContent={implementationContent} />
    </Disclosure>
  );
}

/** The Details inspector's own "Source" section content — `implementationNotes.sourcePaths` only,
 *  kept separate from "Implementation notes" (status + notes) per the flat content order. */
function SourceContent({ meta }: { meta: HermesReferenceMeta }) {
  const sourcePaths = meta.implementationNotes?.sourcePaths ?? [];
  if (sourcePaths.length === 0) {
    return <Text style={styles.emptyText}>No source paths documented.</Text>;
  }
  return (
    <View style={styles.sourcePathList}>
      {sourcePaths.map((sourcePath) => (
        <Text key={sourcePath} style={[styles.sourcePath, wrapStyle]}>
          {sourcePath}
        </Text>
      ))}
    </View>
  );
}

/** The Details inspector's own "Implementation notes" section content — status + notes only
 *  (sourcePaths render separately, in "Source" above it — see `SourceContent`). */
function ImplementationNotesOnlyContent({
  meta,
  implementationContent,
}: {
  meta: HermesReferenceMeta;
  implementationContent?: React.ReactNode;
}) {
  const hasNotes = Boolean(meta.implementationNotes?.status || meta.implementationNotes?.notes?.length || implementationContent);
  if (!hasNotes) {
    return <Text style={styles.emptyText}>No implementation notes documented.</Text>;
  }
  return (
    <View style={styles.implementationBlock}>
      {meta.implementationNotes?.status ? (
        <Text style={styles.implementationStatus}>{meta.implementationNotes.status}</Text>
      ) : null}
      {meta.implementationNotes?.notes?.length ? (
        <View style={styles.notesList}>
          {meta.implementationNotes.notes.map((note, i) => (
            <Text key={i} style={[styles.implementationNote, wrapStyle]}>
              · {note}
            </Text>
          ))}
        </View>
      ) : null}
      {implementationContent}
    </View>
  );
}

interface HermesReferenceDetailsProps {
  meta: HermesReferenceMeta;
  /** The entry's real prop interface (`SectionDef.props`) — rendered via the shared `PropsTable`,
   *  the same table the retained template/framework routes show in their own secondary column. */
  props?: PropDef[];
  implementationContent?: React.ReactNode;
  /** The entry's accessibility guidance (`SectionDef.a11y`) — falls back to the same truthful
   *  "No accessibility notes documented." text the retained routes' own secondary column shows. */
  accessibilityContent?: React.ReactNode;
}

/** The Details inspector's entire content — one flat vertical flow, in the exact required order:
 *  Use when, Avoid when, Alternatives, Props, Accessibility, Adoption status, Source, Implementation
 *  notes. No tabs, no nested drawer, no per-section disclosure — the inspector panel itself scrolls. */
export function HermesReferenceDetails({
  meta,
  props,
  implementationContent,
  accessibilityContent = <Text style={styles.emptyText}>No accessibility notes documented.</Text>,
}: HermesReferenceDetailsProps) {
  const alternatives = meta.alternatives ?? [];

  return (
    <View style={styles.detailsFlow}>
      <DetailsSection label="Use when">
        <Text style={styles.decisionText}>{meta.useWhen ?? 'No usage guidance documented.'}</Text>
        {meta.useSummary ? <Text style={styles.useSummary}>{meta.useSummary}</Text> : null}
      </DetailsSection>
      <DetailsSection label="Avoid when">
        <Text style={styles.decisionText}>{meta.avoidWhen ?? 'No avoidance guidance documented.'}</Text>
      </DetailsSection>
      <DetailsSection label="Alternatives">
        {alternatives.length > 0 ? (
          <View style={styles.alternativesList}>
            {alternatives.map((alternative, i) => (
              <AlternativeRow key={`${alternative.name}-${i}`} alternative={alternative} />
            ))}
          </View>
        ) : (
          <Text style={styles.decisionText}>No direct alternative.</Text>
        )}
      </DetailsSection>
      <DetailsSection label="Props">
        {props && props.length > 0 ? <PropsTable props={props} /> : <Text style={styles.emptyText}>This component takes no props.</Text>}
      </DetailsSection>
      <DetailsSection label="Accessibility">{accessibilityContent}</DetailsSection>
      <DetailsSection label="Adoption status">
        {meta.adoptionStatus ? (
          <Text style={styles.decisionText}>
            <Text style={styles.adoptionStateTag}>{ADOPTION_STATE_LABEL[meta.adoptionStatus.state]}</Text>
            {' — '}
            {meta.adoptionStatus.detail}
          </Text>
        ) : (
          <Text style={styles.emptyText}>No adoption status documented.</Text>
        )}
      </DetailsSection>
      <DetailsSection label="Source">
        <SourceContent meta={meta} />
      </DetailsSection>
      <DetailsSection label="Implementation notes">
        <ImplementationNotesOnlyContent meta={meta} implementationContent={implementationContent} />
      </DetailsSection>
    </View>
  );
}

const styles = StyleSheet.create({
  detailsFlow: { gap: CATALOG_SPACE.xl },
  detailsSection: { gap: CATALOG_SPACE.sm, maxWidth: '100%' },
  detailsSectionLabel: {
    fontSize: CATALOG_TYPE.xs, fontWeight: '700', color: CATALOG_COLOR.textMuted,
    textTransform: 'uppercase', letterSpacing: 0.6,
  },
  emptyText: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, fontStyle: 'italic' },
  decisionText: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.text, lineHeight: 18, maxWidth: '100%' },
  useSummary: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, lineHeight: 18, fontStyle: 'italic' },
  alternativesList: { gap: CATALOG_SPACE.sm },
  alternativeRow: { gap: 2, maxWidth: '100%' },
  alternativeName: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.text },
  alternativeUseWhen: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, lineHeight: 17 },
  adoptionStateTag: {
    fontSize: CATALOG_TYPE.xs, fontWeight: '800', color: CATALOG_COLOR.accent,
    textTransform: 'uppercase', letterSpacing: 0.4,
  },
  disclosure: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: CATALOG_COLOR.borderHairline, paddingTop: CATALOG_SPACE.sm },
  trigger: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingVertical: CATALOG_SPACE.xs, borderRadius: 8,
    borderWidth: 2, borderColor: 'transparent',
  },
  triggerFocused: { borderColor: CATALOG_COLOR.accent },
  triggerPressed: { opacity: 0.7 },
  triggerLabel: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.text },
  disclosureBody: { paddingTop: CATALOG_SPACE.sm, gap: CATALOG_SPACE.sm },
  implementationBlock: { gap: CATALOG_SPACE.sm },
  implementationStatus: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.text, lineHeight: 18 },
  sourcePathList: { gap: 2 },
  sourcePath: {
    fontSize: CATALOG_TYPE.sm, fontFamily: CATALOG_COLOR.code, color: CATALOG_COLOR.textMuted,
    maxWidth: '100%', flexShrink: 1,
  },
  notesList: { gap: 4 },
  implementationNote: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, lineHeight: 17, maxWidth: '100%', flexShrink: 1 },
});
