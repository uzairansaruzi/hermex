import React, { type ComponentProps, type ComponentType, type ReactElement, type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AccessibilityInfo, Animated, Easing, StyleSheet, View, type LayoutChangeEvent } from 'react-native';
import { DS_ICON_SIZE, DS_MOTION_DURATION, DS_MOTION_EASING, DS_SEMANTIC, DS_SPACING } from '../../../tokens';
import { AVATAR_SIZE } from '../Avatar';
import { AnimatedChevron } from '../AnimatedChevron';
import { Card } from '../Card';
import { Divider } from '../Divider';
import { ListItem, type ListItemProps } from '../ListItem';

// Same escape-hatch convention as ListItem's own `HiddenView`: `accessibilityElementsHidden`/
// `importantForAccessibility` cover native, but react-native-web has no case for either, so a
// collapsed section's body needs its own explicit `aria-hidden` to leave the web accessibility tree.
const HiddenableView = View as unknown as ComponentType<ComponentProps<typeof View> & { 'aria-hidden'?: boolean }>;

/** Mandatory visual surface — every caller picks explicitly; there is no default. */
export type AccordionListAppearance = 'card' | 'cardless';
/** Mandatory separator policy — every caller picks explicitly; there is no default.
 *  `topAndBottom` surrounds the whole accordion group with no internal dividers. */
export type AccordionListSeparatorStyle = 'none' | 'betweenRows' | 'topAndBottom' | 'all';
/** `single` permits zero or one open item (tapping the open header collapses it); `multiple`
 *  permits any number of open items. */
export type AccordionListExpansionMode = 'single' | 'multiple';

export interface AccordionListHeader {
  title: string;
  description?: string;
  leading: ReactNode;
  titleAccessory?: ReactNode;
  disabled?: boolean;
  accessibilityLabel?: string;
}

export interface AccordionListProps<Section extends { id: string }, Row extends { id: string }> {
  items: readonly Section[];
  /** Mandatory visual surface — there is no default. */
  appearance: 'card' | 'cardless';
  /** Mandatory separator policy — there is no default. `topAndBottom` surrounds the whole
   *  accordion group with no internal dividers. */
  separatorStyle: 'none' | 'betweenRows' | 'topAndBottom' | 'all';
  mode: AccordionListExpansionMode;
  /** Controlled expansion — when provided, `AccordionList` never owns its own expansion state. */
  expandedIds?: readonly string[];
  /** Seeds local (uncontrolled) expansion state. Ignored once `expandedIds` is provided. */
  initialExpandedIds?: readonly string[];
  onExpandedIdsChange?: (ids: string[]) => void;
  getHeader: (section: Section) => AccordionListHeader;
  getBodyItems: (section: Section) => readonly Row[];
  renderBodyItem: (section: Section, row: Row) => ReactElement<ListItemProps, typeof ListItem>;
}

/** A collection-level, data-agnostic composition of expandable `ListItem` groups: one explicit
 *  appearance, one explicit separator policy, single-or-multiple expansion in controlled or
 *  uncontrolled form, and header/body rows rooted in `ListItem`. The whole header toggles
 *  expansion; the chevron is a decorative indicator inside that same press target, never an
 *  independent control. Grows naturally inside whatever container the caller already scrolls
 *  with, never introducing a scrolling container of its own, and understands nothing about the
 *  data its rows represent. */
export function AccordionList<Section extends { id: string }, Row extends { id: string }>({
  items,
  appearance,
  separatorStyle,
  mode,
  expandedIds,
  initialExpandedIds,
  onExpandedIdsChange,
  getHeader,
  getBodyItems,
  renderBodyItem,
}: AccordionListProps<Section, Row>) {
  const validIds = useMemo(() => new Set(items.map((item) => item.id)), [items]);
  const normalize = useCallback(
    (ids: readonly string[]) => {
      const valid = [...new Set(ids)].filter((id) => validIds.has(id));
      return mode === 'single' ? valid.slice(0, 1) : valid;
    },
    [mode, validIds],
  );
  const isControlled = expandedIds !== undefined;
  const [localExpandedIds, setLocalExpandedIds] = useState<string[]>(() =>
    normalize(initialExpandedIds ?? []),
  );
  const resolvedExpandedIds = normalize(expandedIds ?? localExpandedIds);

  useEffect(() => {
    if (!isControlled) {
      setLocalExpandedIds((current) => normalize(current));
    }
  }, [isControlled, normalize]);

  const commitExpandedIds = (next: readonly string[]) => {
    const normalized = normalize(next);
    if (!isControlled) setLocalExpandedIds(normalized);
    onExpandedIdsChange?.(normalized);
  };

  const toggle = (section: Section) => {
    if (getHeader(section).disabled) return;
    const current = new Set(resolvedExpandedIds);
    if (current.has(section.id)) {
      current.delete(section.id);
    } else if (mode === 'single') {
      current.clear();
      current.add(section.id);
    } else {
      current.add(section.id);
    }
    commitExpandedIds([...current]);
  };

  const [reduceMotion, setReduceMotion] = useState(false);

  useEffect(() => {
    let active = true;
    AccessibilityInfo.isReduceMotionEnabled().then((enabled) => {
      if (active) setReduceMotion(enabled);
    });
    const subscription = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotion);
    return () => {
      active = false;
      subscription.remove();
    };
  }, []);

  const showInternal = separatorStyle === 'betweenRows' || separatorStyle === 'all';
  const showOuter = separatorStyle === 'topAndBottom' || separatorStyle === 'all';

  const renderGroupRows = (section: Section) => {
    const header = getHeader(section);
    const hasLeading = header.leading != null;
    const expanded = resolvedExpandedIds.includes(section.id);
    const rows = getBodyItems(section);

    return (
      <>
        <ListItem
          title={header.title}
          description={header.description}
          leading={
            hasLeading ? <View style={styles.headerLeading}>{header.leading}</View> : undefined
          }
          titleAccessory={header.titleAccessory}
          titleRole="label"
          rowIndicator={
            <AnimatedChevron
              expanded={expanded}
              size={DS_ICON_SIZE.md}
              color={DS_SEMANTIC.text.muted}
              duration={reduceMotion ? 0 : DS_MOTION_DURATION.base}
            />
          }
          onPress={() => toggle(section)}
          disabled={header.disabled}
          expanded={expanded}
          accessibilityLabel={header.accessibilityLabel}
          style={appearance === 'cardless' ? styles.transparentRow : undefined}
        />

        {rows.length > 0 && (
          <AccordionGroupBody expanded={expanded} reduceMotion={reduceMotion}>
            {/* The divider directly under the header spans the full available Accordion content
                width (no inset); only dividers *between* body rows align to body text content. */}
            {showInternal && <Divider />}
            {rows.map((row, index) => {
              const renderedRow = renderBodyItem(section, row);
              return (
                <React.Fragment key={row.id}>
                  {React.cloneElement(renderedRow, {
                    style: [
                      hasLeading && styles.bodyRow,
                      appearance === 'cardless' && styles.transparentRow,
                      renderedRow.props.style,
                    ],
                  })}
                  {showInternal && index < rows.length - 1 && (
                    <View
                      style={
                        hasLeading ? styles.bodyDividerInset : styles.bodyDividerInsetNoLeading
                      }
                    >
                      <Divider />
                    </View>
                  )}
                </React.Fragment>
              );
            })}
          </AccordionGroupBody>
        )}
      </>
    );
  };

  return (
    <View style={appearance === 'card' ? styles.cardStack : styles.cardlessStack}>
      {items.map((section, index) => {
        if (appearance === 'card') {
          return (
            <Card key={section.id} surface="outlined" style={styles.cardGroup}>
              {showOuter && <Divider />}
              {renderGroupRows(section)}
              {showOuter && <Divider />}
            </Card>
          );
        }

        return (
          <React.Fragment key={section.id}>
            {showOuter && index === 0 && <Divider />}
            {renderGroupRows(section)}
            {(showOuter || (separatorStyle === 'betweenRows' && index < items.length - 1)) && (
              <Divider />
            )}
          </React.Fragment>
        );
      })}
    </View>
  );
}

/**
 * Animates one section's body (the header-adjacent divider plus its body rows) open/closed by
 * measuring its natural height once, then tweening between 0 and that height — the same
 * measure-once-then-animate technique Banner's own collapsible callout uses, since `LayoutAnimation`
 * is unreliable on Fabric and a total no-op on web (this catalog's own preview target). Renders in
 * normal flow (and thus visible instantly, unanimated) only on the very first pass while already
 * expanded, so opening a still-unmeasured section never flashes empty before its real height is
 * known; every other pass positions the content absolutely so it can self-measure without disturbing
 * layout, then animates `collapseAnim` between 0 and 1.
 */
function AccordionGroupBody({
  expanded,
  reduceMotion,
  children,
}: {
  expanded: boolean;
  reduceMotion: boolean;
  children: ReactNode;
}) {
  const [measuredHeight, setMeasuredHeight] = useState(0);
  const collapseAnim = useRef(new Animated.Value(expanded ? 1 : 0)).current;
  const duration = reduceMotion ? 0 : DS_MOTION_DURATION.base;

  useEffect(() => {
    const anim = Animated.timing(collapseAnim, {
      toValue: expanded ? 1 : 0,
      duration,
      // `standard` — an in-place expand/collapse (a toggle), per DS_MOTION_EASING_USE.
      easing: Easing.bezier(...DS_MOTION_EASING.standard),
      useNativeDriver: false,
    });
    anim.start();
    return () => anim.stop();
  }, [expanded, duration, collapseAnim]);

  const flowMeasure = measuredHeight === 0 && expanded;
  const onLayout = (e: LayoutChangeEvent) => {
    const h = e.nativeEvent.layout.height;
    if (h > 0 && h !== measuredHeight) setMeasuredHeight(h);
  };

  return (
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
      <HiddenableView
        style={flowMeasure ? undefined : styles.collapseAbsolute}
        onLayout={onLayout}
        accessibilityElementsHidden={!expanded}
        importantForAccessibility={expanded ? 'auto' : 'no-hide-descendants'}
        aria-hidden={!expanded}
      >
        {children}
      </HiddenableView>
    </Animated.View>
  );
}

// Shared derived indent: the header's own text column starts after its `headerLeading` avatar-width
// slot plus ListItem's own leading/title gap, and a body row's own indent must land in the same
// place — both align to this one derived value instead of each independently repeating the sum.
const textColumnIndent = AVATAR_SIZE.small + DS_SPACING[600];

const styles = StyleSheet.create({
  cardStack: { gap: DS_SPACING[400] },
  cardlessStack: { gap: 0 },
  // Card (surface="outlined") supplies the border/background/radius; this composition only zeroes
  // Card's own default vertical padding (ListItem rows already own their vertical rhythm via their
  // own paddingVertical) while keeping Card's 16pt horizontal content padding (DS_SPACING[800]).
  cardGroup: {
    overflow: 'hidden',
    paddingVertical: 0,
  },
  transparentRow: { backgroundColor: 'transparent' },
  headerLeading: {
    width: AVATAR_SIZE.small,
    height: AVATAR_SIZE.small,
    alignItems: 'center',
    justifyContent: 'center',
  },
  bodyRow: {
    paddingLeft: textColumnIndent,
  },
  // Where a divider *between* body rows begins: the body row's own leading inset (avatar width +
  // header/body gap) plus ListItem's own horizontal inset (`row.paddingHorizontal`, DS_SPACING[400])
  // — the row's actual text-content column, not its outer frame. A percentage-width child (Divider)
  // sizes against its parent's content box, so insetting via paddingLeft here shrinks the divider to
  // start at that column and still end flush with the row's own right edge.
  bodyDividerInset: {
    paddingLeft: AVATAR_SIZE.small + DS_SPACING[600] + DS_SPACING[400],
  },
  bodyDividerInsetNoLeading: {
    paddingLeft: DS_SPACING[400],
  },
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
