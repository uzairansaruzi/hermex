import React, { createContext, type ReactNode, isValidElement, cloneElement, useContext, useEffect, useRef, useState } from 'react';
import { View, Pressable, ScrollView, Animated, Easing, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_RADIUS, DS_SHADOW, DS_SPACING, DS_MOTION_DURATION, DS_MOTION_EASING } from '../../../tokens';
import { Dock, type DockProps } from '../Dock';

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);
const MAX_HEIGHT_PERCENT = '90%';

/** True while rendering inside an already-open BottomSheet's tree (header/children/footer alike).
 *  Any component that opens its OWN BottomSheet (e.g. Dropdown) reads this via
 *  `useInsideBottomSheetWarning` to dev-warn against stacking two sheets — a sheet already covers
 *  the whole screen, so a second one has nowhere sensible to appear and just traps the user between
 *  two backdrops. Defaults to `false` for anything rendered outside a BottomSheet entirely. */
const BottomSheetContext = createContext(false);

/** Call this from a component that opens its own BottomSheet (Dropdown, another picker, …) — warns
 *  once per render if it's currently nested inside a different, already-open BottomSheet. Console
 *  warning only (never throws), matching this codebase's other dev-time consistency checks (e.g.
 *  ButtonGroup's `checkConsistency`). */
export function useInsideBottomSheetWarning(componentName: string): void {
  const insideBottomSheet = useContext(BottomSheetContext);
  if (insideBottomSheet) {
    console.warn(
      `[${componentName}] is opening a BottomSheet from inside another, already-open BottomSheet. Never stack two sheets — restructure so ${componentName} lives outside the outer sheet (e.g. in the screen that opens it), or replace it with an inline control (e.g. SegmentedToggle/Radio) for use inside a sheet.`,
    );
  }
}

export interface BottomSheetProps {
  /** Whether the sheet (and its backdrop) are mounted and shown. */
  visible: boolean;
  /** Called when the backdrop is tapped — the sheet doesn't close itself; the caller decides. */
  onDismiss: () => void;
  /** Top area — typically a TopNav with a close/back action. */
  header?: ReactNode;
  /** Middle content area. Grows with its content up to 90% of the available height, then scrolls. */
  children: ReactNode;
  /** Bottom area — typically a Dock with the sheet's primary actions. When `footer` is a Dock
   *  element, its `elevated` prop is driven automatically from whether the content area above it
   *  actually overflows (needs to scroll) — no need to pass `elevated` yourself. */
  footer?: ReactNode;
  style?: StyleProp<ViewStyle>;
}

/**
 * A sheet that slides up from the bottom over a dismissible backdrop. Height is driven by its
 * content (not a fixed set of snap points) up to a cap, past which the content area scrolls. Not
 * portaled through RN's `Modal` — it's a plain absolutely-positioned overlay, so it fills whichever
 * parent View hosts it (RN Views are positioning contexts by default), which also lets the catalog
 * contain a live demo inside a bounded preview frame instead of covering the whole page.
 */
export function BottomSheet({ visible, onDismiss, header, children, footer, style }: BottomSheetProps) {
  const progress = useRef(new Animated.Value(0)).current;
  const [mounted, setMounted] = useState(visible);
  // The sheet's own rendered height, measured via onLayout — its closed position is "translated
  // down by exactly its own height" (fully below the visible area), not a small fixed nudge, so the
  // motion genuinely reads as sliding in from off-screen regardless of how tall the content is.
  // Falls back to a generous guess before the first measurement lands, to avoid a jump on first open.
  const [sheetHeight, setSheetHeight] = useState(0);
  // Drives a Dock footer's `elevated` shadow: on only once the content area's actual measured
  // height exceeds what it's laid out to show, i.e. it's genuinely scrollable — not just "there is
  // a Dock", so a short sheet stays flat and only a scrolling one gets the separating shadow.
  const [scrollLayoutHeight, setScrollLayoutHeight] = useState(0);
  const [scrollContentHeight, setScrollContentHeight] = useState(0);
  const contentOverflows = scrollContentHeight > scrollLayoutHeight + 1;

  useEffect(() => {
    if (visible) setMounted(true);
    // Backdrop opacity still fades (a scrim has no position to slide from); the sheet itself only
    // ever moves via translateY below — no opacity animation on the sheet, just the slide.
    const anim = Animated.timing(progress, {
      toValue: visible ? 1 : 0,
      duration: visible ? DS_MOTION_DURATION.base : DS_MOTION_DURATION.fast,
      // `decelerate` — a sheet entering the screen, per DS_MOTION_EASING_USE (previously left on
      // RN's default in-out ease, the one enter/exit overlay without an explicit curve).
      easing: Easing.bezier(...DS_MOTION_EASING.decelerate),
      useNativeDriver: false,
    });
    anim.start(({ finished }) => {
      if (finished && !visible) setMounted(false);
    });
    return () => anim.stop();
  }, [visible, progress]);

  if (!mounted) return null;

  const translateY = progress.interpolate({ inputRange: [0, 1], outputRange: [sheetHeight || 400, 0] });

  const resolvedFooter =
    isValidElement(footer) && footer.type === Dock
      ? cloneElement(footer as React.ReactElement<DockProps>, { elevated: contentOverflows })
      : footer;

  return (
    <View style={styles.overlay} pointerEvents={visible ? 'auto' : 'none'}>
      <AnimatedPressable
        style={[styles.backdrop, { opacity: progress }]}
        onPress={onDismiss}
        accessibilityRole="button"
        accessibilityLabel="Dismiss"
      />
      <Animated.View
        onLayout={(e) => setSheetHeight(e.nativeEvent.layout.height)}
        style={[styles.sheet, style, { transform: [{ translateY }] }]}
        // Contain assistive-tech focus while open (iOS) — without this, content behind the scrim
        // stays reachable by screen readers even though it's visually blocked.
        accessibilityViewIsModal
      >
        <View style={styles.handle} />
        <BottomSheetContext.Provider value>
          {header}
          <ScrollView
            style={styles.content}
            contentContainerStyle={styles.contentContainer}
            bounces={false}
            onLayout={(e) => setScrollLayoutHeight(e.nativeEvent.layout.height)}
            onContentSizeChange={(_width, height) => setScrollContentHeight(height)}
          >
            {children}
          </ScrollView>
          {resolvedFooter}
        </BottomSheetContext.Provider>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  overlay: { ...StyleSheet.absoluteFill, justifyContent: 'flex-end' },
  backdrop: { ...StyleSheet.absoluteFill, backgroundColor: DS_SEMANTIC.element.overlayBackdrop },
  sheet: {
    maxHeight: MAX_HEIGHT_PERCENT,
    backgroundColor: DS_SEMANTIC.surface.white,
    borderTopLeftRadius: DS_RADIUS.large,
    borderTopRightRadius: DS_RADIUS.large,
    ...DS_SHADOW.bottomSheet,
  },
  // Purely a visual affordance (this sheet has no drag-to-dismiss gesture wired up) — signals "you
  // can swipe this" the same way native sheets do, sized to the common ~36×4 grabber convention.
  handle: {
    alignSelf: 'center',
    width: 36,
    height: 4,
    borderRadius: DS_RADIUS.round,
    backgroundColor: DS_SEMANTIC.border.light,
    marginTop: DS_SPACING[300],
    marginBottom: DS_SPACING[100],
  },
  content: { flexGrow: 0 },
  contentContainer: { padding: DS_SPACING[800] },
});
