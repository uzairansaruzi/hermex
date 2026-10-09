// Dev-only harness — not part of the reusable template. Hosts the Hermex Design System catalog
// (the Phase 0 Hermex audit layer + the retained template catalog, combined) as the default route,
// plus the template's own two worked catalog examples on their original query params, all browsable
// with `expo start --web`, following the same query-parameter routing used by this harness.
//
//   http://localhost:8096/                   → HermesDesignSystemCatalog ("Hermex Design System")
//   http://localhost:8096/?catalog=template  → CatalogExample ("Native App DS Template", untouched)
//   http://localhost:8096/?catalog=framework → CatalogFrameworkExample ("Design System DS Catalog")
import { useEffect } from 'react';
import { HermesDesignSystemCatalog } from '../native/catalog/hermes/HermesDesignSystemCatalog';
import { CatalogExample } from '../native/catalog/CatalogExample';
import { CatalogFrameworkExample } from '../native/catalog/CatalogFrameworkExample';

const search = typeof window !== 'undefined' ? window.location.search : '';
const isFrameworkCatalog = search.includes('catalog=framework');
const isTemplateCatalog = search.includes('catalog=template');

const TITLES = {
  hermes: 'Hermex Design System',
  template: 'Native App DS Template',
  framework: 'Design System DS Catalog',
} as const;

export default function App() {
  useEffect(() => {
    if (typeof document !== 'undefined') {
      document.title = isFrameworkCatalog ? TITLES.framework : isTemplateCatalog ? TITLES.template : TITLES.hermes;
    }
  }, []);

  if (isFrameworkCatalog) return <CatalogFrameworkExample />;
  if (isTemplateCatalog) return <CatalogExample />;
  return <HermesDesignSystemCatalog />;
}
