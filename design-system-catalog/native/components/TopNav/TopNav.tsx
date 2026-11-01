import React, { isValidElement, type ReactNode } from 'react';
import { View, Text, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_TYPOGRAPHY, DS_A11Y_MIN_TOUCH_TARGET } from '../../../tokens';
import { Button, type ButtonProps } from '../Button';

// Both slots reserve this width whether populated or empty, so the title stays centered
// regardless of which side(s) actually have content.
const SLOT_SIZE = DS_A11Y_MIN_TOUCH_TARGET;

/** Dev-time consistency check (same policy as ButtonGroup's `checkConsistency`) — a nav bar's own
 *  leading/trailing actions read as one quiet, uniform family (back arrow, close, overflow menu),
 *  never as a prominent CTA. Warns (never throws) if a slot's Button doesn't follow that: `small`
 *  size, and not `ghost` (which reads as an inline text action, not a nav icon — see Button's own
 *  variant-choice doc). */
function checkSlotButton(node: ReactNode, slotName: 'leading' | 'trailing'): void {
  if (!isValidElement(node) || node.type !== Button) return;
  const props = node.props as ButtonProps;
  if (props.size && props.size !== 'small') {
    console.warn(`[TopNav] ${slotName} button uses size="${props.size}" — TopNav slot buttons should use size="small".`);
  }
  if (props.variant === 'ghost') {
    console.warn(
      `[TopNav] ${slotName} button uses variant="ghost" — that reads as an inline text action, not a nav icon. Use variant="secondary" (TopNav's default) instead.`,
    );
  }
}

export interface TopNavProps {
  /** Centered title text. Ignored when `center` is set. */
  title?: string;
  /** Custom content overriding the centered title — e.g. a search field or segmented toggle. */
  center?: ReactNode;
  /** @deprecated use `leadingPrimary` — kept as a fallback so existing callers keep working. */
  leading?: ReactNode;
  /** @deprecated use `trailingPrimary` — kept as a fallback so existing callers keep working. */
  trailing?: ReactNode;
  /** The leading side's main action — typically a back/close icon Button. Falls back to `leading`
   *  when omitted. Keep it `size="small"` and `variant="secondary"` (TopNav's default) unless
   *  there's a specific reason to deviate — never `ghost`, which reads as an inline text action
   *  rather than a nav icon. Rendered before `leadingSecondary`, closest to the screen edge. */
  leadingPrimary?: ReactNode;
  /** A second, less prominent leading action (e.g. an inline Edit toggle next to Back). Same
   *  size/variant guidance as `leadingPrimary`. Rendered after it, closer to the title. */
  leadingSecondary?: ReactNode;
  /** The trailing side's main action — typically a Save/Done Button, closest to the screen edge.
   *  Falls back to `trailing` when omitted. Same size/variant guidance as `leadingPrimary`. */
  trailingPrimary?: ReactNode;
  /** A second, less prominent trailing action (e.g. an overflow menu next to Save). Rendered
   *  before `trailingPrimary`, closer to the title. Same size/variant guidance as `leadingPrimary`. */
  trailingSecondary?: ReactNode;
  style?: StyleProp<ViewStyle>;
}

/** A screen's top bar: up to two fixed-width slots on each side (primary + secondary) flanking a
 *  centered title (or custom `center` content). Each side always reserves the same two-slot width
 *  regardless of how many of its slots are actually populated, so the title stays truly centered
 *  whether a screen uses zero, one, or two actions per side. Production renders this anatomy via
 *  native `ToolbarContent`; a simple screen with no custom actions may just use a native navigation
 *  title instead of composing TopNav at all. Bottom/keyboard toolbars are a separate concern, out
 *  of scope for TopNav. */
export function TopNav({
  title,
  center,
  leading,
  trailing,
  leadingPrimary,
  leadingSecondary,
  trailingPrimary,
  trailingSecondary,
  style,
}: TopNavProps) {
  const resolvedLeadingPrimary = leadingPrimary ?? leading;
  const resolvedTrailingPrimary = trailingPrimary ?? trailing;
  checkSlotButton(resolvedLeadingPrimary, 'leading');
  checkSlotButton(leadingSecondary, 'leading');
  checkSlotButton(resolvedTrailingPrimary, 'trailing');
  checkSlotButton(trailingSecondary, 'trailing');
  return (
    <View style={[styles.row, style]}>
      <View style={styles.slotGroup}>
        <View style={styles.slot}>{resolvedLeadingPrimary}</View>
        <View style={styles.slot}>{leadingSecondary}</View>
      </View>
      <View style={styles.center}>
        {center ?? (title != null && (
          <Text style={styles.title} numberOfLines={1} accessibilityRole="header">
            {title}
          </Text>
        ))}
      </View>
      <View style={styles.slotGroup}>
        <View style={styles.slot}>{trailingSecondary}</View>
        <View style={styles.slot}>{resolvedTrailingPrimary}</View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    width: '100%',
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: DS_SPACING[800],
    paddingTop: DS_SPACING[800],
    paddingBottom: DS_SPACING[400],
    backgroundColor: DS_SEMANTIC.surface.white,
  },
  // Always at least two slots wide (primary + secondary) on each side, whether or not both are
  // populated — same reasoning as the single-slot version this replaces: a symmetric reserved
  // minimum width on both sides keeps the centered title/`center` content truly centered whenever
  // both sides use same-width (typically icon-only) content. `minWidth`, not `width`, so a wider
  // labeled action (e.g. a modal's "Cancel"/"Save" text Button) can still grow past the minimum
  // instead of being clipped to a fixed icon-sized box.
  slotGroup: { flexDirection: 'row', minWidth: SLOT_SIZE * 2 },
  slot: { minWidth: SLOT_SIZE, minHeight: SLOT_SIZE, alignItems: 'center', justifyContent: 'center' },
  center: { flex: 1, alignItems: 'center' },
  title: { ...DS_TYPOGRAPHY.labelMd, color: DS_SEMANTIC.text.regular },
});
