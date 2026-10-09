import React, { useEffect, useMemo, useRef, useState } from 'react';
import { ScrollView, View, StyleSheet, type LayoutChangeEvent } from 'react-native';
import { DS_SPACING } from '../../../tokens';
import { Pill } from '../Pill';
import type { PillRowItem, PillRowProps } from './PillRow.types';

const GAP = DS_SPACING[600];

const DEFAULT_PILLS: NonNullable<PillRowProps['pills']> = [
  { id: 'home', label: 'Home', variant: 'selected', iconName: 'home' },
  { id: 'work', label: 'Work', variant: 'not_selected', iconName: 'briefcase' },
];

/**
 * A horizontally-scrolling row of Pills with an optional trailing icon-only add pill. Keeps the
 * selected pill scrolled into view, and resets to the start when the pill set genuinely changes.
 */
export function PillRow({
  pills: pillsProp,
  showAddPill = true,
  minPillWidth = 0,
  onAddPress,
  addSelected = false,
  style,
  trailing,
}: PillRowProps) {
  const pills = pillsProp ?? DEFAULT_PILLS;
  const idsKey = pills.map(p => p.id).join('|');

  const scrollRef = useRef<ScrollView>(null);
  const scrollXRef = useRef(0);
  // Laid-out position of each pill (x within the scroll content + width), kept for scroll-into-view.
  const posRef = useRef<Map<string, { x: number; width: number }>>(new Map());
  const [viewportW, setViewportW] = useState(0);

  const onPillLayout = (id: string, e: LayoutChangeEvent) => {
    const { x, width } = e.nativeEvent.layout;
    posRef.current.set(id, { x, width });
  };

  // A genuinely different set of pills (not just a selection change within the same set) forgets
  // wherever the row was scrolled to and starts back at the beginning — otherwise a stale scroll
  // offset or a stale cached position from the PREVIOUS pill set could carry over onto this one.
  useEffect(() => {
    posRef.current.clear();
    scrollRef.current?.scrollTo({ x: 0, animated: false });
  }, [idsKey]);

  // Keep the selected pill fully in view. The selected pill is the one with variant 'selected', or the
  // add pill (tracked under '__add__') when it's selected. Re-runs whenever the selection or the layout
  // changes; deferred a frame so positions are fresh after a layout change.
  const selectedId = useMemo(
    () => (addSelected ? '__add__' : pills.find(p => p.variant === 'selected')?.id),
    [addSelected, pills],
  );
  useEffect(() => {
    if (!selectedId || viewportW <= 0) return;
    const raf = requestAnimationFrame(() => {
      const pos = posRef.current.get(selectedId);
      if (!pos) return;
      const left = scrollXRef.current;
      const right = left + viewportW;
      if (pos.x < left) {
        scrollRef.current?.scrollTo({ x: Math.max(0, pos.x - GAP), animated: true });
      } else if (pos.x + pos.width > right) {
        scrollRef.current?.scrollTo({ x: pos.x + pos.width - viewportW + GAP, animated: true });
      }
    });
    return () => cancelAnimationFrame(raf);
  }, [selectedId, viewportW, idsKey]);

  // `minPillWidth` is applied as a floor (`minWidth`) so each pill grows to fit its own label (never
  // truncates) while short labels still hold the minimum.
  const pillStyle = minPillWidth > 0 ? { minWidth: minPillWidth } : undefined;

  const renderPill = (pill: PillRowItem) => (
    <View key={pill.id} onLayout={e => onPillLayout(pill.id, e)}>
      <Pill
        label={pill.label}
        variant={pill.variant}
        showText={pill.showText}
        iconName={pill.iconName}
        iconSize={pill.iconSize}
        icon={pill.icon}
        onPress={pill.onPress}
        disabled={pill.disabled}
        loading={pill.loading}
        accessibilityLabel={pill.accessibilityLabel}
        style={pillStyle}
      />
    </View>
  );

  return (
    <ScrollView
      ref={scrollRef}
      horizontal
      showsHorizontalScrollIndicator={false}
      // `style` (the ScrollView's OWN box, not its scrollable content) needs an explicit bound —
      // without it, react-native-web sizes the scroll viewport to hug its content instead of the
      // width its parent actually gives it, so it never overflows and never becomes swipable at
      // all (a wide pill set just spills past the layout silently). `contentContainerStyle` is a
      // separate thing: the inner row that's *allowed* to be wider than the viewport.
      style={styles.scrollView}
      contentContainerStyle={[styles.row, style]}
      onLayout={e => setViewportW(e.nativeEvent.layout.width)}
      onScroll={e => {
        scrollXRef.current = e.nativeEvent.contentOffset.x;
      }}
      scrollEventThrottle={16}
    >
      {pills.map(renderPill)}
      {showAddPill && (
        // Record the add pill's position (under '__add__') so it can be scrolled into view when
        // selected — tracked separately from `pills` since it's rendered outside that list.
        <View onLayout={e => onPillLayout('__add__', e)}>
          <Pill
            variant={addSelected ? 'selected' : 'not_selected'}
            showText={false}
            iconName="pencil"
            accessibilityLabel="Edit"
            onPress={onAddPress}
          />
        </View>
      )}
      {trailing}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scrollView: { width: '100%' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[600],
    minHeight: DS_SPACING[2400],
    paddingVertical: DS_SPACING[200],
  },
});
