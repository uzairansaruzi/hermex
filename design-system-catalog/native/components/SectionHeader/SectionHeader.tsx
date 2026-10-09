import React, { useState } from 'react';
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_TYPOGRAPHY, DS_FONT_WEIGHT, DS_RADIUS } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import type { IconName } from '../../../icons';
import { Button } from '../Button';

// Bumped up from the global 2px default — at this icon's small 16px render size, a default-weight
// stroke reads noticeably thinner than the bold (semibold, uppercase) label text it sits beside;
// this brings its visual weight in line with that text, the same reasoning Checkbox's own
// thicker check icon uses for a small glyph that needs to read clearly next to bold UI.
const LABEL_ICON_STROKE_WIDTH = 2.5;

export interface SectionHeaderLabelIcon {
  name: IconName;
  /** Render size in points. Defaults to 16 — matching the trailing button's own small-size icon
   *  (Button's `small` SIZE_TOKENS) and the row's own 16px line-height, so the row reads at a
   *  consistent height whether the label icon or the trailing button is the one present. */
  size?: number;
  /** When provided the icon is wrapped in a Pressable; omit for a non-interactive decoration. */
  onPress?: () => void;
  accessibilityLabel?: string;
}

export interface SectionHeaderProps {
  title: string;
  /**
   * Icon shown right after the title text with a 4 px gap.
   * Pass `onPress` to make it tappable (e.g. info); omit for a static decoration (e.g. pin).
   */
  labelIcon?: SectionHeaderLabelIcon;
  /** Label for a right-aligned ghost button. */
  trailingButtonLabel?: string;
  /** Icon to show on the trailing button. */
  trailingButtonIconName?: IconName;
  /** Whether the icon appears before or after the button label (default: 'trailing'). */
  trailingButtonIconPosition?: 'leading' | 'trailing';
  /** Called when the trailing button is pressed. */
  onTrailingButtonPress?: () => void;
  style?: StyleProp<ViewStyle>;
}

/** An uppercase muted section label with an optional inline icon and a right-aligned ghost button. */
export function SectionHeader({
  title,
  labelIcon,
  trailingButtonLabel,
  trailingButtonIconName,
  trailingButtonIconPosition = 'trailing',
  onTrailingButtonPress,
  style,
}: SectionHeaderProps) {
  const [iconFocused, setIconFocused] = useState(false);
  const iconEl = labelIcon ? (
    labelIcon.onPress ? (
      <Pressable
        onPress={labelIcon.onPress}
        onFocus={() => setIconFocused(true)}
        onBlur={() => setIconFocused(false)}
        // Pads the ~16px icon out to the 44pt touch-target minimum.
        hitSlop={14}
        accessibilityRole="button"
        accessibilityLabel={labelIcon.accessibilityLabel ?? title}
        // Keyboard focus shows the same highlight as a press (same policy as ListItem/SegmentedToggle).
        style={({ pressed }) => [styles.labelIconPressable, (pressed || iconFocused) && styles.labelIconPressed]}
      >
        <Icon name={labelIcon.name} size={labelIcon.size ?? 16} color={DS_SEMANTIC.text.muted} strokeWidth={LABEL_ICON_STROKE_WIDTH} />
      </Pressable>
    ) : (
      <Icon name={labelIcon.name} size={labelIcon.size ?? 16} color={DS_SEMANTIC.text.muted} strokeWidth={LABEL_ICON_STROKE_WIDTH} />
    )
  ) : null;

  return (
    <View style={[styles.container, style]}>
      <View style={styles.left}>
        <View style={styles.titleGroup}>
          <Text style={styles.title} numberOfLines={1}>
            {title}
          </Text>
          {iconEl}
        </View>
      </View>
      {trailingButtonLabel ? (
        <Button
          label={trailingButtonLabel}
          variant="ghost"
          size="small"
          showIcon={!!trailingButtonIconName}
          iconName={trailingButtonIconName}
          iconPosition={trailingButtonIconPosition}
          onPress={onTrailingButtonPress}
        />
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    width: '100%',
  },
  left: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
  },
  titleGroup: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[200],
  },
  title: {
    fontSize: DS_TYPOGRAPHY.labelXs.fontSize,
    fontWeight: DS_FONT_WEIGHT.semibold,
    color: DS_SEMANTIC.text.muted,
    textTransform: 'uppercase',
    // Match the tallest trailing control (16px small button icon / labelIcon) so the row height is
    // constant whether or not a button/icon is present — otherwise toggling them changes the header
    // height and shifts the content beneath it.
    lineHeight: 16,
  },
  labelIconPressable: {
    borderRadius: DS_RADIUS.round,
  },
  labelIconPressed: {
    backgroundColor: DS_SEMANTIC.interaction.pressed,
  },
});
