/**
 * Barrel for the React Native side of the design system.
 *
 * Re-exports the generic component tree and the app-agnostic catalog framework (CatalogShell,
 * SectionBlock, PropsTable, tokens, types…). The worked catalog example lives at
 * `./catalog/CatalogExample` and is intentionally NOT re-exported here — it imports the concrete
 * components, whereas this barrel and the catalog framework stay free of any specific component so
 * the framework can be copied and reused as-is.
 */
export * from './components';
export * from './catalog';
