import React, { type ReactNode } from 'react';
import { View, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import { DS_SPACING } from '../../../tokens';
import type { ButtonProps, ButtonVariant } from '../Button';

export type ButtonGroupVariant = 'horizontal' | 'vertical';

export interface ButtonGroupProps {
  /** @default 'horizontal' */
  variant?: ButtonGroupVariant;
  /** Button elements. Horizontal holds up to two; vertical holds up to three. Extra children are dropped. */
  children: ReactNode;
  style?: StyleProp<ViewStyle>;
}

const MAX_BUTTONS: Record<ButtonGroupVariant, number> = { horizontal: 2, vertical: 3 };

// `ghost` reads as a quiet, text-only, link-like action — placed beside a "real" (filled/outlined)
// button it reads as mismatched weight, as if one of the two isn't really a button. Every other
// variant reads as a standalone action of comparable weight, so those are safe to group.
const ALLOWED_VARIANTS: ButtonVariant[] = ['primary', 'secondary', 'tertiary', 'white'];

/** Opt-in-style consistency check (same policy as SectionBlock's own `checkCompleteness`): every
 *  button in a group should read as one family — same variant tier, same size, and either all
 *  icon+label or all label-only, never a mix (a lone icon+label button beside label-only siblings
 *  draws the eye as "the different one" instead of as an equally-weighted option). Warns in the
 *  console rather than throwing, since a mismatch is a design inconsistency to fix, not a crash. */
function checkConsistency(buttons: ReactNode[]): void {
  const props = buttons
    .filter((b): b is React.ReactElement<ButtonProps> => React.isValidElement(b))
    .map((b) => b.props);
  if (props.length < 2) return;

  for (const p of props) {
    if (p.variant && !ALLOWED_VARIANTS.includes(p.variant)) {
      console.warn(
        `[ButtonGroup] "${p.label ?? '(no label)'}" uses variant="${p.variant}" — grouped buttons should use one of ${ALLOWED_VARIANTS.join('/')}, not ${p.variant}.`,
      );
    }
  }

  const sizes = new Set(props.map((p) => p.size ?? 'large'));
  if (sizes.size > 1) {
    console.warn(`[ButtonGroup] Buttons have mismatched sizes (${[...sizes].join(', ')}) — every button in a group should use the same size.`);
  }

  // Keyed on the (showIcon, showLabel) pair, not showIcon alone — an icon-only button
  // (showIcon + showLabel={false}) next to an icon+label one is exactly the visually-mismatched
  // pairing this check exists to catch, and both have showIcon true.
  const configs = new Set(
    props.map((p) => {
      const icon = p.showIcon ?? false;
      const label = p.showLabel ?? true;
      return icon && label ? 'icon+label' : icon ? 'icon-only' : 'label-only';
    }),
  );
  if (configs.size > 1) {
    console.warn(
      `[ButtonGroup] Buttons mix configurations (${[...configs].join(', ')}) — every button in a group should use the same configuration.`,
    );
  }
}

/**
 * Groups Button elements in one of two layouts:
 *  - `horizontal` (default, up to two): auto-width, trailing-aligned — a dialog's Cancel/Confirm pair.
 *  - `vertical` (up to three): stretched full width, stacked — the same layout Dock's own button
 *    area uses.
 * Every button in a group should read as one family: the same variant tier (`primary`/`secondary`/
 * `tertiary`/`white` — never `ghost`, which reads as a different, lower weight), the same size, and
 * either all icon+label or all label-only, never a mix. Dev-console warns if two or more children
 * disagree.
 */
export function ButtonGroup({ variant = 'horizontal', children, style }: ButtonGroupProps) {
  const buttons = React.Children.toArray(children).slice(0, MAX_BUTTONS[variant]);
  checkConsistency(buttons);
  return <View style={[variant === 'vertical' ? styles.vertical : styles.horizontal, style]}>{buttons}</View>;
}

const styles = StyleSheet.create({
  horizontal: { flexDirection: 'row', justifyContent: 'flex-end', gap: DS_SPACING[400] },
  vertical: { flexDirection: 'column', gap: DS_SPACING[400], width: '100%' },
});
