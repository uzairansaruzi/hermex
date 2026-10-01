import React from 'react';
import { View, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING } from '../../../tokens';

export interface ProgressDotsProps {
  /** 0-based index of the current step. The active dot widens into a pill. */
  active: number;
  /** Total number of steps (dots). */
  total?: number;
  style?: StyleProp<ViewStyle>;
}

/**
 * Step progress indicator — a row of dots where the current step is a widened pill.
 */
export function ProgressDots({ active, total = 6, style }: ProgressDotsProps) {
  return (
    <View
      style={[styles.row, style]}
      accessible
      accessibilityRole="progressbar"
      accessibilityLabel={`Step ${active + 1} of ${total}`}
      accessibilityValue={{ min: 1, max: total, now: active + 1 }}
    >
      {Array.from({ length: total }).map((_, i) => (
        <View key={i} style={[styles.dot, i === active && styles.dotActive]} />
      ))}
    </View>
  );
}

// 7px is intentionally smaller than DS_SPACING[400]=8px — optical correction for small dots.
const DOT_H = 7;
const DOT_PILL_W = 20;
const DOT_RADIUS = 4;

const styles = StyleSheet.create({
  row: { flexDirection: 'row', justifyContent: 'center', alignItems: 'center', gap: DS_SPACING[200] },
  dot: { width: DOT_H, height: DOT_H, borderRadius: DOT_RADIUS, backgroundColor: DS_SEMANTIC.border.subtle },
  // surface.inverse, not text.regular — a dark FILL, not ink (same reasoning as Pill/Toast).
  dotActive: { width: DOT_PILL_W, borderRadius: DOT_RADIUS, backgroundColor: DS_SEMANTIC.surface.inverse },
});
