import React, { type ReactNode, useEffect, useRef, useState } from 'react';
import { View, Pressable, Animated, Easing, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_RADIUS, DS_SHADOW, DS_MOTION_DURATION, DS_MOTION_EASING } from '../../../tokens';

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

export interface DialogProps {
  /** Whether the dialog (and its backdrop) are mounted and shown. */
  visible: boolean;
  /** Called when the backdrop is tapped — the dialog doesn't close itself; the caller decides. */
  onDismiss: () => void;
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
}

/**
 * A card centred on screen over a dismissible backdrop — fades and scales in, distinct from
 * {@link BottomSheet}'s bottom-anchored slide. Named `Dialog` (not `Modal`) to avoid shadowing React
 * Native's own built-in `Modal`. Like BottomSheet, not portaled through RN's `Modal` — a plain
 * absolutely-positioned overlay that fills whichever parent View hosts it.
 */
export function Dialog({ visible, onDismiss, children, style }: DialogProps) {
  const progress = useRef(new Animated.Value(0)).current;
  const [mounted, setMounted] = useState(visible);

  useEffect(() => {
    if (visible) setMounted(true);
    const anim = Animated.timing(progress, {
      toValue: visible ? 1 : 0,
      duration: visible ? DS_MOTION_DURATION.base : DS_MOTION_DURATION.fast,
      // `decelerate` — something entering the screen, per DS_MOTION_EASING_USE.
      easing: Easing.bezier(...DS_MOTION_EASING.decelerate),
      useNativeDriver: false,
    });
    anim.start(({ finished }) => {
      if (finished && !visible) setMounted(false);
    });
    return () => anim.stop();
  }, [visible, progress]);

  if (!mounted) return null;

  const scale = progress.interpolate({ inputRange: [0, 1], outputRange: [0.92, 1] });

  return (
    <View style={styles.overlay} pointerEvents={visible ? 'auto' : 'none'}>
      <AnimatedPressable
        style={[styles.backdrop, { opacity: progress }]}
        onPress={onDismiss}
        accessibilityRole="button"
        accessibilityLabel="Dismiss"
      />
      <Animated.View
        style={[styles.card, style, { opacity: progress, transform: [{ scale }] }]}
        // Contain assistive-tech focus while open (iOS) — without this, content behind the scrim
        // stays reachable by screen readers even though it's visually blocked.
        accessibilityViewIsModal
      >
        {children}
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  overlay: {
    ...StyleSheet.absoluteFill,
    alignItems: 'center',
    justifyContent: 'center',
    padding: DS_SPACING[800],
  },
  backdrop: { ...StyleSheet.absoluteFill, backgroundColor: DS_SEMANTIC.element.overlayBackdrop },
  card: {
    width: '100%',
    maxWidth: 400,
    backgroundColor: DS_SEMANTIC.surface.white,
    borderRadius: DS_RADIUS.large,
    padding: DS_SPACING[800],
    ...DS_SHADOW.card,
  },
});
