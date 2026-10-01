/**
 * react-native-svg renderer for the shared icon data (`./paths`).
 *
 * Reads `ICON_PATHS[name]` and maps each primitive to the matching RN-SVG element. Stroke icons
 * get round caps/joins in the Lucide style; fill icons render solid. Per-primitive `fill`/`stroke`
 * overrides (used by the transit icons) win over the def-level mode.
 */
import React from 'react';
import Svg, { Path, Rect, Circle, Line, Polyline, Polygon } from 'react-native-svg';
import { DS_SEMANTIC, DS_ICON_SIZE } from '../tokens';
import { ICON_PATHS, type IconPrimitive } from './paths';
import type { IconRenderProps } from './types';

export type IconProps = IconRenderProps & { accessibilityLabel?: string };

/** Resolve a primitive's `'color' | 'none'` sentinel against the active icon color. */
function resolvePaint(value: 'color' | 'none' | undefined, color: string): string | undefined {
  if (value === undefined) return undefined;
  return value === 'color' ? color : 'none';
}

export function Icon({
  name,
  size = DS_ICON_SIZE.sm,
  color = DS_SEMANTIC.text.regular,
  strokeWidth,
  accessibilityLabel,
}: IconProps) {
  const def = ICON_PATHS[name];
  if (!def) return null;

  const isStroke = def.mode === 'stroke';
  const defStrokeWidth = strokeWidth ?? def.strokeWidth ?? 2;

  return (
    <Svg
      width={size}
      height={size}
      viewBox={def.viewBox}
      fill="none"
      accessibilityLabel={accessibilityLabel}
    >
      {def.primitives.map((p, i) => {
        // Per-primitive override wins; otherwise fall back to the def mode.
        const fill = resolvePaint(p.fill, color) ?? (isStroke ? 'none' : color);
        const stroke = resolvePaint(p.stroke, color) ?? (isStroke ? color : undefined);
        const hasStroke = stroke !== undefined && stroke !== 'none';

        const common: Record<string, unknown> = { key: i, fill, fillRule: p.fillRule };
        if (hasStroke) {
          common.stroke = stroke;
          common.strokeWidth = p.strokeWidth ?? defStrokeWidth;
          // Round caps/joins are the Lucide house style; only apply for stroke-mode icons.
          if (isStroke) {
            common.strokeLinecap = 'round';
            common.strokeLinejoin = 'round';
          }
        }
        if (p.translateX !== undefined) common.translateX = p.translateX;
        if (p.translateY !== undefined) common.translateY = p.translateY;

        return renderPrimitive(p, common);
      })}
    </Svg>
  );
}

function renderPrimitive(p: IconPrimitive, common: Record<string, unknown>): React.ReactElement | null {
  switch (p.tag) {
    case 'path':
      return <Path {...common} d={p.d} />;
    case 'rect':
      return <Rect {...common} x={p.x} y={p.y} width={p.width} height={p.height} rx={p.rx} ry={p.ry} />;
    case 'circle':
      return <Circle {...common} cx={p.cx} cy={p.cy} r={p.r} />;
    case 'line':
      return <Line {...common} x1={p.x1} y1={p.y1} x2={p.x2} y2={p.y2} />;
    case 'polyline':
      return <Polyline {...common} points={p.points} />;
    case 'polygon':
      return <Polygon {...common} points={p.points} />;
    default:
      return null;
  }
}
