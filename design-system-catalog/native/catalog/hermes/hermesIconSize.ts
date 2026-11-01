/**
 * Hermex Design System icon-size tokens (foundation-only; no production caller yet).
 *
 * Mirrors `HermesIconSize` (HermesMobile/Config/HermesSpacing.swift): the unchanged five-step base
 * scale, plus the semantic pairing aliases defined alongside it — `HermesIconSize.Typography`
 * (which AppFont.Role text an icon size sits beside inline) and `HermesIconSize.Avatar` (which
 * Avatar diameter an icon size sits inside, at the approved pairing: 32pt avatar → 20pt icon, 40pt
 * avatar → 24pt icon, 48pt avatar → 32pt icon). The canonical icon-size source of truth for this
 * catalog — other modules (e.g. `hermesAttachmentSize.ts`) import from here rather than defining
 * their own icon-size cases.
 */

export const HERMES_ICON_SIZE = {
  xs: 12,
  small: 16,
  medium: 20,
  large: 24,
  extraLarge: 32,
} as const;

export type HermesIconSizeKey = keyof typeof HERMES_ICON_SIZE;

export const HERMES_ICON_TYPOGRAPHY_PAIRING = {
  compact: {
    size: HERMES_ICON_SIZE.xs,
    roles: ['caption', 'footnote', 'caption2', 'mono12'],
  },
  standard: {
    size: HERMES_ICON_SIZE.small,
    roles: ['subheadline', 'subheadlineSemibold', 'mono14', 'body', 'label'],
  },
  prominent: {
    size: HERMES_ICON_SIZE.medium,
    roles: ['headline', 'headlineSemibold', 'title3'],
  },
  title: {
    size: HERMES_ICON_SIZE.large,
    roles: ['title2', 'title'],
  },
  // Standalone feature/empty-state icons, not paired beside inline text.
  feature: {
    size: HERMES_ICON_SIZE.extraLarge,
    roles: [] as string[],
  },
} as const;

export type HermesIconTypographyPairingKey = keyof typeof HERMES_ICON_TYPOGRAPHY_PAIRING;

export const HERMES_ICON_AVATAR_PAIRING = {
  small: { avatar: 32, icon: HERMES_ICON_SIZE.medium },
  medium: { avatar: 40, icon: HERMES_ICON_SIZE.large },
  large: { avatar: 48, icon: HERMES_ICON_SIZE.extraLarge },
} as const;

export type HermesIconAvatarPairingKey = keyof typeof HERMES_ICON_AVATAR_PAIRING;
