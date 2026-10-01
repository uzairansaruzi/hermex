import React, { useState } from 'react';
import { View, Text, Pressable, StyleSheet, useWindowDimensions, type TextStyle } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE, CATALOG_RADIUS, CATALOG_NARROW_BREAKPOINT, CATALOG_SPECIMEN_GRID_GAP } from './tokens';
import { PropsTable } from './PropsTable';
import { CatalogSpecimenHeader } from './CatalogSpecimenHeader';
import type { HermesReferenceDestination, SectionDef, VariantSlot } from './types';

// Component documentation uses a 2:1 split: visual examples get the wide primary column while
// reference material stays in the narrower secondary column. The host page caps content at 1200px;
// these caps preserve that ratio while still allowing both columns to shrink when space is tighter.
// Applies only to the retained template/framework routes — a Hermex reference entry (below) uses its
// own full-width Variants/States/Screens card stack instead.
const PRIMARY_COLUMN_WIDTH = 800;
const SECONDARY_COLUMN_WIDTH = 400;
// Shared by the horizontal gap between columns and the vertical gap between blocks inside either
// column — one constant so the hierarchy stays rhythmically consistent. Also reused as the vertical
// gap between a Hermex entry's stacked Variants/States/Screens cards, for the same reason.
const COLUMN_GAP = CATALOG_SPACE['2xl'];

// A Hermex main-canvas "specimen column" (DSR3-04): the bounded box every Variants/States specimen
// renders inside — capped width, padded on all sides, so no child component can overflow its card
// regardless of whether the section uses itemized `variants`/`states` or the `render()` escape hatch.
const SPECIMEN_COLUMN_MAX_WIDTH = 402;

// A long, unbroken path segment (no spaces — e.g. "HermesMobile/Features/Chat/PendingRequestSurfaces.swift")
// has no CSS word-break/overflow-wrap equivalent in RN's own `TextStyle` type (native text already
// wraps at any character once its box runs out of room; only the web target needs telling
// explicitly) — a browser's default flex item still won't shrink an auto-width text box below its
// own unwrapped content width (`min-width: auto`) without this, which is what let a long combined
// path (e.g. after finding 3 below added more callers/paths to one chip) overflow past the narrow-
// viewport content column and get clipped by the chip's own `overflow: 'hidden'`. Cast once, locally,
// rather than widening `styles.path`'s own type with `as any`.
const pathWrapStyle = { overflowWrap: 'anywhere', wordBreak: 'break-word' } as unknown as TextStyle;

/** One labeled block (a block label + a card) inside a column. */
interface BlockDef {
  label: string;
  content: React.ReactNode;
}

/** A `VariantSlot`'s items, stacked/centered (or left-aligned, or filled full-width) per its own
 *  `align`/`itemsFill`. Every item is captioned with its own `name` (e.g. "Primary", "Icon-only")
 *  so it's clear which variant/state each instance demonstrates — not just a bare, unlabeled row of
 *  look-alike components. An individual item's own `fill` stretches just that item's wrapper to the
 *  row's full width — independent of `itemsFill` — so a single wide-format instance (e.g. a
 *  `fullWidth` Button) can sit among otherwise-compact, centered siblings.
 *  `twoColumn` wraps items into two responsive columns when the viewport is wide enough for a real
 *  second column, falling back to the same single centered column everywhere else so nothing renders
 *  cramped. Retained-route `itemsFill` slots stay stacked; a Hermex `specimen` slot may still use the
 *  grid because each item is independently capped. `specimen` additionally caps each item's wrapper
 *  at `SPECIMEN_COLUMN_MAX_WIDTH` with `CATALOG_SPACE.lg` padding on every side (DSR3-04) — set only
 *  by the Hermex main canvas, never the retained template/framework routes. */
function SlotItems({ slot, twoColumn, specimen }: { slot: VariantSlot; twoColumn?: boolean; specimen?: boolean }) {
  // A Hermex main-canvas specimen slot (`specimen`) caps every item at SPECIMEN_COLUMN_MAX_WIDTH
  // regardless of `itemsFill`, so `itemsFill` never has anything to stretch into there and the grid
  // applies the same way it would for a non-`itemsFill` slot. The retained template/framework routes
  // never pass `specimen`, so a wide `itemsFill` slot there keeps its original single stacked column.
  // The grid itself is container-driven: each item requests a comfortable 320px basis, so flex-wrap
  // keeps one column until two specimens plus the shared gap actually fit. This avoids the compressed
  // two-column band created by keying layout only to the viewport breakpoint.
  const useGrid = twoColumn && (specimen || !slot.itemsFill) && slot.items.length > 1;

  return (
    <View
      style={[
        useGrid ? styles.exampleGrid : slot.itemsFill ? styles.exampleStackFill : styles.exampleStack,
        slot.align === 'left' && styles.exampleStackLeft,
      ]}
    >
      {slot.items.map((item) => (
        <View
          key={item.key}
          style={[
            // A block-level itemized specimen (`specimen` grid, `itemsFill` slot) stretches to its
            // own column's inner content width instead of shrink-wrapping — every other combination
            // keeps the existing centered, shrink-to-content item width.
            useGrid ? (specimen && slot.itemsFill ? styles.exampleGridItemFill : styles.exampleGridItem) : styles.exampleItem,
            item.fill && styles.exampleItemFill,
            specimen && styles.specimenColumn,
          ]}
        >
          <CatalogSpecimenHeader name={item.name} details={item.description} />
          {item.node}
        </View>
      ))}
    </View>
  );
}

function EmptyText({ children }: { children: string }) {
  return <Text style={styles.emptyText}>{children}</Text>;
}

/** The "VS" disambiguation note against a component's closest look-alike(s) — shown only by the
 *  retained template/framework header (a Hermex reference entry never shows it — its decision
 *  contract lives in the Details inspector instead, via `useWhen`/`avoidWhen`). */
function WhenToUse({ text }: { text: string }) {
  return (
    <View style={styles.whenToUse}>
      <Text style={styles.whenToUseTag}>VS</Text>
      <Text style={styles.whenToUseText}>{text}</Text>
    </View>
  );
}

// Matches a quoted-string-literal union type, e.g. "'primary' | 'secondary' | 'tertiary'" — anything
// else (string, boolean, IconName, () => void, …) has no fixed enum to sweep and is skipped.
const STRING_LITERAL_RE = /'([^']+)'/g;

/** Opt-in completeness check (rule 4 of the policy documented on `SectionDef.states`): once a
 *  section has at least one `VariantExample.props`-tagged item, warn about any enum value from
 *  `def.props` that no tagged item (across Variants + States) actually demonstrates. Sections that
 *  haven't started tagging are skipped entirely — annotating is gradual, not all-or-nothing. */
function checkCompleteness<TId extends string>(def: SectionDef<TId>): void {
  if (!def.props) return;
  const items = [...(def.variants?.items ?? []), ...(def.states?.items ?? [])];
  const tagged = items.filter((item) => item.props);
  if (tagged.length === 0) return;

  for (const prop of def.props) {
    const literals = prop.type.match(STRING_LITERAL_RE);
    if (!literals || literals.length < 2) continue; // not a multi-value enum
    const values = literals.map((s) => s.slice(1, -1));
    const covered = new Set(
      tagged
        .map((item) => item.props?.[prop.name])
        .filter((v): v is string => typeof v === 'string'),
    );
    const missing = values.filter((v) => !covered.has(v));
    if (missing.length > 0) {
      console.warn(
        `[Catalog] ${def.id}: prop "${prop.name}" has no tagged example for value(s) ${missing.map((v) => `"${v}"`).join(', ')} — ` +
          `add { props: { ${prop.name}: '${missing[0]}' } } to whichever VariantExample already demonstrates it, or add a new one.`,
      );
    }
  }
}

type ColumnKind = 'primary' | 'secondary';

/** Lays out one column's blocks, stacked with `COLUMN_GAP` between them. The LAST block gets
 *  `flex: 1` so its card grows to fill any extra height flexbox's default `alignItems: 'stretch'`
 *  already gave this column (to match whichever sibling column is tallest) — that's what makes
 *  every column's bottom edge land flush, with no JS height measurement. `fill` drops the normal
 *  primary/secondary sizing so a lone column or a narrow-viewport stack spans the full row. */
function Column({ blocks, fill, kind = 'primary' }: { blocks: BlockDef[]; fill?: boolean; kind?: ColumnKind }) {
  const columnStyle = fill
    ? styles.columnFull
    : kind === 'primary'
      ? styles.primaryColumn
      : styles.secondaryColumn;

  return (
    <View style={columnStyle}>
      {blocks.map((block, i) => {
        const isLast = i === blocks.length - 1;
        return (
          <View key={i} style={isLast && styles.blockFill}>
            <Text style={styles.blockLabel}>{block.label}</Text>
            <View style={[styles.card, isLast && styles.cardFill]}>{block.content}</View>
          </View>
        );
      })}
    </View>
  );
}

/** One labeled, full-width card — the Hermex main canvas's own building block (Variants/States/
 *  Screens/Tokens), stacked vertically rather than shared across side-by-side columns. Reuses the
 *  same `blockLabel`/`card` styles as the retained template/framework `Column` above, so both
 *  systems read as one visual language. */
function HermexCard({ label, content }: { label: string; content: React.ReactNode }) {
  return (
    <View>
      <Text style={styles.blockLabel}>{label}</Text>
      <View style={[styles.card, styles.hermexCard]}>{content}</View>
    </View>
  );
}

/** The Hermex main canvas's one Details entry point (DSR3-03) — a single labeled button in the
 *  section header, wired to `onOpenDetails`. Renders nothing when no callback is supplied (e.g. a
 *  Hermex entry with no `hermesReference`, which never reaches this component in the first place). */
function HermexDetailsButton({ onPress }: { onPress?: () => void }) {
  const [focused, setFocused] = useState(false);
  if (!onPress) return null;
  return (
    <Pressable
      onPress={onPress}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      accessibilityRole="button"
      accessibilityLabel="Details"
      style={({ pressed }) => [
        styles.detailsButton,
        focused && styles.detailsButtonFocused,
        pressed && styles.detailsButtonPressed,
      ]}
    >
      <Text style={styles.detailsButtonLabel}>Details</Text>
    </Pressable>
  );
}

/** The Hermex main canvas's Screens card content (DSR3-02) — verified production destinations only:
 *  each destination's `screen` name and `path`, never `effect`, a screenshot, a catalog fixture, a
 *  DEBUG fixture, or a hypothetical destination. Renders the approved exact empty copy when no
 *  destination is verified yet. */
function ScreensContent({ usedIn }: { usedIn?: HermesReferenceDestination[] }) {
  const destinations = usedIn ?? [];
  if (destinations.length === 0) {
    return <EmptyText>No production screens use this yet</EmptyText>;
  }
  return (
    <View style={styles.screensList}>
      {destinations.map((destination, i) => (
        <View key={`${destination.screen}-${i}`} style={styles.screensRow}>
          <Text style={styles.screensScreen}>{destination.screen}</Text>
          {destination.path ? <Text style={[styles.screensPath, pathWrapStyle]}>{destination.path}</Text> : null}
        </View>
      ))}
    </View>
  );
}

/**
 * The Hermex main canvas (DSR3-02/03/04) — the exclusive layout for a `def.hermesReference` entry:
 * a header (title/description + the one Details button) followed by either a single full-width
 * Tokens card (`def.tokenGallery`) or the stacked full-width Variants/States/Screens cards. Never
 * renders Props, Accessibility, decision guidance, source paths, or implementation notes — those
 * live only in the Details inspector `onOpenDetails` opens (`CatalogShell`/`CatalogDetailsInspector`).
 */
function HermexSectionCanvas<TId extends string>({
  def,
  groupLabel,
  onOpenDetails,
}: {
  def: SectionDef<TId>;
  groupLabel?: string;
  onOpenDetails?: (def: SectionDef<TId>) => void;
}) {
  const { width } = useWindowDimensions();
  const isNarrow = width < CATALOG_NARROW_BREAKPOINT;
  const header = (
    <View style={styles.hermexHeaderRow}>
      <View style={styles.hermexHeaderText}>
        {groupLabel && <Text style={styles.groupHeading}>{groupLabel}</Text>}
        <Text style={styles.title}>{def.displayName ?? def.id}</Text>
        <Text style={styles.desc}>{def.description}</Text>
      </View>
      <HermexDetailsButton onPress={onOpenDetails ? () => onOpenDetails(def) : undefined} />
    </View>
  );

  if (def.tokenGallery) {
    const tokensContent = def.render ? def.render() : <EmptyText>No variants documented.</EmptyText>;
    return (
      <View style={styles.section}>
        {header}
        <Column blocks={[{ label: def.fullWidthLabel ?? 'Tokens', content: tokensContent }]} fill />
      </View>
    );
  }

  const variantsContent = def.variants ? (
    <SlotItems slot={def.variants} twoColumn specimen />
  ) : def.render ? (
    <View style={[styles.specimenColumn, styles.renderSpecimenColumn, !isNarrow && styles.renderSpecimenColumnWide]}>
      {def.render()}
    </View>
  ) : (
    <EmptyText>No variants documented.</EmptyText>
  );

  const statesContent = def.states ? (
    <SlotItems slot={def.states} twoColumn specimen />
  ) : (
    <EmptyText>No additional states or configurations documented.</EmptyText>
  );

  const hermexBlocks: BlockDef[] = [
    { label: 'Variants', content: variantsContent },
    { label: 'States', content: statesContent },
    { label: 'Screens', content: <ScreensContent usedIn={def.hermesReference?.usedIn} /> },
  ];

  return (
    <View style={styles.section}>
      {header}
      <View style={styles.hermexCardStack}>
        {hermexBlocks.map((block) => (
          <HermexCard key={block.label} label={block.label} content={block.content} />
        ))}
      </View>
    </View>
  );
}

/**
 * One documented component or token group: an optional group heading (pass `groupLabel` on every
 * section in a sidebar group — not just the first — so each component's category is visible on its
 * own, without having to scroll up to find the nearest heading above it), then title, description,
 * an optional "VS" disambiguation note (`def.whenToUse` — the deciding question against this
 * component's closest look-alike, e.g. InputField vs SearchField), file path, then either —
 *   • a token-gallery section (`def.tokenGallery`): a single "Tokens" column, since there's no
 *     component API (no states/props/accessibility) to document; or
 *   • a component section: a wide primary column stacking Variants above States / Configurations,
 *     beside a narrow secondary column stacking Props above Accessibility. A block with nothing to
 *     show still renders a plain sentence rather than silently reshaping the hierarchy. Pass
 *     `def.hide` to genuinely remove specific cards instead. If hiding leaves one column standing,
 *     it fills the whole row, the same way a `tokenGallery` section does.
 * Whichever column is tallest sets the row's height (flexbox's default `alignItems: 'stretch'`), and
 * every other column's last card grows to fill the rest, so the row's bottom edge lands flush.
 *
 * A Hermex reference entry (`def.hermesReference`) renders through `HermexSectionCanvas` instead —
 * an entirely separate main-canvas layout (stacked full-width Variants/States/Screens cards, or a
 * single Tokens card for a `tokenGallery` entry, plus one header Details button) with no Props/
 * Accessibility/decision-guidance/source/implementation-notes content of its own; that reference
 * material lives only in the Details inspector `onOpenDetails` opens. The template and framework
 * routes below are entirely unaffected — no section on those routes ever has `hermesReference` set.
 */
export function SectionBlock<TId extends string>({
  def,
  groupLabel,
  onOpenDetails,
}: {
  def: SectionDef<TId>;
  groupLabel?: string;
  /** Opens the shared Details inspector for `def` — passed only for a Hermex reference entry
   *  (`CatalogShell` gates this); ignored by the retained template/framework routes. */
  onOpenDetails?: (def: SectionDef<TId>) => void;
}) {
  checkCompleteness(def);

  if (def.hermesReference) {
    return <HermexSectionCanvas def={def} groupLabel={groupLabel} onOpenDetails={onOpenDetails} />;
  }

  const hide = def.hide ?? {};
  // Below CATALOG_NARROW_BREAKPOINT, stack the two documentation columns and explicitly let each
  // fill the row so the desktop max-width caps never leave a narrow card floating in a wider tablet.
  const { width } = useWindowDimensions();
  const isNarrow = width < CATALOG_NARROW_BREAKPOINT;

  const variantsContent = def.variants ? (
    <SlotItems slot={def.variants} twoColumn />
  ) : def.render ? (
    def.render()
  ) : (
    <EmptyText>No variants documented.</EmptyText>
  );

  const primaryHeader = (
    <>
      {groupLabel && <Text style={styles.groupHeading}>{groupLabel}</Text>}
      <Text style={styles.title}>{def.displayName ?? def.id}</Text>
      <Text style={styles.desc}>{def.description}</Text>
      {def.whenToUse ? <WhenToUse text={def.whenToUse} /> : null}
      {def.path ? <Text style={[styles.path, pathWrapStyle]}>{def.path}</Text> : null}
    </>
  );

  const a11yContent = def.a11y ? (
    <Text style={styles.a11yText}>{def.a11y}</Text>
  ) : (
    <EmptyText>No accessibility notes documented.</EmptyText>
  );

  if (def.tokenGallery) {
    return (
      <View style={styles.section}>
        {primaryHeader}
        <View style={[styles.columnsRow, isNarrow && styles.columnsRowNarrow]}>
          <Column blocks={[{ label: def.fullWidthLabel ?? 'Tokens', content: variantsContent }]} fill />
        </View>
      </View>
    );
  }

  const statesContent = def.states ? (
    <SlotItems slot={def.states} />
  ) : (
    <EmptyText>No additional states or configurations documented.</EmptyText>
  );

  const propsContent =
    def.props && def.props.length > 0 ? (
      <PropsTable props={def.props} />
    ) : (
      <EmptyText>This component takes no props.</EmptyText>
    );

  const primaryBlocks: BlockDef[] = [
    ...(hide.variants ? [] : [{ label: 'Variants', content: variantsContent }]),
    ...(hide.states ? [] : [{ label: 'States / Configurations', content: statesContent }]),
  ];

  const secondaryBlocks: BlockDef[] = [
    ...(hide.props ? [] : [{ label: 'Props', content: propsContent }]),
    ...(hide.accessibility ? [] : [{ label: 'Accessibility', content: a11yContent }]),
  ];

  const columns: { blocks: BlockDef[]; kind: ColumnKind }[] = [
    ...(primaryBlocks.length > 0 ? [{ blocks: primaryBlocks, kind: 'primary' as const }] : []),
    ...(secondaryBlocks.length > 0 ? [{ blocks: secondaryBlocks, kind: 'secondary' as const }] : []),
  ];

  return (
    <View style={styles.section}>
      {primaryHeader}
      {columns.length > 0 && (
        <View style={[styles.columnsRow, isNarrow && styles.columnsRowNarrow]}>
          {columns.map((col) => (
            <Column
              key={col.kind}
              blocks={col.blocks}
              kind={col.kind}
              fill={isNarrow || columns.length === 1}
            />
          ))}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  section: { paddingBottom: CATALOG_SPACE.sm },
  groupHeading: {
    fontSize: CATALOG_TYPE.sm, fontWeight: '800', textTransform: 'uppercase', letterSpacing: 0.7,
    color: CATALOG_COLOR.textMuted, marginBottom: CATALOG_SPACE.xl,
  },
  title: { fontSize: CATALOG_TYPE['2xl'], fontWeight: '700', color: CATALOG_COLOR.text, marginBottom: CATALOG_SPACE.xs },
  desc: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, lineHeight: 18, marginBottom: CATALOG_SPACE.sm },
  path: {
    // Text is a flex child of `section` (a column, default `alignItems: 'stretch'`) — without this,
    // the chip's background would stretch to the section's full width instead of hugging its text.
    // Kept for short paths (the common case) — `maxWidth`/`flexShrink` below only take over once a
    // path is too long to fit as-is.
    alignSelf: 'flex-start',
    // Caps the chip at its column's own available width and allows it to shrink below its unwrapped
    // content width — a flex item's default `min-width: auto` otherwise refuses to shrink an
    // auto-sized text box past its own (unwrapped) content size, which is what let a long path
    // overflow the page rather than wrap (paired with `pathWrapStyle`'s word-break, applied
    // separately since it has no typed `TextStyle` equivalent).
    maxWidth: '100%',
    flexShrink: 1,
    fontSize: CATALOG_TYPE.sm, fontFamily: CATALOG_COLOR.code, color: CATALOG_COLOR.textMuted,
    backgroundColor: CATALOG_COLOR.chip, paddingHorizontal: CATALOG_SPACE.sm, paddingVertical: CATALOG_SPACE.xs,
    borderRadius: 6, overflow: 'hidden', marginBottom: COLUMN_GAP,
  },
  // "VS" disambiguation note — a small accent-coloured tag + sentence, distinct from the plain
  // description above it so it reads as "here's the one deciding fact", not more prose to skim past.
  whenToUse: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: CATALOG_SPACE.sm,
    marginBottom: CATALOG_SPACE.sm,
  },
  whenToUseTag: {
    fontSize: CATALOG_TYPE.xs, fontWeight: '800', color: CATALOG_COLOR.accent,
    borderWidth: 1, borderColor: CATALOG_COLOR.accent, borderRadius: 4,
    paddingHorizontal: 5, paddingVertical: 1, marginTop: 1,
  },
  whenToUseText: {
    flex: 1, fontSize: CATALOG_TYPE.sm, lineHeight: 18, color: CATALOG_COLOR.text,
  },
  columnsRow: { flexDirection: 'row', gap: COLUMN_GAP },
  // Narrow-viewport override — stacks the visual-example and reference-content columns vertically.
  columnsRowNarrow: { flexDirection: 'column' },
  primaryColumn: { flex: 2, maxWidth: PRIMARY_COLUMN_WIDTH, gap: COLUMN_GAP },
  secondaryColumn: { flex: 1, maxWidth: SECONDARY_COLUMN_WIDTH, gap: COLUMN_GAP },
  // No maxWidth — for a lone column (`tokenGallery`) with no siblings to share the row with, so its
  // card spans however much width `columnsRow` actually has (bounded only by the host page's own
  // container, e.g. CatalogShell's CATALOG_MAX_CONTENT_WIDTH).
  columnFull: { flex: 1, gap: COLUMN_GAP },
  // Only applied to a column's LAST block — grows to absorb whatever extra height `columnsRow`'s
  // stretch gave this column, so its card's bottom edge reaches the column's bottom.
  blockFill: { flex: 1 },
  cardFill: { flex: 1, justifyContent: 'center' },
  blockLabel: {
    fontSize: CATALOG_TYPE.xs, fontWeight: '700', color: CATALOG_COLOR.textMuted, textTransform: 'uppercase',
    letterSpacing: 0.6, marginBottom: CATALOG_SPACE.sm,
  },
  card: {
    backgroundColor: CATALOG_COLOR.surfaceMuted,
    borderWidth: 1,
    borderColor: CATALOG_COLOR.border,
    borderRadius: CATALOG_RADIUS.md,
    // Every card in every section, in both catalogs — Variants/States/Props/Accessibility/Tokens/
    // Screens — shares this one padding value, since they all render through this single Column/
    // HermexCard/card path.
    padding: CATALOG_SPACE.xl,
    // Guarantees breathing room between whatever a card holds (multiple examples, prop rows, …)
    // at the SectionBlock level, so a SectionDef's render() doesn't have to remember its own gap.
    gap: CATALOG_SPACE.md,
  },
  // Hermex gallery cards use the approved 16px section inset; retained catalog cards keep 24px.
  hermexCard: { padding: CATALOG_SPACE.lg },
  a11yText: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, lineHeight: 18 },
  emptyText: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, fontStyle: 'italic' },
  // Layout for a slot's items: vertical, centered, at least 24px apart — for small instances meant
  // to sit as compact items (Button, Badge, Pill).
  exampleStack: { alignItems: 'center', gap: CATALOG_SPACE.xl },
  // Same, but each item stretches to the card's full width (flexbox's default `alignItems: 'stretch'`
  // — no override needed) — for wide block-level components (Banner, Card, Toast, InputField).
  exampleStackFill: { gap: CATALOG_SPACE.xl },
  exampleStackLeft: { alignItems: 'flex-start' },
  // Up to three responsive columns for a Variants/States box. The parent canvas cap prevents a
  // fourth 320px-basis item from fitting; incomplete rows stay leading-aligned rather than centered.
  // #607 round-3 correction: the shared 40px specimen-grid gap (CATALOG_SPECIMEN_GRID_GAP), not the
  // unrelated 32px COLUMN_GAP that still governs this section's own Variants/States/Props gap.
  exampleGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: CATALOG_SPECIMEN_GRID_GAP, justifyContent: 'flex-start' },
  exampleGridItem: {
    flexBasis: 320, flexGrow: 1, maxWidth: SPECIMEN_COLUMN_MAX_WIDTH, minWidth: 0, alignItems: 'center',
  },
  // #607 round-3 correction: a block-level itemized specimen (Hermex Card, Pending Request, …)
  // stretches to its own specimenColumn's inner content width (402 - 32px padding) instead of
  // shrink-wrapping — the same `alignItems: 'stretch'` every View defaults to, made explicit here
  // since exampleGridItem above overrides it to 'center' for compact, shrink-wrapped items.
  exampleGridItemFill: {
    flexBasis: 320, flexGrow: 1, maxWidth: SPECIMEN_COLUMN_MAX_WIDTH, minWidth: 0, alignItems: 'stretch',
  },
  // One item + its name caption, stacked tightly and centered under the item. 6px sits between
  // CATALOG_SPACE.xs (4) and .sm (8) — no scale step lands on it, so it's a literal value here.
  exampleItem: { alignItems: 'center', gap: 6 },
  // Per-item override (VariantExample.fill) — `alignSelf` always wins over the parent's `alignItems`
  // regardless of whether that parent is a centered `exampleStack` or an already-stretched
  // `exampleStackFill`, so this works the same in either slot.
  exampleItemFill: { alignSelf: 'stretch' },
  // DSR3-04's "specimen column": every Hermex main-canvas Variants/States item renders inside this
  // capped, padded box — `width: '100%'` lets it grow to fill its row/grid slot up to the cap
  // (rather than shrinking to bare content width), so every specimen reads as a consistent,
  // predictable card rather than a variable-width shrink-to-fit item.
  specimenColumn: { width: '100%', maxWidth: SPECIMEN_COLUMN_MAX_WIDTH, padding: CATALOG_SPACE.lg },
  renderSpecimenColumn: { alignSelf: 'center' },
  // #607: a wide render()-based Hermex gallery may span three specimen columns, two shared 40px
  // (CATALOG_SPECIMEN_GRID_GAP) gaps, and this wrapper's own 16px inset on each side. The base style
  // remains a single 402px column below the existing narrow breakpoint; flex wrapping chooses one,
  // two, or three columns from actual space.
  renderSpecimenColumnWide: { maxWidth: SPECIMEN_COLUMN_MAX_WIDTH * 3 + CATALOG_SPECIMEN_GRID_GAP * 2 + CATALOG_SPACE.lg * 2 },
  // Hermex main-canvas header (DSR3-03) — title/description beside the one Details button, replacing
  // the retained template/framework header's inline "VS" note and file-path chip (neither renders
  // for a Hermex reference entry; both moved to the Details inspector's own decision/source content).
  hermexHeaderRow: {
    flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between',
    gap: CATALOG_SPACE.lg, marginBottom: CATALOG_SPACE.xl,
  },
  hermexHeaderText: { flex: 1, minWidth: 0 },
  // Stacks the Hermex main canvas's full-width Variants/States/Screens cards (or the lone Tokens
  // card's sibling-free Column above) with the same rhythm as the retained routes' own column gap.
  hermexCardStack: { gap: COLUMN_GAP },
  detailsButton: {
    flexShrink: 0,
    paddingHorizontal: CATALOG_SPACE.md,
    paddingVertical: CATALOG_SPACE.xs,
    borderRadius: CATALOG_RADIUS.sm,
    borderWidth: 2,
    borderColor: CATALOG_COLOR.border,
  },
  detailsButtonFocused: { borderColor: CATALOG_COLOR.accent },
  detailsButtonPressed: { backgroundColor: CATALOG_COLOR.surfacePressed },
  detailsButtonLabel: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.accent },
  screensList: { gap: CATALOG_SPACE.md },
  screensRow: { gap: 2, maxWidth: '100%' },
  screensScreen: { fontSize: CATALOG_TYPE.sm, fontWeight: '700', color: CATALOG_COLOR.text },
  screensPath: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, lineHeight: 17, maxWidth: '100%', flexShrink: 1 },
});
