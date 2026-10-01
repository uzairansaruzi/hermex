/**
 * Platform-neutral icon identity + render props.
 *
 * No react-native / DOM imports here on purpose — this module is shared by `Icon.native.tsx` and
 * the data map in `paths.ts`, and stays ready for a future non-native renderer to import too.
 */

/** All icons from the Metro NYC Figma design system. */
export type IconName =
  | 'home'
  | 'briefcase'
  | 'add'
  | 'pencil'
  | 'flag'
  | 'menu'
  | 'pin'
  | 'pin-filled'
  | 'pin-hollow'
  | 'walk'
  | 'clear'
  | 'locate-fixed'
  | 'chevron-down'
  | 'chevron-up'
  | 'chevron-left'
  | 'chevron-right'
  | 'move-up-right'
  | 'footprints'
  | 'paperclip'
  | 'map'
  | 'info'
  | 'bug'
  | 'bell'
  | 'bell-plus'
  | 'search'
  | 'clock'
  | 'skip-forward'
  | 'circle-slash'
  | 'circle-plus'
  | 'circle-check'
  | 'circle-x'
  | 'alert-circle'
  | 'info-circle'
  | 'check'
  | 'thumb-up'
  | 'thumb-down'
  | 'users'
  // Clock face (hour hand at 8) — used by the arrive-by row
  | 'clock-8'
  | 'triangle-alert'
  | 'door-open'
  | 'navigation'
  | 'waypoints'
  // Transit mode icons
  | 'subway'
  | 'train'
  | 'ferry';

/** Shared props consumed by both the native and web `Icon` renderers. */
export interface IconRenderProps {
  name: IconName;
  /** Render size in points/pixels. SVG scales without artifacts (default 16). */
  size?: number;
  /** Override fill/stroke color. Defaults to the design-system regular text color. */
  color?: string;
  /** Override a stroke-mode icon's line weight. Defaults to the icon's own def (usually 2) — bump
   *  it for a bolder look (e.g. Checkbox's checkmark) without needing a second icon definition.
   *  Ignored for fill-mode icons, which have no stroke to widen. */
  strokeWidth?: number;
}
