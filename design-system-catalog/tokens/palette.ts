/**
 * Raw color palette — the base scale every semantic token is built from.
 *
 * Each hue steps 0 (lightest) → 800 (darkest). These are RAW values; app code should almost
 * always reach for a semantic token (see semantic.ts) instead of a palette step directly, so a
 * rebrand only touches this file + semantic.ts. To rebrand: swap these hexes for your own scale
 * (keep the 0–800 shape) and the whole system re-themes.
 */
export const PALETTE_STEPS = [0, 100, 200, 300, 400, 500, 600, 700, 800] as const;
export type PaletteStep = (typeof PALETTE_STEPS)[number];

export const DS_PALETTE = {
  grey: {
    0: '#FFFFFF',
    100: '#F5F5F5',
    200: '#E5E5E5',
    300: '#D4D4D4',
    400: '#A3A3A3',
    500: '#737373',
    600: '#404040',
    700: '#171717',
    800: '#000000',
  },
  green: {
    0: '#F0FFF4',
    100: '#C6F6D5',
    200: '#9AE6B4',
    300: '#68D391',
    400: '#48BB78',
    500: '#38A169',
    600: '#2F855A',
    700: '#276749',
    800: '#1C4532',
  },
  blue: {
    0: '#EBF8FF',
    100: '#BEE3F8',
    200: '#90CDF4',
    300: '#63B3ED',
    400: '#4299E1',
    500: '#3182CE',
    600: '#2B6CB0',
    700: '#2C5282',
    800: '#1A365D',
  },
  red: {
    0: '#FFF5F5',
    100: '#FED7D7',
    200: '#FEB2B2',
    300: '#FC8181',
    400: '#F56565',
    500: '#E53E3E',
    600: '#C53030',
    700: '#9B2C2C',
    800: '#63171B',
  },
  yellow: {
    0: '#FFF4EB',
    100: '#FFE3C7',
    200: '#FFD099',
    300: '#FFB966',
    400: '#FFA333',
    500: '#FF8C00',
    600: '#D67600',
    700: '#A35A00',
    800: '#703E00',
  },
  purple: {
    0: '#FAF5FF',
    100: '#E9D8FD',
    200: '#D6BCFA',
    300: '#B794F4',
    400: '#9F7AEA',
    500: '#805AD5',
    600: '#6B46C1',
    700: '#553C9A',
    800: '#322659',
  },
} as const;

export type PaletteName = keyof typeof DS_PALETTE;

function normalizeHex(color: string): string | null {
  const trimmed = color.trim();
  if (!trimmed.startsWith('#')) return null;
  let hex = trimmed.toUpperCase();
  if (hex.length === 4) {
    hex = `#${hex[1]}${hex[1]}${hex[2]}${hex[2]}${hex[3]}${hex[3]}`;
  }
  return hex;
}

/** Resolves a hex color to a palette token name (e.g. `green-600`), or null if not in DS_PALETTE. */
export function paletteTokenForColor(color: string): string | null {
  const target = normalizeHex(color);
  if (!target) return null;

  for (const name of Object.keys(DS_PALETTE) as PaletteName[]) {
    for (const step of PALETTE_STEPS) {
      if (normalizeHex(DS_PALETTE[name][step]) === target) {
        return `${name}-${step}`;
      }
    }
  }
  return null;
}

/** Palette token when mapped; otherwise the raw value (hex / rgba). Used by the catalog. */
export function colorValueLabel(color: string): string {
  return paletteTokenForColor(color) ?? color;
}
