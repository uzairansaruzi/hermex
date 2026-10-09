/**
 * Shared icon layer barrel.
 *
 * Exposes the platform-neutral data + types only. Consumers import the renderer explicitly as
 * `../icons/Icon.native` (the only renderer today — see the repo README for how a future platform
 * port would add its own `Icon.<platform>.tsx` alongside it without touching this data).
 */
export { ICON_PATHS } from './paths';
export type { IconPrimitive, IconDef } from './paths';
export type { IconName, IconRenderProps } from './types';
