import type {
  HermesAdoptionStatus,
  HermesAlternative,
  HermesCompositionConstraint,
  HermesCompositionSlot,
  HermesImplementationNotes,
  HermesMachineConfiguration,
  HermesReferenceDestination,
  HermesReferenceMeta,
  HermesTokenFact,
  HermesUsageExample,
  NavGroup,
  PropDef,
  SectionDef,
} from './types';

/** One documented variant/state instance, stripped of its `node` (a React element isn't JSON-
 *  serializable, and isn't useful to a consumer that only wants to know what's demonstrated). */
export interface ManifestExample {
  key: string;
  name: string;
  /** Present only for examples tagged via `VariantExample.props` — see types.ts. */
  props?: Record<string, unknown>;
}

/** A Hermex entry's decision contract, stripped to plain JSON — see `HermesReferenceMeta` in
 *  types.ts for what each field means. */
export interface ManifestHermesReference {
  useWhen?: string;
  avoidWhen?: string;
  alternatives: HermesAlternative[];
  adoptionStatus?: HermesAdoptionStatus;
  useSummary?: string;
  usedIn?: HermesReferenceDestination[];
  /** Technical provenance, including the native Swift `sourcePaths` this entry documents — so a
   *  consumer of the manifest can tell a React Native browser reconstruction apart from the
   *  production Swift source it describes. */
  implementationNotes?: HermesImplementationNotes;
  /** This component's named content regions/slots — see `HermesCompositionSlot` in types.ts. */
  compositionSlots?: HermesCompositionSlot[];
  /** Structured cross-slot composition rules — see `HermesCompositionConstraint` in types.ts. */
  compositionConstraints?: HermesCompositionConstraint[];
  /** Native Swift API/type/token/pattern symbols to search for — see `HermesReferenceMeta.
   *  canonicalSymbols` in types.ts. */
  canonicalSymbols?: string[];
  /** Canonical Swift usage examples — see `HermesUsageExample` in types.ts. */
  usageExamples?: HermesUsageExample[];
  /** JSON-safe behavioral configuration descriptors for a `render()`-based entry — see
   *  `HermesMachineConfiguration` in types.ts. */
  machineConfigurations?: HermesMachineConfiguration[];
  /** Structured Foundations token facts — see `HermesTokenFact` in types.ts. */
  tokenFacts?: HermesTokenFact[];
}

/** One component's structured documentation — everything `SectionDef` carries, minus the JSX. */
export interface ComponentManifestEntry {
  id: string;
  /** The reader-facing name shown as this section's page title/sidebar label — falls back to `id`
   *  itself (`SectionDef.displayName`'s own default) when the section sets no override. */
  displayName: string;
  path?: string;
  description: string;
  /** The deciding question against this component's closest look-alike, if it has one — see
   *  WHEN_TO_USE.md for the full reasoning this is condensed from. */
  whenToUse?: string;
  a11y?: string;
  props: PropDef[];
  category: string;
  variants: ManifestExample[];
  states: ManifestExample[];
  /** True for a token-gallery entry (raw token data, not a component API) — only present when
   *  `buildComponentManifest` was called with `includeTokenGalleries: true`, since the default
   *  (component-only) manifest omits these entries entirely rather than including a flag on them. */
  tokenGallery?: boolean;
  /** Present only for a Hermex reference entry (`SectionDef.hermesReference`) — absent for the
   *  reusable template's own components/tokens, which carry no Hermex decision contract. */
  hermesReference?: ManifestHermesReference;
}

const stripNode = ({ key, name, props }: { key: string; name: string; props?: Record<string, unknown> }): ManifestExample =>
  props ? { key, name, props } : { key, name };

const buildHermesManifestReference = (meta: HermesReferenceMeta): ManifestHermesReference => ({
  useWhen: meta.useWhen,
  avoidWhen: meta.avoidWhen,
  alternatives: meta.alternatives ?? [],
  adoptionStatus: meta.adoptionStatus,
  useSummary: meta.useSummary,
  usedIn: meta.usedIn,
  implementationNotes: meta.implementationNotes,
  compositionSlots: meta.compositionSlots,
  compositionConstraints: meta.compositionConstraints,
  canonicalSymbols: meta.canonicalSymbols,
  usageExamples: meta.usageExamples,
  machineConfigurations: meta.machineConfigurations,
  tokenFacts: meta.tokenFacts,
});

/**
 * Serializes a catalog's `sections` (+ the `groups` that categorize them) into plain, JSON-safe
 * data — no React elements, so it's directly usable outside the app: fed to another tool, diffed
 * in CI to catch undocumented API changes, or handed to an LLM as ground truth for which props/
 * variants/states a component actually supports, instead of it guessing from the source alone.
 * `render`-based sections (interactive demos with local state) keep their static `props`/`a11y`
 * metadata but naturally have no `variants`/`states` items to list, since those live inside the
 * render function rather than as data.
 *
 * Token-gallery sections (Colors, Spacing, …) are skipped by default — matching the reusable
 * template's own component-only manifest, unchanged for every existing caller. Pass
 * `{ includeTokenGalleries: true }` (the Hermex catalog does) to keep them instead: a caller that
 * needs the full Design System surface — Foundations token groups alongside components/patterns —
 * would otherwise silently miss every token entry.
 */
export function buildComponentManifest<TId extends string>(
  sections: SectionDef<TId>[],
  groups: NavGroup<TId>[],
  options?: { includeTokenGalleries?: boolean },
): ComponentManifestEntry[] {
  const categoryById = new Map<TId, string>();
  for (const group of groups) {
    for (const id of group.ids) categoryById.set(id, group.label);
  }
  const includeTokenGalleries = options?.includeTokenGalleries ?? false;

  return sections
    .filter((def) => includeTokenGalleries || !def.tokenGallery)
    .map((def) => ({
      id: def.id,
      displayName: def.displayName ?? def.id,
      path: def.path,
      description: def.description,
      whenToUse: def.whenToUse,
      a11y: def.a11y,
      props: def.props ?? [],
      category: categoryById.get(def.id) ?? 'Uncategorized',
      variants: (def.variants?.items ?? []).map(stripNode),
      states: (def.states?.items ?? []).map(stripNode),
      ...(def.tokenGallery ? { tokenGallery: true as const } : {}),
      ...(def.hermesReference ? { hermesReference: buildHermesManifestReference(def.hermesReference) } : {}),
    }));
}

/** The one runtime-truth fact every Hermex manifest consumer needs stated once, machine-readably, at
 *  the envelope level — never repeated (or risking contradiction) per entry: the production app is
 *  SwiftUI, and this catalog's own live React Native examples are a documentation reconstruction of
 *  that SwiftUI source, not the production runtime itself. See the matching prose in `HermesOverview`
 *  (hermesSections.tsx). */
export interface HermesManifestRuntime {
  productionRuntime: 'swiftui';
  catalogRuntime: 'react-native-documentation-reconstruction';
  detail: string;
}

export const HERMES_MANIFEST_RUNTIME: HermesManifestRuntime = {
  productionRuntime: 'swiftui',
  catalogRuntime: 'react-native-documentation-reconstruction',
  detail:
    'Hermex ships no React Native runtime. Every live example in this catalog is a React Native documentation reconstruction built from reading the production SwiftUI source, not the production SwiftUI runtime itself.',
};

/** A versioned envelope around `buildComponentManifest`'s own entry array — adds the one
 *  catalog-wide runtime-truth fact above once, rather than letting each of the 37 entries restate
 *  (and risk contradicting) the same fact in prose. Entry-level data is unchanged; this only wraps it. */
export interface HermesManifestEnvelope {
  schemaVersion: 1;
  runtime: HermesManifestRuntime;
  entries: ComponentManifestEntry[];
}

export function buildHermesManifestEnvelope<TId extends string>(
  sections: SectionDef<TId>[],
  groups: NavGroup<TId>[],
): HermesManifestEnvelope {
  return {
    schemaVersion: 1,
    runtime: HERMES_MANIFEST_RUNTIME,
    entries: buildComponentManifest(sections, groups, { includeTokenGalleries: true }),
  };
}
