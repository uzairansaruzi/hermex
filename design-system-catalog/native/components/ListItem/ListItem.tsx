import React, { useState, type ComponentProps, type ComponentType, type ReactNode } from 'react';
import { View, Text, Pressable as RNPressable, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_SPACING, DS_TYPOGRAPHY, DS_A11Y_MIN_TOUCH_TARGET } from '../../../tokens';
import { Loading } from '../Loading';
import { Shimmer, SkeletonGroup } from '../Shimmer';

// `aria-expanded` has no equivalent in React Native's own (native-targeting) Pressable props, and
// react-native-web's own accessibility-prop mapping has no case for `accessibilityState.expanded`
// (unlike disabled/checked/busy/selected) — so it never reaches the DOM on its own. Same narrow,
// explicitly-typed escape hatch as HermesReferenceDetails' own DisclosureTrigger.
const Pressable = RNPressable as unknown as ComponentType<
  ComponentProps<typeof RNPressable> & { 'aria-expanded'?: boolean }
>;

// Same reasoning as above, for the decorative row indicator: `accessibilityElementsHidden`/
// `importantForAccessibility` cover native, but react-native-web has no case for either — an
// explicit `aria-hidden` is needed so a purely decorative indicator (e.g. the accordion chevron)
// can never surface as its own accessibility element in a browser.
const HiddenView = View as unknown as ComponentType<ComponentProps<typeof View> & { 'aria-hidden'?: boolean }>;

export interface ListItemProps {
  title: string;
  /** Small secondary line below the title. Same slot as {@link description}; if both are given,
   *  `description` wins — kept only so existing callers don't need to rename. */
  subtitle?: string;
  /** Preferred name for the secondary line below the title (same slot as `subtitle`). */
  description?: string;
  /** Icon or small custom node placed immediately after the title, on the same line — e.g. a status
   *  dot or an inline Badge that belongs to the title itself rather than the trailing slot. */
  titleAccessory?: ReactNode;
  /** The title's semantic weight. `'label'` reads stronger than the `'body'` default — an
   *  AccordionList header, for instance, next to its `'body'`-weight rows. */
  titleRole?: 'body' | 'label';
  /** A decorative, non-interactive indicator rendered inside the row's own press target — e.g.
   *  AccordionList's chevron. Distinct from {@link trailing}, which sits outside the press target
   *  and stays independently focusable/operable; `rowIndicator` never is. */
  rowIndicator?: ReactNode;
  /** Exposes `accessibilityState.expanded` — e.g. an AccordionList header announcing whether its
   *  body is currently shown. Omit for a row with no expand/collapse behavior. */
  expanded?: boolean;
  /** A third block below the description — for lower-priority extra content (a timestamp, a count,
   *  or a Badge/Button) that shouldn't compete with the description for attention. A plain string
   *  renders in the same small muted style as before; pass a Badge/Button/other node directly for
   *  anything richer. Same slot as {@link metadata}. */
  footer?: ReactNode;
  /** Preferred name for the same third block as `footer` (same slot). If both are given, `metadata`
   *  wins. */
  metadata?: ReactNode;
  /** Leading slot — typically an Avatar or Icon. */
  leading?: ReactNode;
  /** Compact right-aligned value shown before the trailing slot — e.g. a settings row's current
   *  value ("English") ahead of its chevron. */
  trailingText?: string;
  /** A second, more muted right-aligned line below `trailingText` — e.g. a unit or a status caption
   *  under the primary value. Only meaningful alongside `trailingText`. */
  trailingSubtext?: string;
  /** Trailing slot — typically a chevron Icon, a Switch, a Button, or a value label. */
  trailing?: ReactNode;
  /** Makes the whole row tappable. */
  onPress?: () => void;
  disabled?: boolean;
  /** Renders the row's real slots as Shimmer placeholders instead of their content, wrapped in one
   *  {@link SkeletonGroup} so assistive tech announces "Loading" once for the row, not once per
   *  slot. A loading row is never pressable, even when `onPress` is set. */
  loading?: boolean;
  /** Marks the row as the current selection (e.g. a picker row) — exposed as
   *  `accessibilityState.selected`, distinct from `disabled`/`loading`. Purely a state flag; pair it
   *  with your own selected visual (e.g. a trailing checkmark) as the picker configuration does. */
  selected?: boolean;
  /** A row whose action has been taken and is committing (e.g. a just-submitted picker choice) —
   *  renders the row's real title/content, not a Shimmer skeleton, with its own small pending
   *  indicator in the trailing slot. Distinct from {@link loading} (which has no real content yet);
   *  never pressable, even when `onPress` is set. */
  commitPending?: boolean;
  /** Overrides the row's computed accessibility label (title + description) — for a row whose
   *  visible text doesn't fully capture what a screen reader should announce. */
  accessibilityLabel?: string;
  style?: StyleProp<ViewStyle>;
}

/** A single row: optional leading/trailing slots flanking a title (+ optional description/footer).
 *  Stack several inside a {@link List} for a settings screen, menu, or search-results list. */
export function ListItem({
  title,
  subtitle,
  description,
  titleAccessory,
  titleRole = 'body',
  rowIndicator,
  expanded,
  footer,
  metadata,
  leading,
  trailingText,
  trailingSubtext,
  trailing,
  onPress,
  disabled = false,
  loading = false,
  selected = false,
  commitPending = false,
  accessibilityLabel,
  style,
}: ListItemProps) {
  const [focused, setFocused] = useState(false);
  const [pressed, setPressed] = useState(false);
  const resolvedDescription = description ?? subtitle;
  const resolvedFooter = metadata ?? footer;
  const resolvedAccessibilityLabel = accessibilityLabel ?? [title, resolvedDescription].filter(Boolean).join(', ');

  if (loading) {
    return (
      <SkeletonGroup style={[styles.row, styles.rowVerticalSizing, style]} label="Loading">
        {leading && <View style={styles.slot}><Shimmer variant="circle" size={32} /></View>}
        <View style={styles.textGroup}>
          <Shimmer variant="text" width="60%" />
          {resolvedDescription !== undefined && <Shimmer variant="text" width="40%" />}
        </View>
        {(trailingText || trailing) && <Shimmer variant="container" width={48} height={16} />}
      </SkeletonGroup>
    );
  }

  // Never becomes a Shimmer skeleton — the row's real title/content stays visible while its action
  // commits; only a small pending indicator replaces the trailing slot, and the row itself is never
  // pressable while it commits (same as `loading`, but distinct: this state has real content). A
  // merely disabled row stays in this same Pressable branch below — `disabled` is passed straight
  // through to the Pressable itself, so it keeps real button semantics (and cannot activate) instead
  // of being demoted to a plain, non-interactive View.
  const isInteractive = !!onPress && !commitPending;

  const mainContent = (
    <>
      {leading && <View style={styles.slot}>{leading}</View>}
      <View style={styles.textGroup}>
        <View style={styles.titleRow}>
          <Text
            style={[titleRole === 'label' ? styles.titleLabel : styles.title, disabled && styles.disabledText]}
            numberOfLines={1}
          >
            {title}
          </Text>
          {titleAccessory && <View style={styles.titleAccessorySlot}>{titleAccessory}</View>}
        </View>
        {!!resolvedDescription && (
          <Text style={[styles.subtitle, disabled && styles.disabledText]} numberOfLines={1}>{resolvedDescription}</Text>
        )}
        {resolvedFooter != null &&
          (typeof resolvedFooter === 'string' ? (
            <Text style={[styles.footerText, disabled && styles.disabledText]} numberOfLines={1}>{resolvedFooter}</Text>
          ) : (
            <View style={styles.footerNode}>{resolvedFooter}</View>
          ))}
      </View>
      {rowIndicator && (
        <HiddenView
          style={styles.rowIndicator}
          accessible={false}
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
          aria-hidden
        >
          {rowIndicator}
        </HiddenView>
      )}
    </>
  );

  const trailingContent = (trailingText || trailing || commitPending) && (
    <View style={styles.trailingGroup}>
      {!!trailingText && (
        <View style={styles.trailingTextGroup}>
          <Text style={[styles.trailingText, disabled && styles.disabledText]} numberOfLines={1}>{trailingText}</Text>
          {!!trailingSubtext && (
            <Text style={[styles.trailingSubtext, disabled && styles.disabledText]} numberOfLines={1}>{trailingSubtext}</Text>
          )}
        </View>
      )}
      {commitPending ? (
        <View style={styles.slot} accessibilityLabel="Pending">
          <Loading size={16} color={DS_SEMANTIC.text.muted} />
        </View>
      ) : (
        trailing && <View style={styles.slot}>{trailing}</View>
      )}
    </View>
  );

  // The trailing accessory is always its own sibling — never nested inside the row-selecting
  // Pressable below — so it stays independently focusable/operable by touch and VoiceOver alike: an
  // accessible Pressable collapses its subviews into one accessibility element on iOS, which would
  // otherwise swallow a trailing Button/control's own accessibility and hide it from VoiceOver.
  if (isInteractive) {
    return (
      <View style={[styles.row, (pressed || focused) && styles.pressed, commitPending && styles.commitPendingRow, style]}>
        <Pressable
          onPress={onPress}
          disabled={disabled}
          onPressIn={() => setPressed(true)}
          onPressOut={() => setPressed(false)}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          accessibilityRole="button"
          accessibilityLabel={resolvedAccessibilityLabel}
          accessibilityState={{ disabled, selected, expanded }}
          aria-expanded={expanded}
          style={styles.rowMain}
        >
          {mainContent}
        </Pressable>
        {trailingContent}
      </View>
    );
  }

  return (
    <View
      style={[styles.row, styles.rowVerticalSizing, commitPending && styles.commitPendingRow, style]}
      accessible={selected || commitPending || !!accessibilityLabel}
      accessibilityLabel={selected || commitPending || !!accessibilityLabel ? resolvedAccessibilityLabel : undefined}
      accessibilityState={{ disabled, selected, expanded, busy: commitPending }}
    >
      {mainContent}
      {trailingContent}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    width: '100%',
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[600],
    paddingHorizontal: DS_SPACING[400],
    backgroundColor: DS_SEMANTIC.surface.white,
  },
  // The row's own vertical sizing when nothing else owns it: the loading Shimmer skeleton and the
  // non-interactive (no `onPress`, or commit-pending) branch, both of which apply this alongside
  // `row` directly. The interactive branch instead gives this same paddingVertical/minHeight to
  // `rowMain` below, so the Pressable's own hit rectangle matches the full visible row height rather
  // than just its unpadded content.
  rowVerticalSizing: {
    minHeight: DS_A11Y_MIN_TOUCH_TARGET,
    paddingVertical: DS_SPACING[800],
  },
  pressed: {
    backgroundColor: DS_SEMANTIC.interaction.pressed,
  },
  // The row-selecting Pressable itself — lays out leading+text; the trailing accessory sits outside
  // it as a sibling of `row` (see the component body's own comment for why).
  rowMain: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[600],
    minWidth: 0,
    minHeight: DS_A11Y_MIN_TOUCH_TARGET,
    paddingVertical: DS_SPACING[800],
  },
  // A mild, distinct-from-disabled dim while the row's action commits — real content stays visible
  // and legible underneath, unlike the opaque Shimmer skeleton `loading` renders instead.
  commitPendingRow: {
    opacity: 0.7,
  },
  slot: {
    flexShrink: 0,
  },
  textGroup: {
    flex: 1,
    minWidth: 0,
    gap: DS_SPACING[100],
  },
  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[200],
    minWidth: 0,
  },
  titleAccessorySlot: {
    flexShrink: 0,
  },
  title: {
    ...DS_TYPOGRAPHY.bodyMd,
    color: DS_SEMANTIC.text.regular,
    flexShrink: 1,
  },
  titleLabel: {
    ...DS_TYPOGRAPHY.labelMd,
    color: DS_SEMANTIC.text.regular,
    flexShrink: 1,
  },
  rowIndicator: {
    flexShrink: 0,
    alignItems: 'center',
    justifyContent: 'center',
  },
  subtitle: {
    ...DS_TYPOGRAPHY.bodyXs,
    color: DS_SEMANTIC.text.muted,
  },
  footerText: {
    ...DS_TYPOGRAPHY.labelXs,
    color: DS_SEMANTIC.text.muted,
  },
  // A node footer (Badge/Button) brings its own sizing/color — just a top nudge so it doesn't sit
  // flush against subtitle.
  footerNode: {
    marginTop: DS_SPACING[100],
    alignItems: 'flex-start',
  },
  trailingGroup: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: DS_SPACING[300],
    flexShrink: 0,
  },
  trailingTextGroup: {
    alignItems: 'flex-end',
    gap: DS_SPACING[100],
  },
  trailingText: {
    ...DS_TYPOGRAPHY.bodySm,
    color: DS_SEMANTIC.text.muted,
    flexShrink: 1,
  },
  trailingSubtext: {
    ...DS_TYPOGRAPHY.labelXs,
    color: DS_SEMANTIC.text.muted,
    flexShrink: 1,
  },
  // Disabled text — a step lighter than `text.muted` (which the subtitle/footer already use for
  // ordinary secondary text), so a disabled row reads as inactive rather than just secondary —
  // same reasoning as InputField/SearchField (see DS_SEMANTIC.text.disabled's own doc comment).
  disabledText: {
    color: DS_SEMANTIC.text.disabled,
  },
});
