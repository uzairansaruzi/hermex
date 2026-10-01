import type { StyleProp, ViewStyle, TextStyle } from 'react-native';
import type { IconName } from '../../../icons';

/** Which one this is in its screen/modal/sheet — a decision about the action's importance, not
 *  just a visual pick:
 *  - `primary` — *the* primary action to take on this surface (the one thing it wants you to do).
 *    Only one per screen/modal/sheet.
 *  - `secondary` — worth considering in context, but not the primary action.
 *  - `tertiary` — fine if the user never notices it; a low-stakes, easy-to-skip action.
 *  - `white` — the same weight/role as `primary`, for a dark or photo background instead of a
 *    light one (never mix the two — pick whichever reads on the surface behind it).
 *  - `ghost` — for an action inline within a large, word-heavy area (body text, a toast's "Undo") —
 *    not a nav-bar icon or a standalone CTA; see TopNav's own leading/trailing slot guidance
 *    (`size="small"`, `variant="secondary"` by default) for that case instead.
 *  - `destructive` — an action that deletes or irreversibly changes something (never `primary`'s
 *    weight for that, even when it's the main action on the surface) — a decision/confirmation
 *    dialog's "Delete"/"Remove" button, not a plain destructive-flavored nav action. */
export type ButtonVariant = 'primary' | 'secondary' | 'tertiary' | 'white' | 'ghost' | 'destructive';
export type ButtonSize = 'large' | 'medium' | 'small' | 'extraSmall';
export type ButtonIconPosition = 'leading' | 'trailing';

export interface ButtonProps {
  label?: string;
  variant?: ButtonVariant;
  size?: ButtonSize;
  /** Show the icon named by `iconName`. */
  showIcon?: boolean;
  iconName?: IconName;
  iconPosition?: ButtonIconPosition;
  /** Hide the label (with showIcon) for an icon-only, square button. */
  showLabel?: boolean;
  onPress?: () => void;
  disabled?: boolean;
  /** Swaps the label for a spinner and disables presses. Turn on right after the tap that
   *  triggered it, for as long as the background task it kicked off is still running — not a
   *  general "busy" flag unrelated to a real in-flight action following this exact tap. */
  loading?: boolean;
  /** Stretch to fill the available width. Use for the main CTA(s) pinned to the bottom of a
   *  screen/modal/sheet (e.g. inside a Dock); leave off (the default, dynamic/content-hugging
   *  width) for a button placed within surrounding context — a card, a row, inline actions. */
  fullWidth?: boolean;
  style?: StyleProp<ViewStyle>;
  textStyle?: StyleProp<TextStyle>;
  testID?: string;
  accessibilityLabel?: string;
}
