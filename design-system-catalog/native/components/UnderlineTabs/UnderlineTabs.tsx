import React, { useState } from 'react';
import { View, Text, Pressable, Animated, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_RADIUS, DS_TYPOGRAPHY, DS_ICON_SIZE, DS_A11Y_MIN_TOUCH_TARGET } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import type { IconName } from '../../../icons';
import { useSlideAnim } from '../SegmentedToggle/useSlideAnim';

export interface UnderlineTabOption {
  value: string;
  label: string;
  /** Optional leading icon (16px) shown before the label. */
  iconName?: IconName;
  /** Optional count shown in a circular badge after the label (hidden when 0/undefined). */
  badge?: number;
}

export interface UnderlineTabsProps {
  options: UnderlineTabOption[];
  /** The currently-selected option `value`. */
  value: string;
  onChange: (value: string) => void;
  style?: StyleProp<ViewStyle>;
}

const INDICATOR_HEIGHT = 2;

/**
 * Low-prominence tab switcher — left-aligned text labels over a hairline rule, with a thin underline
 * indicator that slides to the selected tab. A quieter stand-in for SegmentedToggle: same
 * options/value/onChange API, but no filled track or lifted thumb. Two or more options.
 */
export function UnderlineTabs({ options, value, onChange, style }: UnderlineTabsProps) {
  // -1 when `value` matches no option (e.g. stale state after the options list changed). The
  // indicator is hidden entirely in that case — clamping to tab 0 would underline a tab whose own
  // label doesn't render as selected, a visibly contradictory state.
  const matchedIndex = options.findIndex(o => o.value === value);
  const hasSelection = matchedIndex !== -1;
  const selectedIndex = Math.max(0, matchedIndex);
  // Per-tab measured geometry (x offset + width within the row), so the indicator can size and slide to
  // each variable-width label.
  const [layouts, setLayouts] = useState<Record<number, { x: number; width: number }>>({});
  // Which tab currently holds keyboard focus (null = none).
  const [focusedValue, setFocusedValue] = useState<string | null>(null);
  // translateX + width animate together; width can't use the native driver, so neither does.
  const anim = useSlideAnim(selectedIndex, false);
  const measured = options.every((_, i) => layouts[i] != null);

  // Unlike SegmentedToggle's analytically-computed thumb position, this indicator slides to each
  // tab's real measured `x` (from onLayout) — already RTL-correct as-is, since onLayout reports actual
  // post-mirroring screen position, not an index-based LTR assumption.
  const indices = options.map((_, i) => i);
  const indicatorX = measured
    ? anim.interpolate({ inputRange: indices, outputRange: indices.map(i => layouts[i].x) })
    : 0;
  const indicatorW = measured
    ? anim.interpolate({ inputRange: indices, outputRange: indices.map(i => layouts[i].width) })
    : 0;

  return (
    <View style={[styles.row, style]} accessibilityRole="tablist">
      {options.map((opt, i) => {
        const selected = opt.value === value;
        const color = selected ? DS_SEMANTIC.text.regular : DS_SEMANTIC.text.muted;
        return (
          <Pressable
            key={opt.value}
            onPress={() => onChange(opt.value)}
            onLayout={e => {
              const { x, width } = e.nativeEvent.layout;
              setLayouts(prev =>
                prev[i] && prev[i].x === x && prev[i].width === width ? prev : { ...prev, [i]: { x, width } },
              );
            }}
            onFocus={() => setFocusedValue(opt.value)}
            onBlur={() => setFocusedValue(prev => (prev === opt.value ? null : prev))}
            accessibilityRole="tab"
            accessibilityLabel={opt.badge != null && opt.badge > 0 ? `${opt.label}, ${opt.badge}` : opt.label}
            accessibilityState={{ selected }}
            // Keyboard focus shows the same highlight as a press (same policy as SegmentedToggle/ListItem).
            style={({ pressed }) => [styles.tab, (pressed || focusedValue === opt.value) && styles.tabPressed]}
          >
            {opt.iconName && <Icon name={opt.iconName} size={DS_ICON_SIZE.sm} color={color} />}
            <Text style={[styles.label, { color }]}>{opt.label}</Text>
            {opt.badge != null && opt.badge > 0 && (
              <View style={[styles.badge, { backgroundColor: color }]}>
                <Text style={[styles.badgeText, { color: DS_SEMANTIC.surface.white }]}>{opt.badge}</Text>
              </View>
            )}
          </Pressable>
        );
      })}
      {measured && hasSelection && (
        <Animated.View
          pointerEvents="none"
          style={[styles.indicator, { width: indicatorW, transform: [{ translateX: indicatorX }] }]}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: DS_SPACING[800],
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: DS_SEMANTIC.element.divider,
  },
  tab: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[200],
    paddingTop: DS_SPACING[400],
    paddingBottom: DS_SPACING[600],
    // A fixed floor (not a spacing token — this is an accessibility guideline number, not a design
    // choice) so the tab's compact visual padding still guarantees a touch target.
    minHeight: DS_A11Y_MIN_TOUCH_TARGET,
  },
  tabPressed: {
    backgroundColor: DS_SEMANTIC.interaction.pressed,
    borderRadius: DS_RADIUS.small,
  },
  label: {
    // Matches the section-header label size (labelXs) it stands in for.
    ...DS_TYPOGRAPHY.labelXs,
    // Pin the line box to the badge height (18) so a tab is the same height with or without a count
    // badge — otherwise the taller badged tab grows the row and shifts the divider/content below it.
    lineHeight: 18,
  },
  // The sliding underline, sat on the hairline rule beneath the selected tab.
  indicator: {
    position: 'absolute',
    left: 0,
    bottom: -StyleSheet.hairlineWidth,
    height: INDICATOR_HEIGHT,
    borderRadius: INDICATOR_HEIGHT / 2,
    backgroundColor: DS_SEMANTIC.text.regular,
  },
  // Fixed-diameter circle so the count badge stays round. 18 doesn't match a DS_SPACING/DS_ICON_SIZE
  // step (16/20 are the neighbors) — sized to comfortably fit a 1-2 digit count at labelXs.
  badge: {
    width: 18,
    height: 18,
    borderRadius: DS_RADIUS.round,
    alignItems: 'center',
    justifyContent: 'center',
  },
  badgeText: {
    ...DS_TYPOGRAPHY.labelXs,
    // Pinned to the badge's own 18px diameter (above) so the count sits centered in the circle.
    lineHeight: 18,
  },
});
