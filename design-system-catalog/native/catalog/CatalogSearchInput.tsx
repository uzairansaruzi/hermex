import { useState } from 'react';
import { View, Text, TextInput, Pressable, StyleSheet } from 'react-native';
import { CATALOG_TYPE, CATALOG_COLOR, CATALOG_SPACE, CATALOG_RADIUS } from './tokens';

/**
 * Plain search input for filtering the catalog's own sidebar nav. Deliberately built from bare
 * RN primitives rather than the host app's own search/field component — the catalog is a
 * documentation tool for that component, not a consumer of it, so its own chrome shouldn't depend
 * on (or accidentally break alongside) whatever that component does.
 */
export function CatalogSearchInput({
  value,
  onChangeText,
  placeholder,
}: {
  value: string;
  onChangeText: (text: string) => void;
  placeholder: string;
}) {
  // Focus darkens the box border — react-native-web resets the browser's default input focus ring,
  // so the box has to draw its own indicator.
  const [focused, setFocused] = useState(false);
  const [clearFocused, setClearFocused] = useState(false);
  // Hover via onHoverIn/Out, not the style callback's `hovered` — same reasoning as NavItem: this
  // project's Pressable types (targeting native) don't expose that field, though RNW fires the events.
  const [clearHovered, setClearHovered] = useState(false);
  return (
    <View style={[styles.box, focused && styles.boxFocused]}>
      <TextInput
        value={value}
        onChangeText={onChangeText}
        placeholder={placeholder}
        placeholderTextColor={CATALOG_COLOR.textMuted}
        // A durable name — the placeholder alone disappears the moment the user types.
        accessibilityLabel="Filter components"
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        style={styles.input}
      />
      {value.length > 0 && (
        <Pressable
          onPress={() => onChangeText('')}
          onFocus={() => setClearFocused(true)}
          onBlur={() => setClearFocused(false)}
          onHoverIn={() => setClearHovered(true)}
          onHoverOut={() => setClearHovered(false)}
          hitSlop={8}
          accessibilityRole="button"
          accessibilityLabel="Clear filter"
          // Press/hover/focus all show the same highlight the sidebar's NavItems use.
          style={({ pressed }) => [
            styles.clearButton,
            (pressed || clearHovered || clearFocused) && styles.clearButtonActive,
          ]}
        >
          <Text style={styles.clear}>×</Text>
        </Pressable>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  box: {
    flexDirection: 'row', alignItems: 'center', gap: CATALOG_SPACE.xs,
    borderWidth: 1, borderColor: CATALOG_COLOR.border, borderRadius: CATALOG_RADIUS.sm,
    paddingHorizontal: 10, height: 36, marginBottom: CATALOG_SPACE.sm,
    backgroundColor: CATALOG_COLOR.surface,
  },
  boxFocused: { borderColor: CATALOG_COLOR.text },
  input: { flex: 1, fontSize: CATALOG_TYPE.md, color: CATALOG_COLOR.text, padding: 0 },
  clearButton: { borderRadius: CATALOG_RADIUS.sm },
  clearButtonActive: { backgroundColor: CATALOG_COLOR.surfacePressed },
  clear: { fontSize: CATALOG_TYPE.lg, color: CATALOG_COLOR.textMuted, paddingHorizontal: 2 },
});
