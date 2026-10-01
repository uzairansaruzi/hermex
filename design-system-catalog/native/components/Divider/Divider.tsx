import React from 'react';
import { View, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC } from '../../../tokens';

export interface DividerProps {
  /**
   * Opacity applied on top of the adaptive divider color, so the same hairline reads lighter or at
   * full strength depending on what it composes over. Component-owned rather than a global token —
   * every caller (e.g. a settings row vs. a card footer) picks its own value contextually.
   * @default 0.72
   */
  opacity?: number;
  style?: StyleProp<ViewStyle>;
}

/** A 1px hairline separator at the divider token colour, translucent by default. */
export function Divider({ opacity = 0.72, style }: DividerProps) {
  return <View style={[styles.line, { opacity }, style]} />;
}

const styles = StyleSheet.create({
  line: {
    height: 1,
    width: '100%',
    backgroundColor: DS_SEMANTIC.element.divider,
  },
});
