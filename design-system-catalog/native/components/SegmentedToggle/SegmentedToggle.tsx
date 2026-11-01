import React, { useState } from 'react';
import { View, Text, Pressable, Animated, I18nManager, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_RADIUS, DS_TYPOGRAPHY, DS_ICON_SIZE, DS_SHADOW, DS_A11Y_MIN_TOUCH_TARGET } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import type { IconName } from '../../../icons';
import { useSlideAnim } from './useSlideAnim';

export interface SegmentedToggleOption {
  value: string;
  label: string;
  /** Optional leading icon (16px) shown before the label. */
  iconName?: IconName;
  /** Optional count shown in a circular badge after the label (hidden when 0/undefined). */
  badge?: number;
}

export interface SegmentedToggleProps {
  options: SegmentedToggleOption[];
  /** The currently-selected option `value`. */
  value: string;
  onChange: (value: string) => void;
  style?: StyleProp<ViewStyle>;
}

const TRACK_PADDING = DS_SPACING[100]; // recessed track inset
const GAP = DS_SPACING[100]; // space between segment slots
const THUMB_INSET = DS_SPACING[100]; // shrinks the thumb inside its slot for breathing room
const TRACK_COLOR = DS_SEMANTIC.surface.recessed; // track background — matches the secondary Button fill
const THUMB_COLOR = DS_SEMANTIC.surface.white; // selected thumb (white pill)

/**
 * Segmented control — a row of mutually-exclusive options on a recessed track. A white "thumb" lifts
 * the selected option and slides horizontally between segments on change. The thumb sits inset from its
 * slot so there's a little gap around it. Two or more options.
 */
export function SegmentedToggle({ options, value, onChange, style }: SegmentedToggleProps) {
  const n = options.length;
  const selectedIndex = Math.max(0, options.findIndex(o => o.value === value));
  const [trackW, setTrackW] = useState(0);
  // Which segment currently holds keyboard focus (null = none) — one state for the whole row, since
  // only one segment can be focused at a time.
  const [focusedValue, setFocusedValue] = useState<string | null>(null);
  // Fixed equal-width segments computed analytically, so translateX-only can stay native-driven.
  const anim = useSlideAnim(selectedIndex, true);

  const innerW = Math.max(0, trackW - TRACK_PADDING * 2);
  const segW = n > 0 ? (innerW - GAP * (n - 1)) / n : 0;
  const thumbW = Math.max(0, segW - THUMB_INSET * 2);
  // Left edge of the thumb at each index (segment left + inset). `track`'s `flexDirection: 'row'`
  // auto-mirrors the segments themselves in RTL, but this absolute-positioned thumb's `left`/
  // `translateX` doesn't — so in RTL, index `i` visually renders at the *mirrored* slot (n-1-i).
  const thumbX =
    n > 1
      ? anim.interpolate({
          inputRange: options.map((_, i) => i),
          outputRange: options.map((_, i) => {
            const slot = I18nManager.isRTL ? n - 1 - i : i;
            return TRACK_PADDING + slot * (segW + GAP) + THUMB_INSET;
          }),
        })
      : TRACK_PADDING + THUMB_INSET;

  return (
    <View
      style={[styles.track, style]}
      onLayout={e => setTrackW(e.nativeEvent.layout.width)}
      accessibilityRole="tablist"
    >
      {trackW > 0 && (
        <Animated.View
          pointerEvents="none"
          style={[styles.thumb, { width: thumbW, transform: [{ translateX: thumbX }] }]}
        />
      )}
      {options.map(opt => {
        const selected = opt.value === value;
        // Black label on the white thumb when selected; muted on the recessed track otherwise.
        const color = selected ? DS_SEMANTIC.text.regular : DS_SEMANTIC.text.muted;
        // The badge is a filled circle of the label colour; its number is white so it stays legible on
        // both the black (selected) and muted-grey (unselected) circle.
        const onColor = DS_SEMANTIC.surface.white;
        return (
          <Pressable
            key={opt.value}
            onPress={() => onChange(opt.value)}
            onFocus={() => setFocusedValue(opt.value)}
            onBlur={() => setFocusedValue(prev => (prev === opt.value ? null : prev))}
            accessibilityRole="tab"
            accessibilityLabel={opt.badge != null && opt.badge > 0 ? `${opt.label}, ${opt.badge}` : opt.label}
            accessibilityState={{ selected }}
            // Keyboard focus shows the same highlight as a press — a flat in-track target has no
            // border to recolor, so focus mirrors the pressed treatment (same policy as ListItem).
            style={({ pressed }) => [styles.segment, (pressed || focusedValue === opt.value) && styles.segmentPressed]}
          >
            {opt.iconName && <Icon name={opt.iconName} size={DS_ICON_SIZE.sm} color={color} />}
            <Text style={[styles.label, { color }]}>{opt.label}</Text>
            {opt.badge != null && opt.badge > 0 && (
              <View style={[styles.badge, { backgroundColor: color }]}>
                <Text style={[styles.badgeText, { color: onColor }]}>{opt.badge}</Text>
              </View>
            )}
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  track: {
    flexDirection: 'row',
    backgroundColor: TRACK_COLOR,
    borderRadius: DS_RADIUS.round,
    padding: TRACK_PADDING,
    gap: GAP,
  },
  // The lifted pill behind the selected segment — slides horizontally on change.
  thumb: {
    position: 'absolute',
    left: 0,
    top: TRACK_PADDING + THUMB_INSET,
    bottom: TRACK_PADDING + THUMB_INSET,
    backgroundColor: THUMB_COLOR,
    borderRadius: DS_RADIUS.round,
    ...DS_SHADOW.resting,
  },
  segment: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: DS_SPACING[200],
    paddingVertical: DS_SPACING[600],
    // The track's own padding + this segment's content otherwise falls short of the touch-target
    // minimum; a fixed floor (not a spacing token — this is an accessibility guideline number, not a
    // design choice) keeps the segment's compact visual padding while still guaranteeing a tappable size.
    minHeight: DS_A11Y_MIN_TOUCH_TARGET,
  },
  segmentPressed: {
    backgroundColor: DS_SEMANTIC.interaction.pressed,
    borderRadius: DS_RADIUS.round,
  },
  label: {
    // Matches the section-header label size (labelXs) it stands in for.
    ...DS_TYPOGRAPHY.labelXs,
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
