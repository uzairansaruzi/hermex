import type { ReactNode } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';
import type { IconName } from '../../../icons';

/** Selection state of the pill. */
export type PillVariant = 'selected' | 'not_selected';

export interface PillProps {
  label?: string;
  variant?: PillVariant;
  /** Screen-reader name. Strongly recommended for an icon-only pill (`showText={false}`) — it is not
   *  enforced, so omitting it means the placeholder `label` default gets announced instead. Defaults
   *  to `label` for text pills. */
  accessibilityLabel?: string;
  /** Hide the label for an icon-only pill. */
  showText?: boolean;
  /** Renders in the inverse/regular color based on selection (preferred over `icon`). */
  iconName?: IconName;
  /** Render size for `iconName` (default 16). */
  iconSize?: number;
  /** Custom leading node — sizes naturally; takes precedence over the default menu icon. */
  icon?: ReactNode;
  onPress?: () => void;
  disabled?: boolean;
  loading?: boolean;
  style?: StyleProp<ViewStyle>;
}
