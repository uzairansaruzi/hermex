import { useState, type ComponentProps, type ComponentType } from 'react';
import { View, Text, ScrollView, Pressable, StyleSheet, useWindowDimensions } from 'react-native';
import type { ViewStyle } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE, CATALOG_RADIUS, CATALOG_NARROW_BREAKPOINT } from './tokens';
import { sortIds, type NavGroup } from './types';
import { CatalogSearchInput } from './CatalogSearchInput';

// `aria-current` has no equivalent in React Native's own (native-targeting) `Pressable` props — it's
// a web-only ARIA attribute react-native-web forwards straight through to the DOM element, with no
// native-side meaning at all. A narrow, explicitly-typed escape hatch (same convention as this file's
// own `position: 'sticky'` style cast below) rather than `as any` on the whole element, so a typo
// here would still be caught.
const LinkPressable = Pressable as unknown as ComponentType<ComponentProps<typeof Pressable> & { 'aria-current'?: 'location' }>;

/**
 * One nav link. Tracks its own hover state via `onHoverIn`/`onHoverOut` (real events on web,
 * simply never fired on native touch devices, so hover styling only ever shows up where it makes
 * sense) rather than reading `hovered` off Pressable's style-callback — this project's Pressable
 * types (targeting native) don't expose that field, even though react-native-web's runtime does.
 */
function NavItem<TId extends string>({ id, label, active, onPress }: { id: TId; label: string; active: boolean; onPress: () => void }) {
  const [hovered, setHovered] = useState(false);
  // Keyboard focus shows the same highlight as hover/press — react-native-web suppresses the
  // browser's default outline on Pressable, so without this a keyboard user tabbing the sidebar
  // gets no visible focus position at all.
  const [focused, setFocused] = useState(false);
  return (
    <LinkPressable
      onPress={onPress}
      onHoverIn={() => setHovered(true)}
      onHoverOut={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      accessibilityRole="link"
      // `aria-current="location"` is the correct current-page/current-section marker for a role="link"
      // element — the previous approach set an `accessibilityState` selected flag (which maps to
      // `aria-selected` on web), an ARIA property valid only for option/tab/row-type roles, not link;
      // dropped rather than kept alongside this.
      aria-current={active ? 'location' : undefined}
      style={({ pressed }) => [styles.item, active && styles.itemActive, (pressed || hovered || focused) && styles.itemPressed]}
    >
      {/* Non-color active cue (bold weight + the row's own itemActive background/indicator above) —
          color alone doesn't survive grayscale/color-blind viewing or a muted display. */}
      <Text style={[styles.label, active && styles.labelActive]}>{label}</Text>
    </LinkPressable>
  );
}

/**
 * Sticky sidebar: app name/subtitle, a filter box, and one Pressable nav link per section id,
 * grouped under labeled headings (e.g. "Components" / "Tokens"). Generic over `TId` — the host
 * app supplies its own section-id union and groups; this component never needs to know what a
 * "Button" or a "Colors" page actually is.
 */
export function CatalogSidebar<TId extends string>({
  logo,
  caption,
  groups,
  active,
  onPress,
  labelFor = (id) => id,
}: {
  logo: string;
  caption: string;
  groups: NavGroup<TId>[];
  active: TId;
  onPress: (id: TId) => void;
  /** Resolves an id to its displayed nav label (default: the id itself) — lets a combined multi-
   *  catalog `sections` array keep unique ids while showing each entry's own clean display name. */
  labelFor?: (id: TId) => string;
}) {
  const [query, setQuery] = useState('');
  const q = query.trim().toLowerCase();
  // Below CATALOG_NARROW_BREAKPOINT, CatalogShell stacks this above the main column instead of
  // beside it — a fixed 240px width and a 100vh sticky height would otherwise either overflow a
  // phone viewport horizontally or consume the whole screen before any content shows. Bound it to
  // a fixed top region with its own internal scroll instead.
  const { width } = useWindowDimensions();
  const isNarrow = width < CATALOG_NARROW_BREAKPOINT;

  return (
    <View style={[styles.sidebar, isNarrow && styles.sidebarNarrow]}>
      {/* Visible on purpose (not the framework's usual `false`) — this list is often long enough to
          scroll on its own (both the 100vh desktop sidebar and the bounded mobile top region), and a
          hidden scrollbar leaves no visual cue that there's more to find below the fold. */}
      <ScrollView style={styles.scroll} contentContainerStyle={styles.content} showsVerticalScrollIndicator>
        <Text style={styles.logo}>{logo}</Text>
        <Text style={styles.subtitle}>{caption}</Text>

        <CatalogSearchInput value={query} onChangeText={setQuery} placeholder="Filter components…" />

        {(() => {
          // Filter to the query, then order through the shared `sortIds` — the same helper
          // CatalogShell uses for the main column's render order and scroll-spy, so this list's
          // visual order can never drift from where a click actually scrolls to. A group's own
          // `alphabetizeByLabel` decides whether that order is keyed on the visible label
          // (`labelFor`) or `sortIds`' raw-id default — see `types.ts`.
          const filtered = groups.map(g => ({
            ...g,
            ids: sortIds(
              q ? g.ids.filter(id => id.toLowerCase().includes(q) || labelFor(id).toLowerCase().includes(q)) : g.ids,
              g.alphabetizeByLabel ? labelFor : undefined,
            ),
          }));
          const hasMatches = filtered.some(g => g.ids.length > 0);
          return (
            <>
              {!hasMatches && <Text style={styles.empty}>No matches</Text>}
              {filtered.map(g => g.ids.length > 0 && (
                <View key={g.label}>
                  <View style={styles.groupLabelRow}>
                    <Text style={styles.groupLabel}>{g.label}</Text>
                  </View>
                  {g.ids.map(id => (
                    <NavItem key={id} id={id} label={labelFor(id)} active={active === id} onPress={() => onPress(id)} />
                  ))}
                </View>
              ))}
            </>
          );
        })()}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  sidebar: {
    width: 240,
    backgroundColor: CATALOG_COLOR.surface,
    borderRightWidth: 1,
    borderRightColor: CATALOG_COLOR.borderHairline,
    // Sticky on web so the sidebar stays put while the main column scrolls. RN's ViewStyle type has
    // no equivalent for these two (there's no native "sticky" or viewport-unit height), so they need
    // an escape hatch — kept as narrow, explicitly-typed casts rather than `as any` on the property so
    // a typo here (e.g. "stickey") would still be caught, even though the final assignment can't be.
    position: 'sticky' as unknown as ViewStyle['position'],
    top: 0,
    height: '100vh' as unknown as ViewStyle['height'],
    overflow: 'hidden',
  },
  // Bounded, non-sticky top region — full width, a fixed max height (its own ScrollView still
  // scrolls the nav list within that), and a bottom hairline instead of the desktop's right border,
  // matching its new position above the main column rather than beside it.
  sidebarNarrow: {
    width: '100%',
    position: 'relative',
    top: undefined,
    height: 'auto' as unknown as ViewStyle['height'],
    maxHeight: 260,
    borderRightWidth: 0,
    borderBottomWidth: 1,
    borderBottomColor: CATALOG_COLOR.borderHairline,
  },
  scroll: { flex: 1 },
  content: { paddingHorizontal: CATALOG_SPACE.lg, paddingTop: 28, paddingBottom: CATALOG_SPACE['3xl'] },
  logo: { fontSize: CATALOG_TYPE.lg, fontWeight: '700', color: CATALOG_COLOR.text },
  subtitle: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, marginTop: 2, marginBottom: 20 },
  empty: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, paddingHorizontal: 10, paddingVertical: CATALOG_SPACE.sm },
  groupLabelRow: {
    marginTop: CATALOG_SPACE.lg, marginBottom: CATALOG_SPACE.xs,
    paddingHorizontal: 10,
  },
  groupLabel: {
    fontSize: CATALOG_TYPE.xs, fontWeight: '800', textTransform: 'uppercase', letterSpacing: 0.7,
    color: CATALOG_COLOR.text,
  },
  item: { borderRadius: CATALOG_RADIUS.sm, marginBottom: 2 },
  itemPressed: { backgroundColor: CATALOG_COLOR.surfacePressed },
  // Non-color active cue: a subtle background tint plus a left-edge indicator bar (via a wide,
  // offset-left border, since RN has no standalone "outline on one side only" primitive) — visible
  // even in grayscale, on top of `labelActive`'s own bold weight below. Color (the accent text) is
  // still there too, but no longer the only signal that a link is the active one.
  itemActive: {
    backgroundColor: CATALOG_COLOR.surfacePressed,
    borderLeftWidth: 3,
    borderLeftColor: CATALOG_COLOR.accent,
  },
  label: { fontSize: CATALOG_TYPE.sm, color: CATALOG_COLOR.textMuted, paddingVertical: 6, paddingHorizontal: 10 },
  labelActive: { color: CATALOG_COLOR.accent, fontWeight: '700' },
});
