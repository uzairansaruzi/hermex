import type React from 'react';
import type { AccessibilityState, StyleProp, ViewStyle } from 'react-native';

export interface FieldContainerProps {
  /** Focused → border darkens to border.dark. */
  focused?: boolean;
  /** Disabled → washed-out fill, non-interactive. The exact fill adapts to the ambient surface tone
   *  (see FieldContainer.tsx's per-tone StyleSheets). */
  disabled?: boolean;
  /** When set (and not disabled), the container is a Pressable with tap feedback — the pressed fill
   *  adapts to the ambient surface tone (see FieldContainer.tsx). */
  onPress?: () => void;
  /** Caller-driven pressed state — applies the same pressed treatment without an `onPress` Pressable
   *  (e.g. an editable field that drives this from the TextInput's onPressIn/onPressOut). */
  pressed?: boolean;
  accessibilityLabel?: string;
  /** Forwarded to the container (Pressable or plain View) — lets a picker-style consumer announce
   *  `{ disabled, expanded }`. When set (or when `accessibilityLabel` is), even the non-Pressable
   *  branch stays an accessible `button` element, so e.g. a disabled Dropdown still announces as
   *  "…, button, disabled" instead of disappearing from the accessibility tree. */
  accessibilityState?: AccessibilityState;
  /** Layout the consumer adds on top of the shared chrome (height, padding, flex direction…). */
  style?: StyleProp<ViewStyle>;
  children: React.ReactNode;
}
