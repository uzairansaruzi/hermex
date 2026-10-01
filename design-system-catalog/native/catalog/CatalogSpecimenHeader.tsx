/**
 * One specimen's name + its own anchored, non-modal Details disclosure (#607 round-3 correction) —
 * shared by SectionBlock's itemized `SlotItems` and HermesComponentFamiliesPreviews' custom
 * `PreviewSpecimen` galleries, so the main gallery surface only ever shows a name and the rendered
 * specimen, with every catalog-authored explanation/caption moved behind this one Details button.
 * The popover overlays the grid (absolutely positioned within this component's own relatively
 * positioned root) rather than reflowing it, is capped at 320px, supports touch and mouse, exposes
 * the trigger's real expanded accessibility state, and closes on a second press of the trigger, an
 * outside press, or Escape — always returning focus to the trigger. Deliberately NOT the 600px modal
 * `CatalogDetailsInspector`: that panel documents a whole component/token entry; this documents one
 * small specimen inline, right where the reader is already looking, so it never reflows or hides the
 * rest of the grid. A plain absolutely-positioned overlay, the same convention
 * `CatalogDetailsInspector`/`Dialog`/`BottomSheet` already use elsewhere in this repo — no portal, no
 * new dependency.
 */
import React, { useCallback, useEffect, useRef, useState, type ComponentPropsWithRef, type ComponentType } from 'react';
import { Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import { CATALOG_COLOR, CATALOG_RADIUS, CATALOG_SPACE, CATALOG_TYPE } from './tokens';

/** Max popover width (frozen acceptance contract) — the popover never spans a whole specimen row. */
const POPOVER_MAX_WIDTH = 320;

// `aria-expanded` has no equivalent in Pressable's own (native-targeting) prop types, and
// react-native-web's accessibility-prop mapping has no case for `accessibilityState.expanded` on its
// own (confirmed by this repo's own ListItem/AccordionList correction) — same narrow, explicitly
// typed escape hatch as CatalogDetailsInspector's own `role`/`aria-modal` cast.
const ExpandableTrigger = Pressable as unknown as ComponentType<ComponentPropsWithRef<typeof Pressable> & { 'aria-expanded'?: boolean }>;

export interface CatalogSpecimenHeaderProps {
  /** The variant/state (or custom gallery specimen) name shown on the main gallery surface — e.g.
   *  "Primary", "Icon-only". Always visible; never gated behind Details. */
  name: string;
  /** Catalog-authored explanation/caption, shown only inside this component's own anchored Details
   *  popover — never inline on the main gallery surface. Omit (or pass `undefined`) and no Details
   *  button renders at all, since there is nothing to disclose. */
  details?: React.ReactNode;
}

export function CatalogSpecimenHeader({ name, details }: CatalogSpecimenHeaderProps) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<View>(null);
  const triggerRef = useRef<View>(null);

  const close = useCallback(() => setOpen(false), []);
  const toggle = useCallback(() => setOpen((value) => !value), []);

  // Escape and outside-press dismissal — web only, mirroring CatalogDetailsInspector's own
  // document-level listeners (see its longer comment). Native has no document/outside-press concept
  // to attach to here, and a second press of the trigger already closes the popover on every
  // platform, so native dismissal is covered without this effect ever running there.
  useEffect(() => {
    if (!open || Platform.OS !== 'web' || typeof document === 'undefined') return;

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      close();
      (triggerRef.current as unknown as HTMLElement | null)?.focus?.();
    };
    const handlePointerDown = (event: MouseEvent) => {
      const rootNode = rootRef.current as unknown as HTMLElement | null;
      if (rootNode && event.target instanceof Node && rootNode.contains(event.target)) return;
      close();
    };

    document.addEventListener('keydown', handleKeyDown);
    document.addEventListener('mousedown', handlePointerDown);
    return () => {
      document.removeEventListener('keydown', handleKeyDown);
      document.removeEventListener('mousedown', handlePointerDown);
    };
  }, [open, close]);

  return (
    <View ref={rootRef} style={[styles.root, open && styles.rootOpen]}>
      <View style={styles.row}>
        <Text style={styles.name}>{name}</Text>
        {details != null && (
          <ExpandableTrigger
            ref={triggerRef}
            onPress={toggle}
            accessibilityRole="button"
            accessibilityLabel="Details"
            accessibilityState={{ expanded: open }}
            aria-expanded={open}
            style={({ pressed }) => [styles.detailsButton, pressed && styles.detailsButtonPressed]}
          >
            <Text style={styles.detailsButtonLabel}>Details</Text>
          </ExpandableTrigger>
        )}
      </View>
      {open && details != null && (
        <View style={styles.popover}>
          {typeof details === 'string' ? <Text style={styles.popoverText}>{details}</Text> : details}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  // Relatively positioned so the popover below anchors to this one header, not the whole grid.
  root: { position: 'relative' },
  // The specimen content is rendered after this header. Raise the whole open header's stacking context,
  // not only the absolutely positioned popover, so later siblings cannot paint over its explanation.
  rootOpen: { zIndex: 100 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: CATALOG_SPACE.sm },
  name: { fontSize: CATALOG_TYPE.xs, color: CATALOG_COLOR.textMuted },
  detailsButton: {
    flexShrink: 0,
    paddingHorizontal: CATALOG_SPACE.sm, paddingVertical: 2, borderRadius: CATALOG_RADIUS.sm,
    borderWidth: 1, borderColor: CATALOG_COLOR.border,
  },
  detailsButtonPressed: { backgroundColor: CATALOG_COLOR.surfacePressed },
  detailsButtonLabel: { fontSize: CATALOG_TYPE.xs, fontWeight: '700', color: CATALOG_COLOR.accent },
  // Overlays the grid instead of reflowing it — absolutely positioned under the trigger with its own
  // stacking layer above any sibling specimen, capped at POPOVER_MAX_WIDTH so it never spans a whole
  // specimen row.
  popover: {
    position: 'absolute', top: '100%', right: 0, marginTop: CATALOG_SPACE.xs, zIndex: 10,
    maxWidth: POPOVER_MAX_WIDTH, padding: CATALOG_SPACE.md, borderRadius: CATALOG_RADIUS.md,
    backgroundColor: CATALOG_COLOR.surface, borderWidth: 1, borderColor: CATALOG_COLOR.border,
    shadowColor: '#000000', shadowOpacity: 0.16, shadowRadius: 12, shadowOffset: { width: 0, height: 4 },
  },
  popoverText: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, lineHeight: 18 },
});
