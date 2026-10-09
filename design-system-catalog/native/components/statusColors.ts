import { DS_SEMANTIC } from '../../tokens';

/**
 * The one shared status→color lookup behind every status-tinted component (Badge, Banner): a light
 * tinted fill (`shade`) paired with a saturated foreground (`emphasis`), so a badge and a banner of
 * the same status always read as the same color identity. Previously each component maintained its
 * own identical copy of this map — one place to change now keeps them matched by construction.
 * (Toast's variant map lives separately: its variant names differ (`success`/`informational`) and it
 * bundles per-variant icons, so it's a different shape, not a third copy of this one.)
 */
export type StatusVariant = 'neutral' | 'info' | 'positive' | 'warning' | 'negative';

export const STATUS_BG: Record<StatusVariant, string> = {
  neutral: DS_SEMANTIC.shade.neutral,
  info: DS_SEMANTIC.shade.info,
  positive: DS_SEMANTIC.shade.positive,
  warning: DS_SEMANTIC.shade.warning,
  negative: DS_SEMANTIC.shade.negative,
};

export const STATUS_FG: Record<StatusVariant, string> = {
  neutral: DS_SEMANTIC.emphasis.neutral,
  info: DS_SEMANTIC.emphasis.info,
  positive: DS_SEMANTIC.emphasis.positive,
  warning: DS_SEMANTIC.emphasis.warning,
  negative: DS_SEMANTIC.emphasis.negative,
};
