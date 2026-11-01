/**
 * The shared Details inspector (DSR3-03) — a right-edge overlay panel, `600px` wide on desktop and
 * full width below `CATALOG_NARROW_BREAKPOINT`, that never pushes or reflows the main canvas beside
 * it. `CatalogShell` owns one instance and one selected-section state; `SectionBlock`'s per-section
 * `Details` button (the inspector's only entry point) opens it with that section's flattened
 * `HermesReferenceDetails` content as `children`. This component owns only the overlay shell itself:
 * backdrop, visible close control, Escape/backdrop/close dismissal, initial heading focus, a Tab
 * focus trap while open, and restoring focus to the triggering `Details` button on close.
 * `CatalogShell` separately makes the underlying catalog pointer-inert and accessibility-hidden while
 * `visible` — see its own comment — since this component has no reference to that sibling content.
 * A plain absolutely-positioned overlay (the same convention `Dialog`/`BottomSheet` already use
 * elsewhere in this repo, never React Native's own built-in portal), one flat vertical reading flow
 * with no internal tab strip, no nested drawer, and no new dependency.
 */
import React, { useEffect, useRef, useState, type ComponentPropsWithRef, type ComponentType } from 'react';
import { AccessibilityInfo, Animated, Easing, Platform, Pressable, ScrollView, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { DS_MOTION_DURATION, DS_MOTION_EASING } from '../../tokens';
import { CATALOG_COLOR, CATALOG_NARROW_BREAKPOINT, CATALOG_RADIUS, CATALOG_SPACE, CATALOG_TYPE } from './tokens';

/** Desktop panel width (DSR3-03) — falls back to the full viewport width once it can no longer be
 *  preserved beside the main canvas, at the same shared breakpoint every other catalog layout switch
 *  uses (`CATALOG_NARROW_BREAKPOINT`). */
const INSPECTOR_MAX_WIDTH = 600;

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

// `role`/`aria-modal`/`tabIndex` have no equivalent in React Native's own (native-targeting) View/
// Pressable prop types, and react-native-web's own accessibility-prop mapping has no case for them
// either — same narrow, explicitly-typed escape hatch as CatalogSidebar's own `aria-current` cast and
// HermesReferenceDetails' own `aria-expanded` cast.
const ModalView = View as unknown as ComponentType<ComponentPropsWithRef<typeof View> & { role?: string; 'aria-modal'?: boolean }>;
const FocusableView = View as unknown as ComponentType<ComponentPropsWithRef<typeof View> & { tabIndex?: number }>;

// The handful of interactive element kinds this catalog's own Details content ever renders (plain-
// text buttons/links) — enough to correctly find the panel's first/last focusable element for the
// Tab trap without reaching for a third-party focus-trap dependency.
const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), [role="button"]:not([aria-disabled="true"]), input:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

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

export interface CatalogDetailsInspectorProps {
  visible: boolean;
  title: string;
  onDismiss: () => void;
  children: React.ReactNode;
}

export function CatalogDetailsInspector({ visible, title, onDismiss, children }: CatalogDetailsInspectorProps) {
  const { width } = useWindowDimensions();
  const isNarrow = width < CATALOG_NARROW_BREAKPOINT;
  const reduceMotion = useReduceMotion();
  const progress = useRef(new Animated.Value(0)).current;
  const [mounted, setMounted] = useState(visible);
  const panelRef = useRef<View>(null);
  const headingRef = useRef<View>(null);
  const previouslyFocused = useRef<{ focus?: () => void } | null>(null);

  useEffect(() => {
    if (visible) setMounted(true);
  }, [visible]);

  useEffect(() => {
    if (!mounted) return;
    const anim = Animated.timing(progress, {
      toValue: visible ? 1 : 0,
      duration: reduceMotion ? 0 : visible ? DS_MOTION_DURATION.base : DS_MOTION_DURATION.fast,
      // `decelerate` entering, `accelerate` exiting — the same overlay-enter/exit convention
      // Dialog.tsx already uses for its own centered card.
      easing: Easing.bezier(...(visible ? DS_MOTION_EASING.decelerate : DS_MOTION_EASING.accelerate)),
      useNativeDriver: false,
    });
    anim.start(({ finished }) => {
      if (finished && !visible) setMounted(false);
    });
    return () => anim.stop();
  }, [visible, mounted, progress, reduceMotion]);

  useEffect(() => {
    if (visible || !mounted) return;
    const exitDuration = reduceMotion ? 0 : DS_MOTION_DURATION.fast;
    const timeout = setTimeout(() => setMounted(false), exitDuration);
    return () => clearTimeout(timeout);
  }, [visible, mounted, reduceMotion]);

  // Focus save/restore, initial heading focus, Tab trap, and Escape — web only. Native has no
  // keyboard-focus/Escape concept equivalent to a browser modal; the panel still mounts, animates,
  // and dismisses correctly there without this effect ever running.
  useEffect(() => {
    if (!visible || !mounted || Platform.OS !== 'web' || typeof document === 'undefined') return;

    previouslyFocused.current = document.activeElement as unknown as { focus?: () => void } | null;
    // react-native-web forwards a plain View's ref directly to its underlying DOM node.
    (headingRef.current as unknown as HTMLElement | null)?.focus?.();

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        onDismiss();
        return;
      }
      if (event.key !== 'Tab') return;
      const panelNode = panelRef.current as unknown as HTMLElement | null;
      if (!panelNode) return;
      const focusable = Array.from(panelNode.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR));
      if (focusable.length === 0) {
        event.preventDefault();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement as HTMLElement | null;
      // The programmatically focused heading (tabIndex -1, initial focus above) is never part of
      // this list, and focus can otherwise sit outside it entirely — redirect Tab/Shift+Tab back
      // into the panel instead of letting the browser's natural DOM-order traversal escape it.
      if (!active || !focusable.includes(active)) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
        return;
      }
      if (event.shiftKey && active === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener('keydown', handleKeyDown);
    return () => {
      document.removeEventListener('keydown', handleKeyDown);
      previouslyFocused.current?.focus?.();
    };
  }, [visible, mounted, onDismiss]);

  if (!mounted) return null;

  // Normal motion slides the panel in from the trailing edge while it fades; Reduce Motion drops the
  // spatial slide entirely and keeps only the opacity change.
  const translateX = progress.interpolate({ inputRange: [0, 1], outputRange: [32, 0] });

  return (
    <View style={styles.root} pointerEvents={visible ? 'auto' : 'none'}>
      <AnimatedPressable
        style={[styles.backdrop, { opacity: progress }]}
        onPress={onDismiss}
        accessibilityRole="button"
        accessibilityLabel="Dismiss"
      />
      <Animated.View
        ref={panelRef}
        style={[styles.panel, isNarrow && styles.panelNarrow, { opacity: progress, transform: reduceMotion ? [] : [{ translateX }] }]}
        accessibilityViewIsModal
      >
        <ModalView style={styles.modalRoot} role="dialog" aria-modal>
          <View style={styles.header}>
            <FocusableView ref={headingRef} tabIndex={-1} accessibilityRole="header" style={styles.headingWrap}>
              <Text style={styles.title}>{title}</Text>
            </FocusableView>
            <Pressable
              onPress={onDismiss}
              accessibilityRole="button"
              accessibilityLabel="Close"
              style={({ pressed }) => [styles.closeButton, pressed && styles.closeButtonPressed]}
            >
              <Text style={styles.closeGlyph}>×</Text>
            </Pressable>
          </View>
          <ScrollView style={styles.body} contentContainerStyle={styles.bodyContent} showsVerticalScrollIndicator={false}>
            {children}
          </ScrollView>
        </ModalView>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  // Fills whatever positioned ancestor CatalogShell renders it in (a sibling of the sidebar/main
  // ScrollView) — React Native's own layout gives every View a default relative position, so this
  // absolute fill is scoped to that ancestor without CatalogShell needing an explicit
  // `position: 'relative'` override of its own.
  root: { ...StyleSheet.absoluteFill, flexDirection: 'row', justifyContent: 'flex-end', overflow: 'hidden', zIndex: 20 },
  backdrop: { ...StyleSheet.absoluteFill, backgroundColor: 'rgba(0,0,0,0.32)' },
  panel: {
    width: '100%',
    maxWidth: INSPECTOR_MAX_WIDTH,
    height: '100%',
    backgroundColor: CATALOG_COLOR.surface,
  },
  panelNarrow: { maxWidth: '100%' },
  modalRoot: { flex: 1 },
  header: {
    flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between',
    gap: CATALOG_SPACE.lg, padding: CATALOG_SPACE.xl,
    borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: CATALOG_COLOR.borderHairline,
  },
  headingWrap: { flex: 1, minWidth: 0 },
  title: { fontSize: CATALOG_TYPE.xl, fontWeight: '700', color: CATALOG_COLOR.text },
  closeButton: {
    flexShrink: 0, width: 32, height: 32, borderRadius: CATALOG_RADIUS.sm,
    alignItems: 'center', justifyContent: 'center', backgroundColor: CATALOG_COLOR.surfaceMuted,
  },
  closeButtonPressed: { backgroundColor: CATALOG_COLOR.surfacePressed },
  closeGlyph: { fontSize: CATALOG_TYPE.xl, color: CATALOG_COLOR.textMuted },
  body: { flex: 1 },
  bodyContent: { padding: CATALOG_SPACE.xl },
});
