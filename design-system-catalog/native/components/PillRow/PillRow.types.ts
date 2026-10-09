import type { ReactNode } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';
import type { PillProps } from '../Pill';

export interface PillRowItem extends Omit<PillProps, 'style'> {
  id: string;
}

export interface PillRowProps {
  pills?: PillRowItem[];
  /** Icon-only add/edit pill at the end of the row. */
  showAddPill?: boolean;
  /** Floor for the content pills' width (px). Excludes the icon-only add pill so it stays circular. */
  minPillWidth?: number;
  onAddPress?: () => void;
  /** Render the add pill in the selected state. */
  addSelected?: boolean;
  style?: StyleProp<ViewStyle>;
  /** Custom trailing content instead of the add pill. */
  trailing?: ReactNode;
}
