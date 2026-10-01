import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Animated, AccessibilityInfo, Platform, Pressable, Text, View, StyleSheet, type ViewStyle, type TextStyle } from 'react-native';
import { DS_SEMANTIC, DS_PALETTE, DS_RADIUS, DS_SPACING, DS_TYPOGRAPHY, DS_FONT_WEIGHT, DS_A11Y_MIN_TOUCH_TARGET } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import { Loading } from '../Loading';
import type { ButtonProps, ButtonVariant, ButtonSize } from './Button.types';

type SizeTokens = { paddingVertical: number; paddingHorizontal: number; fontSize: number; lineHeight: number; iconSize: number };

// The icon size tracks the label's line box so the icon stays proportionate to the text at every size.
const SIZE_TOKENS: Record<ButtonSize, SizeTokens> = {
  large:      { paddingVertical: DS_SPACING[800], paddingHorizontal: DS_SPACING[1200], fontSize: DS_TYPOGRAPHY.labelMd.fontSize, lineHeight: 20, iconSize: 20 },
  medium:     { paddingVertical: DS_SPACING[600], paddingHorizontal: DS_SPACING[800],  fontSize: DS_TYPOGRAPHY.labelSm.fontSize, lineHeight: 18, iconSize: 18 },
  small:      { paddingVertical: DS_SPACING[400], paddingHorizontal: DS_SPACING[800],  fontSize: DS_TYPOGRAPHY.labelXs.fontSize, lineHeight: 16, iconSize: 16 },
  // Below `small` — a compact chrome-level action (e.g. a Tag-adjacent inline control), never the
  // only affordance for a primary action; same touch-target hitSlop safety net as icon-only/ghost.
  extraSmall: { paddingVertical: DS_SPACING[300], paddingHorizontal: DS_SPACING[600],  fontSize: DS_TYPOGRAPHY.labelXs.fontSize, lineHeight: 14, iconSize: 14 },
};

type VariantStyles = { container: ViewStyle; containerPressed: ViewStyle; containerDisabled: ViewStyle; label: TextStyle };

const VARIANT_STYLES: Record<ButtonVariant, VariantStyles> = {
  primary: {
    container: { backgroundColor: DS_SEMANTIC.text.regular },
    containerPressed: { backgroundColor: DS_SEMANTIC.emphasis.neutral },
    containerDisabled: { backgroundColor: DS_SEMANTIC.border.light },
    label: { color: DS_SEMANTIC.text.inverse },
  },
  secondary: {
    container: { backgroundColor: DS_SEMANTIC.surface.recessed },
    // Not DS_SEMANTIC.interaction.pressed/disabledOpacity — this variant's resting background is
    // already the translucent surface.recessed overlay, so its pressed/disabled states are their own
    // tuned darker/lighter versions of that same overlay (recessedPressed/recessedDisabled) rather
    // than a second, independently-chosen overlay stacked on top.
    containerPressed: { backgroundColor: DS_SEMANTIC.surface.recessedPressed },
    containerDisabled: { backgroundColor: DS_SEMANTIC.surface.recessedDisabled },
    label: { color: DS_SEMANTIC.text.regular },
  },
  tertiary: {
    container: { backgroundColor: 'transparent' },
    containerPressed: { backgroundColor: DS_SEMANTIC.interaction.pressed },
    containerDisabled: { backgroundColor: 'transparent' },
    label: { color: DS_SEMANTIC.text.regular },
  },
  white: {
    container: { backgroundColor: DS_SEMANTIC.surface.white },
    containerPressed: { backgroundColor: DS_SEMANTIC.surface.main },
    containerDisabled: { backgroundColor: DS_SEMANTIC.surface.muted },
    label: { color: DS_SEMANTIC.text.regular },
  },
  ghost: {
    container: { backgroundColor: 'transparent' },
    containerPressed: { backgroundColor: DS_SEMANTIC.interaction.pressed },
    containerDisabled: { backgroundColor: 'transparent' },
    label: { color: DS_SEMANTIC.text.regular },
  },
  destructive: {
    container: { backgroundColor: DS_SEMANTIC.shade.negative },
    // A deeper step on the same red ramp `shade.negative` already comes from — not a second,
    // independently-chosen overlay (see `secondary`'s own `recessedPressed` reasoning above).
    containerPressed: { backgroundColor: DS_PALETTE.red[100] },
    containerDisabled: { backgroundColor: DS_SEMANTIC.surface.muted },
    label: { color: DS_SEMANTIC.emphasis.negative },
  },
};

// ─── Press Feedback ───────────────────────────────────────────────────────────
// Standard Press Feedback is the default for every Button: a slight scale response on press,
// suppressed (not merely re-timed) under system Reduce Motion — the resting/pressed background swap
// already below (`variantStyle.containerPressed`) supplies the opacity/color half regardless of
// Reduce Motion. Physical haptics stay a separate, opt-in concern this component does not touch.
const PRESS_SCALE = 0.97;
const PRESS_ANIM_MS = 100;

// Same pattern as Shimmer.tsx/HermesMotionReference.tsx: read the system preference once via
// `AccessibilityInfo.isReduceMotionEnabled()`, then keep it current via `reduceMotionChanged` — no
// new dependency, both calls are the existing `react-native` AccessibilityInfo API.
function useReduceMotion(): boolean {
  const [reduceMotion, setReduceMotion] = useState(false);
  useEffect(() => {
    let mounted = true;
    AccessibilityInfo.isReduceMotionEnabled().then((enabled) => {
      if (mounted) setReduceMotion(enabled);
    });
    const subscription = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotion);
    return () => {
      mounted = false;
      subscription.remove();
    };
  }, []);
  return reduceMotion;
}

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

function ButtonImpl({
  label = 'Button',
  variant = 'primary',
  size = 'large',
  showIcon = false,
  iconName = 'add',
  iconPosition = 'leading',
  showLabel = true,
  onPress,
  disabled = false,
  loading = false,
  fullWidth = false,
  style,
  textStyle,
  testID,
  accessibilityLabel,
}: ButtonProps) {
  const variantStyle = VARIANT_STYLES[variant];
  const isGhost = variant === 'ghost';
  const isIconOnly = showIcon && !showLabel;
  const sizeTokens = SIZE_TOKENS[size];
  const isDisabled = disabled || loading || !onPress;
  // Ghost reads text-first, so its icon is sized to the label's line box rather than the larger standard.
  const renderedIconSize = isGhost ? Math.min(sizeTokens.iconSize, sizeTokens.lineHeight) : sizeTokens.iconSize;
  const iconColor = variant === 'primary'
    ? DS_SEMANTIC.text.inverse
    : variant === 'destructive'
      ? DS_SEMANTIC.emphasis.negative
      : DS_SEMANTIC.text.regular;
  const spinnerColor = iconColor;
  // Match the loader to the resting content height so swapping in the spinner never changes the height.
  const loaderSize = Math.max(showIcon ? sizeTokens.iconSize : 0, showLabel ? sizeTokens.lineHeight : 0) || sizeTokens.iconSize;
  // small/medium icon-only buttons render under the touch-target minimum — pad the tap area out
  // with hitSlop rather than growing the visual button itself.
  const iconOnlyVisualSize = sizeTokens.paddingVertical * 2 + sizeTokens.iconSize;
  const iconOnlyHitSlop = Math.max(0, Math.ceil((DS_A11Y_MIN_TOUCH_TARGET - iconOnlyVisualSize) / 2));
  // Ghost has zero padding (`baseGhost`) — its visual height is just the content's own line box, so
  // every ghost button (label-only or icon-only alike — the icon is itself capped to this same
  // line-box height, see `renderedIconSize` above) needs hitSlop to reach the touch-target minimum,
  // not just the icon-only case the other variants need it for.
  const ghostHitSlop = Math.max(0, Math.ceil((DS_A11Y_MIN_TOUCH_TARGET - sizeTokens.lineHeight) / 2));

  const [focused, setFocused] = useState(false);
  // Tracked as plain state (like `focused` above) rather than read from Pressable's own
  // `style={({ pressed }) => ...}` callback — `Animated.createAnimatedComponent(Pressable)`'s style
  // prop is reserved for animated interpolation, and a function value passed through it isn't invoked
  // on React Native Web, so every style depending on it (background, border, padding/sizing) silently
  // drops out. Deriving `pressed` here instead means `style` below stays a plain array on every
  // platform, sidestepping that gap entirely rather than restructuring into two nested components.
  const [pressed, setPressed] = useState(false);
  const accessibilityState = useMemo(() => ({ disabled: isDisabled, busy: loading }), [isDisabled, loading]);

  const reduceMotion = useReduceMotion();
  const scaleAnim = useRef(new Animated.Value(1)).current;
  const handlePressIn = () => {
    setPressed(true);
    Animated.timing(scaleAnim, {
      toValue: reduceMotion ? 1 : PRESS_SCALE,
      duration: PRESS_ANIM_MS,
      useNativeDriver: Platform.OS !== 'web',
    }).start();
  };
  const handlePressOut = () => {
    setPressed(false);
    Animated.timing(scaleAnim, {
      toValue: 1,
      duration: PRESS_ANIM_MS,
      useNativeDriver: Platform.OS !== 'web',
    }).start();
  };

  const renderInner = () => (
    <View style={[styles.content, isGhost && styles.contentGhost, disabled && styles.contentDisabled]}>
      {showIcon && iconPosition === 'leading' && (
        <Icon name={iconName} size={renderedIconSize} color={iconColor} />
      )}
      {showLabel && (
        <Text
          style={[styles.label, { fontSize: sizeTokens.fontSize, lineHeight: sizeTokens.lineHeight }, variantStyle.label, textStyle]}
        >
          {label}
        </Text>
      )}
      {showIcon && iconPosition === 'trailing' && (
        <Icon name={iconName} size={renderedIconSize} color={iconColor} />
      )}
    </View>
  );

  return (
    <AnimatedPressable
      testID={testID}
      onPress={onPress}
      disabled={isDisabled}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityState={accessibilityState}
      hitSlop={isGhost ? ghostHitSlop : isIconOnly ? iconOnlyHitSlop : undefined}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onPressIn={handlePressIn}
      onPressOut={handlePressOut}
      style={[
        styles.base,
        isGhost ? styles.baseGhost : {
          paddingVertical: sizeTokens.paddingVertical,
          paddingHorizontal: isIconOnly ? sizeTokens.paddingVertical : sizeTokens.paddingHorizontal,
        },
        variantStyle.container,
        fullWidth && styles.fullWidth,
        pressed && !isDisabled && variantStyle.containerPressed,
        isDisabled && !loading && variantStyle.containerDisabled,
        focused && !isDisabled && styles.focused,
        { transform: [{ scale: scaleAnim }] },
        style,
      ]}
    >
      {loading ? <Loading color={spinnerColor} size={loaderSize} /> : renderInner()}
    </AnimatedPressable>
  );
}

/** Skips re-rendering when this button's own props are unchanged. */
export const Button = React.memo(ButtonImpl);

const styles = StyleSheet.create({
  base: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: DS_RADIUS.round,
    borderWidth: 2,
    borderColor: 'transparent',
  },
  baseGhost: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: DS_RADIUS.small,
    borderWidth: 0,
    padding: 0,
  },
  focused: { borderColor: DS_SEMANTIC.interaction.focused },
  fullWidth: { alignSelf: 'stretch' },
  content: { flexDirection: 'row', alignItems: 'center', gap: DS_SPACING[200] },
  contentGhost: { gap: DS_SPACING[100] },
  // Dims the whole content (icon + label together) so an icon-only disabled button is still visibly
  // disabled, not just a disabled button with no label to dim.
  contentDisabled: { opacity: DS_SEMANTIC.interaction.disabledOpacity },
  label: { fontWeight: DS_FONT_WEIGHT.semibold, textAlign: 'center' },
});
