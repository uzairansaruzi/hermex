import React, { useState } from 'react';
import { Pressable, Text, StyleSheet, View } from 'react-native';
import { DS_SEMANTIC, DS_RADIUS, DS_SPACING, DS_TYPOGRAPHY, DS_SHADOW } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import { Loading } from '../Loading';
import type { PillProps } from './Pill.types';

function PillIcon({
  name,
  selected,
  size = 16,
}: {
  name: NonNullable<PillProps['iconName']>;
  selected: boolean;
  size?: number;
}) {
  return (
    <Icon name={name} size={size} color={selected ? DS_SEMANTIC.text.inverse : DS_SEMANTIC.text.regular} />
  );
}

/**
 * A single-line selection chip. `selected` fills solid dark with inverse content; `not_selected`
 * sits on white with a resting shadow. Leading slot holds an `iconName`, a custom `icon` node
 * (sizes naturally), or the default menu icon; the label can be hidden for an icon-only pill.
 */
export function Pill({
  label = 'Text',
  variant = 'selected',
  accessibilityLabel,
  showText = true,
  iconName,
  iconSize = 16,
  icon,
  onPress,
  disabled = false,
  loading = false,
  style,
}: PillProps) {
  const isSelected = variant === 'selected';
  const isDisabled = disabled || loading;
  const [focused, setFocused] = useState(false);

  // A custom `icon` node (e.g. a badge) is taller than a plain icon. The pill keeps a fixed
  // height regardless, so the badge centers in the same height as an icon+label pill; its horizontal
  // padding is then reduced to equal the (smaller) vertical breathing room around the taller badge.
  const isBadge = !iconName && icon != null;

  // The leading slot sizes to its content, so it holds an `iconName` (at `iconSize`), a custom `icon`
  // node of any size, or the default menu icon.
  const iconNode = iconName ? (
    <PillIcon name={iconName} selected={isSelected} size={iconSize} />
  ) : (
    icon ?? <PillIcon name="menu" selected={isSelected} size={iconSize} />
  );

  const content = loading ? (
    <Loading
      size={16}
      color={isSelected ? DS_SEMANTIC.text.inverse : DS_SEMANTIC.text.regular}
    />
  ) : (
    <>
      <View style={styles.iconSlot}>{iconNode}</View>
      {showText && label ? (
        <Text
          // Pills are single-line chips — never wrap (a sub-pixel-tight equal width would otherwise
          // fold the label onto two lines and grow the pill).
          numberOfLines={1}
          style={[
            styles.label,
            { color: isSelected ? DS_SEMANTIC.text.inverse : DS_SEMANTIC.text.regular },
          ]}
        >
          {label}
        </Text>
      ) : null}
    </>
  );

  // Icon-only pills are forced to a fixed width equal to the pill's own fixed height (not left to
  // emerge from padding + the icon's own width, which only happens to land on a square at the
  // default iconSize=16 — passing a different `iconSize` would otherwise stretch it into a
  // rounded rect instead of a true circle) — a fixed square, with content centred inside it via the
  // container's own `alignItems`/`justifyContent: center`, keeps it circular at any icon size.
  const containerStyle = [
    styles.container,
    showText ? { paddingHorizontal: isBadge ? DS_SPACING[400] : DS_SPACING[600] } : styles.iconOnly,
    isSelected ? styles.selected : styles.notSelected,
    isDisabled && styles.disabled,
    style,
  ];

  // A selected pill is the current state — tapping it is a no-op, so it renders as a plain View
  // (no pressed feedback) even when an onPress is wired up.
  if (onPress && !isSelected) {
    return (
      <Pressable
        onPress={onPress}
        disabled={isDisabled}
        // Extends the 40pt-tall pill to the 44pt minimum touch target. An icon-only pill is also only
        // ~40pt wide (no label to widen it), so it needs the same padding on left/right too.
        hitSlop={showText ? { top: 2, bottom: 2 } : { top: 2, bottom: 2, left: 2, right: 2 }}
        accessibilityRole="button"
        accessibilityLabel={accessibilityLabel ?? label}
        accessibilityState={{ disabled: isDisabled, busy: loading, selected: isSelected }}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        style={({ pressed }) => [
          containerStyle,
          pressed && !isDisabled && styles.pressed,
          focused && !isDisabled && styles.focused,
        ]}
      >
        {content}
      </Pressable>
    );
  }

  return <View style={containerStyle}>{content}</View>;
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: DS_SPACING[200],
    // Fixed height so a tall leading node doesn't grow the pill past an icon+label one.
    // Horizontal padding is applied per-instance (equal to the vertical breathing room): normal pills
    // use 12, badge pills 8; icon-only pills get a fixed width instead (see `iconOnly` below).
    height: DS_SPACING[2000],
    borderRadius: DS_RADIUS.round,
  },
  // Fixed width equal to `container`'s own fixed height — a true circle regardless of the leading
  // icon's size, rather than letting width emerge from padding + icon width (see the containerStyle
  // comment above).
  iconOnly: {
    width: DS_SPACING[2000],
  },
  selected: {
    // surface.inverse, not text.regular — this is a dark panel FILL, not ink; the two tokens share a
    // value today but must be free to diverge in a rebrand.
    backgroundColor: DS_SEMANTIC.surface.inverse,
    // Transparent border matching not_selected's 2px, so both variants have identical layout boxes
    // (otherwise unselected pills render taller and the row looks uneven). Reserved at the focus
    // ring's own width (not 1px) so focusing only swaps the border colour, never its width — a
    // width change on focus would otherwise shift the pill's layout, same fix as Button's border.
    borderWidth: 2,
    borderColor: 'transparent',
  },
  notSelected: {
    backgroundColor: DS_SEMANTIC.surface.white,
    // No border — the resting shadow alone separates the pill from the surface. Keep a transparent
    // border (matching selected's reserved focus-ring width) so the box matches its height.
    borderWidth: 2,
    borderColor: 'transparent',
    ...DS_SHADOW.resting,
  },
  pressed: {
    backgroundColor: DS_SEMANTIC.interaction.pressed,
  },
  focused: {
    borderColor: DS_SEMANTIC.interaction.focused,
  },
  // Dims the WHOLE pill — container opacity multiplies down through every child in RN, so the
  // label/icon dim with it; there is no way for a child to opt back out of an ancestor's opacity.
  disabled: {
    opacity: DS_SEMANTIC.interaction.disabledOpacity,
  },
  // Sizes to its content so the leading slot can hold an icon of any size or a custom node.
  iconSlot: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  // No pinned lineHeight — the pill's height follows the label typography (padding + natural line
  // height), so a type-scale change resizes the pill instead of rattling inside a fixed box.
  label: {
    ...DS_TYPOGRAPHY.labelSm,
  },
});
