import React, { useEffect, useRef, useState } from 'react';
import { View, Text, Pressable, Animated, Easing, StyleSheet, type LayoutChangeEvent } from 'react-native';
import { DS_SEMANTIC, DS_RADIUS, DS_SPACING, DS_TYPOGRAPHY, DS_ICON_SIZE, DS_MOTION_DURATION, DS_MOTION_EASING } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import type { IconName } from '../../../icons';
import { AnimatedChevron } from '../AnimatedChevron';
import { STATUS_BG, STATUS_FG } from '../statusColors';
import type { BannerProps, BannerVariant } from './Banner.types';

// Shared with Badge (see ../statusColors) so a banner reads as the same status identity as a
// badge of the same variant — one map, matched by construction.

const BANNER_ICONS: Record<BannerVariant, IconName> = {
  neutral: 'info-circle',
  info: 'info-circle',
  positive: 'circle-check',
  warning: 'triangle-alert',
  negative: 'alert-circle',
};

const COLLAPSE_ANIM_MS = DS_MOTION_DURATION.base;

/**
 * A status callout in two layouts, chosen by props:
 *   • collapsible callout — the whole card toggles the description open/closed;
 *   • standard callout    — leading icon + title, optional description/link/action.
 */
export function Banner({
  variant = 'warning',
  title,
  description,
  collapsible = false,
  defaultExpanded = true,
  backgroundColor,
  onPress,
  trailingIcon,
  textColor,
  icon,
  link,
  action,
  style,
}: BannerProps) {
  const [expanded, setExpanded] = useState(defaultExpanded);
  // Real layout height + opacity via the core `Animated` API (`useNativeDriver: false`) — not
  // `LayoutAnimation`, which is unreliable on the New Architecture (Fabric) and a total no-op on
  // web, so the collapse used to just snap instantly there. Same measure-once-then-animate
  // technique used elsewhere in this DS: render in normal flow only on the very first pass while
  // already expanded (shows instantly, no flash, and captures the real height); every other pass —
  // including the very first while starting collapsed — positions the content absolutely so it can
  // self-measure without affecting layout, then animates between 0 and that measured height.
  const [measuredHeight, setMeasuredHeight] = useState(0);
  const collapseAnim = useRef(new Animated.Value(defaultExpanded ? 1 : 0)).current;

  useEffect(() => {
    const anim = Animated.timing(collapseAnim, {
      toValue: expanded ? 1 : 0,
      duration: COLLAPSE_ANIM_MS,
      // `standard` — an in-place expand/collapse (a toggle), per DS_MOTION_EASING_USE.
      easing: Easing.bezier(...DS_MOTION_EASING.standard),
      useNativeDriver: false,
    });
    anim.start();
    return () => anim.stop();
  }, [expanded, collapseAnim]);

  const bg = backgroundColor ?? STATUS_BG[variant];
  const contentTextColor = textColor ?? STATUS_FG[variant];
  const iconName = icon ?? BANNER_ICONS[variant];

  // ── Collapsible callout: the whole banner toggles the description ─────────────
  if (collapsible) {
    const toggle = () => setExpanded(e => !e);
    const flowMeasure = measuredHeight === 0 && expanded;
    const onDescriptionLayout = (e: LayoutChangeEvent) => {
      const h = e.nativeEvent.layout.height;
      if (h > 0 && h !== measuredHeight) setMeasuredHeight(h);
    };
    return (
      <Pressable
        style={[styles.calloutContainer, { backgroundColor: bg }, style]}
        onPress={toggle}
        accessibilityRole="button"
        accessibilityState={{ expanded }}
      >
        {({ pressed }) => (
          <>
            {pressed && <View style={styles.pressOverlay} pointerEvents="none" />}
            <View style={styles.headerRow}>
              <View style={styles.statusIconLineBox}>
                <Icon name={iconName} size={DS_ICON_SIZE.sm} color={contentTextColor} />
              </View>
              <Text style={[styles.title, styles.titleFlex, { marginBottom: 0 }, { color: contentTextColor }]}>
                {title}
              </Text>
              <AnimatedChevron expanded={expanded} size={DS_ICON_SIZE.xs} color={contentTextColor} />
            </View>
            {!!description && (
              <Animated.View
                style={[
                  styles.collapseClip,
                  measuredHeight === 0
                    ? expanded
                      ? null
                      : styles.collapseHidden
                    : { height: Animated.multiply(collapseAnim, measuredHeight), opacity: collapseAnim },
                ]}
              >
                <View style={flowMeasure ? undefined : styles.collapseAbsolute} onLayout={onDescriptionLayout}>
                  <Text style={[styles.description, styles.descriptionPad, { color: contentTextColor }]}>
                    {description}
                  </Text>
                </View>
              </Animated.View>
            )}
          </>
        )}
      </Pressable>
    );
  }

  // ── Standard callout (title + description) ────────────────────────────────────
  // The description/link content, shared by two possible positions below: the header row's
  // primary text position when title is absent (so a description-only banner never renders an
  // icon-only header plus an indented second row), and the indented second row when title is
  // present (descriptionPad aligns its first line under the title, in line with the icon+gap).
  const descriptionNode = description || link ? (
    <>
      {description ?? ''}
      {description && link ? ' ' : null}
      {link ? (
        <Text style={styles.linkText} onPress={link.onPress} accessibilityRole="link">
          {link.label}
        </Text>
      ) : null}
    </>
  ) : null;

  const body = (pressed: boolean) => (
    <>
      {onPress && pressed && <View style={styles.pressOverlay} pointerEvents="none" />}
      <View style={[styles.headerRow, styles.standardHeaderRow]}>
        <View style={styles.statusIconLineBox}>
          <Icon name={iconName} size={DS_ICON_SIZE.sm} color={contentTextColor} />
        </View>
        {title ? (
          <Text style={[styles.title, styles.titleFlex, { marginBottom: 0 }, { color: contentTextColor }]}>
            {title}
          </Text>
        ) : descriptionNode ? (
          <Text style={[styles.title, styles.titleFlex, { marginBottom: 0 }, { color: contentTextColor }]}>
            {descriptionNode}
          </Text>
        ) : null}
        {trailingIcon ? (
          <View style={styles.statusIconLineBox}>
            <Icon name={trailingIcon} size={DS_ICON_SIZE.sm} color={contentTextColor} />
          </View>
        ) : null}
      </View>
      {title && descriptionNode ? (
        <Text style={[styles.description, styles.descriptionPad, { color: contentTextColor }]}>
          {descriptionNode}
        </Text>
      ) : null}
      {action ? (
        <View style={[styles.actionRow, { paddingHorizontal: DS_SPACING[800] }]}>
          <Pressable
            style={({ pressed }) => [styles.actionButton, pressed && styles.actionButtonPressed]}
            // Pads the compact text button's visual ~26px height out to the 44pt touch-target minimum.
            hitSlop={10}
            onPress={action.onPress}
            accessibilityRole="button"
            accessibilityLabel={action.label}
          >
            <Text style={[styles.actionLabel, { color: contentTextColor }]}>{action.label}</Text>
          </Pressable>
        </View>
      ) : null}
    </>
  );

  if (onPress) {
    return (
      <Pressable
        style={[styles.calloutContainer, { backgroundColor: bg }, style]}
        onPress={onPress}
        accessibilityRole="button"
        accessibilityLabel={title}
      >
        {({ pressed }) => body(pressed)}
      </Pressable>
    );
  }

  return (
    <View style={[styles.calloutContainer, { backgroundColor: bg }, style]}>{body(false)}</View>
  );
}

const styles = StyleSheet.create({
  actionRow: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    marginTop: DS_SPACING[400],
  },
  actionButton: {
    borderRadius: DS_RADIUS.xs,
    paddingVertical: DS_SPACING[200],
    paddingHorizontal: DS_SPACING[600],
  },
  actionButtonPressed: {
    backgroundColor: DS_SEMANTIC.interaction.pressed,
  },
  actionLabel: {
    ...DS_TYPOGRAPHY.labelSm,
  },
  linkText: {
    textDecorationLine: 'underline',
  },
  // Callout: the header carries the top + horizontal padding so the pressed state fills it; the
  // bottom padding lives on the container (constant) so nothing jumps when toggling — only the
  // description mounts/unmounts. overflow:hidden keeps the rounded corners.
  calloutContainer: {
    borderRadius: DS_RADIUS.medium,
    width: '100%',
    overflow: 'hidden',
    paddingBottom: DS_SPACING[800],
  },
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: DS_SPACING[400],
    paddingTop: DS_SPACING[800],
    paddingHorizontal: DS_SPACING[800],
  },
  // Production HermexBanner uses HStack(alignment: .top). Keep this on the standard reconstruction
  // only: a multi-line description-only message starts beside the icon rather than centering the
  // icon against the entire text block, while the separate collapsible catalog example keeps its
  // own centered disclosure-row geometry.
  standardHeaderRow: {
    alignItems: 'flex-start',
  },
  // The native Banner pairs a 16pt icon with subheadline text. The SVG reconstruction needs an
  // explicit first-line box so its visual center aligns with the 20px title line while a multi-line
  // description-only message still keeps the icon beside its first line, not the whole text block.
  statusIconLineBox: {
    width: DS_ICON_SIZE.sm,
    height: DS_TYPOGRAPHY.labelSm.lineHeight,
    alignItems: 'center',
    justifyContent: 'center',
    flexShrink: 0,
  },
  title: {
    ...DS_TYPOGRAPHY.labelSm,
    marginBottom: DS_SPACING[200],
  },
  titleFlex: {
    flex: 1,
  },
  description: {
    ...DS_TYPOGRAPHY.bodySm,
  },
  descriptionPad: {
    // Start-aligns with the title: headerRow padding (800) + icon + gap (400). Logical start/end
    // (not left/right) so the indent follows the icon+title when the layout mirrors in RTL.
    paddingStart: DS_SPACING[800] + DS_ICON_SIZE.sm + DS_SPACING[400],
    paddingEnd: DS_SPACING[800],
    paddingTop: DS_SPACING[200],
  },
  // Translucent pressed overlay — sits above the banner bg so the tinted bg shows through.
  pressOverlay: {
    ...StyleSheet.absoluteFill,
    backgroundColor: DS_SEMANTIC.interaction.pressed,
    borderRadius: DS_RADIUS.medium,
  },
  // Collapsible description — clips the animated height; the child is pinned absolute (except on
  // its very first in-flow measuring pass) so shrinking the parent never re-measures/corrupts it.
  collapseClip: {
    overflow: 'hidden',
    width: '100%',
  },
  collapseHidden: {
    height: 0,
  },
  collapseAbsolute: {
    position: 'absolute',
    left: 0,
    right: 0,
    top: 0,
  },
});
