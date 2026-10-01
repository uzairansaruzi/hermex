/**
 * Reusable design-system catalog framework.
 *
 * App-agnostic by design — nothing here imports from a specific app's `design-system/` folder or
 * component set. To document an app's components, build a `SectionDef[]` (one per component or
 * token group, each with a `render()` that uses that app's real components) and a `NavGroup[]`
 * (how to bucket those sections in the sidebar), then render a single `<CatalogShell />`.
 *
 * See ./CatalogExample.tsx ("Native App DS Template") for a full worked example, built from this
 * template's own components. See ./CatalogFrameworkExample.tsx ("Design System DS Catalog") for a
 * worked example documenting this framework's own eleven pieces — the same catalog shape, one level
 * up. Neither is re-exported here, on purpose: this barrel stays free of any specific component
 * (including its own) so it can be copied into a different app's repo as-is.
 */
export { CatalogShell } from './CatalogShell';
export { CatalogSidebar } from './CatalogSidebar';
export { CatalogSearchInput } from './CatalogSearchInput';
export { SectionBlock } from './SectionBlock';
export { PropsTable } from './PropsTable';
export { VariantGroup } from './VariantGroup';
export { TokenRow } from './TokenRow';
export { DividedStack } from './DividedStack';
export { Swatch } from './Swatch';
export { PhoneFrame } from './PhoneFrame';
export { SpacingScaleGallery } from './SpacingScaleGallery';
export { TypeScaleGallery } from './TypeScaleGallery';
export { buildComponentManifest } from './manifest';
export type { ComponentManifestEntry, ManifestExample } from './manifest';
export type { PropDef, SectionDef, NavGroup } from './types';
export {
  CATALOG_TYPE,
  CATALOG_TYPE_USE,
  CATALOG_SPACE,
  CATALOG_SPACE_USE,
  CATALOG_RADIUS,
  CATALOG_COLOR,
} from './tokens';
