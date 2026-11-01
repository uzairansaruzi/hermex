import React from 'react';
import { View, Text, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { Avatar } from '../Avatar';
import { Button } from '../Button';
import { ButtonGroup } from '../ButtonGroup';
import type { IconName } from '../../../icons';
import { DS_SEMANTIC, DS_SPACING, DS_TYPOGRAPHY } from '../../../tokens';

const AVATAR_SIZE = 64;

export interface EmptyStateAction {
  label: string;
  onPress: () => void;
}

export interface EmptyStateProps {
  /** Icon shown above the title, on an Avatar circle. Defaults to `users` — the same generic-person
   *  glyph Avatar's own icon fallback uses, a reasonable default when nothing more specific fits
   *  ("no saved trips", "no results"). Pass a more specific icon when one obviously fits. */
  iconName?: IconName;
  /** Override the avatar circle's fill — same prop, same meaning as Avatar's own `backgroundColor`.
   *  Defaults to Avatar's own default (a neutral muted surface). */
  backgroundColor?: string;
  title: string;
  /** Supporting line below the title — what's empty, or what to do about it. */
  description?: string;
  /** Primary action rendered below the description (e.g. "Start a trip"). */
  action?: EmptyStateAction;
  /** Optional second action, stacked below `action` as a tertiary button (e.g. "Not now"). Only
   *  rendered when `action` is also set — a secondary action with no primary one doesn't make sense. */
  secondaryAction?: EmptyStateAction;
  style?: StyleProp<ViewStyle>;
}

/**
 * A centred placeholder for a screen or section with nothing to show yet — no results, no saved
 * items, a first-run state. An Avatar (icon on a circular fill, not a bare icon — reuses the same
 * component and default styling a real profile picture would use here), title, optional
 * description, optional action(s), always in that order and always centred; for anything more
 * custom (illustrations, more than two actions), compose your own layout instead of extending this
 * one. `action`/`secondaryAction` render through `ButtonGroup`'s `vertical` layout — always `small`
 * size (EmptyState's own actions read as a lighter-weight, secondary moment, never the primary CTA
 * of the screen they sit in) — so the primary/tertiary pair already follows ButtonGroup's own
 * composition rules (matching size, matching label-only configuration) with nothing extra to wire up.
 */
export function EmptyState({ iconName = 'users', backgroundColor, title, description, action, secondaryAction, style }: EmptyStateProps) {
  return (
    <View style={[styles.container, style]}>
      <Avatar iconName={iconName} size={AVATAR_SIZE} backgroundColor={backgroundColor} />
      <Text style={styles.title}>{title}</Text>
      {!!description && <Text style={styles.description}>{description}</Text>}
      {action && (
        <ButtonGroup variant="vertical" style={styles.actionWrap}>
          <Button label={action.label} onPress={action.onPress} size="small" />
          {secondaryAction && <Button variant="tertiary" label={secondaryAction.label} onPress={secondaryAction.onPress} size="small" />}
        </ButtonGroup>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    paddingHorizontal: DS_SPACING[1200],
    paddingVertical: DS_SPACING[2000],
    gap: DS_SPACING[400],
  },
  title: {
    ...DS_TYPOGRAPHY.labelMd,
    color: DS_SEMANTIC.text.regular,
    textAlign: 'center',
    marginTop: DS_SPACING[400],
  },
  description: {
    ...DS_TYPOGRAPHY.bodySm,
    color: DS_SEMANTIC.text.muted,
    textAlign: 'center',
  },
  actionWrap: {
    marginTop: DS_SPACING[400],
    // Overrides ButtonGroup vertical's own default full-width stretch (right for Dock's button bar,
    // wrong here) — EmptyState's actions read as a secondary, content-sized moment, not a bar
    // spanning the whole width.
    alignItems: 'center',
  },
});
