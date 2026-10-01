/**
 * Platform-neutral icon DATA — no JSX, no react-native, no DOM.
 *
 * Every icon from the Metro NYC design system transcribed as a plain primitive list, kept separate
 * from any renderer on purpose: `Icon.native.tsx` (react-native-svg) consumes it today, and a future
 * `Icon.web.tsx` (DOM `<svg>`) or other platform renderer can consume the same data with zero
 * changes here — see the "porting to another platform" note in the repo README. Path `d` strings are
 * copied verbatim from the original components.
 *
 * Most icons are Lucide-style: a 24×24 viewBox, stroke-only, round caps/joins, default
 * strokeWidth 2. Exceptions carry `mode: 'fill'` (see MODE FILL below).
 */
import type { IconName } from './types';

export interface IconPrimitive {
  tag: 'path' | 'rect' | 'circle' | 'line' | 'polyline' | 'polygon';
  d?: string;
  points?: string;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  rx?: number;
  ry?: number;
  cx?: number;
  cy?: number;
  r?: number;
  x1?: number;
  y1?: number;
  x2?: number;
  y2?: number;
  /**
   * Optional per-primitive extensions — only used by the transit icons (subway/train/ferry),
   * which come from translated groups and mix fill/stroke, and by fill icons that need an
   * even-odd rule. Plain Lucide primitives omit all of these and inherit the def-level mode.
   */
  translateX?: number;
  translateY?: number;
  /** `'color'` → resolved icon color, `'none'` → no fill. Overrides the def mode when present. */
  fill?: 'color' | 'none';
  /** `'color'` → resolved icon color, `'none'` → no stroke. Overrides the def mode when present. */
  stroke?: 'color' | 'none';
  /** Per-primitive stroke width (transit hairlines). Falls back to the def strokeWidth. */
  strokeWidth?: number;
  fillRule?: 'evenodd' | 'nonzero';
}

export interface IconDef {
  viewBox: string; // e.g. '0 0 24 24' (or '0 0 16 16' for the transit icons)
  mode: 'stroke' | 'fill'; // stroke = Lucide style; fill = solid
  strokeWidth?: number; // only for mode:'stroke', default 2
  primitives: IconPrimitive[];
}

export const ICON_PATHS: Record<IconName, IconDef> = {
  // ─── Briefcase (Icons 2: briefcase-business) ──────────────────────────────
  briefcase: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M12 12h.01' },
      { tag: 'path', d: 'M16 6V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v2' },
      { tag: 'path', d: 'M22 13a18.15 18.15 0 0 1-20 0' },
      { tag: 'rect', width: 20, height: 14, x: 2, y: 6, rx: 2 },
    ],
  },

  // ─── Home (Icons 2: house) ────────────────────────────────────────────────
  home: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8' },
      {
        tag: 'path',
        d: 'M3 10a2 2 0 0 1 .709-1.528l7-6a2 2 0 0 1 2.582 0l7 6A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
      },
    ],
  },

  // ─── Add (Icons 2: plus) ──────────────────────────────────────────────────
  add: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M5 12h14' },
      { tag: 'path', d: 'M12 5v14' },
    ],
  },

  // ─── Pencil (Icons 2: pencil) ─────────────────────────────────────────────
  pencil: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      {
        tag: 'path',
        d: 'M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z',
      },
      { tag: 'path', d: 'm15 5 4 4' },
    ],
  },

  // ─── Flag (Icons 2: flag-triangle-right) ──────────────────────────────────
  flag: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M6 22V2.8a.8.8 0 0 1 1.17-.71l11.38 5.69a.8.8 0 0 1 0 1.44L6 15.5' },
    ],
  },

  // ─── Menu (Icons 2: menu) ─────────────────────────────────────────────────
  menu: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M4 5h16' },
      { tag: 'path', d: 'M4 12h16' },
      { tag: 'path', d: 'M4 19h16' },
    ],
  },

  // ─── Pin (Icons 2: pin — thumbtack/pushpin) ───────────────────────────────
  pin: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M12 17v5' },
      {
        tag: 'path',
        d: 'M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z',
      },
    ],
  },

  // ─── Pin Filled (Icons 2: map-pin filled) ─────────────────────────────────
  // MODE FILL — teardrop + dot as one even-odd path so the centre reads as a true cut-out.
  'pin-filled': {
    viewBox: '0 0 24 24',
    mode: 'fill',
    primitives: [
      {
        tag: 'path',
        fillRule: 'evenodd',
        d: 'M12.601 21.799C14.461 20.193 20 14.993 20 10C20 7.87827 19.1571 5.84344 17.6569 4.34315C16.1566 2.84285 14.1217 2 12 2C9.87827 2 7.84344 2.84285 6.34315 4.34315C4.84285 5.84344 4 7.87827 4 10C4 14.993 9.539 20.193 11.399 21.799C11.5723 21.9293 11.7832 21.9998 12 21.9998C12.2168 21.9998 12.4277 21.9293 12.601 21.799Z M12 13C13.6569 13 15 11.6569 15 10C15 8.34315 13.6569 7 12 7C10.3431 7 9 8.34315 9 10C9 11.6569 10.3431 13 12 13Z',
      },
    ],
  },

  // ─── Pin Hollow (Icons 2: map-pin) ────────────────────────────────────────
  'pin-hollow': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      {
        tag: 'path',
        d: 'M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0',
      },
      { tag: 'circle', cx: 12, cy: 10, r: 3 },
    ],
  },

  // ─── Walk (original 24×24 Figma export) ───────────────────────────────────
  // MODE FILL — solid figure, no Icons 2 equivalent.
  walk: {
    viewBox: '0 0 24 24',
    mode: 'fill',
    primitives: [
      {
        tag: 'path',
        d: 'M4.21517 20.6253C3.84172 20.1268 3.96689 19.4336 4.4937 19.0828L7.37241 17.1657C7.61687 17.0029 7.78582 16.7563 7.8439 16.4775L9.04635 10.7062C9.17493 10.0891 8.48889 9.60967 7.91006 9.91224C7.70164 10.0211 7.55697 10.215 7.51734 10.4384L7.08263 12.8893C7.00334 13.3362 6.59711 13.6635 6.12142 13.6635C5.52238 13.6635 5.06505 13.1534 5.15849 12.5894L5.75327 8.99911C5.81205 8.64425 6.04877 8.33904 6.38746 8.18138L10.815 6.12046C11.0846 6.01034 11.3687 5.94611 11.6671 5.92775C11.9655 5.9094 12.2496 5.94611 12.5192 6.03787C12.7887 6.12963 13.0439 6.25811 13.2846 6.42328C13.5252 6.58846 13.7227 6.79952 13.8767 7.05646L15.032 8.81833C15.5326 9.58916 16.2114 10.2223 17.0683 10.7179C17.6537 11.0564 18.2954 11.2793 18.9931 11.3866C19.5443 11.4713 20 11.8926 20 12.4247C20 12.9569 19.5472 13.3943 18.9891 13.3795C18.0289 13.3542 17.1425 13.2547 16.3896 12.8651C15.6579 12.4975 14.8033 11.6128 14.2329 11.1374C13.9237 10.8797 13.6242 11.0638 13.5424 11.4475L13.0797 13.6174C13.0005 13.9887 13.1272 14.3728 13.4151 14.6341L15.1997 16.254C15.3176 16.361 15.4105 16.4908 15.4722 16.6344L17.528 21.423C17.7747 21.9977 17.4743 22.6532 16.8643 22.8711L16.7005 22.9297C16.1224 23.1362 15.4761 22.8732 15.2329 22.3324L13.1877 17.7841C13.1092 17.6094 12.9846 17.457 12.826 17.342L11.8826 16.6568C11.2653 16.2085 10.3691 16.4563 10.0992 17.1497L9.45414 18.807C9.36287 19.0415 9.19045 19.2395 8.96534 19.3682L5.89533 21.1238C5.37875 21.4193 4.71071 21.2868 4.36064 20.8195L4.21517 20.6253ZM13.0428 5.4047C12.447 5.4047 11.9371 5.18905 11.5128 4.75776C11.0886 4.32646 10.8765 3.80799 10.8765 3.20235C10.8765 2.5967 11.0886 2.07824 11.5128 1.64694C11.9371 1.21564 12.447 1 13.0428 1C13.6385 1 14.1484 1.21564 14.5727 1.64694C14.997 2.07824 15.209 2.5967 15.209 3.20235C15.209 3.80799 14.997 4.32646 14.5727 4.75776C14.1484 5.18905 13.6385 5.4047 13.0428 5.4047Z',
      },
    ],
  },

  // ─── Clear (Icons 2: x) ───────────────────────────────────────────────────
  clear: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M18 6 6 18' },
      { tag: 'path', d: 'm6 6 12 12' },
    ],
  },

  // ─── Locate Fixed (Lucide: locate-fixed) ──────────────────────────────────
  'locate-fixed': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'line', x1: 2, x2: 5, y1: 12, y2: 12 },
      { tag: 'line', x1: 19, x2: 22, y1: 12, y2: 12 },
      { tag: 'line', x1: 12, x2: 12, y1: 2, y2: 5 },
      { tag: 'line', x1: 12, x2: 12, y1: 19, y2: 22 },
      { tag: 'circle', cx: 12, cy: 12, r: 7 },
      { tag: 'circle', cx: 12, cy: 12, r: 3 },
    ],
  },

  // ─── Chevrons (Icons 2: chevron-down/up/left/right) ───────────────────────
  'chevron-down': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [{ tag: 'path', d: 'm6 9 6 6 6-6' }],
  },
  'chevron-up': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [{ tag: 'path', d: 'm18 15-6-6-6 6' }],
  },
  'chevron-left': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [{ tag: 'path', d: 'm15 18-6-6 6-6' }],
  },
  'chevron-right': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [{ tag: 'path', d: 'm9 18 6-6-6-6' }],
  },

  // ─── Move up-right (Icons 2: move-up-right) ───────────────────────────────
  'move-up-right': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M13 5H19V11' },
      { tag: 'path', d: 'M19 5L5 19' },
    ],
  },

  // ─── Footprints (Icons 2: footprints) ─────────────────────────────────────
  footprints: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      {
        tag: 'path',
        d: 'M4 16v-2.38C4 11.5 2.97 10.5 3 8c.03-2.72 1.49-6 4.5-6C9.37 2 10 3.8 10 5.5c0 3.11-2 5.66-2 8.68V16a2 2 0 1 1-4 0Z',
      },
      {
        tag: 'path',
        d: 'M20 20v-2.38c0-2.12 1.03-3.12 1-5.62-.03-2.72-1.49-6-4.5-6C14.63 6 14 7.8 14 9.5c0 3.11 2 5.66 2 8.68V20a2 2 0 1 0 4 0Z',
      },
      { tag: 'path', d: 'M16 17h4' },
      { tag: 'path', d: 'M4 13h4' },
    ],
  },

  // ─── Paperclip (Icons 2: paperclip) ───────────────────────────────────────
  paperclip: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      {
        tag: 'path',
        d: 'm16 6-8.414 8.586a2 2 0 0 0 2.829 2.829l8.414-8.586a4 4 0 1 0-5.657-5.657l-8.379 8.551a6 6 0 1 0 8.485 8.485l8.379-8.551',
      },
    ],
  },

  // ─── Map (Icons 2: map) ───────────────────────────────────────────────────
  map: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      {
        tag: 'path',
        d: 'M14.106 5.553a2 2 0 0 0 1.788 0l3.659-1.83A1 1 0 0 1 21 4.619v12.764a1 1 0 0 1-.553.894l-4.553 2.277a2 2 0 0 1-1.788 0l-4.212-2.106a2 2 0 0 0-1.788 0l-3.659 1.83A1 1 0 0 1 3 19.381V6.618a1 1 0 0 1 .553-.894l4.553-2.277a2 2 0 0 1 1.788 0z',
      },
      { tag: 'path', d: 'M15 5.764v15' },
      { tag: 'path', d: 'M9 3.236v15' },
    ],
  },

  // ─── Info (Icons 2: info) ─────────────────────────────────────────────────
  info: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 12, cy: 12, r: 10 },
      { tag: 'path', d: 'M12 16v-4' },
      { tag: 'path', d: 'M12 8h.01' },
    ],
  },

  // ─── Info Circle (alias of info — same Lucide info glyph) ──────────────────
  'info-circle': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 12, cy: 12, r: 10 },
      { tag: 'path', d: 'M12 16v-4' },
      { tag: 'path', d: 'M12 8h.01' },
    ],
  },

  // ─── Bug (Icons 2: bug) ───────────────────────────────────────────────────
  bug: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M12 20v-9' },
      { tag: 'path', d: 'M14 7a4 4 0 0 1 4 4v3a6 6 0 0 1-12 0v-3a4 4 0 0 1 4-4z' },
      { tag: 'path', d: 'M14.12 3.88 16 2' },
      { tag: 'path', d: 'M21 21a4 4 0 0 0-3.81-4' },
      { tag: 'path', d: 'M21 5a4 4 0 0 1-3.55 3.97' },
      { tag: 'path', d: 'M22 13h-4' },
      { tag: 'path', d: 'M3 21a4 4 0 0 1 3.81-4' },
      { tag: 'path', d: 'M3 5a4 4 0 0 0 3.55 3.97' },
      { tag: 'path', d: 'M6 13H2' },
      { tag: 'path', d: 'm8 2 1.88 1.88' },
      { tag: 'path', d: 'M9 7.13V6a3 3 0 1 1 6 0v1.13' },
    ],
  },

  // ─── Bell (Icons 2: bell) ─────────────────────────────────────────────────
  bell: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M10.268 21a2 2 0 0 0 3.464 0' },
      {
        tag: 'path',
        d: 'M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326',
      },
    ],
  },

  // ─── Bell-plus (Icons 2: bell-plus) ───────────────────────────────────────
  'bell-plus': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M10.268 21a2 2 0 0 0 3.464 0' },
      { tag: 'path', d: 'M15 8h6' },
      { tag: 'path', d: 'M18 5v6' },
      {
        tag: 'path',
        d: 'M20.002 14.464a9 9 0 0 0 .738.863A1 1 0 0 1 20 17H4a1 1 0 0 1-.74-1.673C4.59 13.956 6 12.499 6 8a6 6 0 0 1 8.75-5.332',
      },
    ],
  },

  // ─── Search (Lucide: search) ──────────────────────────────────────────────
  search: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 11, cy: 11, r: 8 },
      { tag: 'path', d: 'm21 21-4.34-4.34' },
    ],
  },

  // ─── Clock (Lucide: clock) ────────────────────────────────────────────────
  clock: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 12, cy: 12, r: 10 },
      { tag: 'path', d: 'M12 6v6l4 2' },
    ],
  },

  // ─── Skip Forward (Lucide: skip-forward) ──────────────────────────────────
  'skip-forward': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M21 4v16' },
      {
        tag: 'path',
        d: 'M6.029 4.285A2 2 0 0 0 3 6v12a2 2 0 0 0 3.029 1.715l9.997-5.998a2 2 0 0 0 .003-3.432z',
      },
    ],
  },

  // ─── Circle Slash (Lucide: ban — same "no/prohibited" glyph, kept under our own more
  // descriptive name since this app uses it generically, not just for a literal ban action) ──
  'circle-slash': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 12, cy: 12, r: 10 },
      { tag: 'path', d: 'M4.929 4.929 19.07 19.071' },
    ],
  },

  // ─── Circle Plus (Lucide: circle-plus) ────────────────────────────────────
  'circle-plus': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 12, cy: 12, r: 10 },
      { tag: 'path', d: 'M8 12h8' },
      { tag: 'path', d: 'M12 8v8' },
    ],
  },

  // ─── Circle Check (Lucide: circle-check) ──────────────────────────────────
  'circle-check': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 12, cy: 12, r: 10 },
      { tag: 'path', d: 'm9 12 2 2 4-4' },
    ],
  },

  // MODE FILL — matches metro-native's own "circle-x filled" asset (assets/Icons 2/circle-x
  // filled.svg): a solid circle r=10 at 12,12 with an × cut from it at the exact same line
  // coordinates as Lucide's stroke circle-x — (15,9)-(9,15) and (9,9)-(15,15), 2px-equivalent
  // width. That source draws the × as separate white strokes over a black circle (two fixed
  // colors); rebuilt here as one even-odd cutout instead (same technique as pin-filled's dot
  // cutout) — this renderer only ever paints a primitive in the caller's single `color`, so a
  // cutout is what makes it read identically on any background, not just white.
  // The × is ONE 12-point outline (the true union of the two crossing bars — each bar's own tip
  // corners, joined through the 4 inner points where the bars' edges actually intersect), not two
  // overlapping bar-shaped subpaths. Two separately-closed bars overlap in a diamond at the
  // center, and even-odd cancels that overlap back to *filled* (a visible solid diamond, since
  // it's covered by both bars = crossed twice = back to "inside") — a single non-self-intersecting
  // outline has no such double-cancellation.
  'circle-x': {
    viewBox: '0 0 24 24',
    mode: 'fill',
    primitives: [
      {
        tag: 'path',
        fillRule: 'evenodd',
        d: 'M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0Z M15.707 9.707 13.414 12 15.707 14.293 14.293 15.707 12 13.414 9.707 15.707 8.293 14.293 10.586 12 8.293 9.707 9.707 8.293 12 10.586 14.293 8.293Z',
      },
    ],
  },

  // ─── Alert Circle (Lucide: circle-alert) ──────────────────────────────────
  'alert-circle': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 12, cy: 12, r: 10 },
      { tag: 'line', x1: 12, x2: 12, y1: 8, y2: 12 },
      { tag: 'line', x1: 12, x2: 12.01, y1: 16, y2: 16 },
    ],
  },

  // ─── Check (Lucide: check) ────────────────────────────────────────────────
  check: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [{ tag: 'path', d: 'M20 6 9 17l-5-5' }],
  },

  // ─── Thumb Up (Lucide: thumbs-up) ─────────────────────────────────────────
  'thumb-up': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M7 10v12' },
      {
        tag: 'path',
        d: 'M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z',
      },
    ],
  },

  // ─── Thumb Down (Lucide: thumbs-down) ─────────────────────────────────────
  'thumb-down': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M17 14V2' },
      {
        tag: 'path',
        d: 'M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88Z',
      },
    ],
  },

  // ─── Users (Lucide: users) ────────────────────────────────────────────────
  users: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2' },
      { tag: 'circle', cx: 9, cy: 7, r: 4 },
      { tag: 'path', d: 'M22 21v-2a4 4 0 0 0-3-3.87' },
      { tag: 'path', d: 'M16 3.128a4 4 0 0 1 0 7.744' },
    ],
  },

  // ─── Clock 8 (Icons 2: clock-8) ───────────────────────────────────────────
  'clock-8': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'circle', cx: 12, cy: 12, r: 10 },
      { tag: 'path', d: 'M12 6v6l-4 2' },
    ],
  },

  // ─── Triangle Alert (Icons 2: triangle-alert) ─────────────────────────────
  'triangle-alert': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'm21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3' },
      { tag: 'path', d: 'M12 9v4' },
      { tag: 'path', d: 'M12 17h.01' },
    ],
  },

  // ─── Door Open (Lucide: door-open) ────────────────────────────────────────
  'door-open': {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'M11 20H2' },
      {
        tag: 'path',
        d: 'M11 4.562v16.157a1 1 0 0 0 1.242.97L19 20V5.562a2 2 0 0 0-1.515-1.94l-4-1A2 2 0 0 0 11 4.561z',
      },
      { tag: 'path', d: 'M11 4H8a2 2 0 0 0-2 2v14' },
      { tag: 'path', d: 'M14 12h.01' },
      { tag: 'path', d: 'M22 20h-3' },
    ],
  },

  // ─── Navigation (Lucide: navigation — current-location arrow) ─────────────
  navigation: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [{ tag: 'polygon', points: '3 11 22 2 13 21 11 13 3 11' }],
  },

  // ─── Waypoints (Lucide: waypoints — connected route nodes) ────────────────
  waypoints: {
    viewBox: '0 0 24 24',
    mode: 'stroke',
    primitives: [
      { tag: 'path', d: 'm10.586 5.414-5.172 5.172' },
      { tag: 'path', d: 'm18.586 13.414-5.172 5.172' },
      { tag: 'path', d: 'M6 12h12' },
      { tag: 'circle', cx: 12, cy: 20, r: 2 },
      { tag: 'circle', cx: 12, cy: 4, r: 2 },
      { tag: 'circle', cx: 20, cy: 12, r: 2 },
      { tag: 'circle', cx: 4, cy: 12, r: 2 },
    ],
  },

  // ─── Subway (Figma transit — 16×16, solid) ────────────────────────────────
  // MODE FILL — body + undercarriage, each from a translated group, even-odd.
  subway: {
    viewBox: '0 0 16 16',
    mode: 'fill',
    primitives: [
      {
        tag: 'path',
        translateX: 3.33,
        translateY: 2,
        fillRule: 'evenodd',
        d: 'M8 0C8.73627 0 9.33381 0.596778 9.33398 1.33301V9.33301C9.33398 9.5171 9.1841 9.66602 9 9.66602H0.333984C0.150187 9.66567 0 9.51689 0 9.33301V1.33301C0.000174405 0.596994 0.598011 0.000351672 1.33398 0H8ZM2.22266 6.69238C1.85487 6.69273 1.55682 6.99058 1.55664 7.3584V7.5127C1.55673 7.8806 1.85482 8.17934 2.22266 8.17969H2.44531C2.8134 8.17963 3.11222 7.88078 3.1123 7.5127V7.3584C3.11213 6.99039 2.81334 6.69244 2.44531 6.69238H2.22266ZM6.88965 6.69238C6.52157 6.69238 6.22283 6.99036 6.22266 7.3584V7.5127C6.22274 7.88081 6.52151 8.17969 6.88965 8.17969H7.1123C7.48024 8.17945 7.77824 7.88067 7.77832 7.5127V7.3584C7.77814 6.9905 7.48019 6.69262 7.1123 6.69238H6.88965ZM3 1.4873C2.63237 1.48783 2.33416 1.78561 2.33398 2.15332V4.53809C2.33398 4.90595 2.63226 5.20455 3 5.20508H6.33398C6.70202 5.2049 7 4.90617 7 4.53809V2.15332C6.99982 1.78539 6.70192 1.48748 6.33398 1.4873H3Z',
      },
      {
        tag: 'path',
        translateX: 3.07,
        translateY: 12,
        fillRule: 'evenodd',
        d: 'M2.08028 0L1.31953 0.869141H8.54805L7.78731 0H8.49629L9.80098 1.49121C9.89791 1.60205 9.88641 1.7712 9.77559 1.86816C9.66482 1.96448 9.49644 1.95318 9.39961 1.84277L9.01387 1.40234H0.853713L0.467971 1.84277C0.370988 1.95327 0.201752 1.96491 0.0910178 1.86816C-0.0196679 1.77131 -0.0309286 1.60205 0.0656272 1.49121L0.531448 0.959961L1.37031 0H2.08028Z',
      },
    ],
  },

  // ─── Train (Figma transit — 16×16, solid) ─────────────────────────────────
  // MODE FILL — body + rail, each from a translated group, even-odd.
  train: {
    viewBox: '0 0 16 16',
    mode: 'fill',
    primitives: [
      {
        tag: 'path',
        translateX: 1.92,
        translateY: 2.67,
        fillRule: 'evenodd',
        d: 'M12.0753 2.66699H11.4093C11.0413 2.66699 10.7426 2.96504 10.7423 3.33301V5.33301C10.7423 5.7012 11.0411 6 11.4093 6H12.0753V10H2.67201C0.487882 10 -0.770625 7.51822 0.520641 5.75684L3.94349 1.08984C4.44584 0.40511 5.24462 7.00301e-06 6.09388 0H12.0753V2.66699ZM6.0138 2.66699C5.79226 2.66699 5.58502 2.77731 5.46107 2.96094L4.11048 4.96094C3.81218 5.40361 4.12932 5.99986 4.66322 6H9.40931C9.77723 5.99988 10.0751 5.70187 10.0753 5.33398V3.33301C10.0751 2.96512 9.77723 2.66712 9.40931 2.66699H6.0138Z',
      },
      {
        tag: 'path',
        translateX: 4.337,
        translateY: 13.34,
        fillRule: 'evenodd',
        d: 'M0.333333 0C0.149238 0 0 0.149238 0 0.333333C0 0.517428 0.149238 0.666667 0.333333 0.666667V0.333333V0ZM0.333333 0.333333V0.666667H9.66667V0.333333V0H0.333333V0.333333Z',
      },
    ],
  },

  // ─── Ferry (Figma transit — 16×16) ────────────────────────────────────────
  // MODE FILL — hull (filled + stroked) + cabin (stroke only), each translated. Hairline stroke.
  ferry: {
    viewBox: '0 0 16 16',
    mode: 'fill',
    primitives: [
      {
        tag: 'path',
        translateX: 1.337,
        translateY: 6.329,
        fill: 'color',
        stroke: 'color',
        strokeWidth: 0.666667,
        d: 'M6.33333 7.00733C1.53333 5.94066 0.333333 3.34066 0.333333 1.67399L6.33333 0.340659L13 1.67399C13 3.34066 11.6667 5.94066 6.33333 7.00733Z',
      },
      {
        tag: 'path',
        translateX: 2.627,
        translateY: 3.537,
        fill: 'none',
        stroke: 'color',
        strokeWidth: 0.666667,
        d: 'M5.03946 2.13324L0.743268 3.00017L2.58401 0.333336L7.49792 0.333418L9.84035 3.0337L5.03946 2.13324Z',
      },
    ],
  },
};
