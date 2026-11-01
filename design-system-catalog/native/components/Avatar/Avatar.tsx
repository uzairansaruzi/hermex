import React from 'react';
import { View, Text, Image, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SEMANTIC, DS_FONT_WEIGHT } from '../../../tokens';
import { Icon } from '../../../icons/Icon.native';
import type { IconName } from '../../../icons';

/** Named diameters (px) covering the common cases — pass one of these keys, or a raw number for an
 *  intentional custom size a named step doesn't cover (e.g. a larger hero avatar). Immutable/frozen
 *  so a caller can't mutate a shared step out from under every other consumer. */
export const AVATAR_SIZE = Object.freeze({
  small: 32,
  medium: 40,
  large: 48,
});
export type AvatarSizeName = keyof typeof AVATAR_SIZE;

export interface AvatarProps {
  /** Remote image URL. Takes precedence over `iconName`/`initials`; falls back to them when omitted
   *  or the image fails to load. */
  imageUrl?: string;
  /** Icon shown instead of initials — e.g. for a generic/anonymous avatar. Takes precedence over
   *  `initials` when there's no image. */
  iconName?: IconName;
  /** Shown when there's no image or icon — the first 1-2 characters are used, uppercased. */
  initials?: string;
  /** Diameter — one of the named `AVATAR_SIZE` steps (`'small'` 32 / `'medium'` 40 / `'large'` 48),
   *  or a raw number as an escape hatch for an intentional custom size a named step doesn't cover.
   *  @default 'medium' */
  size?: AvatarSizeName | number;
  /** Icon size override — escape hatch for a production pairing that doesn't follow the default
   *  half-diameter ratio (e.g. HermesAvatar's fixed 32→20/40→24/48→32 icon pairing). Only affects
   *  `iconName` content; has no effect on initials. @default half the resolved diameter, rounded */
  iconSize?: number;
  /** Fill colour behind the icon/initials. Defaults to a neutral muted surface (with dark
   *  foreground); passing a custom colour switches the icon/initials to light (inverse) text,
   *  assuming a saturated/dark fill — match that pairing if you override this. */
  backgroundColor?: string;
  accessibilityLabel?: string;
  style?: StyleProp<ViewStyle>;
}

/** A circular image, icon, or initials fallback on a solid fill — in that order of precedence. */
export function Avatar({
  imageUrl,
  iconName,
  initials,
  size = 'medium',
  iconSize,
  backgroundColor,
  accessibilityLabel,
  style,
}: AvatarProps) {
  const [imageFailed, setImageFailed] = React.useState(false);
  const showImage = !!imageUrl && !imageFailed;
  const showIcon = !showImage && !!iconName;
  const resolvedSize = typeof size === 'number' ? size : AVATAR_SIZE[size];
  const resolvedIconSize = iconSize ?? Math.round(resolvedSize * 0.5);
  const dimension = { width: resolvedSize, height: resolvedSize, borderRadius: resolvedSize / 2 };
  // The default fill (surface.muted) is light, so its icon/initials need dark text; a caller-supplied
  // backgroundColor is assumed saturated/dark (the existing convention — see the "Custom colour"
  // catalog example), so it keeps the light inverse text that pairing needs.
  const contentColor = backgroundColor ? DS_SEMANTIC.text.inverse : DS_SEMANTIC.text.regular;

  return (
    <View
      style={[styles.circle, dimension, !showImage && { backgroundColor: backgroundColor ?? DS_SEMANTIC.surface.muted }, style]}
      accessible
      accessibilityRole="image"
      accessibilityLabel={accessibilityLabel ?? initials}
    >
      {showImage ? (
        <Image source={{ uri: imageUrl }} style={dimension} onError={() => setImageFailed(true)} />
      ) : showIcon ? (
        <Icon name={iconName} size={resolvedIconSize} color={contentColor} />
      ) : (
        <Text style={[styles.initials, { fontSize: Math.round(resolvedSize * 0.4), color: contentColor }]} numberOfLines={1}>
          {(initials ?? '?').slice(0, 2).toUpperCase()}
        </Text>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  circle: {
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  initials: {
    fontWeight: DS_FONT_WEIGHT.semibold,
  },
});
