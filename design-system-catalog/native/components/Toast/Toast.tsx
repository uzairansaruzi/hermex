import React, { useEffect, useRef, useState, type ReactNode } from 'react';
import { View, Text, Animated, Easing, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_RADIUS, DS_TYPOGRAPHY, DS_FONT_WEIGHT, DS_SHADOW, DS_ICON_SIZE, DS_MOTION_DURATION, DS_MOTION_EASING } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import { Button } from '../Button';
import type { IconName } from '../../../icons';

// Generously bigger than any real toast's rendered height, so the slide-in always starts fully
// above the visible area regardless of message length — no onLayout measurement needed (unlike
// Banner's collapse, this only needs "off-screen" vs "resting", not the real height).
const ENTER_FROM_Y = -100;

export type ToastVariant = 'success' | 'informational' | 'warning' | 'negative' | 'neutral';

// Same light tinted fill + saturated foreground pairing as Banner/Badge, so a variant toast reads as
// the same colour identity as the badge/banner of that status.
const VARIANT_CONFIG: Record<ToastVariant, { bg: string; fg: string; icon: IconName }> = {
  success:       { bg: DS_SEMANTIC.shade.positive, fg: DS_SEMANTIC.emphasis.positive, icon: 'circle-check'  },
  informational: { bg: DS_SEMANTIC.shade.info,     fg: DS_SEMANTIC.emphasis.info,     icon: 'info'          },
  warning:       { bg: DS_SEMANTIC.shade.warning,  fg: DS_SEMANTIC.emphasis.warning,  icon: 'triangle-alert'},
  negative:      { bg: DS_SEMANTIC.shade.negative, fg: DS_SEMANTIC.emphasis.negative, icon: 'circle-slash'  },
  neutral:       { bg: DS_SEMANTIC.shade.neutral,  fg: DS_SEMANTIC.emphasis.neutral,  icon: 'info-circle'   },
};

export interface ToastProps {
  message: string;
  /** Whether the toast is mounted and shown — animates in by sliding down from above (+ fading in)
   *  when it becomes true, and slides back out the same way when it becomes false. @default true
   *  (renders already in its resting position, no animation — for call sites that mount/unmount the
   *  whole Toast themselves rather than toggling this prop). */
  visible?: boolean;
  /** When set, applies one of the semantic colour schemes (bg + default icon). */
  variant?: ToastVariant;
  /** Override the icon. Defaults to the variant's icon, or `circle-check` for the base style. */
  iconName?: IconName;
  /** Override the icon colour. Defaults to the variant's emphasis colour for variant toasts, white (matching the text) for base. */
  iconColor?: string;
  /** Optional trailing action — e.g. "Undo". Colour-matched to the toast's own text/icon colour
   *  (whichever that resolves to for the active variant), not a separate fixed accent. */
  action?: { label: string; onPress: () => void };
  /** Opt-in replacement for the built-in `action` ghost Button — e.g. the Hermex catalog's real
   *  extraSmall neutral Button reconstruction, which cannot color-match a status tint. Renders in
   *  the same trailing slot when set; unrelated call sites keep using `action` unchanged. */
  actionNode?: ReactNode;
  /** Whether to draw the vertical rule between the message and the action slot. @default true,
   *  preserving every existing call site's current look. Production HermexToast separates the two by
   *  spacing alone (HStack(spacing: s12) { icon, message, Spacer, action }) with no divider of its
   *  own — the Hermex catalog's own Toast specimen passes `false` to match that exactly. */
  showDivider?: boolean;
  style?: StyleProp<ViewStyle>;
}

/**
 * A transient confirmation bar. Without `variant`, renders the default dark surface with inverse text.
 * With `variant`, the background shifts to the same light tinted fill Banner/Badge use for that
 * status, with the matching saturated emphasis colour for text/icon — not white. Slides in from
 * above (+ fades in) when `visible` turns true, and reverses on the way out — the same
 * measure-free, JS-driven (`useNativeDriver: false`, so it's visible in the web preview too, not
 * just on native) enter/exit pattern Dialog/BottomSheet use for their own show/hide.
 */
export function Toast({ message, visible = true, variant, iconName, iconColor, action, actionNode, showDivider = true, style }: ToastProps) {
  const [mounted, setMounted] = useState(visible);
  const progress = useRef(new Animated.Value(visible ? 1 : 0)).current;

  useEffect(() => {
    if (visible) setMounted(true);
    const duration = visible ? DS_MOTION_DURATION.base : DS_MOTION_DURATION.fast;
    Animated.timing(progress, {
      toValue: visible ? 1 : 0,
      duration,
      // `decelerate` — a toast entering the screen, per DS_MOTION_EASING_USE.
      easing: Easing.bezier(...DS_MOTION_EASING.decelerate),
      useNativeDriver: false,
    }).start();
    // A plain timer (not the animation's own `.start()` callback) drives the unmount-after-exit —
    // `finished` can come back false (or the callback can simply not fire) when this Animated.Value
    // is fighting for frames alongside other continuously-looping JS-driven animations elsewhere on
    // the same screen (Loading, Shimmer), which left Toast permanently stuck invisible-but-mounted
    // in exactly that scenario. A timer matching the animation's own duration is deterministic
    // regardless of what the Animated internals do.
    let hideTimer: ReturnType<typeof setTimeout> | undefined;
    if (!visible) hideTimer = setTimeout(() => setMounted(false), duration);
    return () => {
      if (hideTimer != null) clearTimeout(hideTimer);
    };
  }, [visible, progress]);

  if (!mounted) return null;

  const cfg = variant ? VARIANT_CONFIG[variant] : null;
  const resolvedIcon = iconName ?? cfg?.icon ?? 'circle-check';
  // Message, icon (by default), and the action label all share this colour, so the whole bar reads
  // as one consistent colour identity regardless of variant.
  const resolvedTextColor = cfg ? cfg.fg : DS_SEMANTIC.text.inverse;
  const resolvedIconColor = iconColor ?? resolvedTextColor;

  const translateY = progress.interpolate({ inputRange: [0, 1], outputRange: [ENTER_FROM_Y, 0] });

  return (
    <Animated.View
      style={[styles.toast, cfg && { backgroundColor: cfg.bg }, { opacity: progress, transform: [{ translateY }] }, style]}
      accessibilityRole="alert"
    >
      <Icon name={resolvedIcon} size={DS_ICON_SIZE.sm} color={resolvedIconColor} />
      <Text style={[styles.text, { color: resolvedTextColor }]} numberOfLines={2}>{message}</Text>
      {(action || actionNode) && (
        <>
          {/* A plain vertical rule tinted to resolvedTextColor at reduced opacity — not the shared
              Divider component, which is a fixed subtle-black horizontal line meant for light
              surfaces; Toast's own background can be dark (base) or a light tint (variant), so the
              divider has to adapt to whichever text colour is active instead. Caller-suppressible via
              showDivider — production HermexToast separates message/action by spacing alone. */}
          {showDivider && <View style={[styles.divider, { backgroundColor: resolvedTextColor }]} />}
          {actionNode ?? (
            // Always ghost + label-only — Toast's action is a quiet inline affordance, never a second
            // visual weight competing with the message. Ghost's own padding is already 0, so it sits
            // flush like the rest of the row; textStyle overrides ghost's fixed label colour with
            // resolvedTextColor so the action still colour-matches this toast's own variant.
            <Button variant="ghost" size="small" label={action!.label} onPress={action!.onPress} textStyle={{ color: resolvedTextColor }} />
          )}
        </>
      )}
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  toast: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[300],
    // surface.inverse, not text.regular — the base toast is a dark inverse PANEL; using the ink
    // token here would silently recolor it if a rebrand ever splits ink from dark surfaces.
    backgroundColor: DS_SEMANTIC.surface.inverse,
    borderRadius: DS_RADIUS.medium,
    paddingVertical: DS_SPACING[800],
    paddingHorizontal: DS_SPACING[600],
    borderWidth: 2,
    borderColor: 'transparent',
    ...DS_SHADOW.card,
  },
  text: {
    flex: 1,
    ...DS_TYPOGRAPHY.bodySm,
    fontWeight: DS_FONT_WEIGHT.medium,
  },
  divider: {
    width: 1,
    height: 20,
    opacity: 0.3,
    // Extra space on top of the row's own `gap` — the divider reads as a rule between two distinct
    // regions (message vs. action), so it gets more breathing room than the icon-to-label gap does.
    marginHorizontal: DS_SPACING[200],
  },
});
