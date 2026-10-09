import type { StyleProp, ViewStyle } from 'react-native';
import type { IconName } from '../../../icons';

export type BannerVariant = 'neutral' | 'info' | 'positive' | 'warning' | 'negative';

export interface BannerProps {
  variant?: BannerVariant;
  title?: string;
  description?: string;
  /** When true, the header row (title + chevron) toggles the description open/closed. */
  collapsible?: boolean;
  /** Initial expanded state when collapsible. Defaults to true (description shown). */
  defaultExpanded?: boolean;
  /** Override the variant background color. */
  backgroundColor?: string;
  /** Makes the whole banner tappable, with a pressed state — the tap target is the whole card. */
  onPress?: () => void;
  /** Trailing icon in the header, right-aligned (e.g. 'chevron-right'). */
  trailingIcon?: IconName;
  /** Override the icon/text color (defaults to the variant's emphasis color). */
  textColor?: string;
  /** Override the leading icon for the standard callout layout. */
  icon?: IconName;
  /** Inline tappable link appended to the description text. */
  link?: {
    label: string;
    onPress: () => void;
  };
  /** Action button rendered below the description, right-aligned. */
  action?: {
    label: string;
    onPress: () => void;
  };
  style?: StyleProp<ViewStyle>;
}
