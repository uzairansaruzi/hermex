/**
 * CatalogExample — a full worked example of the reusable catalog framework, wired to THIS
 * template's own generic component set.
 *
 * This is the file a developer copies into their Expo app to browse the design system: it builds a
 * `SectionDef[]` (one entry per component or token group, its real prop table, and either a
 * `variants` list — one item per variant/state, laid out by SectionBlock itself — or a freeform
 * `render()` for content that isn't a simple list, e.g. token galleries) plus a `NavGroup[]` (how
 * those sections bucket in the sidebar), then hands both to a single `<CatalogShell />`, which owns
 * all the layout, scrolling, filtering, and scroll-spy.
 *
 * Everything the catalog documents comes from `../components`; every token value it renders as data
 * comes from `../../tokens`. The framework itself (CatalogShell, SectionBlock, PropsTable, …) knows
 * nothing about any of these components — swap the sections below for your own and it just works.
 *
 * Content rules for every `variants`/`states` list here — see the full versions on `SectionDef` in
 * `./types.ts`: `variants` always includes the prop's default value as its own instance; `states`
 * never leaves a real visually-distinct prop undemonstrated, and shows both sides of a toggle
 * (icon-only vs. icon+text, disabled vs. enabled, …) rather than assuming the reader will
 * cross-reference `variants` for the other half.
 */
import React, { useEffect, useRef, useState } from 'react';
import { View, Text, StyleSheet, ScrollView } from 'react-native';

import {
  AnimatedChevron,
  Avatar,
  Badge,
  Banner,
  BottomSheet,
  Button,
  ButtonGroup,
  Card,
  Checkbox,
  Dialog,
  Divider,
  Dock,
  Dropdown,
  EmptyState,
  FieldContainer,
  InputClearButton,
  InputField,
  List,
  ListItem,
  Loading,
  Pill,
  PillRow,
  type PillRowItem,
  ProgressDots,
  Radio,
  SearchField,
  SectionHeader,
  SegmentedToggle,
  Shimmer,
  SkeletonGroup,
  Surface,
  Switch,
  TextArea,
  Toast,
  Tooltip,
  TopNav,
  UnderlineTabs,
} from '../components';
import {
  DS_PALETTE,
  colorValueLabel,
  DS_RADIUS,
  DS_RADIUS_STEPS,
  DS_RADIUS_USE,
  DS_SEMANTIC,
  DS_SHADOW,
  DS_SHADOW_USE,
  DS_SPACING,
  DS_SPACING_STEPS,
  DS_SPACING_USE,
  DS_ICON_SIZE,
  DS_ICON_SIZE_STEPS,
  DS_FONT_WEIGHT,
  DS_FONT_WEIGHT_USE,
  DS_MOTION_DURATION,
  DS_MOTION_DURATION_STEPS,
  DS_MOTION_DURATION_USE,
  DS_MOTION_EASING,
  DS_MOTION_EASING_STEPS,
  DS_MOTION_EASING_USE,
  DS_MOTION_SPRING,
  DS_MOTION_SPRING_USE,
  DS_MOTION_LOOP_DURATION,
  DS_MOTION_LOOP_DURATION_STEPS,
  DS_MOTION_LOOP_DURATION_USE,
  DS_TYPOGRAPHY,
  DS_TYPOGRAPHY_USE,
  type TypographyToken,
  type FontWeightName,
  type ShadowToken,
  type PaletteName,
} from '../../tokens';
import { Icon } from '../../icons/Icon.native';
import { ICON_PATHS, type IconName } from '../../icons';

import { CatalogShell } from './CatalogShell';
import { VariantGroup } from './VariantGroup';
import { DividedStack } from './DividedStack';
import { Swatch } from './Swatch';
import { TokenRow } from './TokenRow';
import { PhoneFrame } from './PhoneFrame';
import { SpacingScaleGallery } from './SpacingScaleGallery';
import { TypeScaleGallery } from './TypeScaleGallery';
import { buildComponentManifest } from './manifest';
import type { NavGroup, SectionDef } from './types';

// Layout chrome for the live examples. Uses the real DS spacing scale for gaps; the components being
// documented bring their own token-driven styling. Defined up top (not near its call sites further
// down) because `sections`' `variants` arrays are plain data, evaluated eagerly at module load —
// unlike the old `render: () => ...` closures, a `demo.xyz` reference inside a `variants` entry runs
// before a `const demo` declared later in the file would exist yet (a real TDZ crash, not just style).
const demo = StyleSheet.create({
  // Colors — used to wrap Swatch rows. SpacingScaleGallery/TypeScaleGallery (framework building
  // blocks) own the rest of the token-gallery chrome now; this file only supplies the token data.
  row: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: DS_SPACING[600] },
  // A dark backdrop for the one variant example (Button's `white`) that's otherwise invisible on
  // this catalog's own white card — see the `white` variant's own comment at its call site.
  darkBackdrop: {
    backgroundColor: DS_SEMANTIC.text.regular,
    borderRadius: DS_RADIUS.medium,
    padding: DS_SPACING[400],
    alignItems: 'center',
  },
  cardTitle: { ...DS_TYPOGRAPHY.labelMd, color: DS_SEMANTIC.text.regular },
  cardBody: { ...DS_TYPOGRAPHY.bodySm, color: DS_SEMANTIC.text.muted, marginTop: DS_SPACING[200] },
  shimmerLines: { flex: 1, gap: DS_SPACING[400] },
  // BottomSheet/Dropdown demos render inside the shared `PhoneFrame` (./PhoneFrame.tsx) so their
  // absolute overlays stay contained instead of covering the whole catalog page. No padding here —
  // BottomSheet's own content area already supplies the standard 16px.
  sheetContent: {},
  // Dropdown demo — fills PhoneFrame edge-to-edge (`flex:1` + `alignSelf:'stretch'` override
  // PhoneFrame's own `alignItems/justifyContent:'center'`, which centers-and-shrinks BottomSheetDemo's
  // trigger button just fine but would otherwise leave this wrapper short and centered too). Dropdown's
  // own BottomSheet is a sibling of its trigger in the same tree position, so its absolute overlay
  // fills *this* box — it needs to be the full frame, not a small box hugging just the trigger.
  dropdownFrameContent: { flex: 1, alignSelf: 'stretch', padding: DS_SPACING[800] },
  dividerDemo: { width: '100%', gap: DS_SPACING[400] },
  // Trip planner recipe — fills PhoneFrame edge-to-edge the same way dropdownFrameContent does.
  recipeFrameContent: { flex: 1, alignSelf: 'stretch', padding: DS_SPACING[800] },
  recipeFields: { gap: DS_SPACING[600] },
  recipeDivider: { marginVertical: DS_SPACING[600] },
  recipeActions: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  // Saved trips recipe — fills PhoneFrame edge-to-edge (like dropdownFrameContent), with a
  // fixed TopNav header and Dock footer around a scrollable middle, the same fixed-header/
  // scrollable-body/fixed-footer shape a real screen would use.
  savedTripsScreen: { flex: 1, alignSelf: 'stretch' },
  // A fixed cap (not `flex: 1`) — sidesteps a web-only flexbox quirk where a `flex: 1` ScrollView
  // nested inside PhoneFrame's own fixed height doesn't actually shrink to the space left after
  // TopNav/Dock, and grows PhoneFrame itself past its intended 480px instead of scrolling.
  savedTripsScroll: { maxHeight: 320 },
  savedTripsScrollContent: { padding: DS_SPACING[800], gap: DS_SPACING[600] },
  // Shared by SavedTrips' small inline rows — the "Updating arrival times…" loading row and each
  // list row's trailing badge+button cluster (identical layout, one key).
  savedTripsInlineRow: { flexDirection: 'row', alignItems: 'center', gap: DS_SPACING[300] },
  savedTripsLoadingText: { ...DS_TYPOGRAPHY.bodyXs, color: DS_SEMANTIC.text.muted },
  // Floats over the top of the screen — same top/left/right inset Toast's own catalog demo uses —
  // instead of sitting inline in the flex flow and pushing the Dock down. A column with a small
  // gap, since back-to-back removals stack one toast per removal (newest on top).
  savedTripsToastOverlay: { position: 'absolute', top: DS_SPACING[800], left: DS_SPACING[600], right: DS_SPACING[600], zIndex: 20, gap: DS_SPACING[300] },
  // Map mode's stand-in — a real map isn't in scope for this recipe, just enough to show the
  // SegmentedToggle actually switches the screen's content, not just its own thumb.
  savedTripsMapPlaceholder: { alignItems: 'center', justifyContent: 'center', gap: DS_SPACING[400], paddingVertical: DS_SPACING[2400] },
  savedTripsMapPlaceholderText: { ...DS_TYPOGRAPHY.bodySm, color: DS_SEMANTIC.text.muted },
  // Report-an-issue recipe — the BottomSheet's own scrollable content area, so no separate
  // ScrollView is needed here the way savedTripsScroll needs one (BottomSheet already scrolls its
  // `children` past a height cap).
  reportContent: { gap: DS_SPACING[600] },
  reportSwitchRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  // External field label for controls that have no label prop of their own (PillRow) — controls
  // that DO own a label (Dropdown, InputField) use theirs instead of this.
  recipeFieldLabel: { ...DS_TYPOGRAPHY.labelXs, color: DS_SEMANTIC.text.muted, marginBottom: DS_SPACING[200] },
  // FieldContainer — a stand-in "field" body, since the real component only supplies the chrome.
  fieldContainerDemo: { height: 56, justifyContent: 'center', paddingHorizontal: DS_SPACING[800] },
  fieldContainerText: { ...DS_TYPOGRAPHY.bodyMd, color: DS_SEMANTIC.text.muted },
  radioGroup: { gap: DS_SPACING[600], alignItems: 'flex-start' },
  dialogActions: { marginTop: DS_SPACING[800] },
  // Toast demo — floats the toast near the top of the PhoneFrame, the same way a real screen would
  // position it (Toast itself renders no absolute overlay; that's always the call site's job).
  toastDemoOverlay: { position: 'absolute', top: DS_SPACING[800], left: DS_SPACING[600], right: DS_SPACING[600] },
  // Tooltip demos — the bubble is an absolutely-positioned overlay above/below the trigger, sized
  // relative to the trigger's own tiny box, not this box. A fixed-height box with the trigger
  // centred inside gives the bubble equal clearance whichever direction it points, so stacked items
  // (States/Configurations renders 5 of these one after another) don't crowd or overlap each other.
  tooltipDemoBox: { height: 80, alignItems: 'center', justifyContent: 'center' },
  // Radius/Shadow/Motion galleries — one row per token: a name, a rendered preview, a value.
  // `previewRow` doubles as the generic centered row for other demos with the same shape (Shimmer).
  tokenStack: { gap: DS_SPACING[800] },
  previewRow: { flexDirection: 'row', alignItems: 'center', gap: DS_SPACING[600] },
  previewLabel: { minWidth: 64, ...DS_TYPOGRAPHY.labelSm, color: DS_SEMANTIC.text.regular },
  previewValue: { ...DS_TYPOGRAPHY.bodyXs, color: DS_SEMANTIC.text.muted },
  // Font page — the "is a typeface actually set" fact needs to read at a glance, not be buried in
  // the explanatory paragraph below it.
  typefaceStatus: { ...DS_TYPOGRAPHY.labelSm, color: DS_SEMANTIC.text.regular },
  typefaceNote: { marginTop: DS_SPACING[400] },
  radiusBox: { width: 40, height: 40, backgroundColor: DS_SEMANTIC.emphasis.info, borderWidth: StyleSheet.hairlineWidth, borderColor: DS_SEMANTIC.border.light },
  shadowBox: { width: 56, height: 40, borderRadius: DS_RADIUS.medium, backgroundColor: DS_SEMANTIC.surface.white },
  durationBar: { height: 12, borderRadius: DS_RADIUS.small, backgroundColor: DS_SEMANTIC.emphasis.info },
  // Spring config — a wrapping grid of key/value fields, since DS_MOTION_SPRING has 6 fields, too
  // many to lay out as a single previewRow.
  springGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: DS_SPACING[600] },
  springField: { width: 168, gap: DS_SPACING[100] },
  easingValue: { ...DS_TYPOGRAPHY.bodyXs, color: DS_SEMANTIC.text.muted, fontFamily: 'Menlo' },
  // Icons gallery — a size-comparison row, then a grid of every icon at a fixed size.
  iconSizeRow: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'flex-end', gap: DS_SPACING[1200] },
  iconSizeItem: { alignItems: 'center', gap: DS_SPACING[200] },
  iconSizeLabel: { ...DS_TYPOGRAPHY.bodyXs, color: DS_SEMANTIC.text.muted },
  iconGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: DS_SPACING[800] },
  iconGridItem: { width: 72, alignItems: 'center', gap: DS_SPACING[200] },
  iconGridLabel: { ...DS_TYPOGRAPHY.bodyXs, color: DS_SEMANTIC.text.muted, textAlign: 'center' },
  // Manifest — a scrollable, selectable code block; monospace so the JSON stays legible.
  manifestBox: { maxHeight: 480, overflow: 'hidden' },
  manifestText: { ...DS_TYPOGRAPHY.bodyXs, fontFamily: 'Menlo', color: DS_SEMANTIC.text.regular },
});

// ─── Section-id union ─────────────────────────────────────────────────────────
// One string literal per documented section. Threaded through CatalogShell/CatalogSidebar as `TId`
// so the sidebar nav + scroll-spy stay typed to this exact set.
export type SectionId =
  | 'Button'
  | 'ButtonGroup'
  | 'Pill'
  | 'PillRow'
  | 'Card'
  | 'Banner'
  | 'Badge'
  | 'InputField'
  | 'TextArea'
  | 'Dropdown'
  | 'SearchField'
  | 'Switch'
  | 'Checkbox'
  | 'Radio'
  | 'SegmentedToggle'
  | 'UnderlineTabs'
  | 'Toast'
  | 'Shimmer'
  | 'Loading'
  | 'ProgressDots'
  | 'TopNav'
  | 'Dock'
  | 'BottomSheet'
  | 'Tooltip'
  | 'Dialog'
  | 'Divider'
  | 'ListItem'
  | 'List'
  | 'EmptyState'
  | 'SectionHeader'
  | 'Avatar'
  | 'AnimatedChevron'
  | 'FieldContainer'
  | 'InputClearButton'
  | 'SkeletonGroup'
  | 'Colors'
  | 'Spacing'
  | 'Typography'
  | 'Font'
  | 'Motion'
  | 'Radius'
  | 'Shadow'
  | 'Icons'
  | 'Manifest'
  | 'TripPlannerForm'
  | 'SavedTrips'
  | 'ReportIssue';

// ─── Live interactive demos ────────────────────────────────────────────────────
// SectionDef.render() is a plain `() => ReactNode`, so any example that needs its own state lives in
// a small component here (hooks can't run inside a bare render callback).

function SegmentedToggleDemo() {
  const [value, setValue] = useState('map');
  return (
    <SegmentedToggle
      value={value}
      onChange={setValue}
      options={[
        { value: 'map', label: 'Map', iconName: 'map' },
        { value: 'list', label: 'List', iconName: 'menu' },
        { value: 'saved', label: 'Saved', iconName: 'bell', badge: 3 },
        // Label-only segment (no iconName) — the layout every other option's icon would otherwise hide.
        { value: 'settings', label: 'Settings' },
      ]}
    />
  );
}

function UnderlineTabsDemo() {
  const [value, setValue] = useState('all');
  return (
    <UnderlineTabs
      value={value}
      onChange={setValue}
      options={[
        { value: 'all', label: 'All' },
        // Leading-icon tab — the layout every other option (icon-less) would otherwise hide.
        { value: 'nearby', label: 'Nearby', iconName: 'pin' },
        { value: 'favorites', label: 'Favorites', badge: 2 },
      ]}
    />
  );
}

function InputFieldDemo() {
  const [value, setValue] = useState('');
  return (
    <InputField
      label="From"
      value={value}
      onChangeText={setValue}
      editable
      placeholder="Search a station"
    />
  );
}

function SearchFieldDemo() {
  const [value, setValue] = useState('');
  return <SearchField value={value} onChangeText={setValue} placeholder="Search stations" />;
}

// ─── Recipes ────────────────────────────────────────────────────────────────────
// Realistic, composed screens — several components working together the way a real app actually
// uses them, not one component in isolation. Rendered inside PhoneFrame so they read as an actual
// screen rather than a loose cluster of controls on the documentation page.

function TripPlannerFormDemo() {
  const [from, setFrom] = useState('Current location');
  const [to, setTo] = useState('');
  return (
    <PhoneFrame>
      <View style={demo.recipeFrameContent}>
        <Card>
          <View style={demo.recipeFields}>
            <InputField label="From" value={from} onChangeText={setFrom} editable />
            <InputField label="To" value={to} onChangeText={setTo} editable placeholder="Where to?" />
          </View>
          <Divider style={demo.recipeDivider} />
          <View style={demo.recipeActions}>
            <Button variant="tertiary" size="medium" label="Add stop" onPress={() => {}} />
            {/* trim() so a whitespace-only "destination" can't enable Continue. */}
            <Button variant="primary" size="medium" label="Continue" onPress={() => {}} disabled={!to.trim()} />
          </View>
        </Card>
      </View>
    </PhoneFrame>
  );
}

const SAVED_TRIPS_INITIAL = [
  { id: 'uptown', title: 'Uptown & The Bronx', subtitle: '4 min · Subway', iconName: 'subway' as const, badgeVariant: 'positive' as const, badgeLabel: 'On time' },
  { id: 'downtown', title: 'Downtown & Brooklyn', subtitle: '12 min · Train', iconName: 'train' as const, badgeVariant: 'warning' as const, badgeLabel: 'Delayed' },
  { id: 'airport', title: 'Airport Express', subtitle: '22 min · Train', iconName: 'train' as const, badgeVariant: 'neutral' as const, badgeLabel: 'Scheduled' },
];
const SAVED_TRIPS_SORT_OPTIONS = [
  { value: 'arrival', label: 'Arrival time' },
  { value: 'distance', label: 'Distance' },
  { value: 'name', label: 'Name' },
];
// How long the "Trip removed" toast stays up before auto-dismissing, same as a real snackbar —
// matches Toast's own doc comment ("expected to go away on its own or via its own action").
const SAVED_TRIPS_TOAST_MS = 3000;

function SavedTripsDemo() {
  const [tab, setTab] = useState('all');
  const [viewMode, setViewMode] = useState('list');
  const [query, setQuery] = useState('');
  const [sortBy, setSortBy] = useState('arrival');
  const [pills, setPills] = useState<PillRowItem[]>([
    { id: 'subway', label: 'Subway', variant: 'selected', iconName: 'subway' },
    { id: 'train', label: 'Train', variant: 'not_selected', iconName: 'train' },
    { id: 'ferry', label: 'Ferry', variant: 'not_selected', iconName: 'ferry' },
  ]);
  const [showFilterTip, setShowFilterTip] = useState(false);
  const [trips, setTrips] = useState(SAVED_TRIPS_INITIAL);
  // Toasts only appear right after a real action (removing a trip) and auto-dismiss — they never
  // sit statically in the initial render, since that's not what Toast is for. Each removal gets its
  // OWN stacked toast on its own 3s clock (newest on top), so removing a second trip while the
  // first toast is still up never cuts the first one short — the earlier single-toast version
  // reused one `visible` boolean, which couldn't restart its timer for a back-to-back removal.
  // `visible: false` plays Toast's own exit animation; the entry is dropped from the array only
  // after that animation has had time to run.
  const [toasts, setToasts] = useState<
    Array<{ key: number; trip: (typeof SAVED_TRIPS_INITIAL)[number]; visible: boolean }>
  >([]);
  const nextToastKey = useRef(0);
  const toastTimers = useRef<Array<ReturnType<typeof setTimeout>>>([]);
  // Timers are scheduled per-removal (in event handlers, not an effect), so unmount cleanup is one
  // sweep here rather than per-timer effect returns.
  useEffect(() => () => toastTimers.current.forEach(clearTimeout), []);

  const hideToast = (key: number) => {
    setToasts((prev) => prev.map((t) => (t.key === key ? { ...t, visible: false } : t)));
    // Drop the entry once Toast's exit animation (it exits at DS_MOTION_DURATION.fast) has played.
    toastTimers.current.push(
      setTimeout(() => setToasts((prev) => prev.filter((t) => t.key !== key)), DS_MOTION_DURATION.fast),
    );
  };
  const removeTrip = (id: string) => {
    const removed = trips.find((t) => t.id === id);
    if (!removed) return;
    setTrips((prev) => prev.filter((t) => t.id !== id));
    const key = nextToastKey.current++;
    setToasts((prev) => [{ key, trip: removed, visible: true }, ...prev]);
    toastTimers.current.push(setTimeout(() => hideToast(key), SAVED_TRIPS_TOAST_MS));
  };
  const undoRemove = (key: number, trip: (typeof SAVED_TRIPS_INITIAL)[number]) => {
    setTrips((prev) => [...prev, trip]);
    hideToast(key);
  };

  return (
    <PhoneFrame>
      <View style={demo.savedTripsScreen}>
        <TopNav
          title="Saved trips"
          trailing={
            <Tooltip visible={showFilterTip} label="Filter by mode" placement="bottom" align="right">
              <Button
                variant="secondary"
                size="small"
                showIcon
                showLabel={false}
                iconName="menu"
                accessibilityLabel="Filters"
                onPress={() => setShowFilterTip((v) => !v)}
              />
            </Tooltip>
          }
        />
        <Surface tone="muted">
          <ScrollView style={demo.savedTripsScroll} contentContainerStyle={demo.savedTripsScrollContent}>
            <SearchField value={query} onChangeText={setQuery} placeholder="Search stations" />
            <SegmentedToggle
              value={viewMode}
              onChange={setViewMode}
              options={[
                { value: 'list', label: 'List', iconName: 'menu' },
                { value: 'map', label: 'Map', iconName: 'map' },
              ]}
            />
            {viewMode === 'map' ? (
              <View style={demo.savedTripsMapPlaceholder}>
                <Icon name="map" size={DS_ICON_SIZE.xl} color={DS_SEMANTIC.text.muted} />
                <Text style={demo.savedTripsMapPlaceholderText}>Map view</Text>
              </View>
            ) : (
              <>
                <UnderlineTabs
                  value={tab}
                  onChange={setTab}
                  options={[
                    { value: 'all', label: 'All' },
                    { value: 'nearby', label: 'Nearby' },
                    { value: 'favorites', label: 'Favorites' },
                  ]}
                />
                {tab === 'favorites' ? (
                  <EmptyState
                    iconName="waypoints"
                    title="No favorites yet"
                    description="Star a trip to see it here."
                    action={{ label: 'Browse trips', onPress: () => setTab('all') }}
                    secondaryAction={{ label: 'Not now', onPress: () => {} }}
                  />
                ) : (
                  <>
                    <PillRow
                      pills={pills.map((p) => ({ ...p, onPress: () => setPills((prev) => prev.map((x) => ({ ...x, variant: x.id === p.id ? 'selected' : 'not_selected' }))) }))}
                      showAddPill={false}
                    />
                    <View style={demo.savedTripsInlineRow}>
                      <Loading size={14} />
                      <Text style={demo.savedTripsLoadingText}>Updating arrival times…</Text>
                    </View>
                    {/* Dropdown's own `label` prop, not a hand-rolled Text above it — the component
                        already owns the labeled-field pattern (PillRow, which has no label prop, is
                        the case where an external label is legitimately the only option). */}
                    <Dropdown label="Sort by" value={sortBy} onChange={setSortBy} options={SAVED_TRIPS_SORT_OPTIONS} />
                    <SectionHeader title="Nearby stations" />
                    {trips.length > 0 ? (
                      <List>
                        {trips.map((trip) => (
                          <ListItem
                            key={trip.id}
                            title={trip.title}
                            subtitle={trip.subtitle}
                            leading={<Avatar iconName={trip.iconName} size={40} />}
                            trailing={
                              <View style={demo.savedTripsInlineRow}>
                                <Badge variant={trip.badgeVariant} label={trip.badgeLabel} />
                                <Button
                                  variant="ghost"
                                  size="small"
                                  showIcon
                                  showLabel={false}
                                  iconName="clear"
                                  accessibilityLabel={`Remove ${trip.title}`}
                                  onPress={() => removeTrip(trip.id)}
                                />
                              </View>
                            }
                          />
                        ))}
                      </List>
                    ) : (
                      <EmptyState
                        iconName="waypoints"
                        title="No nearby trips"
                        description="Removed trips you save will show up here again."
                      />
                    )}
                  </>
                )}
              </>
            )}
          </ScrollView>
        </Surface>
        {/* Absolutely positioned over the top of the screen (not inline in the flex flow — a real
            toast floats over content, it doesn't push the Dock down) — same placement Toast's own
            catalog demo uses. One Toast per pending removal, stacked newest-on-top; each entry
            stays in the array (with `visible: false`) through its own exit animation instead of
            being yanked out of the tree mid-motion. */}
        <View style={demo.savedTripsToastOverlay} pointerEvents="box-none">
          {toasts.map((t) => (
            <Toast
              key={t.key}
              visible={t.visible}
              message={`${t.trip.title} removed`}
              action={{ label: 'Undo', onPress: () => undoRemove(t.key, t.trip) }}
            />
          ))}
        </View>
        <Dock>
          <Button label="Plan a new trip" onPress={() => {}} />
        </Dock>
      </View>
    </PhoneFrame>
  );
}

// Report-issue recipe's line picker — a PillRow, not a Dropdown, specifically because this lives
// inside a BottomSheet: Dropdown opens its own BottomSheet, and stacking two sheets traps the user
// between backdrops (see BottomSheet's `useInsideBottomSheetWarning`).
const REPORT_LINE_PILLS: PillRowItem[] = [
  { id: '4', label: '4 Train' },
  { id: '6', label: '6 Train' },
  { id: 'q', label: 'Q Train' },
];
// Issue-type category — a PillRow (not SegmentedToggle): this is a data choice being filled into
// the report, not a view/mode switch. SegmentedToggle is for "which mode is this screen in right
// now" (e.g. Map vs List); a form's own answer belongs on Pill/Radio instead.
const REPORT_ISSUE_TYPE_PILLS: PillRowItem[] = [
  { id: 'delay', label: 'Delay' },
  { id: 'crowding', label: 'Crowding' },
  { id: 'safety', label: 'Safety' },
];

function ReportIssueDemo() {
  const [visible, setVisible] = useState(false);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [issueType, setIssueType] = useState('delay');
  const [line, setLine] = useState('4');
  const [details, setDetails] = useState('');
  const [urgent, setUrgent] = useState(false);
  const [visibility, setVisibility] = useState('public');
  const [notify, setNotify] = useState(true);

  const requestClose = () => setConfirmDiscard(true);
  const discard = () => {
    setConfirmDiscard(false);
    setVisible(false);
  };

  return (
    <PhoneFrame>
      {!visible && <Button label="Report an issue" onPress={() => setVisible(true)} />}
      <BottomSheet
        visible={visible}
        onDismiss={requestClose}
        header={
          <TopNav
            title="Report an issue"
            trailing={
              <Button variant="secondary" size="small" showIcon showLabel={false} iconName="clear" accessibilityLabel="Close" onPress={requestClose} />
            }
          />
        }
        footer={
          <Dock>
            <Button label="Submit report" onPress={() => setVisible(false)} />
          </Dock>
        }
      >
        <View style={demo.reportContent}>
          <ProgressDots active={1} total={3} />
          <Banner
            variant="info"
            title="Delays reported near 14 St"
            description="Other riders flagged a signal problem in the last 10 minutes."
          />
          <View>
            <Text style={demo.recipeFieldLabel}>Issue type</Text>
            <PillRow
              pills={REPORT_ISSUE_TYPE_PILLS.map((p) => ({ ...p, variant: p.id === issueType ? 'selected' : 'not_selected', onPress: () => setIssueType(p.id) }))}
              showAddPill={false}
            />
          </View>
          <View>
            <Text style={demo.recipeFieldLabel}>Line</Text>
            <PillRow
              pills={REPORT_LINE_PILLS.map((p) => ({ ...p, variant: p.id === line ? 'selected' : 'not_selected', onPress: () => setLine(p.id) }))}
              showAddPill={false}
            />
          </View>
          <TextArea value={details} onChangeText={setDetails} placeholder="Describe what happened" />
          <Checkbox checked={urgent} onChange={setUrgent} label="This needs urgent attention" />
          <View style={demo.radioGroup}>
            <Radio selected={visibility === 'public'} onPress={() => setVisibility('public')} label="Share publicly" />
            <Radio selected={visibility === 'anonymous'} onPress={() => setVisibility('anonymous')} label="Report anonymously" />
          </View>
          <Switch value={notify} onValueChange={setNotify} label="Notify me when resolved" style={demo.reportSwitchRow} />
          <View>
            <Text style={demo.cardTitle}>Recent reports near you</Text>
            {/* Last line ~70% of the others' width — see ShimmerProps.variant's `'text'` doc.
                SkeletonGroup so the two lines announce as one "Loading" region, not two. */}
            <SkeletonGroup style={demo.shimmerLines}>
              <Shimmer variant="text" width={200} />
              <Shimmer variant="text" width={140} />
            </SkeletonGroup>
          </View>
        </View>
      </BottomSheet>
      <Dialog visible={confirmDiscard} onDismiss={() => setConfirmDiscard(false)}>
        <Text style={demo.cardTitle}>Discard this report?</Text>
        <Text style={demo.cardBody}>Your answers won't be saved.</Text>
        <View style={demo.dialogActions}>
          <ButtonGroup>
            <Button label="Keep editing" variant="tertiary" onPress={() => setConfirmDiscard(false)} />
            <Button label="Discard" onPress={discard} />
          </ButtonGroup>
        </View>
      </Dialog>
    </PhoneFrame>
  );
}

// Renders the live component manifest as selectable JSON text — built from `sections`/`nav`
// themselves (not hand-maintained), so it can never drift out of sync with the catalog above it.
function ManifestView() {
  const json = JSON.stringify(buildComponentManifest(sections, nav), null, 2);
  return (
    <View style={demo.manifestBox}>
      <Text selectable style={demo.manifestText}>
        {json}
      </Text>
    </View>
  );
}

function TextAreaDemo() {
  const [value, setValue] = useState('');
  return <TextArea value={value} onChangeText={setValue} placeholder="Describe the issue…" />;
}

const SAMPLE_DROPDOWN_OPTIONS = [
  { value: 'uptown', label: 'Uptown & The Bronx' },
  { value: 'downtown', label: 'Downtown & Brooklyn' },
  { value: 'crosstown', label: 'Crosstown' },
];

function DropdownDemo() {
  const [value, setValue] = useState('uptown');
  return (
    <PhoneFrame>
      <View style={demo.dropdownFrameContent}>
        <Dropdown
          label="Direction"
          value={value}
          onChange={setValue}
          placeholder="Choose a direction"
          options={SAMPLE_DROPDOWN_OPTIONS}
        />
      </View>
    </PhoneFrame>
  );
}

function BottomSheetDemo() {
  const [visible, setVisible] = useState(false);
  return (
    <PhoneFrame>
      {!visible && <Button label="Open sheet" onPress={() => setVisible(true)} />}
      <BottomSheet
        visible={visible}
        onDismiss={() => setVisible(false)}
        header={
          <TopNav
            title="Trip details"
            trailing={
              <Button
                variant="secondary"
                size="small"
                showIcon
                showLabel={false}
                iconName="clear"
                accessibilityLabel="Close"
                onPress={() => setVisible(false)}
              />
            }
          />
        }
        footer={
          <Dock>
            <Button label="Confirm" onPress={() => setVisible(false)} />
          </Dock>
        }
      >
        <View style={demo.sheetContent}>
          <Text style={demo.cardTitle}>Uptown & The Bronx</Text>
          <Text style={demo.cardBody}>Next train in 4 min · every 6–8 min.</Text>
          {/* Long enough to overflow the phone frame's fixed height — demonstrates the Dock footer's
              `elevated` shadow turning on automatically once this content area actually scrolls. */}
          <Text style={demo.cardBody}>Board at the front car for a faster transfer at Union Sq.</Text>
          <Text style={demo.cardBody}>
            This line runs express between 96 St and 168 St during rush hours, skipping local stops in
            between. Weekend service runs local along the full route, with some stations closed for
            planned maintenance.
          </Text>
          <Text style={demo.cardBody}>
            Elevators are available at 168 St, 137 St, and 125 St — check the map for accessible
            entrances before you travel.
          </Text>
        </View>
      </BottomSheet>
    </PhoneFrame>
  );
}

function SwitchDemo() {
  const [value, setValue] = useState(true);
  return <Switch value={value} onValueChange={setValue} accessibilityLabel="Notifications" />;
}

function SwitchLabelDemo() {
  const [value, setValue] = useState(true);
  return <Switch value={value} onValueChange={setValue} label="Notifications" />;
}

function CheckboxDemo() {
  const [checked, setChecked] = useState(true);
  return <Checkbox checked={checked} onChange={setChecked} label="Remember this trip" />;
}

function RadioGroupDemo() {
  const [value, setValue] = useState('uptown');
  return (
    <View style={demo.radioGroup}>
      <Radio selected={value === 'uptown'} onPress={() => setValue('uptown')} label="Uptown & The Bronx" />
      <Radio selected={value === 'downtown'} onPress={() => setValue('downtown')} label="Downtown & Brooklyn" />
    </View>
  );
}

function TooltipDemo() {
  const [visible, setVisible] = useState(true);
  return (
    <Tooltip visible={visible} label="Tap to add a stop">
      <Button
        variant="ghost"
        size="medium"
        showIcon
        showLabel={false}
        iconName="add"
        accessibilityLabel="Add stop"
        onPress={() => setVisible((v) => !v)}
      />
    </Tooltip>
  );
}

function DialogDemo() {
  const [visible, setVisible] = useState(false);
  return (
    <PhoneFrame>
      {!visible && <Button label="Open dialog" onPress={() => setVisible(true)} />}
      <Dialog visible={visible} onDismiss={() => setVisible(false)}>
        <Text style={demo.cardTitle}>Delete this trip?</Text>
        <Text style={demo.cardBody}>This can't be undone.</Text>
        <View style={demo.dialogActions}>
          <ButtonGroup>
            <Button label="Cancel" variant="tertiary" onPress={() => setVisible(false)} />
            <Button label="Delete" onPress={() => setVisible(false)} />
          </ButtonGroup>
        </View>
      </Dialog>
    </PhoneFrame>
  );
}

// Drives Toast's `visible` prop directly (rather than the usual mount/unmount-the-whole-component
// pattern) so this demo actually exercises the slide-in-from-top/fade animation, not just the two
// static end states.
function ToastDemo() {
  const [visible, setVisible] = useState(true);
  return (
    <PhoneFrame>
      <Button label={visible ? 'Hide toast' : 'Show toast'} onPress={() => setVisible((v) => !v)} />
      <View style={demo.toastDemoOverlay} pointerEvents="box-none">
        <Toast message="Trip saved" variant="success" visible={visible} />
      </View>
    </PhoneFrame>
  );
}

// ─── Token galleries ───────────────────────────────────────────────────────────
// Swatch/SpacingScaleGallery/TypeScaleGallery are framework building blocks (`./Swatch`,
// `./SpacingScaleGallery`, `./TypeScaleGallery`) — this file only supplies the token data they render.

const SEMANTIC_GROUPS: { name: string; desc: string; entries: [string, string][] }[] = [
  { name: 'Semantic · surface', desc: 'page and card backgrounds', entries: Object.entries(DS_SEMANTIC.surface) },
  { name: 'Semantic · text', desc: 'text colors', entries: Object.entries(DS_SEMANTIC.text) },
  { name: 'Semantic · border', desc: 'dividers and outlines', entries: Object.entries(DS_SEMANTIC.border) },
  // disabledOpacity is a number (0.38), not a color — called out separately below, not mixed into the swatch grid.
  { name: 'Semantic · interaction', desc: 'pressed/hover/focus overlays', entries: Object.entries(DS_SEMANTIC.interaction).filter(([name]) => name !== 'disabledOpacity') as [string, string][] },
  { name: 'Semantic · element', desc: 'dividers and backdrops', entries: Object.entries(DS_SEMANTIC.element) },
  { name: 'Semantic · emphasis', desc: 'saturated status accents', entries: Object.entries(DS_SEMANTIC.emphasis) },
  { name: 'Semantic · shade', desc: 'tinted status fills', entries: Object.entries(DS_SEMANTIC.shade) },
];

function ColorsGallery() {
  const paletteHues = Object.keys(DS_PALETTE) as PaletteName[];
  return (
    <DividedStack>
      {SEMANTIC_GROUPS.map((group) => (
        <VariantGroup key={group.name} name={group.name} desc={group.desc} align="left">
          <View style={demo.row}>
            {group.entries.map(([name, value]) => (
              // valueLabel resolves the hex back to its palette source (e.g. "green.700") when it
              // traces to one; rgba overlays (recessed, pressed, hover, …) have no palette equivalent,
              // so colorValueLabel falls back to showing the rgba string itself.
              <Swatch key={name} name={name} value={value} valueLabel={colorValueLabel(value)} width={100} />
            ))}
          </View>
        </VariantGroup>
      ))}
      <VariantGroup name="interaction.disabledOpacity" desc="not a color — opacity applied to a whole disabled tappable element" align="left">
        <Text style={demo.previewValue}>{DS_SEMANTIC.interaction.disabledOpacity}</Text>
      </VariantGroup>
      {paletteHues.map((hue) => (
        <VariantGroup key={hue} name={`Palette · ${hue}`} desc="raw ramp, 0 → 800" align="left">
          <View style={demo.row}>
            {Object.entries(DS_PALETTE[hue]).map(([step, value]) => (
              <Swatch key={step} name={`${hue}.${step}`} value={value} />
            ))}
          </View>
        </VariantGroup>
      ))}
    </DividedStack>
  );
}

function RadiusGallery() {
  return (
    <View style={demo.tokenStack}>
      {DS_RADIUS_STEPS.map((step, i) => (
        <TokenRow key={step} use={DS_RADIUS_USE[step]} last={i === DS_RADIUS_STEPS.length - 1}>
          <View style={demo.previewRow}>
            <Text style={demo.previewLabel}>{step}</Text>
            <View style={[demo.radiusBox, { borderRadius: DS_RADIUS[step] }]} />
            <Text style={demo.previewValue}>{DS_RADIUS[step]}px</Text>
          </View>
        </TokenRow>
      ))}
    </View>
  );
}

function ShadowGallery() {
  const steps = Object.keys(DS_SHADOW) as ShadowToken[];
  return (
    <View style={demo.tokenStack}>
      {steps.map((step, i) => (
        <TokenRow key={step} use={DS_SHADOW_USE[step]} last={i === steps.length - 1}>
          <View style={demo.previewRow}>
            <Text style={demo.previewLabel}>{step}</Text>
            <View style={[demo.shadowBox, DS_SHADOW[step]]} />
          </View>
        </TokenRow>
      ))}
    </View>
  );
}

function MotionGallery() {
  const maxDuration = Math.max(...Object.values(DS_MOTION_DURATION));
  const maxLoopDuration = Math.max(...Object.values(DS_MOTION_LOOP_DURATION));
  return (
    <DividedStack>
      <VariantGroup name="Duration" desc="one-shot transitions — reach for base (240ms) first" align="left">
        <View style={demo.tokenStack}>
          {DS_MOTION_DURATION_STEPS.map((step, i) => (
            <TokenRow key={step} use={DS_MOTION_DURATION_USE[step]} last={i === DS_MOTION_DURATION_STEPS.length - 1}>
              <View style={demo.previewRow}>
                <Text style={demo.previewLabel}>{step}</Text>
                <View style={[demo.durationBar, { width: (DS_MOTION_DURATION[step] / maxDuration) * 120 }]} />
                <Text style={demo.previewValue}>{DS_MOTION_DURATION[step]}ms</Text>
              </View>
            </TokenRow>
          ))}
        </View>
      </VariantGroup>
      <VariantGroup name="Loop duration" desc="continuous, indeterminate loops — a spinner or a shimmer pulse, not a one-shot transition" align="left">
        <View style={demo.tokenStack}>
          {DS_MOTION_LOOP_DURATION_STEPS.map((step, i) => (
            <TokenRow key={step} use={DS_MOTION_LOOP_DURATION_USE[step]} last={i === DS_MOTION_LOOP_DURATION_STEPS.length - 1}>
              <View style={demo.previewRow}>
                <Text style={demo.previewLabel}>{step}</Text>
                <View style={[demo.durationBar, { width: (DS_MOTION_LOOP_DURATION[step] / maxLoopDuration) * 120 }]} />
                <Text style={demo.previewValue}>{DS_MOTION_LOOP_DURATION[step]}ms</Text>
              </View>
            </TokenRow>
          ))}
        </View>
      </VariantGroup>
      <VariantGroup name="Easing" desc="cubic-bezier curves — convert with Easing.bezier(...DS_MOTION_EASING.x)" align="left">
        <View style={demo.tokenStack}>
          {DS_MOTION_EASING_STEPS.map((step, i) => (
            <TokenRow key={step} use={DS_MOTION_EASING_USE[step]} last={i === DS_MOTION_EASING_STEPS.length - 1}>
              <View style={demo.previewRow}>
                <Text style={demo.previewLabel}>{step}</Text>
                <Text style={demo.easingValue}>cubic-bezier({DS_MOTION_EASING[step].join(', ')})</Text>
              </View>
            </TokenRow>
          ))}
        </View>
      </VariantGroup>
      <VariantGroup name="Spring" desc="for Animated.spring(value, DS_MOTION_SPRING) — snap-point transitions, not fixed-duration timing">
        <View style={demo.tokenStack}>
          <TokenRow use={DS_MOTION_SPRING_USE} last>
            <View style={demo.springGrid}>
              {(Object.entries(DS_MOTION_SPRING) as [string, number | boolean][]).map(([key, value]) => (
                <View key={key} style={demo.springField}>
                  <Text style={demo.previewLabel}>{key}</Text>
                  <Text style={demo.previewValue}>{String(value)}</Text>
                </View>
              ))}
            </View>
          </TokenRow>
        </View>
      </VariantGroup>
    </DividedStack>
  );
}

function IconsGallery() {
  const names = Object.keys(ICON_PATHS) as IconName[];
  return (
    <DividedStack>
      <VariantGroup name="Sizes" desc="pair an icon with the text scale beside it" align="left">
        <View style={demo.iconSizeRow}>
          {DS_ICON_SIZE_STEPS.map((step) => (
            <View key={step} style={demo.iconSizeItem}>
              <Icon name="home" size={DS_ICON_SIZE[step]} />
              <Text style={demo.iconSizeLabel}>{step} · {DS_ICON_SIZE[step]}px</Text>
            </View>
          ))}
        </View>
      </VariantGroup>
      <VariantGroup name={`All icons (${names.length})`} desc="rendered at 24px" align="left">
        <View style={demo.iconGrid}>
          {names.map((name) => (
            <View key={name} style={demo.iconGridItem}>
              <Icon name={name} size={DS_ICON_SIZE.lg} />
              <Text style={demo.iconGridLabel} numberOfLines={1}>{name}</Text>
            </View>
          ))}
        </View>
      </VariantGroup>
    </DividedStack>
  );
}


// ─── Sections ──────────────────────────────────────────────────────────────────
// The ordered list of everything the catalog documents. `variants` lists one item per variant/state
// (SectionBlock lays them out); `render()` is the escape hatch for content that isn't a simple list
// (token galleries, live interactive demos). `props` mirrors each component's real interface; `a11y`
// states what the source actually does.
export const sections: SectionDef<SectionId>[] = [
  {
    id: 'Button',
    path: 'native/components/Button',
    description:
      'The primary tap target. Six visual weights, three sizes, optional leading/trailing icon, plus loading and icon-only modes.',
    whenToUse: 'An action — something happens on tap. For a tappable chip that just flips a persistent selected state, use Pill instead.',
    a11y: 'Renders a Pressable with accessibilityRole="button"; pass accessibilityLabel for icon-only buttons where the label is hidden.',
    props: [
      { name: 'label', type: 'string', desc: 'Button text.' },
      {
        name: 'variant',
        type: "'primary' | 'secondary' | 'tertiary' | 'white' | 'ghost' | 'destructive'",
        default: 'primary',
        desc: "Which action this is, not just a look: primary = the one main action here; secondary = worth considering, not primary; tertiary = fine if the user skips it; white = primary on a dark/photo bg; ghost = inline within word-heavy text, not a nav icon or standalone CTA; destructive = deletes or irreversibly changes something.",
      },
      { name: 'size', type: "'large' | 'medium' | 'small'", default: 'large', desc: 'Control size.' },
      { name: 'showIcon', type: 'boolean', desc: 'Show the icon named by iconName.' },
      { name: 'iconName', type: 'IconName', desc: 'Which icon to render.' },
      { name: 'iconPosition', type: "'leading' | 'trailing'", default: 'leading', desc: 'Which side of the label the icon sits on.' },
      { name: 'showLabel', type: 'boolean', default: 'true', desc: 'Hide the label (with showIcon) for an icon-only, square button.' },
      { name: 'onPress', type: '() => void', desc: 'Tap handler.' },
      { name: 'loading', type: 'boolean', desc: 'Swap the label for a spinner and disable presses — turn on right after this exact tap, for as long as the background task it started is still running.' },
      { name: 'disabled', type: 'boolean', desc: 'Non-interactive, dimmed.' },
      { name: 'fullWidth', type: 'boolean', desc: 'Stretch to fill the width — for the main CTA(s) at the bottom of a screen/modal/sheet. Leave off for a button placed within surrounding context (dynamic, content-hugging width).' },
    ],
    // Tagged with `props` (the reference example for the VariantExample→PropsTable cross-check —
    // see SectionBlock's checkCompleteness) — every item here renders at the default `size: 'large'`,
    // so that's tagged too even though no example passes it explicitly.
    variants: {
      items: [
        { key: 'primary', name: 'Primary', props: { variant: 'primary', size: 'large' }, node: <Button label="Primary" variant="primary" onPress={() => {}} /> },
        { key: 'secondary', name: 'Secondary', props: { variant: 'secondary', size: 'large' }, node: <Button label="Secondary" variant="secondary" onPress={() => {}} /> },
        { key: 'tertiary', name: 'Tertiary', props: { variant: 'tertiary', size: 'large' }, node: <Button label="Tertiary" variant="tertiary" onPress={() => {}} /> },
        {
          key: 'white',
          name: 'White',
          props: { variant: 'white', size: 'large' },
          // `white` is documented as "solid light (for dark/photo backgrounds)" — invisible on
          // this catalog's own white card, so it needs a dark backdrop to read as a real button.
          node: (
            <View style={demo.darkBackdrop}>
              <Button label="White" variant="white" onPress={() => {}} />
            </View>
          ),
        },
        { key: 'ghost', name: 'Ghost', props: { variant: 'ghost', size: 'large' }, node: <Button label="Ghost" variant="ghost" onPress={() => {}} /> },
        { key: 'destructive', name: 'Destructive', props: { variant: 'destructive', size: 'large' }, node: <Button label="Delete" variant="destructive" onPress={() => {}} /> },
      ],
    },
    states: {
      items: [
        { key: 'with-icon', name: 'With icon', props: { iconPosition: 'leading' }, node: <Button label="Add stop" showIcon iconName="add" onPress={() => {}} /> },
        {
          key: 'trailing-icon',
          name: 'Trailing icon',
          props: { iconPosition: 'trailing' },
          node: <Button label="Continue" showIcon iconName="chevron-right" iconPosition="trailing" onPress={() => {}} />,
        },
        { key: 'icon-only', name: 'Icon-only', node: <Button label="Add stop" showIcon showLabel={false} iconName="add" onPress={() => {}} /> },
        { key: 'loading', name: 'Loading', node: <Button label="Loading" loading onPress={() => {}} /> },
        { key: 'disabled', name: 'Disabled', node: <Button label="Disabled" disabled onPress={() => {}} /> },
        { key: 'full-width', name: 'Full width', fill: true, node: <Button label="Confirm trip" fullWidth onPress={() => {}} /> },
        // Closes a real gap the completeness check surfaced: `size` was never explicitly demonstrated
        // anywhere in this section (every other example renders at the implicit 'large' default).
        { key: 'medium', name: 'Medium size', props: { size: 'medium' }, node: <Button label="Add stop" size="medium" onPress={() => {}} /> },
        { key: 'small', name: 'Small size', props: { size: 'small' }, node: <Button label="Add stop" size="small" onPress={() => {}} /> },
      ],
    },
  },
  {
    id: 'Pill',
    path: 'native/components/Pill',
    description: 'A compact selectable chip — selected/unselected states with an optional leading icon.',
    whenToUse: "A selection toggle, not an action — tapping it flips a persistent selected state. If tapping it should instead make something happen, use Button.",
    a11y: 'Pressable with accessibilityLabel; an icon-only pill (showText={false}) needs an explicit accessibilityLabel so it is announced.',
    props: [
      { name: 'label', type: 'string', desc: 'Chip text.' },
      { name: 'variant', type: "'selected' | 'not_selected'", default: 'not_selected', desc: 'Selection state.' },
      { name: 'iconName', type: 'IconName', desc: 'Leading icon, tinted by selection.' },
      { name: 'showText', type: 'boolean', default: 'true', desc: 'Hide for an icon-only pill.' },
      { name: 'onPress', type: '() => void', desc: 'Tap handler.' },
    ],
    variants: {
      items: [
        { key: 'selected', name: 'Selected', props: { variant: 'selected' }, node: <Pill label="Home" variant="selected" iconName="home" onPress={() => {}} /> },
        { key: 'not-selected', name: 'Not selected', props: { variant: 'not_selected' }, node: <Pill label="Work" variant="not_selected" iconName="briefcase" onPress={() => {}} /> },
      ],
    },
    states: {
      items: [
        {
          key: 'icon-text',
          name: 'Icon + Text',
          node: <Pill label="Nearby" variant="not_selected" iconName="pin" onPress={() => {}} />,
        },
        {
          key: 'icon-only',
          name: 'Icon-only',
          node: <Pill label="Saved" variant="not_selected" iconName="bell" showText={false} onPress={() => {}} />,
        },
        {
          key: 'disabled',
          name: 'Disabled',
          node: <Pill label="Sold out" variant="not_selected" iconName="clock" disabled onPress={() => {}} />,
        },
        {
          key: 'loading',
          name: 'Loading',
          node: <Pill label="Saving" variant="not_selected" iconName="clock" loading onPress={() => {}} />,
        },
      ],
    },
  },
  {
    id: 'PillRow',
    path: 'native/components/PillRow',
    description: 'A horizontally-scrolling row of Pill chips, with an optional trailing icon-only add pill — keeps the selected pill scrolled into view automatically.',
    whenToUse: 'A scrollable row of selection chips (e.g. saved-place shortcuts) — for a fixed row of action buttons instead, use ButtonGroup.',
    a11y: 'The row itself carries no accessibility role; each Pill (including the add pill) keeps its own accessibilityLabel/role from the Pill component.',
    props: [
      { name: 'pills', type: 'PillRowItem[]', desc: "Pills to render — each is a Pill's own props plus an id. Defaults to a two-item Home/Work sample." },
      { name: 'showAddPill', type: 'boolean', default: 'true', desc: 'Icon-only add/edit pill at the end of the row.' },
      { name: 'minPillWidth', type: 'number', desc: "Floor for the content pills' width (px); excludes the icon-only add pill so it stays circular." },
      { name: 'onAddPress', type: '() => void', desc: 'Tap handler for the add pill.' },
      { name: 'addSelected', type: 'boolean', default: 'false', desc: 'Render the add pill in the selected state.' },
      { name: 'trailing', type: 'ReactNode', desc: 'Custom trailing content instead of the add pill.' },
    ],
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'few',
          name: 'Few pills',
          node: (
            <PillRow
              pills={[
                { id: 'home', label: 'Home', variant: 'selected', iconName: 'home' },
                { id: 'work', label: 'Work', variant: 'not_selected', iconName: 'briefcase' },
              ]}
            />
          ),
        },
        {
          key: 'many',
          name: 'Many pills (scrollable)',
          node: (
            <PillRow
              pills={[
                { id: 'home', label: 'Home', variant: 'not_selected', iconName: 'home' },
                { id: 'work', label: 'Work', variant: 'selected', iconName: 'briefcase' },
                { id: 'gym', label: 'Gym', variant: 'not_selected', iconName: 'map' },
                { id: 'saved', label: 'Saved', variant: 'not_selected', iconName: 'bell' },
                { id: 'nearby', label: 'Nearby', variant: 'not_selected', iconName: 'pin' },
                { id: 'recent', label: 'Recent', variant: 'not_selected', iconName: 'clock' },
              ]}
            />
          ),
        },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'no-add',
          name: 'No add pill',
          props: { showAddPill: false },
          node: (
            <PillRow
              showAddPill={false}
              pills={[
                { id: 'home', label: 'Home', variant: 'selected', iconName: 'home' },
                { id: 'work', label: 'Work', variant: 'not_selected', iconName: 'briefcase' },
              ]}
            />
          ),
        },
        {
          key: 'add-selected',
          name: 'Add pill selected',
          props: { addSelected: true },
          node: (
            <PillRow
              addSelected
              pills={[
                { id: 'home', label: 'Home', variant: 'not_selected', iconName: 'home' },
                { id: 'work', label: 'Work', variant: 'not_selected', iconName: 'briefcase' },
              ]}
            />
          ),
        },
        {
          key: 'min-width',
          name: 'Minimum pill width',
          props: { minPillWidth: 96 },
          node: (
            <PillRow
              minPillWidth={96}
              pills={[
                { id: 'home', label: 'Home', variant: 'selected', iconName: 'home' },
                { id: 'work', label: 'Work', variant: 'not_selected', iconName: 'briefcase' },
              ]}
            />
          ),
        },
      ],
    },
  },
  {
    id: 'ButtonGroup',
    path: 'native/components/ButtonGroup',
    description: 'Groups Button elements in one of two layouts: horizontal (up to two, auto-width, trailing-aligned) or vertical (up to three, stretched full width — the same layout Dock\'s own button area uses). Every button in a group should read as one family — the same variant tier (primary/secondary/tertiary/white, never ghost), the same size, and either all icon+label or all label-only, never a mix. Dev-console warns if two or more children disagree.',
    a11y: 'A plain View; each Button child carries its own accessibility role and label.',
    props: [
      { name: 'variant', type: "'horizontal' | 'vertical'", default: 'horizontal', desc: 'Which layout to use.' },
      { name: 'children', type: 'ReactNode', required: true, desc: 'Button elements. Horizontal holds up to two; vertical holds up to three. Extra children are dropped.' },
    ],
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'horizontal',
          name: 'Horizontal',
          props: { variant: 'horizontal' },
          node: (
            <ButtonGroup variant="horizontal">
              <Button label="Cancel" variant="tertiary" onPress={() => {}} />
              <Button label="Confirm" onPress={() => {}} />
            </ButtonGroup>
          ),
        },
        {
          key: 'vertical',
          name: 'Vertical',
          props: { variant: 'vertical' },
          node: (
            <ButtonGroup variant="vertical">
              <Button label="Start trip" onPress={() => {}} />
              <Button label="Save for later" variant="secondary" onPress={() => {}} />
              <Button label="Share" variant="tertiary" onPress={() => {}} />
            </ButtonGroup>
          ),
        },
      ],
    },
  },
  {
    id: 'Card',
    path: 'native/components/Card',
    description: 'The primary content surface — a rounded white card with a soft resting shadow. Pass children, or onPress to make the whole card a button.',
    whenToUse: 'A standalone, self-contained unit with its own shadow. For a row in a homogeneous stack of peers (with dividers between them), use ListItem inside a List instead.',
    a11y: 'When onPress is set, renders a Pressable with accessibilityRole="button" and a visible focus ring; a plain card is a non-interactive View.',
    props: [
      { name: 'children', type: 'ReactNode', desc: 'Card content.' },
      { name: 'onPress', type: '() => void', desc: 'Makes the whole card a tappable button.' },
      { name: 'disabled', type: 'boolean', desc: 'Only valid on a pressable card.' },
    ],
    // No `variant` prop exists on Card, so its "Variants" column just shows the one default look;
    // `onPress`/`disabled` are interaction states, not style variants — those live under "States".
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'default',
          name: 'Default',
          node: (
            <Card>
              <Text style={demo.cardTitle}>Uptown & The Bronx</Text>
              <Text style={demo.cardBody}>Next train in 4 min · every 6–8 min</Text>
            </Card>
          ),
        },
      ],
    },
    // Repeats "Plain" here (not just in Variants) so States / Configurations reads as the full
    // interaction range — plain, pressable, disabled — on its own.
    states: {
      itemsFill: true,
      items: [
        {
          key: 'plain',
          name: 'Plain',
          node: (
            <Card>
              <Text style={demo.cardTitle}>Uptown & The Bronx</Text>
              <Text style={demo.cardBody}>Next train in 4 min · every 6–8 min</Text>
            </Card>
          ),
        },
        {
          key: 'pressable',
          name: 'Pressable',
          node: (
            <Card onPress={() => {}}>
              <Text style={demo.cardTitle}>Crosstown Bus M14</Text>
              <Text style={demo.cardBody}>Tap to view live arrivals</Text>
            </Card>
          ),
        },
        {
          key: 'disabled',
          name: 'Disabled',
          node: (
            <Card onPress={() => {}} disabled>
              <Text style={demo.cardTitle}>Franklin Ave Shuttle</Text>
              <Text style={demo.cardBody}>Temporarily unavailable</Text>
            </Card>
          ),
        },
      ],
    },
  },
  {
    id: 'Banner',
    path: 'native/components/Banner',
    description: 'An inline callout for status/announcements — five semantic variants, optional collapsible body, inline link, and action button.',
    whenToUse: "Persistent and in-flow, describing a standing condition about the screen's content. For a transient, self-contained event notification, use Toast instead.",
    a11y: 'When onPress/action is set the header/button are Pressables; the collapsible header toggles the description with a chevron affordance.',
    props: [
      { name: 'variant', type: "'neutral' | 'info' | 'positive' | 'warning' | 'negative'", default: 'neutral', desc: 'Semantic color scheme.' },
      { name: 'title', type: 'string', desc: 'Header text.' },
      { name: 'description', type: 'string', desc: 'Body text.' },
      { name: 'collapsible', type: 'boolean', desc: 'Header toggles the description open/closed.' },
      { name: 'onPress', type: '() => void', desc: 'Makes the whole callout tappable, with a pressed state.' },
      { name: 'action', type: '{ label; onPress }', desc: 'Button rendered below the description.' },
    ],
    variants: {
      itemsFill: true,
      items: [
        { key: 'neutral', name: 'Neutral', props: { variant: 'neutral' }, node: <Banner variant="neutral" title="Schedule notice" description="Holiday schedule in effect Monday." /> },
        { key: 'info', name: 'Info', props: { variant: 'info' }, node: <Banner variant="info" title="Weekend service change" description="The 6 runs express in both directions this weekend." /> },
        { key: 'positive', name: 'Positive', props: { variant: 'positive' }, node: <Banner variant="positive" title="Service restored" description="All lines are running on a normal schedule." /> },
        { key: 'warning', name: 'Warning', props: { variant: 'warning' }, node: <Banner variant="warning" title="Delays" description="Signal problems near 14 St." /> },
        { key: 'negative', name: 'Negative', props: { variant: 'negative' }, node: <Banner variant="negative" title="Line suspended" description="No service between 96 St and 137 St until further notice." /> },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'tappable',
          name: 'Tappable',
          node: (
            <Banner
              variant="neutral"
              title="Alert preferences"
              description="Tap to manage which alerts you receive."
              onPress={() => {}}
            />
          ),
        },
        {
          key: 'collapsible-expanded',
          name: 'Collapsible (expanded)',
          node: (
            <Banner
              variant="neutral"
              title="Trip details"
              description="Board at the front car for a faster transfer at Union Sq."
              collapsible
            />
          ),
        },
        {
          key: 'collapsible-collapsed',
          name: 'Collapsible (collapsed)',
          node: (
            <Banner
              variant="neutral"
              title="Trip details"
              description="Board at the front car for a faster transfer at Union Sq."
              collapsible
              defaultExpanded={false}
            />
          ),
        },
        {
          key: 'action',
          name: 'With action',
          node: (
            <Banner
              variant="info"
              title="App update available"
              description="Version 4.2 adds live bus tracking."
              action={{ label: 'Update', onPress: () => {} }}
            />
          ),
        },
        {
          key: 'link',
          name: 'With link',
          node: (
            <Banner
              variant="neutral"
              title="Fare increase"
              description="New fares start March 1."
              link={{ label: 'Learn more', onPress: () => {} }}
            />
          ),
        },
      ],
    },
  },
  {
    id: 'Badge',
    path: 'native/components/Badge',
    description: 'A small status chip — five semantic variants, with optional leading/trailing icons or icon-only.',
    whenToUse: "Read-only and inline, not tappable — for one row's data point. For a tappable chip with a selected state, use Pill; for a message about the whole screen, use Toast or Banner.",
    a11y: 'A plain View with text; the label carries the meaning, so avoid encoding status by color alone.',
    props: [
      { name: 'variant', type: "'neutral' | 'info' | 'positive' | 'warning' | 'negative'", default: 'neutral', desc: 'Semantic color scheme.' },
      { name: 'label', type: 'string', desc: 'Chip text; omit (with an icon) for icon-only.' },
      { name: 'leadingIcon', type: 'IconName', desc: 'Icon before the label.' },
      { name: 'trailingIcon', type: 'IconName', desc: 'Icon after the label.' },
      { name: 'accessibilityLabel', type: 'string', desc: 'Accessible name — required for an icon-only badge (no label).' },
    ],
    variants: {
      items: [
        { key: 'neutral', name: 'Neutral', props: { variant: 'neutral' }, node: <Badge variant="neutral" label="Local" /> },
        { key: 'info', name: 'Info', props: { variant: 'info' }, node: <Badge variant="info" label="Notice" leadingIcon="info-circle" /> },
        { key: 'positive', name: 'Positive', props: { variant: 'positive' }, node: <Badge variant="positive" label="On time" leadingIcon="circle-check" /> },
        { key: 'warning', name: 'Warning', props: { variant: 'warning' }, node: <Badge variant="warning" label="Delayed" leadingIcon="triangle-alert" /> },
        { key: 'negative', name: 'Negative', props: { variant: 'negative' }, node: <Badge variant="negative" label="Suspended" leadingIcon="circle-slash" /> },
      ],
    },
    states: {
      items: [
        {
          key: 'leading-icon',
          name: 'Leading icon',
          node: <Badge variant="positive" label="On time" leadingIcon="circle-check" />,
        },
        {
          key: 'trailing-icon',
          name: 'Trailing icon',
          node: <Badge variant="positive" label="On time" trailingIcon="circle-check" />,
        },
        {
          key: 'icon-only',
          name: 'Icon-only',
          node: <Badge variant="info" leadingIcon="info-circle" accessibilityLabel="Notice" />,
        },
      ],
    },
  },
  {
    id: 'Avatar',
    path: 'native/components/Avatar',
    description: 'A circular image, or an initials fallback on a solid fill when there\'s no image (or it fails to load).',
    a11y: 'Renders with accessibilityRole="image"; pass accessibilityLabel for a meaningful name, otherwise it falls back to the initials text.',
    props: [
      { name: 'imageUrl', type: 'string', desc: 'Remote image URL. Takes precedence over iconName/initials; falls back to them when omitted or the image fails to load.' },
      { name: 'iconName', type: 'IconName', desc: 'Icon shown instead of initials — e.g. for a generic/anonymous avatar. Takes precedence over initials when there\'s no image.' },
      { name: 'initials', type: 'string', desc: 'Shown when there\'s no image or icon — the first 1-2 characters are used, uppercased.' },
      { name: 'size', type: 'number', default: '40', desc: 'Diameter in px.' },
      { name: 'backgroundColor', type: 'string', desc: 'Fill colour behind the icon/initials. Defaults to a neutral emphasis colour.' },
    ],
    // No `variant` prop exists on Avatar — its "Variants" column shows the three real content modes
    // (image, icon, initials fallback), in the same precedence order the component itself resolves
    // them; size/colour variety lives under "States".
    variants: {
      items: [
        { key: 'image', name: 'Image', node: <Avatar imageUrl="https://i.pravatar.cc/100" accessibilityLabel="Jordan Lee" /> },
        { key: 'icon', name: 'Icon', node: <Avatar iconName="users" accessibilityLabel="Guest" /> },
        { key: 'initials', name: 'Initials fallback', node: <Avatar initials="JL" accessibilityLabel="Jordan Lee" /> },
      ],
    },
    // `size` is a continuous number, not an enum — small/medium/large is an explicit, labeled sweep
    // across it. "Medium" is the same 40px default already used unsized in Variants above, but it
    // gets its own labeled instance here so States / Configurations reads as the full size range on
    // its own, without requiring the reader to notice an unlabeled default elsewhere.
    states: {
      items: [
        { key: 'small', name: 'Small', node: <Avatar initials="JL" size={24} /> },
        { key: 'medium', name: 'Medium (default)', node: <Avatar initials="JL" size={40} /> },
        { key: 'large', name: 'Large', node: <Avatar initials="JL" size={64} /> },
        { key: 'custom-color', name: 'Custom colour', node: <Avatar initials="AC" backgroundColor={DS_SEMANTIC.emphasis.info} /> },
      ],
    },
  },
  {
    id: 'InputField',
    path: 'native/components/InputField',
    description: 'A floating-label field. Resting: a centred, body-sized label with no border. Active (focused, or picker with active set) or filled: the label floats to a small top caption, row 2 shows the value/input, and a border fades in while active.',
    whenToUse: 'A named field with a fixed identity ("To", "Arrive by") across the interaction. For free-text search with no floating label, use SearchField; for one of a small known set of choices, use Dropdown.',
    a11y: 'The editable mode is a live TextInput; the picker mode is a Pressable row. Either mode shows a clear button while active (focused, or active for a picker) with a value set. Provide a meaningful label.',
    props: [
      { name: 'label', type: "'To' | 'From' | 'Walk time' | 'Arrive by' | 'Name' | 'icon'", default: 'To', desc: 'Leading label slot.' },
      { name: 'value', type: 'string', desc: 'Current value.' },
      { name: 'onChangeText', type: '(text: string) => void', desc: 'Editable-mode change handler.' },
      { name: 'editable', type: 'boolean', default: 'false', desc: 'Live TextInput vs. tappable picker.' },
      { name: 'placeholder', type: 'string', desc: 'Shown when empty.' },
      { name: 'valueIcon', type: 'IconName', desc: 'Trailing icon after the value; also tints the value text with the accent colour.' },
      { name: 'valueAccent', type: 'boolean', desc: 'Tint the value text with the accent colour. Overridden by valueIcon\'s tint when both are set.' },
      { name: 'active', type: 'boolean', default: 'false', desc: 'Force the floated label + border look — for a picker field whose external picker (e.g. a Dropdown\'s sheet) is open. Editable fields derive this from focus and ignore it.' },
      { name: 'optional', type: 'boolean', default: 'false', desc: 'Appends " (Optional)" to the resting label only — it drops off once the label floats.' },
      { name: 'disabled', type: 'boolean', desc: 'Grey background, dimmed label/value text, non-interactive.' },
    ],
    // `label` is an enum prop, but its other 5 values are just text-content variety at the same
    // fixed slot — only `icon` renders through a genuinely different path, so `Default` (the resting
    // look, label defaults to 'To') and `Icon label` are the two Variants; every other prop's
    // real visual effect (active, optional, value states, disabled) lives under "States" below.
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'default',
          name: 'Default',
          props: { label: 'To' },
          node: <InputField label="To" placeholder="Search a station" onPress={() => {}} />,
        },
        {
          key: 'icon-label',
          name: 'Icon label',
          props: { label: 'icon' },
          node: <InputField label="icon" labelIcon="flag" value="Custom stop" onPress={() => {}} />,
        },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        { key: 'editable', name: 'Editable', props: { label: 'From' }, node: <InputFieldDemo /> },
        {
          key: 'picker',
          name: 'Picker (filled)',
          node: <InputField label="To" value="Grand Central" placeholder="Search a station" onPress={() => {}} />,
        },
        {
          key: 'active',
          name: 'Active (external picker open)',
          node: <InputField label="To" value="Grand Central" placeholder="Search a station" active onPress={() => {}} />,
        },
        {
          key: 'optional',
          name: 'Optional label',
          props: { label: 'Name' },
          node: <InputField label="Name" placeholder="Nickname" optional onPress={() => {}} />,
        },
        {
          key: 'value-icon',
          name: 'Value with icon',
          props: { label: 'Walk time' },
          node: <InputField label="Walk time" value="8 min" valueIcon="footprints" />,
        },
        {
          key: 'value-accent',
          name: 'Accent value',
          props: { label: 'Arrive by' },
          node: <InputField label="Arrive by" value="9:12 AM" valueAccent />,
        },
        { key: 'disabled', name: 'Disabled', node: <InputField label="Arrive by" value="9:12 AM" disabled /> },
      ],
    },
  },
  {
    id: 'TextArea',
    path: 'native/components/TextArea',
    description: 'A multi-line input that grows with its content from a minimum height.',
    a11y: 'A multiline TextInput; pass accessibilityLabel via inputProps when there is no visible label beside it.',
    props: [
      { name: 'value', type: 'string', required: true, desc: 'Current text.' },
      { name: 'onChangeText', type: '(text: string) => void', required: true, desc: 'Change handler.' },
      { name: 'placeholder', type: 'string', desc: 'Shown when empty.' },
      { name: 'minHeight', type: 'number', default: '96', desc: 'Height before it grows with content.' },
    ],
    // No `variant` prop exists on TextArea — its "Variants" column just shows the one default look.
    variants: {
      itemsFill: true,
      items: [{ key: 'default', name: 'Default', node: <TextAreaDemo /> }],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'disabled',
          name: 'Disabled',
          node: <TextArea value="This report has already been submitted." onChangeText={() => {}} editable={false} />,
        },
      ],
    },
  },
  {
    id: 'Dropdown',
    path: 'native/components/Dropdown',
    description: 'A labelled field that opens a BottomSheet picker on tap — the "bottom sheet picker" interaction: tap the trigger, pick an option from the sheet, it closes.',
    whenToUse: 'The answer is one of a small, known set of choices — never free text. For free-text filtering, use SearchField; for a named field with a fixed identity, use InputField.',
    a11y: 'The trigger is a Pressable (via FieldContainer) with accessibilityRole="button". Options render as accessibilityRole="radio" inside a "radiogroup", with accessibilityState.checked reflecting the current selection.',
    props: [
      { name: 'label', type: 'string', desc: 'Field label shown above the value.' },
      { name: 'value', type: 'string', desc: 'Selected option\'s value.' },
      { name: 'placeholder', type: 'string', desc: 'Shown when no option is selected.' },
      { name: 'options', type: '{ value; label }[]', required: true, desc: 'The selectable options.' },
      { name: 'onChange', type: '(value: string) => void', required: true, desc: 'Called with the newly selected option\'s value.' },
      { name: 'disabled', type: 'boolean', desc: 'Non-interactive, dimmed; the picker won\'t open.' },
    ],
    // No `variant` prop exists on Dropdown — its "Variants" column shows the one interactive default
    // (tap it to see the real picker open/select/close cycle); the closed-trigger configurations
    // that don't need the sheet live under "States".
    variants: {
      itemsFill: true,
      items: [{ key: 'default', name: 'Default (tap to open)', node: <DropdownDemo /> }],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'placeholder',
          name: 'Placeholder',
          node: <Dropdown label="Direction" placeholder="Choose a direction" options={SAMPLE_DROPDOWN_OPTIONS} onChange={() => {}} />,
        },
        {
          key: 'no-label',
          name: 'No label',
          node: <Dropdown value="uptown" options={SAMPLE_DROPDOWN_OPTIONS} onChange={() => {}} />,
        },
        {
          key: 'disabled',
          name: 'Disabled',
          node: <Dropdown label="Direction" value="uptown" options={SAMPLE_DROPDOWN_OPTIONS} onChange={() => {}} disabled />,
        },
      ],
    },
  },
  {
    id: 'SearchField',
    path: 'native/components/SearchField',
    description: 'Single-line search input on the shared field chrome — leading search icon, a border that darkens on focus, and a clear button while active with text.',
    whenToUse: 'Free-text filtering/searching only — never a named field with a fixed value. For that, use InputField; for a small known set of choices, use Dropdown.',
    a11y: 'Forwards a ref to the underlying TextInput; all TextInputProps pass through, so pass accessibilityLabel/placeholder as needed.',
    props: [
      { name: 'value', type: 'string', desc: 'Controlled value.' },
      { name: 'defaultValue', type: 'string', desc: 'Initial value for uncontrolled use.' },
      { name: 'onChangeText', type: '(text: string) => void', desc: 'Change handler.' },
      { name: 'iconName', type: 'IconName', default: 'search', desc: 'Leading icon.' },
      { name: 'placeholder', type: 'string', desc: 'Shown when empty.' },
      { name: 'disabled', type: 'boolean', desc: 'Dimmed icon/text, muted fill, non-interactive.' },
      { name: 'containerStyle', type: 'StyleProp<ViewStyle>', desc: 'Extra layout applied to the field container.' },
    ],
    // No `variant` prop exists on SearchField — its "Variants" column shows the one interactive
    // default (type to see the clear button appear); filled/disabled looks live under "States".
    variants: {
      itemsFill: true,
      items: [{ key: 'default', name: 'Default (type to see clear button)', node: <SearchFieldDemo /> }],
    },
    states: {
      itemsFill: true,
      items: [
        { key: 'empty', name: 'Empty', node: <SearchField value="" onChangeText={() => {}} placeholder="Search stations" /> },
        { key: 'filled', name: 'With value', node: <SearchField value="Union Sq" onChangeText={() => {}} /> },
        { key: 'disabled', name: 'Disabled', node: <SearchField value="" onChangeText={() => {}} placeholder="Search stations" disabled /> },
      ],
    },
  },
  {
    id: 'Switch',
    path: 'native/components/Switch',
    description: 'A boolean on/off toggle. The thumb slides and the track crossfades colour, sharing SegmentedToggle/UnderlineTabs\' own slide-animation hook for a consistent motion feel.',
    whenToUse: 'A setting that takes effect immediately, no separate save step. For recording a fact a future action (like a form submit) will act on, use Checkbox; for one-of-many exclusive selection, use Radio.',
    a11y: 'Renders a Pressable with accessibilityRole="switch" and accessibilityState.checked — pass accessibilityLabel to say what it controls.',
    props: [
      { name: 'value', type: 'boolean', required: true, desc: 'Whether the switch is on.' },
      { name: 'onValueChange', type: '(value: boolean) => void', required: true, desc: 'Called with the new value on tap.' },
      { name: 'label', type: 'string', desc: 'Optional inline label before the track, at the same bodyMd size Checkbox/Radio use — tapping it toggles too.' },
      { name: 'disabled', type: 'boolean', desc: 'Non-interactive, dimmed.' },
      { name: 'accessibilityLabel', type: 'string', desc: 'Accessible name. Defaults to `label` — pass this separately only when they should differ (or there\'s no visible label).' },
    ],
    // No `variant` prop exists on Switch — its "Variants" column shows the one interactive default
    // (tap it to see both positions); off/on/disabled/label instances live under "States".
    variants: {
      items: [{ key: 'default', name: 'Default (tap to toggle)', node: <SwitchDemo /> }],
    },
    states: {
      items: [
        { key: 'off', name: 'Off', node: <Switch value={false} onValueChange={() => {}} accessibilityLabel="Notifications" /> },
        { key: 'on', name: 'On', node: <Switch value={true} onValueChange={() => {}} accessibilityLabel="Notifications" /> },
        { key: 'label', name: 'With label', props: { label: true }, node: <SwitchLabelDemo /> },
        { key: 'disabled', name: 'Disabled', node: <Switch value={true} onValueChange={() => {}} disabled accessibilityLabel="Notifications" /> },
      ],
    },
  },
  {
    id: 'Checkbox',
    path: 'native/components/Checkbox',
    description: 'A square selection control — the box fills with the accent colour and a checkmark when checked.',
    whenToUse: 'An independent on/off fact about this one item — any number can be checked at once. For a setting that takes effect immediately, use Switch; for one-of-many exclusive selection, use Radio.',
    a11y: 'Renders a Pressable with accessibilityRole="checkbox" and accessibilityState.checked; the optional label doubles as its accessibilityLabel.',
    props: [
      { name: 'checked', type: 'boolean', required: true, desc: 'Whether the box is checked.' },
      { name: 'onChange', type: '(checked: boolean) => void', required: true, desc: 'Called with the new value on tap.' },
      { name: 'label', type: 'string', desc: 'Optional inline label to the right of the box.' },
      { name: 'disabled', type: 'boolean', desc: 'Non-interactive, dimmed.' },
    ],
    variants: {
      items: [{ key: 'default', name: 'Default (tap to toggle)', node: <CheckboxDemo /> }],
    },
    states: {
      items: [
        { key: 'unchecked', name: 'Unchecked', node: <Checkbox checked={false} onChange={() => {}} label="Remember this trip" /> },
        { key: 'checked', name: 'Checked', node: <Checkbox checked={true} onChange={() => {}} label="Remember this trip" /> },
        { key: 'no-label', name: 'No label', node: <Checkbox checked={true} onChange={() => {}} /> },
        { key: 'disabled', name: 'Disabled', node: <Checkbox checked={true} onChange={() => {}} disabled label="Remember this trip" /> },
      ],
    },
  },
  {
    id: 'Radio',
    path: 'native/components/Radio',
    description: 'A single circular selection control — a filled dot appears in the ring when selected. A group of mutually-exclusive Radios is just multiple instances sharing one selected value in the consumer.',
    whenToUse: 'One selection from a mutually-exclusive set — checking one should un-check another. For an independent on/off fact, use Checkbox; for a setting that takes effect immediately, use Switch.',
    a11y: 'Renders a Pressable with accessibilityRole="radio" and accessibilityState.selected; the optional label doubles as its accessibilityLabel.',
    props: [
      { name: 'selected', type: 'boolean', required: true, desc: 'Whether this radio is the selected one.' },
      { name: 'onPress', type: '() => void', required: true, desc: 'Tap handler — select this option in the consumer\'s state.' },
      { name: 'label', type: 'string', desc: 'Optional inline label to the right of the circle.' },
      { name: 'disabled', type: 'boolean', desc: 'Non-interactive, dimmed.' },
    ],
    variants: {
      items: [{ key: 'default', name: 'Default (tap to select)', node: <RadioGroupDemo /> }],
    },
    states: {
      items: [
        { key: 'unselected', name: 'Unselected', node: <Radio selected={false} onPress={() => {}} label="Uptown & The Bronx" /> },
        { key: 'selected', name: 'Selected', node: <Radio selected={true} onPress={() => {}} label="Uptown & The Bronx" /> },
        { key: 'disabled', name: 'Disabled', node: <Radio selected={true} onPress={() => {}} disabled label="Uptown & The Bronx" /> },
      ],
    },
  },
  {
    id: 'SegmentedToggle',
    path: 'native/components/SegmentedToggle',
    description: 'A row of mutually-exclusive options on a recessed track, with a white thumb that slides to the selected segment. Two or more options.',
    whenToUse: 'A filled, heavier-weight control for a primary, prominent choice on the screen. For quieter secondary navigation, use UnderlineTabs.',
    a11y: 'The row is accessibilityRole="tablist"; each segment is a "tab" with accessibilityState.selected reflecting the current value.',
    props: [
      { name: 'options', type: '{ value; label; iconName?; badge? }[]', required: true, desc: 'The segments.' },
      { name: 'value', type: 'string', required: true, desc: 'The selected option value.' },
      { name: 'onChange', type: '(value: string) => void', required: true, desc: 'Selection handler.' },
    ],
    render: () => <SegmentedToggleDemo />,
  },
  {
    id: 'UnderlineTabs',
    path: 'native/components/UnderlineTabs',
    description: 'A quieter tab switcher — left-aligned labels over a hairline rule, with a sliding underline indicator. Same options/value/onChange API as SegmentedToggle.',
    whenToUse: "Quiet, secondary navigation within a screen that already has a clear primary focus. For a prominent, primary choice, use SegmentedToggle.",
    a11y: 'Each tab is a Pressable label; the underline is a visual indicator only, so selection is also conveyed by the active label weight.',
    props: [
      { name: 'options', type: '{ value; label; iconName?; badge? }[]', required: true, desc: 'The tabs.' },
      { name: 'value', type: 'string', required: true, desc: 'The selected option value.' },
      { name: 'onChange', type: '(value: string) => void', required: true, desc: 'Selection handler.' },
    ],
    render: () => <UnderlineTabsDemo />,
  },
  {
    id: 'Toast',
    path: 'native/components/Toast',
    description: 'A transient confirmation bar. Without a variant it renders the dark surface with inverse text; a variant shifts to a pastel status color.',
    whenToUse: "Transient and self-contained, floating over the screen, expected to go away on its own or via its own action. For a persistent, in-flow message about a standing condition, use Banner.",
    a11y: 'Rendered with accessibilityRole="alert" so screen readers announce it when it appears.',
    props: [
      { name: 'message', type: 'string', required: true, desc: 'Toast text.' },
      { name: 'visible', type: 'boolean', default: 'true', desc: 'Slides in from above (+ fades in) when set true, and reverses on the way out. Default true renders already in its resting position, unanimated — for call sites that mount/unmount Toast itself instead of toggling this.' },
      { name: 'variant', type: "'success' | 'informational' | 'warning' | 'negative' | 'neutral'", desc: 'Semantic color scheme.' },
      { name: 'iconName', type: 'IconName', desc: 'Override the variant/default icon.' },
      { name: 'action', type: '{ label; onPress }', desc: 'Optional trailing action — e.g. "Undo". Colour-matched to the toast\'s own text/icon colour, not a separate fixed accent.' },
    ],
    variants: {
      itemsFill: true,
      items: [
        { key: 'base', name: 'Base (no variant)', node: <Toast message="Changes saved" /> },
        { key: 'success', name: 'Success', props: { variant: 'success' }, node: <Toast message="Trip saved" variant="success" /> },
        { key: 'informational', name: 'Informational', props: { variant: 'informational' }, node: <Toast message="New app version available" variant="informational" /> },
        { key: 'warning', name: 'Warning', props: { variant: 'warning' }, node: <Toast message="Signal delays reported" variant="warning" /> },
        { key: 'negative', name: 'Negative', props: { variant: 'negative' }, node: <Toast message="Failed to save trip" variant="negative" /> },
        { key: 'neutral', name: 'Neutral', props: { variant: 'neutral' }, node: <Toast message="3 new updates" variant="neutral" /> },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'action',
          name: 'With action',
          node: <Toast message="Trip removed" action={{ label: 'Undo', onPress: () => {} }} />,
        },
        {
          key: 'visible-toggle',
          name: 'Slide-in animation (toggle)',
          node: <ToastDemo />,
        },
      ],
    },
  },
  {
    id: 'Shimmer',
    path: 'native/components/Shimmer',
    description: 'Loading placeholders that breathe while content loads. `text` stands in for one line of text (an element with 3 lines gets 3 stacked `text` Shimmers, not one tall one), `circle` is always for a circular element, and `container` covers everything else (Card, Banner, image, …) — sized to match the real element it replaces, not an arbitrary block. When several stand in for one element, wrap them in `SkeletonGroup`.',
    whenToUse: 'A composite skeleton (several Shimmers standing in for one element) → wrap them in SkeletonGroup so it announces "Loading" once, not once per block. A single lone Shimmer needs no wrapper — it announces on its own.',
    a11y: 'A standalone Shimmer is exposed as accessibilityRole="progressbar" + accessibilityLabel="Loading". Inside a SkeletonGroup, each block goes silent and the group carries one busy "Loading" announcement for the whole skeleton — so a screen reader says "Loading" once, not once per block.',
    props: [
      { name: 'variant', type: "'text' | 'container' | 'circle'", default: 'text', desc: 'Placeholder shape — one text line, a circular element, or everything else (sized to match).' },
      { name: 'width', type: 'number | `${number}%`', desc: 'Width (text/container).' },
      { name: 'height', type: 'number', desc: 'Height (text/container) — match the real element this stands in for.' },
      { name: 'size', type: 'number', default: '40', desc: 'Diameter for the circle variant.' },
    ],
    // One standalone example per `variant` enum value (`text` is the default, so it comes first),
    // plus the composed "Circle + text" usage — shown here too, not just under States, so Variants
    // reads as complete on its own.
    variants: {
      itemsFill: true,
      items: [
        { key: 'text', name: 'Text (one line)', props: { variant: 'text' }, node: <Shimmer variant="text" width={160} /> },
        { key: 'circle', name: 'Circle', props: { variant: 'circle' }, node: <Shimmer variant="circle" size={40} /> },
        {
          key: 'container',
          name: 'Container (matches Card)',
          props: { variant: 'container' },
          // Same radius Card itself renders at (DS_RADIUS.medium, via dimensionsForVariant) and a
          // plausible real Card content height — a container skeleton should reserve the same
          // layout space the real element will occupy, not an arbitrary block.
          node: <Shimmer variant="container" height={96} />,
        },
        {
          key: 'circle-and-text',
          name: 'Circle + text (2 lines)',
          // SkeletonGroup so the whole avatar+2-lines skeleton announces "Loading" once, not three
          // times (one per block) — it carries the caller's row layout itself.
          node: (
            <SkeletonGroup style={demo.previewRow}>
              <Shimmer variant="circle" size={40} />
              {/* Last line ~70% of the others' width — see ShimmerProps.variant's `'text'` doc. */}
              <View style={demo.shimmerLines}>
                <Shimmer variant="text" width={160} />
                <Shimmer variant="text" width={112} />
              </View>
            </SkeletonGroup>
          ),
        },
      ],
    },
    // Repeated here (not just in Variants) so States / Configurations is independently complete too.
    states: {
      itemsFill: true,
      items: [
        {
          key: 'circle-and-text',
          name: 'Circle + text (2 lines)',
          // SkeletonGroup so the whole avatar+2-lines skeleton announces "Loading" once, not three
          // times (one per block) — it carries the caller's row layout itself.
          node: (
            <SkeletonGroup style={demo.previewRow}>
              <Shimmer variant="circle" size={40} />
              {/* Last line ~70% of the others' width — see ShimmerProps.variant's `'text'` doc. */}
              <View style={demo.shimmerLines}>
                <Shimmer variant="text" width={160} />
                <Shimmer variant="text" width={112} />
              </View>
            </SkeletonGroup>
          ),
        },
        {
          key: 'three-lines',
          name: 'Three lines of text',
          node: (
            // Explicit px widths (not "100%") specifically so the last line's 70% ratio is a real,
            // checkable relationship to the other two, not two independent percentages. Wrapped in a
            // SkeletonGroup so all three lines announce as one "Loading" region.
            <SkeletonGroup style={demo.shimmerLines}>
              <Shimmer variant="text" width={200} />
              <Shimmer variant="text" width={200} />
              <Shimmer variant="text" width={140} />
            </SkeletonGroup>
          ),
        },
      ],
    },
  },
  {
    id: 'Loading',
    path: 'native/components/Loading',
    description: 'An indeterminate loader — the shape fills up, empties out, then fills again, seamlessly. Two variants: circle (used internally by Button and Pill for their own loading states) and linear.',
    a11y: 'Exposed to assistive tech as accessibilityRole="progressbar" with accessibilityLabel="Loading" — no extra wiring needed at the call site.',
    props: [
      { name: 'variant', type: "'circle' | 'linear'", default: 'circle', desc: 'Which shape to render.' },
      { name: 'size', type: 'number', default: '20', desc: 'Diameter in px — circle only.' },
      { name: 'width', type: "number | `${number}%`", default: "'100%'", desc: 'Track width — linear only.' },
      { name: 'height', type: 'number', default: '4', desc: 'Track/bar thickness — linear only.' },
      { name: 'color', type: 'string', desc: 'Stroke (circle) / fill (linear) colour. Defaults to the regular text colour.' },
      { name: 'trackColor', type: 'string', desc: 'Track (background) colour — linear only.' },
      { name: 'duration', type: 'number', default: '1200', desc: 'One fill→empty cycle duration in ms.' },
    ],
    // One example per `variant` enum value — `circle` is the default, so it comes first.
    variants: {
      itemsFill: true,
      items: [
        { key: 'circle', name: 'Circle', props: { variant: 'circle' }, node: <Loading variant="circle" /> },
        { key: 'linear', name: 'Linear', props: { variant: 'linear' }, node: <Loading variant="linear" /> },
      ],
    },
    // `size` (circle) and `height` (linear) are continuous numbers, not enums — small/medium/large
    // and thin/default/thick are explicit, labeled sweeps across each, rather than a single "bigger"
    // example. "Medium"/"Default" repeat the same 20px/4px values already used unsized in Variants
    // above, labeled here so States / Configurations reads as the full range on its own.
    states: {
      itemsFill: true,
      items: [
        { key: 'small-circle', name: 'Small circle', node: <Loading variant="circle" size={14} /> },
        { key: 'medium-circle', name: 'Medium circle (default)', node: <Loading variant="circle" size={20} /> },
        { key: 'large-circle', name: 'Large circle', node: <Loading variant="circle" size={40} /> },
        { key: 'thin-linear', name: 'Thin linear', node: <Loading variant="linear" height={2} /> },
        { key: 'default-linear', name: 'Default linear', node: <Loading variant="linear" height={4} /> },
        { key: 'thick-linear', name: 'Thick linear', node: <Loading variant="linear" height={8} /> },
        { key: 'accent', name: 'Accent colour', node: <Loading variant="circle" color={DS_SEMANTIC.emphasis.info} /> },
      ],
    },
  },
  {
    id: 'ProgressDots',
    path: 'native/components/ProgressDots',
    description: 'A row of dots for a stepped flow; the active dot widens into a pill.',
    a11y: 'Decorative progress indicator; convey the "step X of Y" position in text for screen readers.',
    props: [
      { name: 'active', type: 'number', required: true, desc: '0-based index of the current step.' },
      { name: 'total', type: 'number', default: '6', desc: 'Number of dots.' },
    ],
    // No `variant` prop exists on ProgressDots — its "Variants" column just shows the one default
    // look; `active`'s different positions are progress states, covered under "States".
    variants: {
      items: [{ key: 'default', name: 'Default', node: <ProgressDots active={1} total={4} /> }],
    },
    states: {
      items: [
        { key: 'first', name: 'First step', node: <ProgressDots active={0} total={4} /> },
        { key: 'middle', name: 'Middle step', node: <ProgressDots active={2} total={4} /> },
        { key: 'last', name: 'Last step', node: <ProgressDots active={3} total={4} /> },
      ],
    },
  },
  {
    id: 'TopNav',
    path: 'native/components/TopNav',
    description: 'A screen\'s top bar — fixed-width leading/trailing slots flanking a centered title (or custom center content). Slots reserve their layout space even when empty, so the title stays centered no matter which sides are populated.',
    a11y: 'The title renders with accessibilityRole="header". Slot content (typically icon-only Buttons) carries its own accessibilityLabel.',
    props: [
      { name: 'title', type: 'string', desc: 'Centered title text. Ignored when center is set.' },
      { name: 'center', type: 'ReactNode', desc: 'Custom content overriding the centered title.' },
      { name: 'leading', type: 'ReactNode', desc: 'Leading slot — typically a back/close icon Button.' },
      { name: 'trailing', type: 'ReactNode', desc: 'Trailing slot — typically an action icon Button.' },
    ],
    // No `variant` prop exists on TopNav — its "Variants" column just shows the one default look,
    // with both slots populated; the individual slot combinations live under "States".
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'default',
          name: 'Default',
          node: (
            <TopNav
              title="Trip planner"
              leading={<Button variant="secondary" size="small" showIcon showLabel={false} iconName="chevron-left" accessibilityLabel="Back" onPress={() => {}} />}
              trailing={<Button variant="secondary" size="small" showIcon showLabel={false} iconName="search" accessibilityLabel="Search" onPress={() => {}} />}
            />
          ),
        },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        { key: 'title-only', name: 'Title only', node: <TopNav title="Settings" /> },
        {
          key: 'leading-only',
          name: 'Leading only',
          node: (
            <TopNav
              title="Trip details"
              leading={<Button variant="secondary" size="small" showIcon showLabel={false} iconName="chevron-left" accessibilityLabel="Back" onPress={() => {}} />}
            />
          ),
        },
        {
          key: 'trailing-only',
          name: 'Trailing only',
          node: (
            <TopNav
              title="Saved trips"
              trailing={<Button variant="secondary" size="small" showIcon showLabel={false} iconName="add" accessibilityLabel="Add" onPress={() => {}} />}
            />
          ),
        },
        {
          key: 'custom-center',
          name: 'Custom center',
          node: (
            <TopNav
              leading={<Button variant="secondary" size="small" showIcon showLabel={false} iconName="clear" accessibilityLabel="Close" onPress={() => {}} />}
              center={<Text style={demo.cardTitle}>Custom center content</Text>}
            />
          ),
        },
      ],
    },
  },
  {
    id: 'Dock',
    path: 'native/components/Dock',
    description: 'Pinned to the bottom of the screen, above the home indicator — holds up to three full-width Buttons stacked vertically, with an optional small caption area above them.',
    a11y: 'A plain View; each Button child carries its own accessibility role and label.',
    props: [
      { name: 'children', type: 'ReactNode', required: true, desc: 'Up to three full-width Button elements, stacked vertically. Extra children are dropped.' },
      { name: 'caption', type: 'ReactNode', desc: 'Small text shown above the top button — e.g. a trip summary.' },
      { name: 'showCaption', type: 'boolean', default: 'true', desc: 'Hide the caption row without unmounting caption content.' },
      { name: 'elevated', type: 'boolean', default: 'false', desc: 'Shows the upward-cast shadow, separating the Dock from scrollable content above it. BottomSheet sets this automatically for a Dock footer; set it yourself elsewhere.' },
    ],
    // No `variant` prop exists on Dock — its "Variants" column just shows the one default look,
    // at its max button count; the caption/count variations live under "States".
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'default',
          name: 'Default',
          node: (
            <Dock caption="3 stops · 24 min total">
              <Button label="Start trip" onPress={() => {}} />
              <Button label="Save for later" variant="secondary" onPress={() => {}} />
              <Button label="Share" variant="tertiary" onPress={() => {}} />
            </Dock>
          ),
        },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'no-caption',
          name: 'No caption',
          node: (
            <Dock>
              <Button label="Confirm" onPress={() => {}} />
              <Button label="Cancel" variant="tertiary" onPress={() => {}} />
            </Dock>
          ),
        },
        {
          key: 'caption-hidden',
          name: 'Caption hidden',
          node: (
            <Dock caption="3 stops · 24 min total" showCaption={false}>
              <Button label="Start trip" onPress={() => {}} />
            </Dock>
          ),
        },
        {
          key: 'single-button',
          name: 'Single button',
          node: (
            <Dock>
              <Button label="Got it" onPress={() => {}} />
            </Dock>
          ),
        },
        {
          key: 'elevated',
          name: 'Elevated',
          node: (
            <Dock elevated caption="3 stops · 24 min total">
              <Button label="Start trip" onPress={() => {}} />
            </Dock>
          ),
        },
      ],
    },
  },
  {
    id: 'BottomSheet',
    path: 'native/components/BottomSheet',
    description: 'A sheet that slides up over a dismissible backdrop. Height is driven by its content (not fixed snap points) up to 90% of the available height, then the content area scrolls. Compose header with TopNav and footer with Dock.',
    whenToUse: 'For longer, browsable content, or anything that benefits from a TopNav/Dock header-footer structure. For a short, focused decision that interrupts the flow, use Dialog.',
    a11y: 'The backdrop is a Pressable with accessibilityRole="button" and accessibilityLabel="Dismiss"; header/content/footer carry their own accessibility (e.g. TopNav\'s title as accessibilityRole="header").',
    props: [
      { name: 'visible', type: 'boolean', required: true, desc: 'Whether the sheet (and its backdrop) are mounted and shown.' },
      { name: 'onDismiss', type: '() => void', required: true, desc: 'Called when the backdrop is tapped — the sheet doesn\'t close itself; the caller decides.' },
      { name: 'header', type: 'ReactNode', desc: 'Top area — typically a TopNav with a close/back action.' },
      { name: 'children', type: 'ReactNode', required: true, desc: 'Middle content area. Grows with its content up to 90% of the available height, then scrolls.' },
      { name: 'footer', type: 'ReactNode', desc: 'Bottom area — typically a Dock with the sheet\'s primary actions.' },
    ],
    render: () => <BottomSheetDemo />,
  },
  {
    id: 'Tooltip',
    path: 'native/components/Tooltip',
    description: 'A small floating label anchored above or below its wrapped trigger. Fully controlled — drive `visible` from the trigger\'s own onLongPress/onPressIn, since mobile has no hover.',
    a11y: 'The bubble is a plain, non-interactive View; the trigger you wrap it around carries its own accessibility.',
    props: [
      { name: 'visible', type: 'boolean', required: true, desc: 'Whether the bubble is shown.' },
      { name: 'label', type: 'string', required: true, desc: 'The tooltip text.' },
      { name: 'placement', type: "'top' | 'bottom'", default: 'top', desc: 'Which side of the trigger the bubble appears on.' },
      { name: 'align', type: "'left' | 'center' | 'right'", default: 'center', desc: "Preferred horizontal anchor — which edge of the trigger the bubble aligns to. Only a preference: the bubble is always clamped to stay on screen, and the arrow always points at the trigger's true center regardless." },
      { name: 'children', type: 'ReactNode', required: true, desc: 'The trigger content the bubble is anchored to.' },
    ],
    variants: {
      items: [
        {
          key: 'default',
          name: 'Default (tap to toggle)',
          props: { placement: 'top', align: 'center' },
          node: (
            <View style={demo.tooltipDemoBox}>
              <TooltipDemo />
            </View>
          ),
        },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'bottom',
          name: 'Placement: bottom',
          props: { placement: 'bottom' },
          node: (
            <View style={demo.tooltipDemoBox}>
              <Tooltip visible label="Tap to add a stop" placement="bottom">
                <Button variant="ghost" size="medium" showIcon showLabel={false} iconName="add" accessibilityLabel="Add stop" onPress={() => {}} />
              </Tooltip>
            </View>
          ),
        },
        {
          // The arrow always attaches to whichever bubble edge faces the trigger — so a
          // placement="bottom" bubble (sitting below the trigger) has its arrow on its own TOP
          // edge, not its bottom. Naming/labels below describe the arrow's actual visual corner on
          // the bubble, not the `placement` value, since that's what a reader looking at the
          // rendered example actually sees.
          key: 'top-left',
          name: 'Top-left arrow',
          props: { placement: 'bottom', align: 'left' },
          node: (
            <View style={demo.tooltipDemoBox}>
              <Tooltip visible label="Top left" placement="bottom" align="left">
                <Button variant="ghost" size="medium" showIcon showLabel={false} iconName="add" accessibilityLabel="Add stop" onPress={() => {}} />
              </Tooltip>
            </View>
          ),
        },
        {
          key: 'top-right',
          name: 'Top-right arrow',
          props: { placement: 'bottom', align: 'right' },
          node: (
            <View style={demo.tooltipDemoBox}>
              <Tooltip visible label="Top right" placement="bottom" align="right">
                <Button variant="ghost" size="medium" showIcon showLabel={false} iconName="add" accessibilityLabel="Add stop" onPress={() => {}} />
              </Tooltip>
            </View>
          ),
        },
        {
          key: 'bottom-left',
          name: 'Bottom-left arrow',
          props: { placement: 'top', align: 'left' },
          node: (
            <View style={demo.tooltipDemoBox}>
              <Tooltip visible label="Bottom left" placement="top" align="left">
                <Button variant="ghost" size="medium" showIcon showLabel={false} iconName="add" accessibilityLabel="Add stop" onPress={() => {}} />
              </Tooltip>
            </View>
          ),
        },
        {
          key: 'bottom-right',
          name: 'Bottom-right arrow',
          props: { placement: 'top', align: 'right' },
          node: (
            <View style={demo.tooltipDemoBox}>
              <Tooltip visible label="Bottom right" placement="top" align="right">
                <Button variant="ghost" size="medium" showIcon showLabel={false} iconName="add" accessibilityLabel="Add stop" onPress={() => {}} />
              </Tooltip>
            </View>
          ),
        },
      ],
    },
  },
  {
    id: 'Dialog',
    path: 'native/components/Dialog',
    description: 'A card centred on screen over a dismissible backdrop — fades and scales in, distinct from BottomSheet\'s bottom-anchored slide. Named Dialog (not Modal) to avoid shadowing React Native\'s own built-in Modal.',
    whenToUse: 'A short, focused decision that interrupts the flow (confirm/cancel, a single form). For anything longer, browsable, or that needs its own internal scrolling, use BottomSheet.',
    a11y: 'The backdrop is a Pressable with accessibilityRole="button" and accessibilityLabel="Dismiss"; content you pass as children carries its own accessibility.',
    props: [
      { name: 'visible', type: 'boolean', required: true, desc: 'Whether the dialog (and its backdrop) are mounted and shown.' },
      { name: 'onDismiss', type: '() => void', required: true, desc: 'Called when the backdrop is tapped — the dialog doesn\'t close itself; the caller decides.' },
      { name: 'children', type: 'ReactNode', required: true, desc: 'The dialog\'s content.' },
    ],
    render: () => <DialogDemo />,
  },
  {
    id: 'Divider',
    path: 'native/components/Divider',
    description: 'A 1px hairline separator at the divider token colour.',
    a11y: 'A plain, non-interactive View — purely decorative.',
    props: [],
    // No `variant` prop and no other real configuration exists on Divider — a single hairline is the
    // whole component, shown here between two lines of content to demonstrate real placement.
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'default',
          name: 'Default',
          node: (
            <View style={demo.dividerDemo}>
              <Text style={demo.cardBody}>Section one</Text>
              <Divider />
              <Text style={demo.cardBody}>Section two</Text>
            </View>
          ),
        },
      ],
    },
  },
  {
    id: 'ListItem',
    path: 'native/components/ListItem',
    description: 'A single row: optional leading/trailing slots flanking a title (+ optional subtitle/footer). Stack several inside a List for a settings screen, menu, or search-results list.',
    whenToUse: "A row in a set of visually-light peers sharing a List's own surface and dividers. For a standalone unit with its own shadow, use Card instead.",
    a11y: 'A tappable row (onPress set) renders as a Pressable with accessibilityRole="button" and an accessibilityLabel built from title + subtitle; a plain row is a non-interactive View.',
    props: [
      { name: 'title', type: 'string', required: true, desc: 'Primary text.' },
      { name: 'subtitle', type: 'string', desc: 'Small secondary line below the title.' },
      { name: 'footer', type: 'ReactNode', desc: 'A third block below subtitle — a plain string, or a Badge/Button/other node for anything richer.' },
      { name: 'leading', type: 'ReactNode', desc: 'Leading slot — typically an Avatar or Icon.' },
      { name: 'trailingText', type: 'string', desc: 'Compact right-aligned value shown before the trailing slot — e.g. a settings row\'s current value ahead of its chevron.' },
      { name: 'trailingSubtext', type: 'string', desc: 'A second, more muted right-aligned line below trailingText.' },
      { name: 'trailing', type: 'ReactNode', desc: 'Trailing slot — typically a chevron Icon, a Switch, a Button, or a value label.' },
      { name: 'onPress', type: '() => void', desc: 'Makes the whole row tappable.' },
      { name: 'disabled', type: 'boolean', desc: 'Non-interactive, dimmed.' },
    ],
    // No `variant` prop exists on ListItem — its "Variants" column shows the title-only default and
    // the title+subtitle look; slot/interaction configurations live under "States".
    variants: {
      itemsFill: true,
      items: [
        { key: 'default', name: 'Default', node: <ListItem title="Notifications" /> },
        { key: 'subtitle', name: 'With subtitle', node: <ListItem title="Notifications" subtitle="Delay and service alerts" /> },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'leading',
          name: 'With leading',
          node: <ListItem title="Jordan Lee" subtitle="Last trip: Uptown & The Bronx" leading={<Avatar initials="JL" size={32} />} />,
        },
        {
          key: 'trailing',
          name: 'With trailing',
          node: <ListItem title="Notifications" trailing={<Icon name="chevron-right" color={DS_SEMANTIC.text.muted} />} />,
        },
        {
          key: 'footer-text',
          name: 'With footer (text)',
          node: <ListItem title="Signal delay" subtitle="Reported near 14 St" footer="2 min ago" />,
        },
        {
          key: 'footer-badge',
          name: 'With footer (badge)',
          node: <ListItem title="Line suspended" subtitle="96 St and 137 St" footer={<Badge variant="negative" label="Service alert" />} />,
        },
        {
          key: 'footer-button',
          name: 'With footer (button)',
          node: <ListItem title="Trip request" subtitle="Jordan Lee wants to share a ride" footer={<Button label="Accept" size="small" onPress={() => {}} />} />,
        },
        {
          key: 'trailing-text',
          name: 'With trailing data',
          node: (
            <ListItem
              title="Language"
              trailingText="English"
              trailing={<Icon name="chevron-right" color={DS_SEMANTIC.text.muted} />}
              onPress={() => {}}
            />
          ),
        },
        {
          key: 'trailing-subtext',
          name: 'With trailing data (secondary)',
          node: <ListItem title="Storage used" trailingText="2.4 GB" trailingSubtext="of 5 GB" />,
        },
        {
          key: 'trailing-button',
          name: 'With trailing button',
          node: <ListItem title="Pending invite" subtitle="Sam Rivera" trailing={<Button label="Accept" size="small" onPress={() => {}} />} />,
        },
        {
          key: 'pressable',
          name: 'Pressable',
          node: (
            <ListItem
              title="Notifications"
              trailing={<Icon name="chevron-right" color={DS_SEMANTIC.text.muted} />}
              onPress={() => {}}
            />
          ),
        },
        { key: 'disabled', name: 'Disabled', node: <ListItem title="Notifications" onPress={() => {}} disabled /> },
      ],
    },
  },
  {
    id: 'List',
    path: 'native/components/List',
    description: 'Stacks ListItem rows on a rounded white surface, with a Divider automatically inserted between each consecutive pair — never after the last.',
    a11y: 'A plain View; each ListItem child carries its own accessibility.',
    props: [
      { name: 'children', type: 'ReactNode', required: true, desc: 'ListItem elements.' },
    ],
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'default',
          name: 'Default',
          node: (
            <List>
              <ListItem title="Notifications" trailing={<Icon name="chevron-right" color={DS_SEMANTIC.text.muted} />} onPress={() => {}} />
              <ListItem title="Jordan Lee" subtitle="Last trip: Uptown & The Bronx" leading={<Avatar initials="JL" size={32} />} onPress={() => {}} />
              <ListItem title="Delete account" onPress={() => {}} />
            </List>
          ),
        },
      ],
    },
  },
  {
    id: 'EmptyState',
    path: 'native/components/EmptyState',
    description: 'A centred placeholder for a screen or section with nothing to show yet — no results, no saved items, a first-run state.',
    whenToUse: "Fills the entire content area because there's nothing else to show. For a note that sits alongside other real content, use Banner instead.",
    a11y: 'A plain View with text; the action(s) render as real Buttons inside a ButtonGroup, which carry their own accessibility.',
    props: [
      { name: 'iconName', type: 'IconName', default: 'users', desc: "Icon shown above the title, on an Avatar circle — the same generic-person glyph Avatar's own icon fallback uses." },
      { name: 'backgroundColor', type: 'string', desc: "Override the avatar circle's fill — same prop, same meaning as Avatar's own backgroundColor. Defaults to Avatar's own default." },
      { name: 'title', type: 'string', required: true, desc: 'Primary message.' },
      { name: 'description', type: 'string', desc: "Supporting line below the title — what's empty, or what to do about it." },
      { name: 'action', type: '{ label; onPress }', desc: 'Primary action, rendered below the description as a small primary Button.' },
      { name: 'secondaryAction', type: '{ label; onPress }', desc: 'Optional second action, stacked below `action` as a small tertiary Button via ButtonGroup — only rendered when `action` is also set.' },
    ],
    // No `variant` prop exists on EmptyState — its "Variants" column shows the minimal default
    // (iconName omitted, so it falls back to the real default) — the description/action
    // configurations live under "States".
    variants: {
      itemsFill: true,
      items: [{ key: 'default', name: 'Default', node: <EmptyState title="No saved trips yet" /> }],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'description',
          name: 'With description',
          node: <EmptyState iconName="search" title="No results found" description="Try a different station or address." />,
        },
        {
          key: 'action',
          name: 'With action',
          node: (
            <EmptyState
              iconName="waypoints"
              title="No saved trips yet"
              description="Your saved trips will show up here."
              action={{ label: 'Start a trip', onPress: () => {} }}
            />
          ),
        },
        {
          key: 'secondary-action',
          name: 'With two actions',
          props: { secondaryAction: true },
          node: (
            <EmptyState
              iconName="waypoints"
              title="No saved trips yet"
              description="Your saved trips will show up here."
              action={{ label: 'Start a trip', onPress: () => {} }}
              secondaryAction={{ label: 'Not now', onPress: () => {} }}
            />
          ),
        },
        {
          key: 'custom-color',
          name: 'Custom avatar colour',
          node: (
            <EmptyState
              iconName="triangle-alert"
              title="Something went wrong"
              description="Check your connection and try again."
              backgroundColor={DS_SEMANTIC.emphasis.negative}
            />
          ),
        },
      ],
    },
  },
  {
    id: 'SectionHeader',
    path: 'native/components/SectionHeader',
    description: 'An uppercase muted section label with an optional inline icon and a right-aligned ghost button.',
    whenToUse: "A label above a group of related rows within a screen (e.g. above a List) — for the screen's own top bar, use TopNav.",
    a11y: 'Title renders as plain Text — no heading role. A tappable labelIcon (onPress set) becomes accessibilityRole="button" with accessibilityLabel falling back to the section\'s own title; a non-interactive labelIcon has no accessibility node of its own. The trailing button is a real Button, so it carries Button\'s own accessibility for free.',
    props: [
      { name: 'title', type: 'string', required: true, desc: 'Section label text.' },
      { name: 'labelIcon', type: '{ name; size?; onPress?; accessibilityLabel? }', desc: 'Icon shown right after the title. Pass onPress to make it tappable; omit for a static decoration.' },
      { name: 'trailingButtonLabel', type: 'string', desc: 'Label for a right-aligned ghost button.' },
      { name: 'trailingButtonIconName', type: 'IconName', desc: 'Icon on the trailing button.' },
      { name: 'trailingButtonIconPosition', type: "'leading' | 'trailing'", default: 'trailing', desc: 'Which side of the label the trailing button\'s icon sits on.' },
      { name: 'onTrailingButtonPress', type: '() => void', desc: 'Tap handler for the trailing button.' },
    ],
    variants: {
      itemsFill: true,
      items: [
        { key: 'title-only', name: 'Title only', node: <SectionHeader title="Nearby stations" /> },
        {
          key: 'with-icon',
          name: 'With icon',
          node: <SectionHeader title="Trip details" labelIcon={{ name: 'info-circle', accessibilityLabel: 'About trip details' }} />,
        },
        {
          key: 'with-button',
          name: 'With trailing button',
          node: <SectionHeader title="Saved places" trailingButtonLabel="See all" onTrailingButtonPress={() => {}} />,
        },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'tappable-icon',
          name: 'Tappable icon',
          node: (
            <SectionHeader
              title="Delays"
              labelIcon={{ name: 'info-circle', onPress: () => {}, accessibilityLabel: 'What causes delays' }}
            />
          ),
        },
        {
          key: 'icon-and-button',
          name: 'Icon + trailing button',
          // This instance demonstrates the 'trailing' (default) icon position — tagged so
          // checkCompleteness sees both enum values covered, not just the 'leading' one below.
          props: { trailingButtonIconPosition: 'trailing' },
          node: (
            <SectionHeader
              title="Alerts"
              labelIcon={{ name: 'bell' }}
              trailingButtonLabel="Manage"
              trailingButtonIconName="chevron-right"
              onTrailingButtonPress={() => {}}
            />
          ),
        },
        {
          key: 'leading-icon-position',
          name: 'Trailing button, leading icon',
          props: { trailingButtonIconPosition: 'leading' },
          node: (
            <SectionHeader
              title="Saved places"
              trailingButtonLabel="Add"
              trailingButtonIconName="add"
              trailingButtonIconPosition="leading"
              onTrailingButtonPress={() => {}}
            />
          ),
        },
      ],
    },
  },
  {
    id: 'Colors',
    path: 'tokens/palette.ts · tokens/semantic.ts',
    description: 'The color tokens the whole system is built from — saturated semantic accents and the raw grey ramp, each shown at its real value.',
    tokenGallery: true,
    render: () => <ColorsGallery />,
  },
  {
    id: 'Spacing',
    path: 'tokens/scales.ts',
    description: 'The spacing scale (token number ÷ 50 = px), each step with a grounded "when to use this" note from DS_SPACING_USE. Reference steps directly — DS_SPACING[800], never a raw 16 — the key union is typo-safe by itself.',
    tokenGallery: true,
    render: () => (
      <SpacingScaleGallery steps={DS_SPACING_STEPS} values={DS_SPACING} useNotes={DS_SPACING_USE} />
    ),
  },
  {
    id: 'Typography',
    path: 'tokens/typography.ts',
    description: 'The type scale, rendered at its real sizes with a grounded "when to use this" note from DS_TYPOGRAPHY_USE per token — label* are semibold UI labels, body* regular reading text, emphasis*/title/display headlines.',
    tokenGallery: true,
    render: () => (
      <TypeScaleGallery
        steps={Object.keys(DS_TYPOGRAPHY) as TypographyToken[]}
        sampleStyle={(name) => DS_TYPOGRAPHY[name]}
        meta={(name) => `${DS_TYPOGRAPHY[name].fontSize}/${DS_TYPOGRAPHY[name].fontWeight}`}
        useNotes={DS_TYPOGRAPHY_USE}
      />
    ),
  },
  {
    id: 'Font',
    path: 'tokens/typography.ts',
    description: 'The typeface in use, and the font-weight scale on its own — most components get their weight via a DS_TYPOGRAPHY token\'s embedded fontWeight rather than DS_FONT_WEIGHT directly.',
    tokenGallery: true,
    render: () => (
      <DividedStack>
        <VariantGroup name="Typeface" desc="which font family renders every token on this page" align="left">
          <View style={demo.previewRow}>
            <Text style={demo.previewLabel}>Font family</Text>
            <Text style={demo.typefaceStatus}>None set — falls back to the OS default</Text>
          </View>
          <Text style={[demo.previewValue, demo.typefaceNote]}>
            No custom typeface is loaded anywhere in this template — every DS_TYPOGRAPHY / DS_FONT_WEIGHT
            token renders in the OS default system font: San Francisco on iOS, Roboto on Android, the
            browser's system-ui stack on web (which is what you're seeing on this page right now). To
            use a custom font instead, load it (e.g. via expo-font's useFonts) and add a fontFamily
            field to each DS_TYPOGRAPHY token — none currently set one.
          </Text>
        </VariantGroup>
        <VariantGroup name="Weight" desc="DS_FONT_WEIGHT, in isolation" align="left">
          <TypeScaleGallery
            steps={Object.keys(DS_FONT_WEIGHT) as FontWeightName[]}
            sampleStyle={(name) => ({ fontSize: 16, fontWeight: DS_FONT_WEIGHT[name] })}
            meta={(name) => DS_FONT_WEIGHT[name]}
            useNotes={DS_FONT_WEIGHT_USE}
          />
        </VariantGroup>
      </DividedStack>
    ),
  },
  {
    id: 'Motion',
    path: 'tokens/motion.ts',
    description: 'Duration (one-shot transitions), loop duration (continuous, indeterminate loops like Loading/Shimmer), easing, and spring tokens for transitions/animations. Easings are cubic-bezier tuples, not Easing objects, so the token file stays free of any react-native import. The spring config is grounded in the metro-native app this template was extracted from, where the same values drive its BottomSheet\'s snap-point transitions.',
    tokenGallery: true,
    render: () => <MotionGallery />,
  },
  {
    id: 'Radius',
    path: 'tokens/scales.ts',
    description: 'The corner-radius scale, each step with a grounded "when to use this" note from DS_RADIUS_USE. Reference steps directly — DS_RADIUS.medium, never a raw 12 — the key union is typo-safe by itself.',
    tokenGallery: true,
    render: () => <RadiusGallery />,
  },
  {
    id: 'Shadow',
    path: 'tokens/shadow.ts',
    description: 'Elevation tokens as ready-to-spread React Native style objects (shadowColor/Offset/Opacity/Radius + Android elevation).',
    tokenGallery: true,
    render: () => <ShadowGallery />,
  },
  {
    id: 'Icons',
    path: 'icons/paths.ts',
    description: 'Every icon available to the Icon component, plus the DS_ICON_SIZE steps it can be rendered at — pair an icon\'s size with the text scale beside it.',
    tokenGallery: true,
    render: () => <IconsGallery />,
  },
  {
    id: 'AnimatedChevron',
    path: 'native/components/AnimatedChevron',
    description: 'A chevron that morphs between down (collapsed) and up (expanded) — flipping vertically in place instead of rotating through a sideways-pointing angle, and instead of swapping icons. The morph Banner\'s own collapsible header uses for its disclosure indicator. Not commonly used on its own; exported for building a custom disclosure/accordion toggle.',
    a11y: 'Purely decorative — no accessibility role of its own. Wrap it in an accessible parent (the way Banner\'s own header Pressable does) if the toggle needs to be announced.',
    props: [
      { name: 'expanded', type: 'boolean', required: true, desc: 'Points up when true, down when false.' },
      { name: 'size', type: 'number', default: '16', desc: 'Icon size in px.' },
      { name: 'color', type: 'string', desc: 'Icon color.' },
      { name: 'duration', type: 'number', default: '240', desc: 'Morph duration in ms.' },
    ],
    variants: {
      items: [
        { key: 'collapsed', name: 'Collapsed', props: { expanded: false }, node: <AnimatedChevron expanded={false} /> },
        { key: 'expanded', name: 'Expanded', props: { expanded: true }, node: <AnimatedChevron expanded={true} /> },
      ],
    },
    states: {
      items: [
        { key: 'size', name: 'Custom size', node: <AnimatedChevron expanded={false} size={28} /> },
        { key: 'color', name: 'Custom color', node: <AnimatedChevron expanded={true} color={DS_SEMANTIC.emphasis.info} /> },
      ],
    },
  },
  {
    id: 'FieldContainer',
    path: 'native/components/FieldContainer',
    description: 'The shared field chrome — white surface, medium radius, a 1px border that darkens on focus and mutes when disabled — behind InputField, TextArea, Dropdown, and SearchField, so all four share one visually-consistent field look instead of each re-implementing it.',
    a11y: 'Renders a plain View by default. Passing onPress (without disabled) makes it a Pressable with accessibilityRole="button" and the given accessibilityLabel — a consumer building a real editable field (InputField\'s editable mode) relies on its own inner TextInput for accessibility instead.',
    props: [
      { name: 'focused', type: 'boolean', default: 'false', desc: 'Border darkens to border.dark.' },
      { name: 'disabled', type: 'boolean', default: 'false', desc: 'Muted surface.main fill, non-interactive.' },
      { name: 'onPress', type: '() => void', desc: 'When set (and not disabled), the container is a Pressable with tap feedback.' },
      { name: 'pressed', type: 'boolean', default: 'false', desc: "Caller-driven pressed state — applies the pressed treatment without an onPress Pressable (e.g. an editable field driving this from its own TextInput's onPressIn/onPressOut)." },
      { name: 'accessibilityLabel', type: 'string', desc: 'Only used when onPress is set.' },
      { name: 'children', type: 'ReactNode', required: true, desc: 'The field\'s own layout, height, padding, and content.' },
    ],
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'resting',
          name: 'Resting',
          node: (
            <FieldContainer style={demo.fieldContainerDemo}>
              <Text style={demo.fieldContainerText}>Field content</Text>
            </FieldContainer>
          ),
        },
        {
          key: 'focused',
          name: 'Focused',
          props: { focused: true },
          node: (
            <FieldContainer focused style={demo.fieldContainerDemo}>
              <Text style={demo.fieldContainerText}>Field content</Text>
            </FieldContainer>
          ),
        },
        {
          key: 'disabled',
          name: 'Disabled',
          props: { disabled: true },
          node: (
            <FieldContainer disabled style={demo.fieldContainerDemo}>
              <Text style={demo.fieldContainerText}>Field content</Text>
            </FieldContainer>
          ),
        },
      ],
    },
    states: {
      itemsFill: true,
      items: [
        {
          key: 'pressed',
          name: 'Pressed (caller-driven)',
          props: { pressed: true },
          node: (
            <FieldContainer pressed style={demo.fieldContainerDemo}>
              <Text style={demo.fieldContainerText}>Field content</Text>
            </FieldContainer>
          ),
        },
        {
          key: 'pressable',
          name: 'Pressable (with onPress)',
          node: (
            <FieldContainer onPress={() => {}} accessibilityLabel="Field content" style={demo.fieldContainerDemo}>
              <Text style={demo.fieldContainerText}>Field content</Text>
            </FieldContainer>
          ),
        },
      ],
    },
  },
  {
    id: 'InputClearButton',
    path: 'native/components/InputClearButton',
    description: 'The clear (×) button InputField and SearchField both show once a field is active and holds a value — a filled circle-x icon sized to reach the 44pt touch target via hitSlop, not visual size.',
    a11y: 'A Pressable with accessibilityRole="button" and the given (or default "Clear field") accessibilityLabel; hitSlop of 10 on every side pads its 24×24 visual size out to the 44pt minimum.',
    props: [
      { name: 'onPress', type: '() => void', required: true, desc: 'Tap handler — typically clears the paired field and refocuses it.' },
      { name: 'accessibilityLabel', type: 'string', default: "'Clear field'", desc: 'Accessible name — InputField/SearchField pass a field-specific label (e.g. "Clear To").' },
    ],
    variants: {
      items: [{ key: 'default', name: 'Default', node: <InputClearButton onPress={() => {}} /> }],
    },
    states: {
      items: [
        { key: 'custom-label', name: 'Custom accessibility label', node: <InputClearButton onPress={() => {}} accessibilityLabel="Clear search" /> },
      ],
    },
  },
  {
    id: 'SkeletonGroup',
    path: 'native/components/Shimmer',
    description: 'An accessibility wrapper for a composite skeleton — several Shimmers standing in for one real element (e.g. a list row: an avatar + a two-line label). It announces the whole thing as one "Loading" region and silences the individual blocks, so a screen reader says "Loading" once instead of once per Shimmer. Adds no layout of its own — pass your own flexDirection/gap via style.',
    whenToUse: 'Wrap 2+ Shimmers that together stand in for one element. A single lone Shimmer already announces on its own and needs no wrapper.',
    a11y: 'Carries accessibilityRole="progressbar" + accessibilityLabel (default "Loading") + accessibilityState={{ busy: true }} for the whole region; provides a context that makes every descendant Shimmer drop its own announcement. Net effect: one "Loading" announcement per skeleton, not one per block.',
    props: [
      { name: 'label', type: 'string', default: "'Loading'", desc: 'Accessible name for the whole loading region.' },
      { name: 'style', type: 'StyleProp<ViewStyle>', desc: 'Layout for the group (flexDirection, gap, …) — it renders a plain View, so styles land where you\'d expect.' },
      { name: 'children', type: 'ReactNode', required: true, desc: 'The Shimmers making up the skeleton.' },
    ],
    // No visual variants/states — it's a transparent a11y wrapper. The one example shows the
    // composite it wraps; Props + Accessibility document its contract.
    hide: { states: true },
    variants: {
      itemsFill: true,
      items: [
        {
          key: 'composite',
          name: 'Wrapping a composite skeleton',
          node: (
            <SkeletonGroup style={demo.previewRow}>
              <Shimmer variant="circle" size={40} />
              <View style={demo.shimmerLines}>
                <Shimmer variant="text" width={160} />
                <Shimmer variant="text" width={112} />
              </View>
            </SkeletonGroup>
          ),
        },
      ],
    },
  },
  {
    id: 'TripPlannerForm',
    path: 'Card · InputField · Divider · Button',
    description: 'A composed real screen — not one component in isolation — showing how Card, InputField, Divider, and Button actually fit together: a From/To trip form with a secondary "Add stop" action and a primary "Continue" that\'s disabled until a destination is entered.',
    tokenGallery: true,
    fullWidthLabel: 'Preview',
    render: () => <TripPlannerFormDemo />,
  },
  {
    id: 'SavedTrips',
    path: 'TopNav · SearchField · UnderlineTabs · PillRow · SectionHeader · Dropdown · List · ListItem · Avatar · Badge · Loading · Toast · EmptyState · Tooltip · Dock',
    description: 'A composed real screen — a saved-trips list with a search bar, tab switcher, mode filter pills, a sort Dropdown, and a bottom action bar. Switch to the "Favorites" tab (or remove every row) to see the EmptyState alternative to the list; tap the header icon to see its Tooltip; tap a row\'s trailing × to see the Toast, which only appears after that real action and auto-dismisses (or Undo) — remove two rows back-to-back and each removal gets its own stacked toast on its own clock.',
    tokenGallery: true,
    fullWidthLabel: 'Preview',
    render: () => <SavedTripsDemo />,
  },
  {
    id: 'ReportIssue',
    path: 'BottomSheet · Banner · PillRow · TextArea · Checkbox · Radio · Switch · ProgressDots · Shimmer · Dialog',
    description: 'A composed real screen — a "report an issue" flow opened from a BottomSheet, combining a step indicator, a service-alert banner, a Pill-based issue-type and line picker (a data choice, not a view switch, so Pill rather than SegmentedToggle), free-text and toggle inputs, and a loading skeleton for recent reports. Dismissing with unsaved changes opens a confirmation Dialog.',
    tokenGallery: true,
    fullWidthLabel: 'Preview',
    render: () => <ReportIssueDemo />,
  },
  {
    id: 'Manifest',
    path: 'native/catalog/manifest.ts',
    description: 'Every component above, serialized to plain JSON — id, file path, description, props, accessibility notes, and every documented variant/state (name + tagged prop values, no JSX). Built live from this same catalog via buildComponentManifest(), so it can\'t drift out of sync. Meant for tooling, not humans: feed it to an LLM (or a lint script) as ground truth for which props/variants a component actually supports, instead of it guessing from source.',
    tokenGallery: true,
    render: () => <ManifestView />,
  },
];

// ─── Sidebar grouping ──────────────────────────────────────────────────────────
export const nav: NavGroup<SectionId>[] = [
  { label: 'Actions', ids: ['Button', 'ButtonGroup', 'Pill', 'PillRow'] },
  { label: 'Surfaces', ids: ['Card', 'Banner', 'Badge', 'Avatar'] },
  { label: 'Inputs', ids: ['InputField', 'TextArea', 'Dropdown', 'SearchField'] },
  { label: 'Controls', ids: ['Switch', 'Checkbox', 'Radio'] },
  { label: 'Selection', ids: ['SegmentedToggle', 'UnderlineTabs'] },
  { label: 'Feedback', ids: ['Toast', 'Shimmer', 'Loading', 'ProgressDots'] },
  { label: 'Navigation', ids: ['TopNav', 'Dock', 'BottomSheet'] },
  { label: 'Overlays', ids: ['Tooltip', 'Dialog'] },
  { label: 'Layout', ids: ['Divider', 'ListItem', 'List', 'EmptyState', 'SectionHeader'] },
  { label: 'Sub-Parts', ids: ['AnimatedChevron', 'FieldContainer', 'InputClearButton', 'SkeletonGroup'] },
  { label: 'Recipes', ids: ['TripPlannerForm', 'SavedTrips', 'ReportIssue'] },
  { label: 'Tokens', ids: ['Colors', 'Spacing', 'Typography', 'Font', 'Motion', 'Radius', 'Shadow', 'Icons'] },
  { label: 'Reference', ids: ['Manifest'] },
];

/**
 * The whole design-system catalog for this template, ready to drop into an Expo app (e.g. render it
 * from a dev-only route). CatalogShell owns layout, scrolling, filtering, and scroll-spy — this file
 * only supplies the data.
 */
export function CatalogExample() {
  return <CatalogShell appName="Native App DS Template" title="Component Catalog" groups={nav} sections={sections} />;
}
