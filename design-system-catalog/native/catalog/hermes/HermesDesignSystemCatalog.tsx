/**
 * HermesDesignSystemCatalog — "Hermex Design System": the default catalog route.
 *
 * Renders only the Hermex reference layer (`hermesSections`/`hermesNav` — real findings traced to
 * Hermex's SwiftUI production source, organized into the approved five-group taxonomy: Foundations,
 * Materials, Native iOS, Components, Patterns). The retained template catalog (`sections`/`nav`
 * exported from `../CatalogExample`) is a separate, unmerged reference available only at the
 * `?catalog=template` route (see `native-preview/App.tsx`); this file never imports it. The audit
 * overview renders once, above the first group, via `CatalogShell`'s `intro` slot rather than as its
 * own nav entry. `CatalogShell` owns layout, scrolling, filtering, and scroll-spy.
 */
import { CatalogShell } from '../CatalogShell';
import { hermesSections, hermesNav, HermesOverview } from './hermesSections';

export function HermesDesignSystemCatalog() {
  return (
    <CatalogShell
      appName="Hermex"
      title="Hermex Design System"
      groups={hermesNav}
      sections={hermesSections}
      intro={() => <HermesOverview />}
      // Token Coverage moved from its own entry into the overview's Implementation notes, so it is
      // counted separately from the 26 visual references (Materials + Native iOS + Components +
      // Patterns, excluding the Foundations token galleries).
      subtitle="Hermex · 26 visual references · token coverage in overview"
    />
  );
}
