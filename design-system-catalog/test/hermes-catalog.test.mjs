// Minimal Node built-in test (node:test + node:assert) — no new test dependency.
// Asserts against source text rather than executing the RN/Expo app, since this repo has no test
// runner/renderer set up for .tsx; that's enough to pin down the required catalog/title/routes/
// evidence structure without pulling in a new toolchain.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const read = (rel) => readFileSync(path.join(ROOT, rel), 'utf8');

const HERMES_CATALOG_PATH = 'native/catalog/hermes/HermesDesignSystemCatalog.tsx';
const HERMES_SECTIONS_PATH = 'native/catalog/hermes/hermesSections.tsx';
const APP_PATH = 'native-preview/App.tsx';
const TOKENS_PATH = 'native/catalog/tokens.ts';
const CATALOG_SHELL_PATH = 'native/catalog/CatalogShell.tsx';
const CATALOG_SIDEBAR_PATH = 'native/catalog/CatalogSidebar.tsx';
const SECTION_BLOCK_PATH = 'native/catalog/SectionBlock.tsx';
const PROPS_TABLE_PATH = 'native/catalog/PropsTable.tsx';
const CATALOG_EXAMPLE_PATH = 'native/catalog/CatalogExample.tsx';
const DIST_INDEX_HTML_PATH = 'native-preview/dist/index.html';
const TYPES_PATH = 'native/catalog/types.ts';
const HERMES_REFERENCE_DETAILS_PATH = 'native/catalog/hermes/HermesReferenceDetails.tsx';
const VARIANT_GROUP_PATH = 'native/catalog/VariantGroup.tsx';
const HERMES_TOKEN_PROPOSAL_PATH = 'native/catalog/hermes/hermesTokenProposal.ts';
const HERMES_TOKEN_GALLERIES_PATH = 'native/catalog/hermes/HermesTokenProposalGalleries.tsx';
const HERMES_COLOR_DATA_PATH = 'native/catalog/hermes/hermesColorCatalogData.ts';
const HERMES_SEMANTIC_COLOR_REFERENCE_PATH = 'native/catalog/hermes/HermesSemanticColorReference.tsx';
const HERMES_ICON_REFERENCE_PATH = 'native/catalog/hermes/HermesIconReference.tsx';
const HERMES_ICON_SIZE_PATH = 'native/catalog/hermes/hermesIconSize.ts';
const HERMES_MOTION_REFERENCE_PATH = 'native/catalog/hermes/HermesMotionReference.tsx';
const HERMES_ICON_INVENTORY_PATH = 'native/catalog/hermes/hermesIconInventory.generated.json';
const HERMES_ICON_TRACE_PATH = 'native/catalog/hermes/hermesIconComputedSiteTrace.generated.json';
const ICON_GENERATOR_SCRIPT_PATH = 'scripts/generate-icon-previews.mjs';
const ICON_RENDERER_PACKAGE_PATH = 'icon-renderer/Package.swift';
const ICON_RENDERER_TEST_PATH = 'icon-renderer/Tests/IconRenderTests/IconRenderTests.swift';
const ICON_RENDERER_GITIGNORE_PATH = 'icon-renderer/.gitignore';
const NATIVE_PREVIEW_PACKAGE_JSON_PATH = 'native-preview/package.json';
const SIMULATOR_UDID_PATTERN = /\b[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\b/i;
const NATIVE_PREVIEW_GITIGNORE_PATH = 'native-preview/.gitignore';

// Extracts one top-level `SectionDef` block (from its `id: '<id>',` line up to the next section's
// opening `\n  {`) out of hermesSections.tsx source text — shared by every test below that needs to
// scope an assertion to exactly one section instead of the whole file.
const extractHermesSection = (src, id) => {
  const idx = src.indexOf(`id: '${id}',`);
  assert.notEqual(idx, -1, `expected a SectionDef with id '${id}'`);
  const nextIdx = src.indexOf('\n  {', idx);
  return src.slice(idx, nextIdx === -1 ? src.length : nextIdx);
};

// Extracts a named top-level function's own body text by tracking brace depth from its first
// opening '{' to the matching '}'. Unlike extractHermesSection (which scopes to a SectionDef
// object literal's own properties — id, disposition, hermes metadata, the render reference), this
// scopes to a separately-declared gallery function's actual JSX body, since a SectionDef's `render`
// typically just references a gallery function by name and does not itself contain that function's
// content.
function extractFunctionBody(src, functionName) {
  // `(?:<[^>]*>)?` optionally skips a generic type-parameter list (e.g. `function Foo<TId extends
  // string>(`) between the function name and its own parameter list.
  const headerPattern = new RegExp(`function ${functionName}\\s*(?:<[^>]*>)?\\s*\\([^)]*\\)[^{]*\\{`);
  const match = src.match(headerPattern);
  assert.ok(match, `expected a function named ${functionName}`);
  const start = match.index + match[0].length - 1;
  let depth = 0;
  for (let i = start; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth -= 1;
      if (depth === 0) return src.slice(start + 1, i);
    }
  }
  throw new Error(`unterminated function body for ${functionName}`);
}

// The catalog route (HermesDesignSystemCatalog.tsx) passes hermesNav/hermesSections straight
// through to CatalogShell; the actual Phase 0 audit data (ids, groups, per-entry metadata, evidence
// status) lives in hermesSections.tsx, which it imports — together they're "the Hermex catalog"
// these assertions check against.
const hermesCatalogSource = () => read(HERMES_SECTIONS_PATH) + '\n' + read(HERMES_CATALOG_PATH);

test('Hermex catalog file exists and exports the combined catalog component', () => {
  assert.ok(existsSync(path.join(ROOT, HERMES_CATALOG_PATH)), `${HERMES_CATALOG_PATH} should exist`);
  assert.ok(existsSync(path.join(ROOT, HERMES_SECTIONS_PATH)), `${HERMES_SECTIONS_PATH} should exist`);
  const src = read(HERMES_CATALOG_PATH);
  assert.match(src, /export function HermesDesignSystemCatalog/);
  assert.match(src, /title="Hermex Design System"/);
});

test('every Hermes-owned nav group begins with an approved taxonomy prefix, including a separate Native iOS group', () => {
  const hermesSrc = read(HERMES_SECTIONS_PATH);
  const navBlockMatch = hermesSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array in hermesSections.tsx');
  const navBlock = navBlockMatch[0];
  const labels = [...navBlock.matchAll(/label:\s*'([^']+)'/g)].map((m) => m[1]);
  assert.equal(labels.length, 5, 'expected Foundations, Materials, Native iOS, Components, and Patterns nav groups');
  for (const label of labels) {
    assert.ok(
      label.startsWith('Foundations') || label.startsWith('Materials') || label.startsWith('Native iOS') || label.startsWith('Components') || label.startsWith('Patterns'),
      `hermesNav label "${label}" must start with an approved taxonomy prefix`,
    );
  }
});

test("the default route's sidebar order places Native iOS before Hermex Components and Patterns, using hermesNav's own group order directly with no template re-assembly", () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array in hermesSections.tsx');
  const labels = [...navBlockMatch[0].matchAll(/label:\s*'([^']+)'/g)].map((m) => m[1]);
  const prefixOrder = ['Foundations', 'Materials', 'Native iOS', 'Components', 'Patterns'];
  assert.deepEqual(
    labels.map((label) => prefixOrder.find((prefix) => label.startsWith(prefix))),
    prefixOrder,
    "expected hermesNav's five groups ordered Foundations, Materials, Native iOS, Components, Patterns",
  );

  const catalogSrc = read(HERMES_CATALOG_PATH);
  assert.match(catalogSrc, /groups=\{hermesNav\}/, 'expected the default route to pass hermesNav directly as groups, with no filtering/re-assembly');
  assert.match(catalogSrc, /sections=\{hermesSections\}/, 'expected the default route to pass hermesSections directly as sections, with no filtering/re-assembly');
  for (const stale of ['templateComponentGroups', 'templateTokenGroups', 'const nav:', 'const sections:']) {
    assert.ok(!catalogSrc.includes(stale), `did not expect "${stale}" to remain in the default route`);
  }
});

test('no disposition-named ("Verified foundations" / "Migration candidates" / "Conditional / retained") group labels remain, and there is no separate "Overview" sidebar group', () => {
  const src = hermesCatalogSource();
  for (const stale of ['Hermex — Verified foundations', 'Hermex — Migration candidates', 'Hermex — Conditional / retained', "label: 'Overview'"]) {
    assert.ok(!src.includes(stale), `did not expect the retired group label/pattern "${stale}" to still appear`);
  }
});

test('side-panel group titles omit the redundant Hermex suffix while native and custom controls stay separated', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const navBlock = src.match(/export const hermesNav:[^;]*;/s)?.[0] ?? '';

  assert.deepEqual(
    [...navBlock.matchAll(/label:\s*'([^']+)'/g)].map((match) => match[1]),
    ['Foundations', 'Materials', 'Native iOS', 'Components', 'Patterns'],
  );
  assert.match(navBlock, /label: 'Native iOS',\s*\n\s*ids: \['Hermes TopNav'\]/);
  assert.match(navBlock, /label: 'Components'[\s\S]*'Segmented Control'/);
  assert.doesNotMatch(src, /Hermex Segmented Control|Hermes Segmented Control/);

  const search = extractHermesSection(src, 'Search');
  assert.match(search, /HermexSearchField/, 'expected the Search entry to name the canonical HermexSearchField component');
  assert.match(search, /system-backed `TextField`|system-backed TextField/i, 'expected the Search entry to state the native TextField still owns text editing');
  assert.match(search, /`\.hermexSearch/, 'expected the Search entry to document the Hermex-owned .hermexSearch composition modifier');
  assert.doesNotMatch(
    search,
    /forwards straight to native `.searchable`|avoid[^']*custom chrome/i,
    'native .searchable forwarding and the ban on custom chrome are retired',
  );

  const segmented = extractHermesSection(src, 'Segmented Control');
  assert.match(segmented, /fixed/);
  assert.match(segmented, /scrolling/);
  assert.match(segmented, /custom Hermex/i);
  assert.match(segmented, /selection transition/i);
  assert.match(segmented, /44pt/);
  assert.doesNotMatch(segmented, /native iOS segmented Picker|\.pickerStyle\(\.segmented\)/);

  const previews = read('native/catalog/hermes/HermesComponentFamiliesPreviews.tsx');
  assert.match(previews, /export function SegmentedControlGallery/);
  assert.doesNotMatch(previews, /NativeSegmentedControlGallery|native iOS segmented Picker/);
});

test("the default route never imports or assembles CatalogExample's template nav/sections, while CatalogExample.tsx itself (used by the separate ?catalog=template route) is fully preserved", () => {
  const catalogSrc = read(HERMES_CATALOG_PATH);
  // Scoped to the actual code constructs a merge would require (an import statement, the identifiers
  // a re-assembly would declare, the literal re-label string, a rendered reference count) rather than
  // a bare "does the word template ever appear" scan, which would also flag this file's own doc
  // comment explaining that the separate ?catalog=template route exists.
  assert.doesNotMatch(catalogSrc, /from\s+'\.\.\/CatalogExample'/, 'expected no import from CatalogExample in the default route');
  assert.doesNotMatch(catalogSrc, /\btemplateNav\b|\btemplateSections\b|\bTemplateSectionId\b/, 'expected no template nav/sections identifiers in the default route');
  assert.doesNotMatch(catalogSrc, /Template library \(not adopted\)/, 'expected no "Template library" label assembled into the default route');
  assert.doesNotMatch(catalogSrc, /\d+ template references?/i, 'expected no template-reference count in the default route\'s subtitle');

  // CatalogExample.tsx itself, and its own nav, remain fully intact for the separate ?catalog=template route.
  const templateSrc = read(CATALOG_EXAMPLE_PATH);
  const templateNavBlockMatch = templateSrc.match(/export const nav:[^;]*;/s);
  assert.ok(templateNavBlockMatch, 'expected an exported nav array in CatalogExample.tsx, unchanged');
  const originalLabels = [...templateNavBlockMatch[0].matchAll(/label:\s*'([^']+)'/g)].map((m) => m[1]);
  assert.ok(originalLabels.length >= 10, `expected the template's own full set of nav groups preserved, found ${originalLabels.length}`);
  assert.ok(originalLabels.includes('Reference'), 'expected the template\'s own "Reference" nav group (Manifest page) preserved');
});

test('CatalogShell exposes an intro slot rendered above the first nav group, and the Hermex audit overview is rendered through it — not as its own nav entry', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  assert.match(shellSrc, /intro\?:\s*\(\)\s*=>\s*React\.ReactNode/, 'expected CatalogShell to accept an optional `intro` render prop');
  assert.match(shellSrc, /\{intro\s*&&\s*<View[^>]*>\{intro\(\)\}<\/View>\}/, 'expected CatalogShell to render `intro()` above the groups');

  const hermesSectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(hermesSectionsSrc, /export function HermesOverview/, 'expected hermesSections.tsx to export a standalone HermesOverview component');
  assert.ok(!hermesSectionsSrc.includes("id: 'Hermex Overview'"), 'the overview must not also be registered as its own SectionDef/nav entry');

  const catalogSrc = read(HERMES_CATALOG_PATH);
  assert.match(catalogSrc, /intro=\{\(\)\s*=>\s*<HermesOverview\s*\/>\}/, 'expected HermesDesignSystemCatalog to pass HermesOverview into CatalogShell\'s intro slot');
});

test('Hermex reference metadata and accessible disclosure path exist, and the temporary Task 1 audit-panel compatibility path is fully removed', () => {
  const typesSrc = read(TYPES_PATH);
  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  const shellSrc = read(CATALOG_SHELL_PATH);

  assert.match(typesSrc, /export interface HermesReferenceDestination/);
  assert.match(typesSrc, /screen:\s*string/);
  assert.match(typesSrc, /path\?:\s*string/);
  assert.match(typesSrc, /effect:\s*string/);
  assert.match(typesSrc, /export interface HermesReferenceMeta/);
  assert.match(typesSrc, /useSummary\?:\s*string/);
  assert.match(typesSrc, /usedIn\?:\s*HermesReferenceDestination\[\]/);
  assert.match(typesSrc, /implementationNotes\?:\s*HermesImplementationNotes/);
  assert.match(typesSrc, /hermesReference\?:\s*HermesReferenceMeta/);
  assert.match(typesSrc, /path\?:\s*string/);
  assert.doesNotMatch(typesSrc, /HermesAudit|HermesDisposition|HermesEvidenceLevel/);

  // Round 3 moves HermesReferenceDetails out of SectionBlock's own render and into the shared
  // Details inspector CatalogShell owns (see the DSR3-03 tests below) — accessible disclosure
  // machinery (used by the Overview's own compact Implementation notes disclosure) still lives in
  // HermesReferenceDetails.tsx itself.
  assert.match(detailsSrc, /accessibilityRole="button"/);
  assert.match(detailsSrc, /accessibilityState=\{\{\s*expanded\s*\}\}/);
  assert.match(detailsSrc, /<AnimatedChevron/);
  assert.match(detailsSrc, /Implementation notes/);
  assert.match(sectionBlockSrc, /def\.hermesReference/);
  assert.doesNotMatch(sectionBlockSrc, /<HermesReferenceDetails/, 'HermesReferenceDetails now renders inside the shared Details inspector, not SectionBlock\'s own main-canvas render');
  assert.match(shellSrc, /<HermesReferenceDetails/, 'expected CatalogShell to render HermesReferenceDetails inside its own Details inspector');
  assert.doesNotMatch(sectionBlockSrc, /HermesAuditPanel/);

  assert.ok(!existsSync(path.join(ROOT, 'native/catalog/hermes/HermesAuditPanel.tsx')), 'Task 2 removes the temporary audit panel once every entry migrates to hermesReference');
});

// Controller-found ambiguity (2026-09-21 follow-up): "adopted production namespace"/"adopted
// production scale"/"adopted production Swift" reads as a release-status claim ("production" as in
// "shipped to production"), not the intended "non-test Swift source" meaning — even though the
// per-family evidence text elsewhere already correctly scopes adoption to the local implementation
// branch. UI-facing labels/descriptions for the five locally-adopted token families (HermesColorRamp,
// HermesMotion, HermesSpacing, HermesRadius, HermesShadow) must say "adopted local implementation
// namespace/scale" or "adopted in the verified local implementation branch" instead. "production
// Swift source" remains fine where it unambiguously means non-test app code, never adoption/release
// status — this test only bans the specific ambiguous "adopted production ..." constructions.
test('UI-facing catalog text never describes a locally adopted token family as "adopted production namespace", "adopted production scale", or "adopted production Swift"', () => {
  const src = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(
    src,
    /adopted production\s+(?:[\w/]+\s+)?(?:namespace|scale)/i,
    'must not describe HermesColorRamp/HermesMotion/HermesSpacing/HermesRadius/HermesShadow as an "adopted production namespace/scale" — that reads as release status, not "adopted in the verified local implementation branch"',
  );
  assert.doesNotMatch(
    src,
    /adopted production Swift\b/i,
    'must not describe adopted ramp/token values as "adopted production Swift" — that reads as release status',
  );
});

test('catalog implementation status describes the in-repository candidate and points to entry-level adoption truth without mutable publication claims', () => {
  const src = read(HERMES_SECTIONS_PATH);
  assert.match(src, /Design System candidate/i);
  assert.match(src, /bounded production adoptions are named|each entry[^.]*adoption status/i);
  assert.doesNotMatch(src, /Production-screen adoption is intentionally\s+excluded from this slice/i);
  assert.doesNotMatch(src, /Production-screen migration\/adoption is not included in this branch/i);
  assert.match(src, /design-system-catalog\//);
  assert.doesNotMatch(src, /issue\/607-shared-design-system|issue\/607-foundation-base/);
  assert.doesNotMatch(src, /contributor-fork branch|current migration candidate|no pull request|TestFlight upload|release, or deployment/i);
  assert.doesNotMatch(
    src,
    /maintained outside the Git worktree/i,
    'the catalog moved in-repository (design-system-catalog/) and must no longer claim to be maintained outside the Git worktree',
  );
  assert.match(
    src,
    /versioned\s+under[\s\S]{0,60}design-system-catalog\/[\s\S]{0,150}Design System Contract/i,
    'expected the overview to name design-system-catalog/ as the versioned in-repository path, validated by the Design System Contract CI job',
  );
});

test('App.tsx titles the default route exactly "Hermex Design System" and preserves ?catalog=framework/template routes', () => {
  const src = read(APP_PATH);
  assert.match(src, /'Hermex Design System'/);
  assert.match(src, /catalog=framework/);
  assert.match(src, /catalog=template/);
  assert.match(src, /HermesDesignSystemCatalog/);
  assert.match(src, /CatalogFrameworkExample/);
  assert.match(src, /CatalogExample/);
});

// Regression guard for the narrow-viewport defect (390x844: fixed 240px sidebar beside main left
// ~150px, wrapping the page title character-by-character, columns staying horizontal). Text-based,
// like the rest of this file — there's no RN test renderer set up — but pinned to the actual
// mechanism (a shared breakpoint token, each framework file switching layout below it) so the
// responsive seam can't be quietly deleted from just one of the three files, or the breakpoint
// silently dropped from tokens.ts, without failing this test. Applies to all three routes (default
// Hermex, ?catalog=template, ?catalog=framework) because all three render through this one shared
// CatalogShell/CatalogSidebar/SectionBlock framework, not a per-catalog layout.
test('the shared catalog framework defines and applies a narrow-viewport breakpoint on all three routes\' layout (sidebar, main padding, section columns)', () => {
  const tokensSrc = read(TOKENS_PATH);
  assert.match(
    tokensSrc,
    /export const CATALOG_NARROW_BREAKPOINT\s*=\s*\d+/,
    'expected a shared CATALOG_NARROW_BREAKPOINT export in tokens.ts',
  );

  const shellSrc = read(CATALOG_SHELL_PATH);
  assert.match(shellSrc, /useWindowDimensions/, 'CatalogShell should read the viewport width');
  assert.match(shellSrc, /CATALOG_NARROW_BREAKPOINT/, 'CatalogShell should compare against the shared breakpoint');
  assert.match(
    shellSrc,
    /rootNarrow:\s*\{\s*flexDirection:\s*'column'/,
    "CatalogShell should stack sidebar-above-main (flexDirection: 'column') below the breakpoint",
  );
  // "approximately 16-24px horizontal padding" (acceptance criteria) — pinned to the actual numeric
  // range, not just "some smaller value", so a future edit can't silently pad it back out to the
  // desktop's 48px (which is what caused the original defect) while still passing a looser check.
  const mainPaddingMatch = shellSrc.match(/mainContentNarrow:\s*\{[^}]*paddingHorizontal:\s*(\d+)/);
  assert.ok(mainPaddingMatch, 'CatalogShell should define a narrow-viewport main content padding override');
  const mainPadding = Number(mainPaddingMatch[1]);
  assert.ok(
    mainPadding >= 16 && mainPadding <= 24,
    `expected narrow-viewport main content horizontal padding within 16-24px, got ${mainPadding}`,
  );

  const sidebarSrc = read(CATALOG_SIDEBAR_PATH);
  assert.match(sidebarSrc, /useWindowDimensions/, 'CatalogSidebar should read the viewport width');
  assert.match(sidebarSrc, /CATALOG_NARROW_BREAKPOINT/, 'CatalogSidebar should compare against the shared breakpoint');
  assert.match(
    sidebarSrc,
    /sidebarNarrow:\s*\{[^}]*width:\s*'100%'/,
    'CatalogSidebar should become full-width (not the fixed 240px desktop sidebar) below the breakpoint',
  );
  assert.match(
    sidebarSrc,
    /sidebarNarrow:\s*\{[^}]*maxHeight:\s*\d+/,
    'CatalogSidebar should bound its own height (not the desktop 100vh sticky sidebar) below the breakpoint, so it reads as a top region, not the whole screen',
  );

  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  assert.match(sectionBlockSrc, /useWindowDimensions/, 'SectionBlock should read the viewport width');
  assert.match(sectionBlockSrc, /CATALOG_NARROW_BREAKPOINT/, 'SectionBlock should compare against the shared breakpoint');
  assert.match(
    sectionBlockSrc,
    /columnsRowNarrow:\s*\{\s*flexDirection:\s*'column'/,
    "SectionBlock should stack its visual-example and reference-content columns (flexDirection: 'column') below the breakpoint",
  );
});

test('SectionBlock uses the approved two-column documentation hierarchy on the retained template/framework routes: wide Variants/States primary column, narrow Props/Accessibility secondary column (a Hermex reference entry never reaches this codepath at all — see HermexSectionCanvas below)', () => {
  const src = read(SECTION_BLOCK_PATH);
  const generalBody = extractFunctionBody(src, 'SectionBlock');

  assert.doesNotMatch(generalBody, /HermexSectionCanvas\s*\{/, 'the exported SectionBlock function body should only delegate to HermexSectionCanvas, not inline its logic');
  assert.match(
    generalBody,
    /const primaryBlocks: BlockDef\[\] = \[[\s\S]*label: 'Variants'[\s\S]*label: 'States \/ Configurations'/,
    'expected Variants and States / Configurations to stack in the primary column',
  );
  assert.match(
    generalBody,
    /const secondaryBlocks: BlockDef\[\] = \[[\s\S]*label: 'Props'/,
    'expected Props to render in the secondary column',
  );
  assert.match(
    generalBody,
    /const secondaryBlocks: BlockDef\[\] = \[[\s\S]*label: 'Accessibility'/,
    'expected the secondary-column Accessibility block to render unconditionally on the retained routes — a Hermex reference entry never reaches this branch, so there is no longer an isHermexReference guard here',
  );
  assert.match(
    src,
    /primaryColumn:\s*\{[^}]*flex:\s*2[^}]*\}/,
    'expected the visual-example primary column to receive the wider two-thirds share',
  );
  assert.match(
    src,
    /secondaryColumn:\s*\{[^}]*flex:\s*1[^}]*\}/,
    'expected the reference-content secondary column to receive the narrower one-third share',
  );
  assert.doesNotMatch(src, /columnWide/, 'the superseded three-column Props-width special case should be removed');
});

test('DSR3-02/03: SectionBlock delegates every def.hermesReference entry to its own HermexSectionCanvas main-canvas layout instead of the retained template/framework two-column hierarchy', () => {
  const src = read(SECTION_BLOCK_PATH);
  assert.match(
    src,
    /if\s*\(def\.hermesReference\)\s*\{\s*return\s*<HermexSectionCanvas/,
    'expected SectionBlock to delegate a def.hermesReference entry to HermexSectionCanvas',
  );
});

test('native-preview/dist/index.html restores the react-native-web root height/overflow reset', () => {
  const html = read(DIST_INDEX_HTML_PATH);
  assert.match(html, /html,\s*\n?\s*body\s*\{\s*\n?\s*height:\s*100%;/, 'expected html/body to be reset to full height');
  assert.match(html, /body\s*\{\s*\n?\s*overflow:\s*hidden;/, 'expected body overflow to be reset to hidden');
  assert.match(html, /#root\s*\{[^}]*height:\s*100%;[^}]*flex:\s*1;/s, 'expected #root to be reset to a flexed, full-height element');
});

test('CatalogShell resolves the real web scrolling element (nested overflow scroller when it genuinely overflows, otherwise document.scrollingElement), gives sections stable DOM anchors, and binds scroll-spy to the resolved element', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  // Stable per-section web anchor.
  assert.match(shellSrc, /nativeID=\{sectionAnchorId\(def\.id\)\}/, 'expected each section wrapper to carry a stable nativeID anchor');
  assert.match(shellSrc, /function sectionAnchorId/);

  // Scroller-fallback resolution: trust the nested node only when it actually overflows, else fall
  // back to document.scrollingElement.
  assert.match(shellSrc, /function resolveWebScrollElement/);
  assert.match(shellSrc, /scrollHeight\s*>\s*.*clientHeight/, 'expected a real-overflow check before trusting the nested ScrollView node');
  assert.match(shellSrc, /document\.scrollingElement/, 'expected a document.scrollingElement fallback');

  // scrollTo computes the target from the anchor DOM node, then scrolls the *resolved* element.
  assert.match(shellSrc, /getAnchorOffset\(sectionAnchorId\(id\), scrollElement\)/);
  assert.match(shellSrc, /scrollElement\.scrollTop\s*=/, 'expected scrollTo to move the resolved scroll element, not always the nested ScrollView node');

  // Scroll-spy is bound to the same resolved element via a real DOM listener, not just RN's
  // `onScroll` prop (which is wired to the nested node and never fires when the document scrolls).
  assert.match(shellSrc, /resolveWebScrollElement\(scrollRef\)/g);
  assert.match(shellSrc, /addEventListener\('scroll',\s*handleWebScroll/);

  // Native's own offset/scrollTo path is untouched.
  assert.match(shellSrc, /scrollRef\.current\?\.scrollTo\(\{\s*y:/, 'expected the native ScrollView.scrollTo offset path to still exist');
  assert.match(shellSrc, /if \(Platform\.OS === 'web'\) return;/, 'expected the native onScroll handler to explicitly sit out on web, deferring to the DOM scroll-spy listener');
});

// Regression contract for the frozen-scroll-spy defect: a fresh load highlighted AppFont at
// 1440x900, then a script set the real nested ScrollView's scrollTop to Hermex Colors — after 1s
// AppFont was still shown active. Root cause: the scroll-spy effect resolved
// `resolveWebScrollElement(scrollRef)` exactly once at mount and captured that single element into
// its `handleWebScroll` closure — if the nested node wasn't yet measurably overflowing on that
// first effect run (its content may not have finished laying out), the effect permanently listens
// on `document` instead, and a nested `overflow: auto` scroll never bubbles a `scroll` event up to
// `document`, so scroll-spy silently stops updating forever once layout settles. Click-to-scroll
// was unaffected because `scrollTo` already re-resolves the scroll element fresh on every call.
test('web scroll-spy re-resolves the active scroll element on every scroll event (not once at mount) and binds listeners to both the nested node and document, independent of which one overflows at mount', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  const effectMatch = shellSrc.match(/useEffect\(\(\) => \{[\s\S]*?\n {2}\}, \[\]\);/);
  assert.ok(effectMatch, 'expected a mount-effect wiring up the web scroll-spy listener(s) in CatalogShell.tsx');
  const effectBlock = effectMatch[0];

  // The handler itself must resolve the active scroll element fresh on every invocation — not close
  // over a single element resolved once, outside the handler, when the effect first ran. This is
  // the actual defect: extracting just `handleWebScroll`'s own function body and asserting the
  // resolve call happens *inside* it (not merely somewhere earlier in the same effect) is what
  // fails against the frozen-at-mount implementation.
  const handlerMatch = effectBlock.match(/const handleWebScroll = \(\) => \{[\s\S]*?\n {4}\};/);
  assert.ok(handlerMatch, 'expected a `handleWebScroll` handler defined inside the scroll-spy effect');
  assert.match(
    handlerMatch[0],
    /resolveWebScrollElement\(scrollRef\)/,
    'handleWebScroll must re-resolve the active scroll element on every event, not read a value captured once when the effect first ran (the frozen-scroll-spy defect)',
  );

  // A listener must be attached directly to the nested ScrollView node itself (not only reachable
  // through resolveWebScrollElement's own internal overflow heuristic) — otherwise, if that node
  // isn't yet the "resolved" element at mount, nothing is ever listening to it once it does become
  // the real scroller, since its own `overflow: auto` scroll never bubbles to `document`.
  assert.match(
    effectBlock,
    /getNestedScrollNode\(scrollRef\)/,
    'expected the effect to bind directly to the nested ScrollView node via getNestedScrollNode, independent of the mount-time overflow check',
  );
  assert.match(
    effectBlock,
    /addEventListener\('scroll',\s*handleWebScroll/,
  );
  assert.match(
    effectBlock,
    /document\.addEventListener\('scroll',\s*handleWebScroll/,
    'expected a listener on document as well, since the nested node may not be the real scroller yet at mount',
  );

  // Deferred rebind after a layout tick (requestAnimationFrame), not a poll — covers the case where
  // the nested node's ref wasn't attached/measurable at all on the very first effect run.
  assert.match(effectBlock, /requestAnimationFrame\(/, 'expected a one-shot requestAnimationFrame-deferred rebind, not a polling interval');
  assert.doesNotMatch(effectBlock, /setInterval\(/, 'scroll-spy rebinding must not poll on an interval');

  // Cleanup must tear down everything this effect bound: both listeners and the deferred rAF.
  assert.match(effectBlock, /cancelAnimationFrame\(/, 'expected the deferred requestAnimationFrame callback to be cancelled on cleanup');
  assert.match(effectBlock, /removeEventListener\('scroll',\s*handleWebScroll\)/, 'expected listener cleanup on unmount');
  assert.match(
    effectBlock,
    /document\.removeEventListener\('scroll',\s*handleWebScroll(?:,[^)]*)?\)/,
    'expected the document listener to be cleaned up on unmount too (options argument shape is pinned down more precisely by the capture-mode test below)',
  );
});

// Correction 1 (2026-09-18): controller-observed runtime failure — a real nested overflow scroller
// (scrollHeight 67628, clientHeight 900, overflow-y:auto) dispatched a `scroll` event that neither
// the effect's own nested-node reference nor `document` ever received, so scroll-spy stayed frozen
// on AppFont after a controller-driven scroll to Hermex Spacing. The source-text contract above
// already required *a* nested-node listener and a document listener; it did not require binding
// directly to whatever `resolveWebScrollElement` itself currently resolves to (which self-corrects
// between the nested node and `document.scrollingElement` as layout settles, unlike a raw
// `getNestedScrollNode` reference captured once per bind attempt) — this test closes that gap.
test('web scroll-spy binds directly to whatever resolveWebScrollElement(scrollRef) currently resolves to (not only getNestedScrollNode and document), dedupes bound elements via a Set, and cleans up every one without polling', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  const effectMatch = shellSrc.match(/useEffect\(\(\) => \{[\s\S]*?\n {2}\}, \[\]\);/);
  assert.ok(effectMatch, 'expected a mount-effect wiring up the web scroll-spy listener(s) in CatalogShell.tsx');
  const effectBlock = effectMatch[0];

  // The bind logic itself (outside handleWebScroll, which already re-resolves for its own position
  // math) must call resolveWebScrollElement(scrollRef) again to decide what to *attach* a listener
  // to — extracted as its own named function so this is unambiguous from a bare "appears somewhere
  // in the effect" scan (handleWebScroll's own body already contains one legitimate call).
  const bindFnMatch = effectBlock.match(/const bind\w+ = \(\) => \{[\s\S]*?\n {4}\};/);
  assert.ok(bindFnMatch, 'expected a named bind function (attaching listeners) inside the scroll-spy effect, separate from handleWebScroll');
  assert.match(bindFnMatch[0], /getNestedScrollNode\(scrollRef\)/, 'expected the bind function to still attach to the raw nested ScrollView node');
  assert.match(
    bindFnMatch[0],
    /resolveWebScrollElement\(scrollRef\)/,
    'expected the bind function to ALSO attach directly to whatever resolveWebScrollElement(scrollRef) currently resolves to, not only the raw nested node',
  );

  // Deduplicated tracking/cleanup: a Set of every HTMLElement actually bound, so the same physical
  // element (the common case: the nested node IS what resolveWebScrollElement resolves to) is never
  // double-bound, and cleanup can remove precisely what was attached.
  assert.match(effectBlock, /new Set(?:<[^>]*>)?\(\)/, 'expected a Set tracking every bound HTMLElement');
  assert.match(effectBlock, /\.has\(/, 'expected the bind function to check the Set before attaching (dedup)');
  assert.match(effectBlock, /\.add\(/, 'expected the bind function to record each newly-bound element in the Set');

  // Cleanup must remove the listener from every element the Set tracked — not just one hardcoded
  // reference — plus the always-present document listener and the deferred rAF.
  assert.match(
    effectBlock,
    /\.forEach\(|for\s*\(const\s+\w+\s+of\s+\w+\)/,
    'expected cleanup to iterate every bound element (Set#forEach or a for..of loop), not a single hardcoded reference',
  );
  assert.match(effectBlock, /cancelAnimationFrame\(/);
  assert.match(
    effectBlock,
    /document\.removeEventListener\('scroll',\s*handleWebScroll(?:,[^)]*)?\)/,
    'expected a document listener removal (options argument shape is pinned down more precisely by the capture-mode test below)',
  );

  // Still no polling.
  assert.doesNotMatch(effectBlock, /setInterval\(/, 'scroll-spy rebinding must not poll on an interval');
});

// Correction 2 (2026-09-18): CDP-confirmed runtime diagnosis — the real late-overflowing nested
// scroller only ever picks up React Native Web's own listener (Correction 1's direct-element
// binding attempt runs before that scroller exists/overflows), and a plain bubbling-phase document
// listener can never observe its `scroll` events anyway, since `scroll` does not bubble. A capture-
// phase document listener DOES observe it (confirmed: `captureSeen: 1` for an explicit non-bubbling
// scroll dispatched on that exact late scroller), because capture listeners on an ancestor run
// during the event's capture phase, before target dispatch — independent of bubbling. This test
// requires the document listener to use capture mode, with matching add/remove options (capture
// mode must match exactly for `removeEventListener` to actually detach the same listener).
test('the document scroll-spy fallback listener is registered and removed in capture mode (not bubbling), so it can observe a late-overflowing nested scroller\'s non-bubbling scroll events', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  const effectMatch = shellSrc.match(/useEffect\(\(\) => \{[\s\S]*?\n {2}\}, \[\]\);/);
  assert.ok(effectMatch, 'expected a mount-effect wiring up the web scroll-spy listener(s) in CatalogShell.tsx');
  const effectBlock = effectMatch[0];

  const addMatch = effectBlock.match(/document\.addEventListener\('scroll',\s*handleWebScroll,\s*([^)]*)\)/);
  assert.ok(addMatch, 'expected document.addEventListener(\'scroll\', handleWebScroll, <options>) with an explicit options argument');
  assert.match(addMatch[1], /capture:\s*true|^\s*true\s*$/, 'expected the document scroll listener to be registered with capture: true (or a bare `true` third argument)');

  const removeMatch = effectBlock.match(/document\.removeEventListener\('scroll',\s*handleWebScroll,\s*([^)]*)\)/);
  assert.ok(removeMatch, 'expected document.removeEventListener(\'scroll\', handleWebScroll, <options>) with a matching options argument — capture mode must match exactly for the listener to actually be removed');
  assert.match(removeMatch[1], /capture:\s*true|^\s*true\s*$/, 'expected the document scroll listener removal to also specify capture: true (or bare `true`), matching the add call');

  // Preserved from Correction 1: direct-element binding/dedup, programmatic-scroll guard, fresh
  // per-event resolution, no polling.
  assert.match(effectBlock, /new Set(?:<[^>]*>)?\(\)/, 'expected Correction 1\'s bound-element Set to still be present');
  assert.match(effectBlock, /getNestedScrollNode\(scrollRef\)/);
  assert.match(effectBlock, /resolveWebScrollElement\(scrollRef\)/);
  assert.match(effectBlock, /isProgrammaticScroll\.current/, 'expected the programmatic-scroll guard to still be present');
  assert.doesNotMatch(effectBlock, /setInterval\(/, 'scroll-spy rebinding must not poll on an interval');
});

test('Hermex source-evidence Tokens are built from the original template building blocks (TypeScaleGallery, Swatch, TokenRow, VariantGroup, DividedStack) and use the existing tokenGallery/fullWidthLabel seams', () => {
  const src = read(HERMES_SECTIONS_PATH);
  for (const building of ['TypeScaleGallery', 'Swatch', 'TokenRow', 'VariantGroup', 'DividedStack']) {
    assert.match(src, new RegExp(`import \\{ ${building} \\} from '\\.\\./${building}'`), `expected hermesSections.tsx to import the original ${building} building block`);
  }
  assert.match(src, /tokenGallery:\s*true/);
  assert.match(src, /fullWidthLabel:/);
});

test('Hermex proposal uses the retained template token galleries (including SpacingScaleGallery) and never claims production adoption', () => {
  const sections = read(HERMES_SECTIONS_PATH);
  const galleries = read(HERMES_TOKEN_GALLERIES_PATH);
  assert.ok(existsSync(path.join(ROOT, HERMES_TOKEN_PROPOSAL_PATH)), `${HERMES_TOKEN_PROPOSAL_PATH} should exist`);
  assert.ok(existsSync(path.join(ROOT, HERMES_TOKEN_GALLERIES_PATH)), `${HERMES_TOKEN_GALLERIES_PATH} should exist`);
  for (const building of ['TypeScaleGallery', 'TokenRow', 'VariantGroup', 'DividedStack', 'SpacingScaleGallery']) {
    assert.match(galleries, new RegExp(`import \\{ ${building} \\} from '\\.\\./${building}'`), `expected HermesTokenProposalGalleries.tsx to import the original ${building} building block`);
  }
  assert.match(sections + galleries, /Proposed — not yet adopted/);
  assert.doesNotMatch(sections + galleries, /adopted production token system/i);
});

// ─── Approved normalized token proposal contracts (2026-09-18 implementation plan) ──────────────
// hermesTokenProposal.ts is the sole data source for these; HermesTokenProposalGalleries.tsx must
// render every fact it asserts here. Values are copied verbatim from the approved design spec.

// ─── Color adoption contracts (family plan 02's CO-3) ────────────────────────────────────────────

test('hermesColorCatalogData.ts defines the exact 9 color ramps, 11 steps each (99 values), with the exact 500 source anchors, the still-live spec §4.1 consumption restriction rendered by HermesColorRampGallery, and no dependency on the proposal module', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /import\s*\{[^}]*HERMES_COLOR_RAMPS[^}]*\}\s*from\s*'\.\/hermesColorCatalogData'/, 'must import the adopted ramp data from hermesColorCatalogData.ts, never hermesTokenProposal.ts');
  assert.doesNotMatch(
    sectionsSrc,
    /import\s*\{[^}]*(?:HERMES_COLOR_RAMPS|HERMES_COLOR_RAMP_STEPS|HERMES_SEMANTIC_COLORS)[^}]*\}\s*from\s*'\.\/hermesTokenProposal'/,
    'Color ramp/semantic data must never be imported from the proposal module',
  );
  const gallery = extractFunctionBody(sectionsSrc, 'HermesColorRampGallery');
  assert.match(gallery, /Object\.keys\(HERMES_COLOR_RAMPS\)\.map/, 'must iterate every ramp key, not a hardcoded list of ramp names');
  assert.match(gallery, /HERMES_COLOR_RAMP_STEPS\.map/, 'must iterate every step, not a hardcoded list of steps');
  assert.doesNotMatch(gallery, /ProposalStatus|Proposed — not yet adopted|proposed generated value/i, 'the adopted ramp gallery must carry no retired proposal-status language');
  assert.match(gallery, /HERMES_COLOR_GENERATED_STEP_CONSUMPTION_RESTRICTION/, 'the ramp gallery must render the consumption restriction, not merely a pinning claim');

  const adoptedDataSrc = read('native/catalog/hermes/hermesColorCatalogData.ts');
  assert.match(adoptedDataSrc, /export const HERMES_COLOR_RAMP_STEPS = \[50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950\] as const;/, 'exactly 11 steps in the adopted data this gallery iterates over');
  for (const name of ['Neutral', 'Gold', 'Blue', 'Purple', 'Red', 'Green', 'Orange', 'Cyan', 'Pink']) {
    assert.match(adoptedDataSrc, new RegExp(`\\b${name}:\\s*\\{ 50:`), `HERMES_COLOR_RAMPS must define the ${name} ramp (9 total, verified by name)`);
  }
  for (const anchor of ['#8E8E93', '#FFD700', '#5B7CFF', '#AF52DE', '#FF3B30', '#34C759', '#FB923C', '#67E8F9', '#F472B6']) {
    assert.ok(adoptedDataSrc.includes(anchor), `expected the 500 anchor ${anchor} preserved byte-for-byte`);
  }
  assert.match(
    adoptedDataSrc,
    /No production UI pairing may consume a generated \(non-500\) step until that specific pairing has passed contrast validation/,
    'expected the truthful adopted-state form of spec §4.1\'s restriction, naming consumption (not adoption) as the gate',
  );
  assert.doesNotMatch(adoptedDataSrc, /from\s*'\.\/hermesTokenProposal'/, 'hermesColorCatalogData.ts must not import anything from the proposal module');
});

test('Hermex Colors section includes the product-palette sub-block with all 14 named HermesProductPalette constants', () => {
  const src = read(HERMES_SECTIONS_PATH);
  // Issue #607 Slice A hoisted the two literal palette arrays HermesProductPaletteGallery renders
  // to shared top-level consts (HERMEX_HEADER_ACCENT_PALETTE / HERMEX_PROJECT_COLOR_PALETTE) so the
  // same typed data also backs hermesReference.tokenFacts — the gallery function body itself now
  // just references them, so this checks the whole file rather than only the function's own body.
  assert.match(src, /HERMEX_HEADER_ACCENT_PALETTE/);
  assert.match(src, /HERMEX_PROJECT_COLOR_PALETTE/);
  const gallery = extractFunctionBody(src, 'HermesProductPaletteGallery');
  assert.match(gallery, /headerAccents = HERMEX_HEADER_ACCENT_PALETTE/);
  assert.match(gallery, /projectPalette = HERMEX_PROJECT_COLOR_PALETTE/);
  assert.match(src, /headerAccentYellow/);
  assert.match(src, /headerAccentWhite/);
  assert.match(src, /projectViolet/);
  assert.match(src, /projectPink/);
});

test('the superseded Color-only proposal gallery implementation is deleted from HermesTokenProposalGalleries.tsx, not merely left as dead code, while every other family\'s still-unadopted proposal gallery and shared plumbing survive', () => {
  const proposalGalleriesSrc = read(HERMES_TOKEN_GALLERIES_PATH);
  assert.doesNotMatch(proposalGalleriesSrc, /function ColorRampGroup/, 'ColorRampGroup was Color-only and must be deleted, not left as dead code');
  assert.doesNotMatch(proposalGalleriesSrc, /export function HermesColorsProposalGallery/, 'HermesColorsProposalGallery was Color-only and must be deleted, not left as dead code');
  assert.doesNotMatch(proposalGalleriesSrc, /HERMES_COLOR_RAMPS|HERMES_COLOR_RAMP_STEPS|HERMES_COLOR_GENERATED_STEP_WARNING|HERMES_SEMANTIC_COLORS/, 'the four Color-only data imports must be removed once their only consumers are deleted');
  assert.match(proposalGalleriesSrc, /function ProposalStatus/, 'shared plumbing used by the other five proposal galleries must survive');
  assert.match(proposalGalleriesSrc, /export function AppFontProposalGallery/);
  assert.match(proposalGalleriesSrc, /export function HermesMotionProposalGallery/);
  assert.match(proposalGalleriesSrc, /export function HermesSpacingProposalGallery/);
  // HermesGeometryProposalGallery is deleted by family plan 04's SR-8 (R11 correction) — its own
  // absence is now asserted by this file's separate dead-gallery-regression test (item 5 above),
  // not by this test, which continues to guard the four proposal galleries that remain unadopted.
  assert.match(proposalGalleriesSrc, /export function HermesTokenCoverageGallery/);

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /HermesColorsProposalGallery/, 'no reference to the retired HermesColorsProposalGallery may remain anywhere in hermesSections.tsx, including the import list');
});

test('the Color ramp/semantic data and its retired proposal-only companions are removed from hermesTokenProposal.ts entirely, moved (not duplicated, and with no dependency on the proposal module) into hermesColorCatalogData.ts, and the module header no longer claims Color is still a proposal', () => {
  const proposalDataSrc = read(HERMES_TOKEN_PROPOSAL_PATH);
  assert.doesNotMatch(proposalDataSrc, /HERMES_COLOR_RAMPS/, 'HERMES_COLOR_RAMPS must be moved out of hermesTokenProposal.ts, not duplicated');
  assert.doesNotMatch(proposalDataSrc, /HERMES_COLOR_RAMP_STEPS/, 'HERMES_COLOR_RAMP_STEPS must be moved out of hermesTokenProposal.ts, not duplicated');
  assert.doesNotMatch(proposalDataSrc, /HERMES_COLOR_GENERATED_STEP_WARNING/, 'this exact symbol is deleted here because its requirement has a renamed adopted-state successor (HERMES_COLOR_GENERATED_STEP_CONSUMPTION_RESTRICTION in hermesColorCatalogData.ts), not because the requirement itself has no successor');
  assert.doesNotMatch(proposalDataSrc, /HERMES_SEMANTIC_COLORS/, 'this exact symbol/name is deleted here because its 13 genuinely-true facts move to a new, differently-named export in hermesColorCatalogData.ts while 3 proposal-only roles are explicitly retired — not because semantic-color facts have no successor at all');
  assert.doesNotMatch(proposalDataSrc, /SemanticColorFact/, 'its supporting type must be deleted alongside it');
  assert.doesNotMatch(proposalDataSrc, /does not currently have/i, 'the module header must no longer claim every value here (including Color, now adopted) lacks production Swift');
  assert.doesNotMatch(proposalDataSrc, /still awaiting adoption/i, 'Finding N10: the header must not make an absolute snapshot claim that goes false the moment a later family (e.g. Typography, already adopted via TY-5) leaves its own data block physically present here');

  const adoptedDataSrc = read('native/catalog/hermes/hermesColorCatalogData.ts');
  assert.match(adoptedDataSrc, /export const HERMES_COLOR_RAMPS: Record<string, HermesColorRamp> = \{/, 'the ramp data must exist, byte-for-byte, in its new adopted-state home');
  assert.match(adoptedDataSrc, /Gold: \{ 50: '#FFFDF2', 100: '#FFFAE0', 200: '#FFF4B8', 300: '#FFEC85', 400: '#FFE247', 500: '#FFD700', 600: '#E6C200', 700: '#C4A600', 800: '#9E8500', 900: '#786500', 950: '#524500' \}/);
  assert.match(adoptedDataSrc, /Pink: \{ 50: '#FEF8FB', 100: '#FEEEF6', 200: '#FCD8EB', 300: '#FABBDC', 400: '#F799CA', 500: '#F472B6', 600: '#DC67A4', 700: '#BC588C', 800: '#974771', 900: '#733656', 950: '#4E243A' \}/);
  assert.match(adoptedDataSrc, /export type HermesColorCatalogClassification/, 'expected a new, local, Color-only classification type');
  assert.doesNotMatch(adoptedDataSrc, /ProposalClassification/, 'must not import or reference the proposal module\'s classification type');
  assert.doesNotMatch(adoptedDataSrc, /from\s*'\.\/hermesTokenProposal'/, 'hermesColorCatalogData.ts must have zero imports from the proposal module');
});

test('the proposal galleries render the required classification labels, including for source/proposed/migration/retained/platform-owned facts', () => {
  const galleries = read(HERMES_TOKEN_GALLERIES_PATH);
  for (const label of [
    'Current production evidence',
    'Proposed — not yet adopted',
    'Migration candidate',
    'Retained component exception',
    'Platform-owned adaptive token',
  ]) {
    assert.ok(galleries.includes(label), `expected the classification label "${label}" to be rendered`);
  }
});

test('hermesTokenProposal.ts defines the exact core type primitives (12/14/16/18, line heights 16/20/22/24, regular+bold), semantic aliases, retained title hierarchy, and the equal-number preview disclaimer', () => {
  const proposal = read(HERMES_TOKEN_PROPOSAL_PATH);
  const primitivePairs = [['12', 16], ['14', 20], ['16', 22], ['18', 24]];
  for (const [size, lineHeight] of primitivePairs) {
    assert.ok(proposal.includes(`'font.${size}'`), `expected primitive font.${size}`);
    assert.ok(proposal.includes(`sizePt: ${size}`), `expected sizePt ${size}`);
    assert.ok(proposal.includes(`lineHeightPt: ${lineHeight}`), `expected lineHeightPt ${lineHeight}`);
  }
  assert.match(proposal, /weights:\s*\[?'regular',\s*'bold'\]?/);
  for (const alias of ['type.caption', 'type.footnote', 'type.subtext', 'type.body', 'type.headline', 'type.title.4']) {
    assert.ok(proposal.includes(`'${alias}'`), `expected semantic alias '${alias}'`);
  }
  const titlePairs = [['type.title.3', 20, 25], ['type.title.2', 22, 28], ['type.title.1', 28, 34]];
  for (const [alias, size, lineHeight] of titlePairs) {
    assert.ok(proposal.includes(`'${alias}'`), `expected title alias '${alias}'`);
    assert.ok(proposal.includes(`sizePt: ${size}`), `expected title sizePt ${size}`);
    assert.ok(proposal.includes(`lineHeightPt: ${lineHeight}`), `expected title lineHeightPt ${lineHeight}`);
  }
  assert.match(proposal, /not a physical point-to-pixel conversion/i);
  for (const migration of [
    'Caption 12',
    'Subheadline 15 migrates to Subtext 14',
    'Body 17 and Callout 16 consolidate to Body 16',
    'Headline 17 semibold migrates to Headline 18',
    'medium/semibold remain documented exceptions',
    'SF Symbols remain outside typography',
  ]) {
    assert.ok(proposal.includes(migration), `expected typography migration statement including "${migration}"`);
  }
});

test('hermesTokenProposal.ts defines the exact motion durations, easing roles, property/spring primitives, all 8 semantic bundles, the current-duration mapping, Reduce Motion behaviors, and deferred families', () => {
  const proposal = read(HERMES_TOKEN_PROPOSAL_PATH);
  for (const duration of [0, 100, 150, 200, 250, 300]) {
    assert.ok(proposal.includes(`'${duration}': ${duration}`), `expected duration primitive ${duration}`);
  }
  for (const easing of ['easeOut', 'easeIn', 'easeInOut', 'smooth(extraBounce: 0)', 'snappy']) {
    assert.ok(proposal.includes(easing), `expected easing role value "${easing}"`);
  }
  assert.match(proposal, /'motion\.opacity\.hidden':\s*0/);
  assert.match(proposal, /'motion\.opacity\.visible':\s*1/);
  assert.match(proposal, /'motion\.scale\.press':\s*0\.975/);
  assert.match(proposal, /'motion\.scale\.enter':\s*0\.95/);
  assert.match(proposal, /'motion\.distance\.short':\s*'8 pt'/);
  assert.match(proposal, /'motion\.direction\.edge':\s*\[?'top',\s*'bottom',\s*'leading',\s*'trailing'\]?/);
  assert.match(proposal, /response:\s*0\.30,\s*damping:\s*0\.70/);
  assert.match(proposal, /response:\s*0\.35,\s*damping:\s*0\.80/);
  for (const bundle of [
    'motion.feedback.press', 'motion.state.change', 'motion.content.enter', 'motion.content.exit',
    'motion.overlay.enter', 'motion.overlay.exit', 'motion.content.reposition', 'motion.scroll.follow',
  ]) {
    assert.ok(proposal.includes(`'${bundle}'`), `expected semantic motion bundle '${bundle}'`);
  }
  for (const mapping of ['100/120', '150/160', '180/200/220', "current: '240'", "current: '280'"]) {
    assert.ok(proposal.includes(mapping), `expected current-duration mapping entry "${mapping}"`);
  }
  for (const reduceMotionFact of [
    'immediate 0 ms', 'remove scale and spring', 'fade or none', 'nil/identity semantics', 'BotFaceMotion',
  ]) {
    assert.ok(proposal.includes(reduceMotionFact), `expected Reduce Motion fact "${reduceMotionFact}"`);
  }
  assert.match(proposal, /50 ms hover/);
  assert.match(proposal, /400–700 ms interface durations/);
  assert.match(proposal, /stagger\/delay/);
  assert.match(proposal, /haptic/);
});

test('hermesTokenProposal.ts defines the exact spacing/radius/geometry scales, semantic aliases, 44pt hit target, and migration mappings', () => {
  const proposal = read(HERMES_TOKEN_PROPOSAL_PATH);
  assert.match(proposal, /HERMES_SPACING_STEPS\s*=\s*\[0,\s*2,\s*4,\s*8,\s*12,\s*16,\s*20,\s*24,\s*32,\s*40,\s*48,\s*64\]/);
  assert.match(proposal, /HERMES_RADIUS_STEPS\s*=\s*\[0,\s*4,\s*8,\s*12,\s*16,\s*20,\s*24,\s*'full'\]/);
  for (const [alias, value] of [
    ['radius.control', 8], ['radius.field', 12], ['radius.card', 16],
    ['radius.prominent', 20], ['radius.chrome', 24],
  ]) {
    assert.ok(proposal.includes(`'${alias}': ${value}`), `expected radius alias '${alias}': ${value}`);
  }
  assert.ok(proposal.includes("'radius.pill': 'Capsule'"));
  assert.match(proposal, /HERMES_ICON_SIZES\s*=\s*\[12,\s*16,\s*20,\s*24,\s*32\]/);
  assert.match(proposal, /HERMES_CONTROL_SIZES\s*=\s*\[32,\s*40,\s*44,\s*48\]/);
  assert.match(proposal, /44 pt minimum hit target/);
  assert.ok(proposal.includes("'stroke.1'"));
  assert.ok(proposal.includes("'stroke.2'"));
  assert.ok(proposal.includes("'layout.readable.800'"));
  assert.ok(proposal.includes("'layout.readable.1000'"));
  assert.match(proposal, /bodyWindowHeight/);
  assert.match(proposal, /240pt/);
  assert.match(proposal, /Retained component exception/);
  assert.match(proposal, /5→space\.4/);
  assert.match(proposal, /26→space\.24/);
  assert.match(proposal, /Composer 26 normalizes to chrome 24/);
});

// Family plan 06, CC-1 (corrected after CC-2's Iconography insertion): HermesShadow
// (HermesMobile/Config/HermesShadow.swift) ships as an adopted production namespace — Hermex
// Shadow gets its own dedicated Tokens — Hermex page. CC-2 inserted Hermex Iconography immediately
// after Hermex Shadow (and before Hermex Token Coverage), so Shadow's own relative-position check
// now targets Iconography, its actual immediate successor in the final nine-entry order, rather
// than Token Coverage. Scoped to Shadow's own relative position (not a second full-array duplicate
// of the assertion above) plus its gallery function's own case-name fidelity.
test('Hermex Shadow is inserted immediately before Hermex Iconography in the Foundations — Hermex order, with all 8 exact case names in its own gallery function', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);

  const shadowSection = extractHermesSection(sectionsSrc, 'Hermex Shadow');
  assert.match(shadowSection, /tokenGallery:\s*true/, 'expected Hermex Shadow to be a tokenGallery SectionDef');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const tokensGroupMatch = navBlockMatch[0].match(/label:\s*'Foundations',\s*\n\s*ids:\s*\[([^\]]*)\]/);
  assert.ok(tokensGroupMatch, 'expected the Foundations — Hermex nav group');
  const tokenIds = [...tokensGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  const shadowIndex = tokenIds.indexOf('Hermex Shadow');
  const iconographyIndex = tokenIds.indexOf('Hermex Iconography');
  assert.notEqual(shadowIndex, -1, 'expected Hermex Shadow in the Foundations — Hermex nav order');
  assert.notEqual(iconographyIndex, -1, 'expected Hermex Iconography in the Foundations — Hermex nav order');
  assert.equal(
    shadowIndex,
    iconographyIndex - 1,
    'expected Hermex Shadow immediately before Hermex Iconography in the Foundations — Hermex order',
  );

  // Issue #607 Slice A hoisted the literal `cases` array HermesShadowGallery renders to a shared
  // top-level const (HERMES_SHADOW_CASES) so the same typed data also backs hermesReference.
  // tokenFacts — the gallery function body itself now just references it by name.
  const gallery = extractFunctionBody(sectionsSrc, 'HermesShadowGallery');
  assert.match(gallery, /cases: ShadowFact\[\] = HERMES_SHADOW_CASES/, 'expected HermesShadowGallery to read the shared HERMES_SHADOW_CASES const');
  for (const caseName of [
    'none',
    'controlSubtleResting',
    'controlSubtlePressed',
    'controlElevatedResting',
    'controlElevatedPressed',
    'popover',
    'chrome',
    'overlay',
  ]) {
    assert.match(sectionsSrc, new RegExp(`'${caseName}'`), `expected the exact case name '${caseName}' in hermesSections.tsx`);
  }
  assert.doesNotMatch(
    gallery,
    /controlResting/,
    'must never abbreviate a control case name (dropping Subtle/Elevated) to "controlResting"',
  );
  assert.doesNotMatch(
    sectionsSrc,
    /controlResting/,
    'must never abbreviate a control case name (dropping Subtle/Elevated) to "controlResting"',
  );

  // CC-1 correction: HermesMobile/Config/HermesShadow.swift resolves exactly three cases
  // differently by appearance — controlElevatedResting, controlElevatedPressed, and chrome.
  // Both controlSubtleResting/Pressed are constant across schemes despite the two subtle
  // opacity numbers happening to coincide light vs. dark. The case data itself now lives in the
  // shared HERMES_SHADOW_CASES const (see Issue #607 Slice A), not inline in the gallery function.
  const chromeCase = sectionsSrc.match(/\{ name: 'chrome'[^}]*\}/);
  assert.ok(chromeCase, "expected a 'chrome' shadow case object");
  assert.match(chromeCase[0], /lightOpacity:\s*0\.12\b/, 'expected chrome lightOpacity 0.12');
  assert.match(chromeCase[0], /darkOpacity:\s*0\.28\b/, 'expected chrome darkOpacity 0.28');
  assert.match(chromeCase[0], /adaptive:\s*true/, 'expected chrome to be adaptive, matching HermesShadow.swift');

  for (const subtleName of ['controlSubtleResting', 'controlSubtlePressed']) {
    const subtleCase = sectionsSrc.match(new RegExp(`\\{ name: '${subtleName}'[^}]*\\}`));
    assert.ok(subtleCase, `expected a '${subtleName}' shadow case object`);
    assert.match(
      subtleCase[0],
      /adaptive:\s*false/,
      `expected ${subtleName} to be constant across light/dark (adaptive: false), matching HermesShadow.swift`,
    );
  }
});

// Family plan 06, CC-2: the Iconography section imports two same-directory generated .json
// artifacts directly (see test above) — TypeScript needs resolveJsonModule for those imports to
// typecheck at all.
test('resolveJsonModule is enabled so the catalog JSON imports typecheck', () => {
  const tsconfig = JSON.parse(read('native-preview/tsconfig.json'));
  assert.equal(
    tsconfig.compilerOptions && tsconfig.compilerOptions.resolveJsonModule,
    true,
    'expected compilerOptions.resolveJsonModule === true in native-preview/tsconfig.json',
  );
});

// Family plan 06, CC-2a: every computed (non-literal) systemName/systemImage site in the generated
// inventory must carry exactly one hand-traced entry recording every concrete SF Symbol name that
// site's expression can produce, resolved against the pinned protected Swift source.
test('computed icon site trace JSON accounts for every site in the generated inventory with a valid status', () => {
  const inventoryPath = path.join(ROOT, 'native/catalog/hermes/hermesIconInventory.generated.json');
  const tracePath = path.join(ROOT, 'native/catalog/hermes/hermesIconComputedSiteTrace.generated.json');
  assert.ok(existsSync(tracePath), `expected the generated computed-site trace JSON at ${tracePath}`);

  const inventory = JSON.parse(readFileSync(inventoryPath, 'utf8'));
  const trace = JSON.parse(readFileSync(tracePath, 'utf8'));
  assert.ok(Array.isArray(trace.entries), 'expected trace JSON to have an entries array');

  const inventorySites = inventory.computedSites.map((c) => c.site);
  const traceSites = trace.entries.map((e) => e.site);

  assert.deepEqual(
    [...traceSites].sort(),
    [...inventorySites].sort(),
    'expected exactly one trace entry per inventory computed-site, no missing or extra site',
  );

  const seen = new Set();
  for (const site of traceSites) {
    assert.ok(!seen.has(site), `duplicate trace entry for site ${site}`);
    seen.add(site);
  }

  for (const entry of trace.entries) {
    assert.match(
      entry.status,
      /^(traced|unresolved-external)$/,
      `expected a valid status for ${entry.site}, got ${entry.status}`,
    );
    assert.ok(Array.isArray(entry.resolvedNames), `expected resolvedNames to be an array for ${entry.site}`);
    for (const name of entry.resolvedNames) {
      assert.equal(typeof name, 'string', `expected every resolvedNames entry to be a string for ${entry.site}`);
    }
    assert.equal(
      new Set(entry.resolvedNames).size,
      entry.resolvedNames.length,
      `expected resolvedNames to be unique for ${entry.site}`,
    );
    assert.ok(
      entry.traceMethod === 'direct' || entry.traceMethod.startsWith('call-graph via '),
      `expected traceMethod to be "direct" or start with "call-graph via " for ${entry.site}, got ${entry.traceMethod}`,
    );
    if (entry.status === 'traced') {
      assert.ok(entry.resolvedNames.length > 0, `expected at least one resolvedName for traced site ${entry.site}`);
    }
  }

  const sortedSites = [...traceSites].sort((a, b) => a.localeCompare(b));
  assert.deepEqual(traceSites, sortedSites, 'expected trace entries sorted by site');
});

test('Hermex Token Coverage no longer claims no global spacing/radius scale or no shadow/elevation family exists, while still stating the honesty facts that remain true (no owned icon set, no semantic color layer, Dynamic Type owns type sizes)', () => {
  const src = read(HERMES_SECTIONS_PATH) + '\n' + read(HERMES_TOKEN_GALLERIES_PATH);
  assert.doesNotMatch(src, /No global Hermex spacing scale/, 'false once HermesSpacing ships');
  assert.doesNotMatch(src, /No global Hermex radius scale/, 'false once HermesRadius ships');
  assert.doesNotMatch(src, /no shadow\/elevation family/i, 'false once HermesShadow ships — case-insensitive so it also guards the lowercase knownVariants form');
  assert.match(src, /SF Symbols/);
  assert.match(src, /No semantic surface\/text\/border color layer/);
  assert.match(src, /Dynamic Type owns type sizes/);
});

// Evidence-accuracy correction, verified against Hermex HEAD d29dda8. Each of these three catalog
// claims outran what was actually verified in source/rendered evidence; this guards them from
// silently regressing back to the overclaim. Also guards that this evidence survived verbatim when
// AppFont/Adaptive Glass moved from the old "Verified foundations" group into "Tokens — Hermex".
test('Hermex Typography describes the adopted .appFont(role:) mechanism, not the retired AppFont call-site census', () => {
  const src = hermesCatalogSource();
  const section = extractHermesSection(src, 'Hermex Typography');
  assert.doesNotMatch(
    section,
    /151 references? across 33 production( Swift)? files/i,
    'Hermex Typography must not retain the pre-migration AppFont call-site count — that surface is being migrated, not documented as a static fact',
  );
  assert.match(section, /appFont\(role:\)|\.appFont\(/, 'expected Hermex Typography to describe the adopted .appFont(role:) modifier');
});

test('Hermex Typography catalogs named semibold roles and the 14pt/12pt mono roles', () => {
  const src = hermesCatalogSource();
  const section = extractHermesSection(src, 'Hermex Typography');

  for (const role of ['headlineSemibold', 'subheadlineSemibold', 'captionSemibold', 'mono14', 'mono12']) {
    assert.match(section, new RegExp(role), `expected ${role} in the Hermex Typography catalog`);
  }
  assert.match(section, /14pt monospaced/);
  assert.match(section, /12pt monospaced/);
});

test('ContentUnavailableView cites the verified production files + source references baseline, not literal "call sites", and Content Unavailable is documented as foundation-only', () => {
  const src = hermesCatalogSource();
  assert.doesNotMatch(
    src,
    /28 call sites/i,
    'ContentUnavailableView must not claim "28 call sites"',
  );
  assert.match(src, /30 production files/i, 'ContentUnavailableView should cite the verified 30 production files');
  assert.match(src, /68 source references/i, 'ContentUnavailableView should cite the verified 68 source references');
  const section = extractHermesSection(src, 'Content Unavailable');
  assert.match(section, /none imports HermexContentUnavailable\.swift/i);
});

// ─── Fable review correction packet (lineage c47cd161-f191-47d2-8851-2604a321c558) ────────────────
// Directly-validated findings from an independent review of the finished build. Each test below is
// scoped to exactly one finding; see the packet's own numbering in the session instructions.

// Finding 1: mobile source-path chip clipped mid-word at 390px (SectionBlock.tsx's `path` style was
// flex-start + overflow:hidden with no width cap or wrap behavior).
test("SectionBlock's source-path chip wraps long unbreakable paths within the content column instead of clipping, while still hugging short paths", () => {
  const src = read(SECTION_BLOCK_PATH);
  const pathBlockMatch = src.match(/path:\s*\{[\s\S]*?\n {2}\},/);
  assert.ok(pathBlockMatch, 'expected a `path:` style block in SectionBlock.tsx');
  const pathBlock = pathBlockMatch[0];
  assert.match(pathBlock, /alignSelf:\s*'flex-start'/, 'short paths should still hug their own compact content width');
  assert.match(pathBlock, /maxWidth:\s*'100%'/, 'the chip must not be allowed to grow past its column\'s own width');
  assert.match(pathBlock, /flexShrink:\s*1/, 'the chip must be allowed to shrink below its unwrapped content width');
  assert.match(src, /overflowWrap|wordBreak/, 'expected a web word-break/overflow-wrap style so an unspaced long path (e.g. a full file path) actually wraps instead of overflowing');
});

// Finding 3: Pending-Request Surface's real callers are ClarificationRequestCard, BotPendingRequestCard,
// and BotRoomComposerView (verified via grep for the four `.pendingRequest*Surface` calls across the
// read-only Hermex repo); HermesMobileTests/BotPendingRequestTests.swift tests pending-request *model*
// parsing only (BotPendingRequestParsingTests) and contains zero references to the surface extensions,
// so it does not evidence them.
test('Pending-Request Surface callers/source paths correctly include ClarificationRequestCard, BotPendingRequestCard, BotRoomComposerView, and exclude the non-evidencing test file', () => {
  const src = hermesCatalogSource();
  assert.match(src, /ClarificationRequestCard/);
  assert.match(src, /BotPendingRequestCard/);
  assert.match(src, /BotRoomComposerView/);
  assert.match(src, /HermesMobile\/Features\/Chat\/ClarificationRequestCard\.swift/);
  assert.match(src, /HermesMobile\/Features\/Bots\/BotPendingRequestCard\.swift/);
  assert.match(src, /HermesMobile\/Features\/Bots\/BotRoomComposerView\.swift/);
  assert.doesNotMatch(
    src,
    /HermesMobileTests\/BotPendingRequestTests\.swift/,
    'that test file exercises pendingRequest *model* parsing (BotPendingRequestParsingTests), not the visual surfaces — it must not be cited as evidence for them',
  );
});

// Correction (design-system-foundation truthfulness pass): the prior "promoted requestCardSurface(
// cornerRadius:material:) in HermexCard.swift" claim did not match production source —
// PendingRequestSurfaces.swift's real, unchanged function is pendingRequestCardSurface(cornerRadius:)
// (a single CGFloat parameter, unconditionally opaque); no RequestCardMaterial type exists in
// production, and ApprovalRequestOverlay.swift does not call this function at all.
test('Pending Request documents the real, unchanged pendingRequestCardSurface(cornerRadius:) — never a fabricated requestCardSurface(cornerRadius:material:)/RequestCardMaterial promotion into HermexCard.swift, and never ApprovalRequestOverlay as a caller', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Pending Request');
  assert.match(section, /pendingRequestCardSurface\(cornerRadius:\)/);
  assert.doesNotMatch(section, /requestCardSurface\(cornerRadius:material:\)/, 'requestCardSurface(cornerRadius:material:) does not exist in production — this claim must not appear');
  assert.doesNotMatch(section, /RequestCardMaterial/, 'RequestCardMaterial is not defined in PendingRequestSurfaces.swift or any pending-request production file');
  assert.doesNotMatch(section, /translucentOverScrim/);
  assert.doesNotMatch(section, /HermesMobile\/Features\/Shared\/HermexCard\.swift/, 'Pending Request does not depend on HermexCard.swift');
  assert.doesNotMatch(section, /ApprovalRequestOverlay['"),.]*\s+(?:is a|as a) (?:fourth )?(?:real )?caller/i, 'ApprovalRequestOverlay.swift does not call pendingRequestCardSurface(cornerRadius:) and must not be cited as a caller');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Chat\/ApprovalRequestOverlay\.swift/, 'ApprovalRequestOverlay.swift must not appear in sourcePaths as a caller');
});

// Finding 7: source-explicit pending-surface corner radii are block=12, field=14
// (PendingRequestSurfaces.swift's PendingRequestBlockSurface/PendingRequestFieldSurface) — the
// reconstruction previously used a placeholder 10 for both. The card surface's radius is a caller-
// supplied parameter (24pt via ChatComposerMetrics.cardCornerRadius for Sessions, 14pt via
// BotPendingRequestCard.cornerRadius for Bots), so it should be captioned as such rather than
// presented as a fixed constant the way block/field are.
test('Pending-Request Surface reconstruction matches the real block/field corner radii (12/14) and captions the card radius as caller-supplied', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Pending Request');
  assert.match(src, /prBlock:\s*\{[^}]*borderRadius:\s*12,/, 'block surface corner radius should be 12 (PendingRequestBlockSurface)');
  assert.match(src, /prField:\s*\{[^}]*borderRadius:\s*14,/, 'field surface corner radius should be 14 (PendingRequestFieldSurface)');
  assert.match(section, /caller-supplied|caller-provided/i, 'expected the card surface\'s radius to be captioned as a caller-supplied parameter, not a fixed constant');
  assert.match(section, /24pt/, 'expected the Sessions caller value (ChatComposerMetrics.cardCornerRadius)');
  assert.doesNotMatch(section, /26pt/, 'the retired pre-HermesRadius Sessions value must not remain in the Pending-Request reconstruction');
});

test('Hermex Token Coverage preserves the three still-true honesty facts (SF Symbols in place of an owned icon set, no semantic color layer, Dynamic Type owns type sizes) inside the final coverage table', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const table = extractFunctionBody(src, 'HermesTokenCoverageTable');
  assert.match(table, /SF Symbols/);
  assert.match(table, /No semantic surface\/text\/border color layer/);
  assert.match(table, /Dynamic Type owns type sizes/);
});

test('the now-dead HermesTokenCoverageGallery proposal import and its own embed are removed, not left as unrendered dead code (Finding N5)', () => {
  const src = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(src, /HermesTokenCoverageGallery/, 'the retired HermesTokenCoverageGallery (aliased as HermesTokenCoverageProposalGallery) must be removed from the import list, and its embed replaced by <HermesTokenCoverageTable />, once this task lands');
  assert.doesNotMatch(src, /HermesTokenCoverageProposalGallery/, 'no reference to the old proposal-gallery alias may remain anywhere in hermesSections.tsx');
});

// Finding 8: hard line-wraps landing right after a hyphen collapse (via JSX's own whitespace
// collapsing) into a visible "word- word" artifact — e.g. "design-\n        system" renders as
// "design- system". Scans for the general pattern, not just the two reported instances, so a future
// edit reintroducing the same class of artifact elsewhere in the file also fails this test.
test('no hard-wrapped mid-word copy artifacts (a hyphen immediately followed by a line break) remain in the Hermex catalog copy', () => {
  const src = hermesCatalogSource();
  const match = src.match(/[a-z]-\n\s+[a-z]/);
  assert.ok(!match, `found a hyphen immediately followed by a line break (renders as a "word- word" artifact once JSX collapses the whitespace): ${match ? JSON.stringify(match[0]) : ''}`);
});

// Finding 5: the default computed subtitle ("Hermex · 59 components & tokens") merged 12 actually-
// audited Hermex entries with 47 un-audited retained template references into one misleading number.
// CatalogShell gains an optional override; only the Hermex route uses it — generic routes (the
// template's own two catalogs) keep the plain computed default. The default route no longer merges
// template sections at all, so its subtitle states Hermex-only information.
test('CatalogShell accepts an optional subtitle override; the Hermex route states its corrected component/token count after the AppFont split and Adaptive Glass move, contains only Hermex information, and generic routes keep the computed default', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  assert.match(shellSrc, /subtitle\?:\s*string/, 'expected CatalogShell to accept an optional subtitle override prop');

  const catalogSrc = read(HERMES_CATALOG_PATH);
  const subtitleMatch = catalogSrc.match(/subtitle="([^"]*)"/);
  assert.ok(subtitleMatch, 'expected a literal subtitle prop on the default route');
  assert.equal(subtitleMatch[1], 'Hermex · 26 visual references · token coverage in overview');
  assert.doesNotMatch(subtitleMatch[1], /template/i, 'expected the Hermex subtitle to contain only Hermex information, with no template reference count');

  const templateSrc = read(CATALOG_EXAMPLE_PATH);
  const frameworkSrc = read('native/catalog/CatalogFrameworkExample.tsx');
  for (const src of [templateSrc, frameworkSrc]) {
    assert.doesNotMatch(src, /<CatalogShell[\s\S]{0,400}subtitle=/, 'the retained generic catalogs must keep the computed default subtitle, not a hardcoded override');
  }
});

// Finding 9: the active sidebar link relied on color alone (`labelActive: { color: CATALOG_COLOR.accent }`)
// and set an ARIA-invalid `accessibilityState={{ selected: active }}` on a `role="link"` element
// (`aria-selected` is only valid on option/tab/row-type roles). The long sidebar list also hid its
// own scrollbar, hurting discoverability.
test('sidebar active nav links use non-color-only cues and valid web link semantics; the sidebar list keeps its own scrollbar visible', () => {
  const src = read(CATALOG_SIDEBAR_PATH);
  assert.match(src, /accessibilityRole="link"/);
  assert.doesNotMatch(
    src,
    /accessibilityState=\{\{\s*selected:\s*active\s*\}\}/,
    'aria-selected is invalid for role="link" (valid only for option/tab/row-type roles) — must be removed',
  );
  assert.match(src, /'aria-current'/, "expected an aria-current marker for the active link — react-native-web forwards it to the DOM; there is no native RN prop equivalent");
  assert.match(src, /location/, 'expected aria-current to use the "location" token for a currently-active nav link');
  // Non-color cue: bold weight and/or a background/border indicator on the active item.
  assert.match(src, /itemActive/);
  assert.match(
    src,
    /fontWeight:\s*'700'|fontWeight:\s*'800'|itemActive:\s*\{[^}]*(backgroundColor|borderLeftWidth|borderLeftColor)/,
  );
  // Keyboard focus must remain visible (regression guard — unrelated to this finding, but this
  // finding's own fix must not accidentally remove it).
  assert.match(src, /focused/);
  // The sidebar's own long nav list keeps a visible scrollbar for discoverability.
  assert.doesNotMatch(src, /showsVerticalScrollIndicator=\{false\}/, 'the sidebar nav list should show its own scrollbar');
});

// Finding 10 (partial — the rest is covered by the strengthened Motion/Radius pairing assertions
// above): the merged Hermex + template section union must have no duplicate ids, since CatalogShell
// keys its combined `sections` array by id and a collision would silently drop one section's content.
test('the merged Hermex + template section union has no duplicate ids', () => {
  const hermesBlockMatch = read(HERMES_SECTIONS_PATH).match(/export const hermesSections: SectionDef<HermesSectionId>\[\] = \[[\s\S]*?\n\];/);
  assert.ok(hermesBlockMatch, 'expected an exported hermesSections array');
  const templateBlockMatch = read(CATALOG_EXAMPLE_PATH).match(/export const sections: SectionDef<SectionId>\[\] = \[[\s\S]*?\n\];/);
  assert.ok(templateBlockMatch, 'expected an exported sections array in CatalogExample.tsx');

  // Anchored to "  {\n    id: '...'" — a top-level SectionDef's own `id` field, immediately after its
  // object literal opens — not a bare `/id:\s*'.../ ` scan, which also matches unrelated inline data
  // (e.g. a demo's own `PillRowItem` literals like `{ id: 'home', ... }` inside a section's `node:`).
  const idsFrom = (block) => [...block.matchAll(/\n {2}\{\s*\n {4}id: '([^']+)'/g)].map((m) => m[1]);
  const hermesIds = idsFrom(hermesBlockMatch[0]);
  const templateIds = idsFrom(templateBlockMatch[0]);
  assert.ok(hermesIds.length >= 13, `expected at least 13 Hermex-specific section ids, found ${hermesIds.length}`);
  assert.ok(templateIds.length >= 47, `expected at least 47 template section ids, found ${templateIds.length}`);

  const allIds = [...hermesIds, ...templateIds];
  const seen = new Set();
  const duplicates = allIds.filter((id) => (seen.has(id) ? true : (seen.add(id), false)));
  assert.equal(duplicates.length, 0, `expected no duplicate ids across the merged Hermex+template section union; duplicates: ${duplicates.join(', ')}`);
});

test("VariantGroup's left-aligned description occupies the available width and wraps long unbroken tokens (e.g. a source path) instead of overflowing its card", () => {
  const src = read(VARIANT_GROUP_PATH);

  const descMatch = src.match(/\n {2}desc:\s*\{[^}]*\}/);
  assert.ok(descMatch, 'expected a `desc` style block');
  assert.match(descMatch[0], /maxWidth:\s*'100%'/, "desc must be capped at its group's own available width");
  assert.match(descMatch[0], /flexShrink:\s*1/, 'desc must be allowed to shrink below its unwrapped content width');

  assert.match(src, /overflowWrap|wordBreak/, 'expected a web word-break/overflow-wrap style for a long unbroken source-path token inside a description');
  assert.match(
    src,
    /style=\{\[styles\.desc,[^\]]*\w+WrapStyle[^\]]*\]\}/,
    'expected the wrap style to actually be applied to the rendered description Text, not just declared unused',
  );
});

// ─── Fable review fix (2026-09-18) ────────────────────────────────────────────────────────────────
// A fresh read-only Claude Fable review of the finished token-system build returned FAIL with two
// Important findings, both independently confirmed by the controller. See
// `.superpowers/sdd/2026-09-18-hermex-token-system-implementation-plan/fable-review-fix-brief.md`.

// Finding 1: evidence/token-system-final/mobile-typography.png at 390px shows proposed typography
// identifiers (e.g. "type.caption.reg…") truncated by TypeScaleGallery's one-line sample clamp, and
// neither typeMeta() nor the old generic TYPE_USE_NOTES copy repeated the full identifier anywhere
// else in that row — so the full proposed token name was not recoverable at 390px. Fixed by making
// every proposal use note lead with its own full `step` identifier, verbatim, before the existing
// proposal/disclaimer copy (TypeScaleGallery itself — the shared template seam — must stay untouched).
test('every Hermex typography proposal use note is built from its own full step identifier (not generic copy), so the full proposed token name is recoverable even when the clamped sample truncates', () => {
  const galleriesSrc = read(HERMES_TOKEN_GALLERIES_PATH);
  const useNotesMatch = galleriesSrc.match(/const TYPE_USE_NOTES[\s\S]*?\n\) as Record<ProposedTypeStep, string>;/);
  assert.ok(useNotesMatch, 'expected a TYPE_USE_NOTES construction in HermesTokenProposalGalleries.tsx');
  assert.match(
    useNotesMatch[0],
    /`\$\{step\}[^`]*Proposed/,
    'expected each use note\'s own template literal to start with `${step}` (the full identifier) before the proposal/disclaimer copy — a generic note with no step interpolation regresses this finding',
  );

  // TypeScaleGallery itself — the shared template seam — must remain untouched by this fix.
  const typeScaleGallerySrc = read('native/catalog/TypeScaleGallery.tsx');
  assert.doesNotMatch(typeScaleGallerySrc, /numberOfLines=\{2\}|numberOfLines=\{undefined\}/, 'TypeScaleGallery.tsx must not be modified to work around this — the fix belongs in the Hermex proposal gallery\'s own use notes');
});

test('the out-of-scope HermesGeometryProposalGallery (icon size / control size / stroke width) is deleted from HermesTokenProposalGalleries.tsx as dead code, while its underlying out-of-scope reference data and contract test remain fully intact in hermesTokenProposal.ts, per spec §13', () => {
  const proposalGalleriesSrc = read(HERMES_TOKEN_GALLERIES_PATH);
  assert.doesNotMatch(proposalGalleriesSrc, /export function HermesGeometryProposalGallery/, 'HermesGeometryProposalGallery has no future adoption path (icon-size/control-size/stroke-width are permanent spec §13 non-goals) and must be deleted, not left as dead code');
  assert.doesNotMatch(
    proposalGalleriesSrc,
    /HERMES_ICON_SIZES|HERMES_CONTROL_SIZES|HERMES_CONTROL_MIN_HIT_TARGET_NOTE|HERMES_STROKES|HERMES_LAYOUT|HERMES_RETAINED_BODY_WINDOW_HEIGHT|HERMES_GEOMETRY_MIGRATION|HERMES_RADIUS_STEPS|HERMES_RADIUS_ALIASES|HERMES_RADIUS_MIGRATION/,
    'the gallery-only imports feeding the now-deleted gallery must be removed from this file\'s own import list',
  );
  assert.doesNotMatch(proposalGalleriesSrc, /const radiusPreview/, 'the module-private radiusPreview style object, used only by the deleted gallery, must be removed');
  // Shared plumbing and every other still-unadopted proposal gallery in this file must survive:
  assert.match(proposalGalleriesSrc, /function ProposalStatus/);
  assert.match(proposalGalleriesSrc, /export function AppFontProposalGallery/);
  assert.match(proposalGalleriesSrc, /export function HermesMotionProposalGallery/);
  assert.match(proposalGalleriesSrc, /export function HermesSpacingProposalGallery/);
  assert.match(proposalGalleriesSrc, /export function HermesTokenCoverageGallery/);

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /HermesGeometryProposalGallery/, 'no reference to the retired HermesGeometryProposalGallery may remain in hermesSections.tsx, including the import list');

  // This is a gallery/import deletion only, never a data deletion — the underlying out-of-scope
  // reference data and its own pre-existing contract test remain fully intact and untouched.
  const proposalDataSrc = read(HERMES_TOKEN_PROPOSAL_PATH);
  assert.match(proposalDataSrc, /HERMES_ICON_SIZES\s*=\s*\[12,\s*16,\s*20,\s*24,\s*32\]/);
  assert.match(proposalDataSrc, /HERMES_CONTROL_SIZES\s*=\s*\[32,\s*40,\s*44,\s*48\]/);
  assert.ok(proposalDataSrc.includes("'stroke.1'"));
  assert.ok(proposalDataSrc.includes("'stroke.2'"));
});

test('hermesIconInventory.generated.json is valid JSON with sorted literal/computed arrays and no timestamp field (R2: generated by the widened, label-scoped scanner, not a call-head allowlist)', () => {
  const jsonPath = 'native/catalog/hermes/hermesIconInventory.generated.json';
  assert.ok(existsSync(path.join(ROOT, jsonPath)), `${jsonPath} should exist`);
  const data = JSON.parse(read(jsonPath));
  assert.ok(Array.isArray(data.literals) && data.literals.length > 0);
  assert.ok(Array.isArray(data.computedSites));
  assert.ok(!('generatedAt' in data), 'generated output must not embed a non-reproducible timestamp');
  const names = data.literals.map((l) => l.name);
  assert.deepEqual(names, [...names].sort(), 'literals must be sorted by name for deterministic diffs');
});

// ─── Task 2: visual-first Hermex entries, Token Coverage moved to overview ──────────────────────

test('every primary Hermex entry declares hermesReference (never the removed hermes audit field), and Hermex Token Coverage is no longer a primary/nav entry', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const catalogSrc = read(HERMES_CATALOG_PATH);
  const typesSrc = read(TYPES_PATH);
  const sectionBlockSrc = read(SECTION_BLOCK_PATH);

  const primaryHermexIds = [
    'Adaptive Glass',
    'Content Unavailable',
    'Pending Request',
    'Hermes Card',
    'Attachment',
    'Hermes Banner',
    'Hermes Avatar',
    'Row Divider',
    'Tag',
    'Search',
    'Segmented Control',
    'Buttons',
    'Hermes TopNav',
    'Skeleton Loading',
    'List / ListItem',
    'Transcript Log Row',
    'Composer Toolbar',
    'Transcript Activity',
    'Composer',
    'Hermex Typography',
    'Hermex Font',
    'Hermex Colors',
    'Hermex Motion',
    'Hermex Radius & Geometry',
    'Hermex Spacing',
    'Hermex Shadow',
    'Hermex Iconography',
  ];

  for (const id of primaryHermexIds) {
    const section = extractHermesSection(sectionsSrc, id);
    assert.match(section, /hermesReference:\s*\{/, `expected "${id}" to declare hermesReference:`);
    assert.doesNotMatch(section, /\n\s*hermes:\s*\{/, `expected "${id}" to no longer declare the removed hermes: field`);
  }

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const navBlock = navBlockMatch[0];

  assert.doesNotMatch(sectionsSrc, /id:\s*'Hermex Token Coverage'/);
  assert.doesNotMatch(navBlock, /Hermex Token Coverage/);
  assert.match(sectionsSrc, /function HermesTokenCoverageTable/);
  assert.match(sectionsSrc + read(HERMES_REFERENCE_DETAILS_PATH), /Implementation notes/);
  assert.match(sectionsSrc, /Adopted in the verified local implementation; pending upstream acceptance\./);

  assert.doesNotMatch(sectionsSrc, /knownVariants|evidenceLevel|evidenceNote|disposition:/);
  assert.doesNotMatch(typesSrc, /HermesAudit|HermesDisposition|HermesEvidenceLevel/);
  assert.doesNotMatch(sectionBlockSrc, /HermesAuditPanel/);

  assert.match(catalogSrc, /subtitle="Hermex · 26 visual references · token coverage in overview"/);
});

// Pinned to specification revision 1. The 2026-09-26 revised specification explicitly supersedes
// ContentUnavailableView (renamed/expanded into the Content Unavailable pattern), Card Chrome
// (renamed/expanded into Card with Section/Request/Compact variants), Offline Cache Notice (folded
// into the new Banner family's Offline variant), and Picker Row (removed as a standalone family) —
// those four descriptions/whenToUse strings are intentionally dropped from this list rather than
// kept as stale literal-string pins; every other entry below is unchanged and still pinned verbatim.
test('Hermex entries carry the exact approved introductions from specification revision 1', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const exactDescriptions = [
    'A shared surface treatment that uses Liquid Glass when available, Material as a fallback, and an opaque background when Reduce Transparency is enabled.',
    'Colored initials identify the active server or account. In the Sessions header, the same control changes into a close button while search is open.',
    'Named text roles keep hierarchy consistent and scale with Dynamic Type. Caption, footnote, and caption 2 intentionally share the same compact base size.',
    'Hermex uses San Francisco. Callers choose a named Hermex Typography role; the role alone decides weight and design, so a caller never passes weight or design directly.',
    'Semantic colors describe purpose rather than a fixed hex value, so surfaces, text, borders, actions, and status feedback adapt correctly. Product palettes provide the selectable header and project accents.',
    'Eight named motion patterns pair intent with duration and easing. Reduce Motion shortens or removes movement while preserving the state change.',
    'A seven-step radius scale and semantic aliases shape controls, fields, cards, prominent surfaces, and app chrome. Feature-specific dimensions stay named when they are not reusable radius tokens.',
    'A 12-step spacing scale controls gaps and padding throughout Hermex, from compact icon spacing to large section separation.',
    'Eight elevation roles distinguish resting and pressed controls, popovers, composer chrome, and overlays. Some roles adjust their opacity between light and dark appearance.',
    'Hermex uses SF Symbols for navigation, actions, status, and content cues. Browse the visual inventory by symbol name; implementation traces remain secondary.',
  ];
  for (const description of exactDescriptions) {
    assert.ok(src.includes(description), `expected the exact approved introduction: "${description}"`);
  }
  const exactWhenToUse = [
    'Use it for glass-like cards and controls instead of rebuilding platform and accessibility fallbacks on each screen.',
  ];
  for (const whenToUse of exactWhenToUse) {
    assert.ok(src.includes(whenToUse), `expected the exact approved whenToUse: "${whenToUse}"`);
  }
});

// ─── Task 3: complete semantic color reference, simplified token galleries ──────────────────────

test('HERMES_SEMANTIC_COLORS declares exactly the 13 roles, each with purpose/use/previewLight/previewDark/sample, and HermesSemanticColorReference renders light/dark groups', () => {
  const dataSrc = read(HERMES_COLOR_DATA_PATH);
  const referenceSrc = read(HERMES_SEMANTIC_COLOR_REFERENCE_PATH);
  const sectionsSrc = read(HERMES_SECTIONS_PATH);

  const semanticRoles = [
    'color.background.canvas',
    'color.background.surface',
    'color.background.elevated',
    'color.text.primary',
    'color.text.secondary',
    'color.text.tertiary',
    'color.border.default',
    'color.action.accent',
    'color.status.success',
    'color.status.warning',
    'color.status.danger',
    'color.status.info',
    'color.content.disabled',
  ];
  const declaredRoles = [...dataSrc.matchAll(/\n {2}'(color\.[a-zA-Z.]+)':\s*\{/g)].map((m) => m[1]);
  assert.deepEqual(declaredRoles, semanticRoles, 'HERMES_SEMANTIC_COLORS must declare exactly these 13 roles, in this order');

  for (const role of semanticRoles) {
    const roleBlockMatch = dataSrc.match(new RegExp(`'${role.replace(/\./g, '\\.')}':\\s*\\{([\\s\\S]*?)\\n {2}\\},`));
    assert.ok(roleBlockMatch, `expected a declaration block for '${role}'`);
    const block = roleBlockMatch[1];
    for (const field of ['purpose:', 'use:', 'previewLight:', 'previewDark:', 'sample:']) {
      assert.ok(block.includes(field), `expected '${role}' to declare ${field}`);
    }
  }

  assert.match(referenceSrc, /export function HermesSemanticColorReference/);
  assert.match(referenceSrc, /scheme="Light"/);
  assert.match(referenceSrc, /scheme="Dark"/);
  for (const heading of ['Surfaces', 'Text', 'Borders', 'Actions', 'Statuses', 'Disabled content']) {
    assert.ok(referenceSrc.includes(heading), `expected group heading "${heading}"`);
  }

  // Scoped to the visible primary galleries only — not the whole file, whose Token Coverage table
  // (rendered only inside the overview's collapsed Implementation notes disclosure) still legitimately
  // uses this historical terminology.
  const primaryGalleryFnNames = [
    'HermesColorsGallery', 'HermesColorRampGallery', 'HermesProductPaletteGallery',
    'HermesGeometryGallery', 'HermesSpacingGallery', 'HermesShadowGallery',
    'HermesTypographyGallery', 'HermesFontGallery',
  ];
  const gallerySrc = primaryGalleryFnNames.map((fn) => extractFunctionBody(sectionsSrc, fn)).join('\n') + referenceSrc;
  for (const stale of [
    'Migration-count reconciliation',
    'Current production evidence',
    'adopted local implementation namespace',
    'Proposed — not yet adopted',
  ]) {
    assert.doesNotMatch(gallerySrc, new RegExp(stale.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), `expected the primary gallery source to no longer include "${stale}"`);
  }
});

test('Hermex Colors renders Color ramps / Semantic roles / Product palettes through HermesSemanticColorReference, and the primary radius/spacing/shadow galleries use concise renamed groups', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const gallery = extractFunctionBody(sectionsSrc, 'HermesColorsGallery');
  assert.match(gallery, /<HermesSemanticColorReference\s*\/>/);
  assert.match(gallery, /name="Color ramps"/);
  assert.match(gallery, /name="Semantic roles"/);
  assert.match(gallery, /name="Product palettes"/);

  assert.match(sectionsSrc, /import\s*\{\s*HermesSemanticColorReference\s*\}\s*from\s*'\.\/HermesSemanticColorReference'/);

  const geometryGallery = extractFunctionBody(sectionsSrc, 'HermesGeometryGallery');
  assert.match(geometryGallery, /name="Reusable radius roles"/);
  assert.match(geometryGallery, /name="Feature-specific geometry"/);

  const spacingGallery = extractFunctionBody(sectionsSrc, 'HermesSpacingGallery');
  assert.match(spacingGallery, /Related controls — 8 pt/);
  assert.match(spacingGallery, /Separate content groups — 24 pt/);
});

// ─── Task 4: searchable 202-name visual icon inventory ──────────────────────────────────────────

test('buildHermesIconNames deduplicates the generated literal/computed inventories into the authoritative 202-name union, and HermesIconReference renders a searchable grid of simulator-generated glyph previews with a per-tile fallback', () => {
  const iconInventory = JSON.parse(read(HERMES_ICON_INVENTORY_PATH));
  const iconTrace = JSON.parse(read(HERMES_ICON_TRACE_PATH));
  const literalNames = new Set(iconInventory.literals.map((entry) => entry.name));
  const computedNames = new Set(iconTrace.entries.flatMap((entry) => entry.resolvedNames));
  const union = [...new Set([...literalNames, ...computedNames])].sort((a, b) => a.localeCompare(b));

  assert.equal(literalNames.size, 158);
  assert.equal(computedNames.size, 154);
  assert.equal(union.length, 202);
  assert.equal(union.filter((name) => !literalNames.has(name)).length, 44);

  const referenceSrc = read(HERMES_ICON_REFERENCE_PATH);
  assert.match(referenceSrc, /import\s+hermesIconInventory\s+from\s+'\.\/hermesIconInventory\.generated\.json'/);
  assert.match(referenceSrc, /import\s+hermesIconComputedSiteTrace\s+from\s+'\.\/hermesIconComputedSiteTrace\.generated\.json'/);
  assert.match(referenceSrc, /export function buildHermesIconNames/);
  assert.match(referenceSrc, /new Set/);
  assert.match(referenceSrc, /\.flatMap\(/);
  assert.match(referenceSrc, /<TextInput/);
  assert.match(referenceSrc, /toLocaleLowerCase\(\)/);
  assert.doesNotMatch(referenceSrc, /Literal symbols/);
  assert.doesNotMatch(referenceSrc, /Computed sites/);

  // Each tile now requests a real simulator-rendered PNG and only falls back to text when that
  // specific asset is missing or fails to load — the fallback is no longer the unconditional
  // per-tile render every name got before this change.
  assert.match(referenceSrc, /from\s+'react-native'/);
  assert.match(referenceSrc, /<Image\b/);
  assert.match(referenceSrc, /onError=\{/);
  assert.match(referenceSrc, /useState/);
  assert.match(referenceSrc, /hasError/);
  assert.match(referenceSrc, /generated-icons/);
  assert.match(referenceSrc, /Glyph unavailable in browser/);
  assert.match(referenceSrc, /rendered by the iOS SF Symbols runtime/i);

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /function HermesIconographyGallery|function IconComputedSiteCard|ICON_SITE_LIMITATION_NOTE/);
  const iconographySection = extractHermesSection(sectionsSrc, 'Hermex Iconography');
  assert.match(iconographySection, /render:\s*\(\)\s*=>\s*<HermesIconReference\s*\/>/);
});

// ─── Adopted default icon-size sets (option 1): unchanged base scale + Typography/Avatar pairing ──

test('hermesIconSize.ts mirrors the adopted HermesIconSize base scale, unchanged, as the canonical icon-size source of truth', () => {
  assert.ok(existsSync(path.join(ROOT, HERMES_ICON_SIZE_PATH)), `${HERMES_ICON_SIZE_PATH} should exist as the canonical icon-size token source of truth`);
  const src = read(HERMES_ICON_SIZE_PATH);
  assert.match(src, /export const HERMES_ICON_SIZE = \{/);
  for (const [key, value] of [['xs', 12], ['small', 16], ['medium', 20], ['large', 24], ['extraLarge', 32]]) {
    assert.match(src, new RegExp(`${key}:\\s*${value}\\b`), `expected HERMES_ICON_SIZE.${key} === ${value}`);
  }
});

test('hermesIconSize.ts declares HERMES_ICON_TYPOGRAPHY_PAIRING with the exact compact/standard/prominent/title/feature aliases and their covered AppFont roles', () => {
  const src = read(HERMES_ICON_SIZE_PATH);
  assert.match(src, /export const HERMES_ICON_TYPOGRAPHY_PAIRING = \{/);
  const pairings = [
    ['compact', 'xs', ['caption', 'footnote', 'caption2', 'mono12']],
    ['standard', 'small', ['subheadline', 'subheadlineSemibold', 'mono14', 'body', 'label']],
    ['prominent', 'medium', ['headline', 'headlineSemibold', 'title3']],
    ['title', 'large', ['title2', 'title']],
    ['feature', 'extraLarge', []],
  ];
  for (const [alias, baseKey, roles] of pairings) {
    const blockMatch = src.match(new RegExp(`${alias}:\\s*\\{([\\s\\S]*?)\\n {2}\\},`));
    assert.ok(blockMatch, `expected a HERMES_ICON_TYPOGRAPHY_PAIRING.${alias} entry`);
    const block = blockMatch[1];
    assert.match(block, new RegExp(`HERMES_ICON_SIZE\\.${baseKey}\\b`), `expected ${alias} to alias HERMES_ICON_SIZE.${baseKey}`);
    for (const role of roles) {
      assert.match(block, new RegExp(`'${role}'`), `expected ${alias} to cover AppFont role '${role}'`);
    }
  }
});

test('hermesIconSize.ts declares HERMES_ICON_AVATAR_PAIRING with small/medium/large records at the approved avatar/icon pairing', () => {
  const src = read(HERMES_ICON_SIZE_PATH);
  assert.match(src, /export const HERMES_ICON_AVATAR_PAIRING = \{/);
  for (const [name, avatar, iconKey] of [['small', 32, 'medium'], ['medium', 40, 'large'], ['large', 48, 'extraLarge']]) {
    const blockMatch = src.match(new RegExp(`${name}:\\s*\\{([\\s\\S]*?)\\},`));
    assert.ok(blockMatch, `expected a HERMES_ICON_AVATAR_PAIRING.${name} entry`);
    const block = blockMatch[1];
    assert.match(block, new RegExp(`avatar:\\s*${avatar}\\b`), `expected ${name} avatar diameter ${avatar}`);
    assert.match(block, new RegExp(`icon:\\s*HERMES_ICON_SIZE\\.${iconKey}\\b`), `expected ${name} icon to alias HERMES_ICON_SIZE.${iconKey}`);
  }
});

test('hermesAttachmentSize.ts no longer owns HERMES_ICON_SIZE_EXTRA_LARGE — that alias lives solely in the canonical ./hermesIconSize module', () => {
  const src = read(HERMES_ATTACHMENT_SIZE_PATH);
  assert.doesNotMatch(src, /HERMES_ICON_SIZE_EXTRA_LARGE/, 'the duplicate icon-size export must be removed from hermesAttachmentSize.ts');
});

test('HermesComponentFamiliesPreviews.tsx and hermesSections.tsx read HERMES_ICON_SIZE.extraLarge from the canonical ./hermesIconSize module, not a duplicate export', () => {
  for (const sourcePath of [COMPONENT_FAMILIES_PREVIEWS_PATH, HERMES_SECTIONS_PATH]) {
    const src = read(sourcePath);
    assert.match(
      src,
      /import\s*\{\s*HERMES_ICON_SIZE\s*\}\s*from\s*'\.\/hermesIconSize'/,
      `expected ${sourcePath} to import HERMES_ICON_SIZE from ./hermesIconSize`,
    );
    assert.doesNotMatch(src, /HERMES_ICON_SIZE_EXTRA_LARGE/, `expected ${sourcePath} to no longer reference the retired HERMES_ICON_SIZE_EXTRA_LARGE`);
    assert.match(src, /HERMES_ICON_SIZE\.extraLarge\b/, `expected ${sourcePath} to reference HERMES_ICON_SIZE.extraLarge`);
  }
});

test('HermesIconReference renders a five-step default icon-size scale using a real generated SF Symbol asset, before the searchable inventory', () => {
  const referenceSrc = read(HERMES_ICON_REFERENCE_PATH);
  assert.match(
    referenceSrc,
    /import\s*\{\s*HERMES_ICON_SIZE,\s*HERMES_ICON_TYPOGRAPHY_PAIRING,\s*HERMES_ICON_AVATAR_PAIRING\s*\}\s*from\s*'\.\/hermesIconSize'/,
    'expected HermesIconReference.tsx to import the canonical icon-size tokens',
  );
  // The five steps are declared once, data-driven from HERMES_ICON_SIZE, at module scope — mirroring
  // the existing HermesUsageSize gallery precedent (hermesSections.tsx's HermesSpacingGallery) rather
  // than repeating each key inside the mapped render function.
  for (const key of ['xs', 'small', 'medium', 'large', 'extraLarge']) {
    assert.match(referenceSrc, new RegExp(`HERMES_ICON_SIZE\\.${key}\\b`), `expected the size-scale data to reference HERMES_ICON_SIZE.${key}`);
  }
  const scaleGalleryBody = extractFunctionBody(referenceSrc, 'IconSizeScaleGallery');
  assert.match(scaleGalleryBody, /\.map\(/, 'expected the size-scale gallery to render every step from its data source, not hand-duplicated tiles');
  assert.match(scaleGalleryBody, /iconAssetUri\(/, 'expected the size-scale gallery to reuse the real generated SF Symbol asset helper, not a substitute glyph');

  const referenceBody = extractFunctionBody(referenceSrc, 'HermesIconReference');
  const scaleIdx = referenceBody.indexOf('<IconSizeScaleGallery');
  const searchIdx = referenceBody.indexOf('styles.searchRow');
  assert.notEqual(scaleIdx, -1, 'expected HermesIconReference to render <IconSizeScaleGallery />');
  assert.notEqual(searchIdx, -1, 'expected HermesIconReference to still render the searchable inventory');
  assert.ok(scaleIdx < searchIdx, 'expected the default icon-size scale to render before the searchable inventory');
});

test('HermesIconReference documents Typography pairing (semantic name, icon size, covered AppFont roles) and Avatar pairing (20/24/32pt glyphs in 32/40/48pt containers), plus the 44pt hit-target distinction', () => {
  const referenceSrc = read(HERMES_ICON_REFERENCE_PATH);

  // The pairing name, icon size, and covered AppFont roles all come from iterating
  // HERMES_ICON_TYPOGRAPHY_PAIRING's own entries (already asserted verbatim against
  // hermesIconSize.ts above) — the guide renders each entry's key and its size/roles fields rather
  // than re-declaring the alias names or numbers locally.
  const typographyBody = extractFunctionBody(referenceSrc, 'IconTypographyPairingGuide');
  assert.match(typographyBody, /Object\.entries\(HERMES_ICON_TYPOGRAPHY_PAIRING\)/, 'expected the guide to render every pairing entry, not a hand-duplicated list');
  assert.match(typographyBody, /\.map\(/);
  assert.match(typographyBody, /pairing\.size/, 'expected the guide to display each pairing\'s icon size');
  assert.match(typographyBody, /pairing\.roles/, 'expected the guide to display each pairing\'s covered AppFont roles');

  // Same data-driven precedent for the Avatar pairing specimens: diameters/icon sizes come from
  // HERMES_ICON_AVATAR_PAIRING's own entries (already asserted verbatim against hermesIconSize.ts
  // above), not re-declared as local literals.
  const avatarBody = extractFunctionBody(referenceSrc, 'IconAvatarPairingGallery');
  assert.match(avatarBody, /Object\.entries\(HERMES_ICON_AVATAR_PAIRING\)/, 'expected the gallery to render every pairing entry, not a hand-duplicated list');
  assert.match(avatarBody, /pairing\.avatar/, 'expected each specimen\'s circular container to size from pairing.avatar');
  assert.match(avatarBody, /pairing\.icon/, 'expected each specimen\'s glyph to size from pairing.icon');

  assert.match(referenceSrc, /44[×x]44 ?pt|44 ?pt minimum interaction target|44 ?pt minimum hit target/i, 'expected explicit guidance that glyph size is separate from the 44pt minimum interaction target');
});

test('the Hermex Iconography section metadata cites HermesIconSize\'s real Swift source and documents the adopted default icon-size scale and pairing sets', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Hermex Iconography');
  assert.match(section, /HermesMobile\/Config\/HermesSpacing\.swift/, 'expected the Iconography section to cite the real Swift source for HermesIconSize');
  assert.match(section, /default icon[- ]size scale/i, 'expected the section to document the adopted default icon-size scale');
  assert.match(section, /Typography pairing/i, 'expected the section to document the Typography pairing aliases');
  assert.match(section, /Avatar pairing/i, 'expected the section to document the Avatar pairing aliases');
});

test('generate-icon-previews.mjs orchestrates a real iOS-runtime render on a portable Simulator destination and fails closed on any missing symbol', () => {
  assert.ok(existsSync(path.join(ROOT, ICON_GENERATOR_SCRIPT_PATH)), `${ICON_GENERATOR_SCRIPT_PATH} should exist`);
  const src = read(ICON_GENERATOR_SCRIPT_PATH);

  // Same dedup/sort algorithm as buildHermesIconNames, over the same two checked-in JSON files —
  // the generator must not invent its own separate symbol list.
  assert.match(src, /hermesIconInventory\.generated\.json/);
  assert.match(src, /hermesIconComputedSiteTrace\.generated\.json/);
  assert.match(src, /new Set/);
  assert.match(src, /\.flatMap\(/);

  // Portability correction (2026-09-28): no committed source may hardcode a Simulator UDID. The
  // destination must resolve at runtime: an explicit env override first, otherwise
  // discovery of an available iPhone Simulator via `simctl`, preferring the named Design System
  // device and falling back to another available iPhone — never macOS/AppKit.
  assert.doesNotMatch(src, SIMULATOR_UDID_PATTERN, 'no machine-local Simulator UDID may be hardcoded');
  assert.match(src, /process\.env\.HERMEX_ICON_SIMULATOR_UDID/, 'expected an explicit env override for the destination UDID, checked before simctl discovery');
  assert.match(src, /'simctl',\s*'list',\s*'devices',\s*'available'/, 'expected simctl device discovery scoped to available devices');
  assert.match(src, /Hermex Design System iPhone 17 Pro/, 'expected the named Design System simulator to still be preferred when present');
  assert.match(src, /iPhone/, 'expected the fallback to another available iPhone');
  assert.match(src, /-destination',\s*`id=\$\{/, 'expected a concrete resolved id=<udid> destination passed to xcodebuild, not a name-based -destination');

  assert.match(src, /xcodebuild/);
  assert.match(src, /\btest\b/);
  assert.match(src, /xcresulttool/);
  assert.match(src, /export/);
  assert.match(src, /attachments/);
  assert.match(src, /202/, 'expected the generator to assert the authoritative 202-name count');
  assert.match(src, /public[\\/]generated-icons/);

  // Fail-closed: a short symbol count, or any renderer failure, must stop the script rather than
  // silently writing a partial manifest.
  assert.match(src, /process\.exit\(1\)|throw new Error/);
});

// Portability and fallback correction (2026-09-28): controller-reproduced defects — `npm run web`
// depended on strict `generate:icons`, so it never started on a machine without Xcode/iOS Simulator,
// hiding the existing per-tile "Glyph unavailable in browser" fallback; and the generator/test
// hardcoded one machine-local Simulator UDID. Each test below is scoped to exactly one requirement.

test('Correction (2026-09-28): generate-icon-previews.mjs distinguishes optional prerequisite unavailability (missing Xcode/Simulator) from every real render or data failure via a dedicated error type', () => {
  const src = read(ICON_GENERATOR_SCRIPT_PATH);

  assert.match(src, /class PrerequisiteUnavailableError extends Error/, 'expected a dedicated error type marking "generation unavailable" distinctly from any other failure');
  assert.match(src, /--optional/, 'expected an --optional CLI flag for the best-effort browser-startup mode');

  // The optional-mode short-circuit must be wired specifically to prerequisite resolution — not to
  // runSimulatorRender, exportAttachments, or either count check — so a real compile/render/export
  // failure or a wrong/partial count always propagates to the top-level catch (process.exit(1)) in
  // both modes.
  assert.match(
    src,
    /=\s*checkPrerequisites\(\);\s*\}\s*catch\s*\(error\)\s*\{\s*if\s*\(optional\s*&&\s*error instanceof PrerequisiteUnavailableError\)\s*\{/,
    'expected the optional-mode downgrade to wrap exactly the checkPrerequisites() call',
  );

  const mainBody = extractFunctionBody(src, 'main');
  assert.match(mainBody, /names, found/, 'expected the 202-name union count check to remain unconditional inside main()');
  assert.match(mainBody, /rendered PNG attachments, found/, 'expected the exact-202-attachments check to remain unconditional inside main()');
  assert.doesNotMatch(
    mainBody,
    /runSimulatorRender\([^)]*\)[\s\S]{0,40}catch[\s\S]{0,120}if\s*\(optional/,
    'a real runSimulatorRender failure must never be caught and downgraded by the optional-mode branch',
  );
});

test('Correction (2026-09-28): npm run web starts the dev server via the generator\'s best-effort mode even without Xcode/Simulator, while npm run generate:icons stays strict', () => {
  const packageJson = JSON.parse(read(NATIVE_PREVIEW_PACKAGE_JSON_PATH));
  assert.ok(packageJson.scripts['generate:icons'], 'expected a documented explicit "generate:icons" script');
  assert.match(packageJson.scripts['generate:icons'], /generate-icon-previews\.mjs/);
  assert.doesNotMatch(packageJson.scripts['generate:icons'], /--optional/, 'the explicit generate:icons command must stay strict, never best-effort');

  assert.match(packageJson.scripts.web, /generate-icon-previews\.mjs/, 'expected `npm run web` to wire in generation rather than requiring a separate undocumented step');
  assert.match(packageJson.scripts.web, /--optional\b/, "expected `npm run web` to invoke the generator's best-effort mode so a machine without Xcode can still start the dev server");
  assert.doesNotMatch(packageJson.scripts.web, /&&\s*npm run generate:icons(?!\S)/, 'npm run web must not depend on the strict generate:icons script');

  const gitignore = read(NATIVE_PREVIEW_GITIGNORE_PATH);
  assert.match(gitignore, /public\/generated-icons|generated-icons/, 'expected generated PNGs/manifest to be gitignored, never committed');
});

test('Correction (2026-09-28): README documents strict explicit generation vs. best-effort browser startup, the destination override env var, and the honest per-tile fallback, without a machine-local UDID', () => {
  const readme = read('README.md');
  assert.doesNotMatch(readme, SIMULATOR_UDID_PATTERN, 'no machine-local Simulator UDID may be documented');
  assert.match(readme, /HERMEX_ICON_SIMULATOR_UDID/, 'expected the README to document the destination override env var');
  assert.match(readme, /--optional/, 'expected the README to name the best-effort flag npm run web uses');
  assert.match(readme, /npm run generate:icons/, 'expected the README to still document the strict explicit generation command');
  assert.match(readme, /Glyph unavailable in browser/, 'expected the README to name the existing per-tile fallback that best-effort mode preserves');
});

test('Correction (2026-09-28): machine-local Simulator UDID literals are absent from the generator and its documentation', () => {
  for (const relPath of [ICON_GENERATOR_SCRIPT_PATH, 'README.md']) {
    assert.doesNotMatch(read(relPath), SIMULATOR_UDID_PATTERN, `${relPath} must not hardcode a machine-local Simulator UDID`);
  }
});

test('the icon-renderer SwiftPM package renders through the real iOS UIKit/SwiftUI runtime (UIImage/Image systemName), never AppKit or a substitute icon library', () => {
  assert.ok(existsSync(path.join(ROOT, ICON_RENDERER_PACKAGE_PATH)), `${ICON_RENDERER_PACKAGE_PATH} should exist`);
  const packageSrc = read(ICON_RENDERER_PACKAGE_PATH);
  assert.match(packageSrc, /\.iOS\(/, 'expected the package to declare an iOS platform, not build for macOS/AppKit');
  assert.doesNotMatch(packageSrc, /\.macOS\(/);

  assert.ok(existsSync(path.join(ROOT, ICON_RENDERER_TEST_PATH)), `${ICON_RENDERER_TEST_PATH} should exist`);
  const testSrc = read(ICON_RENDERER_TEST_PATH);
  assert.match(testSrc, /import UIKit/);
  assert.doesNotMatch(testSrc, /import AppKit/);
  assert.doesNotMatch(testSrc, /NSImage/);
  assert.match(testSrc, /UIImage\(systemName:/);
  assert.match(testSrc, /XCTAttachment/);
  assert.match(testSrc, /\.keepAlways/);
  // Fail-closed: a nil UIImage(systemName:) must fail the run, not render a placeholder.
  assert.match(testSrc, /XCTAssertTrue\(missing\.isEmpty|XCTFail/);

  assert.ok(existsSync(path.join(ROOT, ICON_RENDERER_GITIGNORE_PATH)), `${ICON_RENDERER_GITIGNORE_PATH} should exist so the generated names file and build products are never committed`);
  const rendererGitignore = read(ICON_RENDERER_GITIGNORE_PATH);
  assert.match(rendererGitignore, /GeneratedNames\.swift|GeneratedResources/);
  assert.match(rendererGitignore, /\.build/);
});

test('npm run web makes the generated glyph previews available without an undocumented manual step, and a documented explicit generation command also exists', () => {
  const packageJson = JSON.parse(read(NATIVE_PREVIEW_PACKAGE_JSON_PATH));
  assert.ok(packageJson.scripts['generate:icons'], 'expected a documented explicit "generate:icons" script');
  assert.match(packageJson.scripts['generate:icons'], /generate-icon-previews\.mjs/);
  assert.match(packageJson.scripts.web, /generate:icons|generate-icon-previews\.mjs/, 'expected `npm run web` to wire in generation rather than requiring a separate undocumented step');

  const gitignore = read(NATIVE_PREVIEW_GITIGNORE_PATH);
  assert.match(gitignore, /public\/generated-icons|generated-icons/, 'expected generated PNGs/manifest to be gitignored, never committed');
});

// ─── Task 5: eight replayable motion demonstrations with Reduce Motion ──────────────────────────

test('HermesMotionReference declares all eight motion demo ids, one Replay per demo, a shared Reduce Motion control, and never autoplays or loops', () => {
  const referenceSrc = read(HERMES_MOTION_REFERENCE_PATH);
  const motionDemoIds = [
    'feedbackPress',
    'stateChange',
    'contentEnter',
    'contentExit',
    'overlayEnter',
    'overlayExit',
    'contentReposition',
    'scrollFollow',
  ];
  for (const id of motionDemoIds) {
    assert.ok(referenceSrc.includes(`'${id}'`), `expected the exact motion demo id '${id}'`);
  }
  assert.match(referenceSrc, />Replay</);
  assert.match(referenceSrc, /accessibilityLabel=\{`\$\{title\}: Replay`\}/);
  assert.match(referenceSrc, /Reduce Motion/);
  assert.match(referenceSrc, /AccessibilityInfo\.isReduceMotionEnabled/);
  assert.match(referenceSrc, /Browser demonstration; timing and compositing approximate the SwiftUI implementation\./);
  assert.doesNotMatch(referenceSrc, /Animated\.loop/);

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /function HermesMotionGallery|CHAT_MOTION:|SESSION_LIST_MOTION:|function MotionFactRow/);
  const motionSection = extractHermesSection(sectionsSrc, 'Hermex Motion');
  assert.match(motionSection, /render:\s*\(\)\s*=>\s*<HermesMotionReference\s*\/>/);
});

// Correction (final-review source accuracy): Hermex Motion's own description and alternatives
// already state eight named motion patterns (feedbackPress, stateChange, contentEnter, contentExit,
// overlayEnter, overlayExit, contentReposition, scrollFollow), but an implementation note still
// called it a stale "six-step scale" — a leftover from before the eighth pattern was added.
test('Correction (final-review source accuracy): Hermex Motion no longer calls HermesMotion.Bundle a stale "six-step scale" — it is the eight-pattern scale its own description already states', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const motionSection = extractHermesSection(sectionsSrc, 'Hermex Motion');
  assert.doesNotMatch(motionSection, /six-step scale/, 'HermesMotion.Bundle has eight named patterns, not six');
  assert.match(motionSection, /eight-pattern scale/, 'expected the implementation note to call it the eight-pattern scale');
});

// ─── Rendered-verification correction (2026-09-26) ───────────────────────────────────────────────
// Controller-owned browser verification of the completed Hermex catalog reproduced three issues:
// the Implementation notes disclosure never exposed a browser-observable expanded/collapsed state,
// the Content/Overlay exit motion demos jumped to their exited placeholder immediately on Replay
// instead of animating out over the configured duration, and Replay on web logged a
// useNativeDriver-is-missing console warning. Each test below is scoped to exactly one finding.

test('Correction (2026-09-26): the Implementation notes/Where it appears disclosure exposes an explicit aria-expanded state, since react-native-web does not translate accessibilityState.expanded into aria-expanded on its own', () => {
  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  // Preserved from the original contract.
  assert.match(detailsSrc, /accessibilityRole="button"/);
  assert.match(detailsSrc, /accessibilityState=\{\{\s*expanded\s*\}\}/);
  assert.match(detailsSrc, /<AnimatedChevron/);
  // The actual fix: react-native-web's own accessibility-prop mapping has no case for
  // `accessibilityState.expanded` (unlike disabled/checked/busy/selected), so it never reaches the
  // DOM as `aria-expanded` on its own — an explicit `aria-expanded` prop is required, same escape
  // hatch convention as CatalogSidebar's own `aria-current` cast.
  assert.match(
    detailsSrc,
    /aria-expanded=\{expanded\}/,
    'expected an explicit aria-expanded prop wired to the disclosure\'s own expanded state',
  );
});

test('Correction (2026-09-26): Content exit and Overlay exit demos animate out over their full configured duration before showing the exited placeholder, instead of switching instantly on Replay', () => {
  const referenceSrc = read(HERMES_MOTION_REFERENCE_PATH);

  // Root cause: `exited`/`closed` was derived from `playKey > 0`, and `playKey` increments
  // synchronously inside `replay()`, before the exit animation has played at all — so the
  // placeholder swapped in immediately instead of after the configured duration.
  assert.doesNotMatch(
    referenceSrc,
    /playKey > 0/,
    'the exited/closed placeholder must no longer be derived from playKey',
  );

  const contentExit = extractFunctionBody(referenceSrc, 'ContentExitDemo');
  assert.match(contentExit, /const \[exited, setExited\] = useState\(false\)/, 'expected ContentExitDemo to own its own exited state, independent of playKey');
  assert.match(contentExit, /setExited\(false\)/, 'expected Replay to first reset back to the visible resting state');
  assert.match(
    contentExit,
    /replay\(durationMs,\s*false,\s*\(\)\s*=>\s*setExited\(true\)\)/,
    'expected the exited placeholder to appear only via the animation\'s own completion callback, not synchronously when Replay is pressed',
  );

  const overlayExit = extractFunctionBody(referenceSrc, 'OverlayExitDemo');
  assert.match(overlayExit, /const \[closed, setClosed\] = useState\(false\)/, 'expected OverlayExitDemo to own its own closed state, independent of playKey');
  assert.match(overlayExit, /setClosed\(false\)/, 'expected Replay to first reset back to the visible resting state');
  assert.match(
    overlayExit,
    /replay\(durationMs,\s*false,\s*\(\)\s*=>\s*setClosed\(true\)\)/,
    'expected the closed placeholder to appear only via the animation\'s own completion callback, not synchronously when Replay is pressed',
  );

  // The shared replay hook must actually support a completion callback, invoked only once the
  // animation genuinely finishes (not when interrupted by a fresh Replay mid-animation).
  assert.match(
    referenceSrc,
    /const replay = \(durationMs: number, opacityOnly = false, onComplete\?:\s*\(\)\s*=>\s*void\)\s*=>\s*\{/,
    'expected useReplayAnimation\'s replay() to accept an optional onComplete callback',
  );
  assert.match(
    referenceSrc,
    /\.start\(\(\{\s*finished\s*\}\)\s*=>\s*\{\s*if\s*\(finished\)\s*onComplete\?\.\(\);\s*\}\)/,
    'expected the completion callback to fire only when the animation actually finished',
  );
});

test('Correction (2026-09-26): Replay never requests the native driver on web, avoiding the "useNativeDriver is not supported" console warning, while still allowed on native', () => {
  const referenceSrc = read(HERMES_MOTION_REFERENCE_PATH);
  assert.match(referenceSrc, /import\s*\{[^}]*\bPlatform\b[^}]*\}\s*from\s*'react-native'/, 'expected Platform to be imported from react-native');
  assert.doesNotMatch(
    referenceSrc,
    /useNativeDriver:\s*true/,
    'must not unconditionally request the native driver, since react-native-web has no native animated module and falls back to JS with a console warning',
  );
  assert.match(
    referenceSrc,
    /useNativeDriver:\s*Platform\.OS\s*!==\s*'web'/,
    'expected the native driver to be requested on native only, never on web',
  );
});

// ─── Reusable component families (2026-09-26 implementation plan) ──────────────────────────────
// Bounded production adoption of Avatar/Shimmer/Button/List/ListItem/Card/Divider/Badge families
// plus the strongest secondary patterns (Disclosure Row, Attachment Tile). New
// section ids deliberately avoid the bare generic-component names ('Avatar', 'Badge', 'Button',
// 'Shimmer', 'Divider') — the retained template catalog already registers sections under those
// exact ids, and CatalogShell's merged nav is keyed by id (see the "no duplicate ids" test above).
const COMPONENT_FAMILIES_PREVIEWS_PATH = 'native/catalog/hermes/HermesComponentFamiliesPreviews.tsx';

test('Card no longer describes stale 16pt-horizontal/14pt-vertical padding and states the approved 16pt-all-around default', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Card');
  assert.doesNotMatch(section, /14pt vertical/, 'the stale 16 horizontal / 14 vertical padding claim must be gone');
  assert.match(section, /16pt (?:content )?padding on every edge/, 'expected the approved 16pt-all-around default to be stated');
  // The real generic Card component (not a local recon style) is the source of truth for the default
  // padding claim — see the "Correction (gap 2)" tests below for its own density contract.
  const cardImplSrc = read('native/components/Card/Card.tsx');
  assert.match(cardImplSrc, /card:\s*\{[^}]*padding:\s*DS_SPACING\[800\]/s);
  assert.doesNotMatch(cardImplSrc, /paddingVertical|paddingHorizontal/);
});

test('Card documents HermexCard.swift as a new, foundation-only primitive that SectionCard does NOT delegate to — both remain separate, independently-implemented components', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Card');

  assert.match(section, /HermexCard\.swift is a new, foundation-only Card primitive/);
  assert.doesNotMatch(section, /SectionCard.*composition.*delegates.*HermexCard/is, 'must not claim SectionCard delegates its chrome to HermexCard.swift — SectionCard.swift does not reference HermexCard.swift');
  assert.match(section, /does not replace or share an implementation with the existing, already-adopted SectionCard\.swift/);
  assert.match(section, /outlined.*system background.*separator/is);
  assert.match(section, /no production file imports HermexCard\.swift/i);
});

// Issue #607 semantic-accuracy follow-up: the prior pass still presented HermexCard.swift as though
// it were a constructible view with `title`/`content`/`footer` slots/props of its own. HermexCard.swift
// declares no such view — title/content/footer are SectionCard's own real API (SectionCard.swift),
// a separate, pre-existing component this entry must not conflate with HermexCard's own surface
// modifiers (.hermexCardSurface(_:cornerRadius:), .compactCardSurface(cornerRadius:fill:),
// .requestCardSurface(cornerRadius:material:)).
test('Issue #607 follow-up: Hermes Card\'s own top-level props never attribute SectionCard\'s title/content/footer anatomy to HermexCard.swift, and canonicalSymbols name the real surface modifiers/metrics', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Card');
  const topLevelProps = section.split('hermesReference:')[0];

  assert.doesNotMatch(topLevelProps, /name:\s*'title'/, 'HermexCard.swift declares no title prop/slot of its own — that is SectionCard\'s real API');
  assert.doesNotMatch(topLevelProps, /name:\s*'content'/, 'HermexCard.swift declares no content prop/slot of its own — its modifiers wrap caller-owned content instead');
  assert.doesNotMatch(topLevelProps, /name:\s*'footer'/, 'HermexCard.swift declares no footer prop/slot of its own — that is SectionCard\'s real API');
  assert.match(section, /surface-modifier family|family of View (?:surface )?modifiers/i, 'expected Card to be described as a surface-modifier family, not a constructible view');

  const ref = extractHermesReferenceBlock(section);
  const canonical = extractBracketBlock(ref, /canonicalSymbols:\s*\[/);
  assert.match(canonical, /compactCardSurface/, 'expected the real .compactCardSurface(cornerRadius:fill:) modifier to be a canonical symbol');
  assert.match(canonical, /requestCardSurface/, 'expected the real .requestCardSurface(cornerRadius:material:) modifier to be a canonical symbol');
  assert.match(canonical, /RequestCardMaterial/, 'expected the real RequestCardMaterial enum to be a canonical symbol');
  assert.match(canonical, /HermexCardMetrics/, 'expected the real HermexCardMetrics enum to be a canonical symbol');
});

// Issue #607 semantic-accuracy follow-up: the prior pass attributed a `standardBorder`/
// `increasedContrastBorder` member pair to `HermexCardColors` and claimed Card chrome includes
// "elevation" — neither matches HermexCard.swift. HermexCardColors declares only primarySurface/
// secondarySurface; both border roles live on the separate, shared HermexSurfaceBorderColors
// (.resting/.increasedContrast), and `.hermexCardSurface` applies no shadow in either case.
test('Issue #607 follow-up: Hermes Card never attributes a standardBorder/increasedContrastBorder member to HermexCardColors, names the real HermexSurfaceBorderColors.resting/.increasedContrast border roles, and states that the surface modifiers add no shadow', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Card');

  assert.doesNotMatch(section, /\(primarySurface\/secondarySurface\/standardBorder\/increasedContrastBorder\)/, 'HermexCardColors does not define standardBorder/increasedContrastBorder');
  assert.doesNotMatch(section, /HermexCardColors\.standardBorder/);
  assert.doesNotMatch(section, /HermexCardColors\.increasedContrastBorder/);
  assert.match(section, /HermexSurfaceBorderColors\.resting/, 'expected the real shared border role to be named');
  assert.match(section, /HermexSurfaceBorderColors\.increasedContrast/, 'expected the real shared border role to be named');
  assert.match(section, /hermexCardSurface[\s\S]{0,120}(?:adds|applies) no (?:shadow|elevation)/i, 'expected an explicit statement that the surface modifier adds no shadow/elevation');
});

// Issue #607 semantic-accuracy follow-up: the catalog reconstruction's own HERMEX_CARD_COLORS object
// mirrored the same retired standardBorder/increasedContrastBorder member names — DSR2-01 moved both
// border roles off HermexCardColors onto the shared HermexSurfaceBorderColors (already reconstructed
// here as HERMEX_SURFACE_BORDER_COLORS for Search/Text Input/Code Input) in production Swift.
test('Issue #607 follow-up: the Hermex Card catalog reconstruction\'s HERMEX_CARD_COLORS object defines only the real HermexCardColors surface roles (primarySurface/secondarySurface), and every render site sources its border color from the shared HERMEX_SURFACE_BORDER_COLORS reconstruction instead of a retired HERMEX_CARD_COLORS border member', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const objMatch = src.match(/const HERMEX_CARD_COLORS[\s\S]*?\};/);
  assert.ok(objMatch, 'expected a top-level HERMEX_CARD_COLORS object in hermesSections.tsx');
  const obj = objMatch[0];
  assert.doesNotMatch(obj, /standardBorder/, 'the retired component-local standardBorder member must be gone from the catalog reconstruction');
  assert.doesNotMatch(obj, /increasedContrastBorder/, 'the retired component-local increasedContrastBorder member must be gone from the catalog reconstruction');
  assert.match(obj, /primarySurface/);
  assert.match(obj, /secondarySurface/);
  assert.doesNotMatch(src, /HERMEX_CARD_COLORS\.standardBorder/, 'no render site may reference the retired standardBorder member');
  assert.doesNotMatch(src, /HERMEX_CARD_COLORS\.increasedContrastBorder/, 'no render site may reference the retired increasedContrastBorder member');
});

test('Avatar broadens Identity Avatar into the umbrella while keeping the original approved introduction verbatim, truthfully separating the pre-existing adopted ServerAvatarBadge/bot-face system from the new unadopted HermexAvatar.swift/HermesAvatarSize', () => {
  const src = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(src, /id:\s*'Identity Avatar'/, 'the id must be renamed, not left alongside a new duplicate');
  const section = extractHermesSection(src, 'Hermes Avatar');
  assert.match(
    section,
    /Colored initials identify the active server or account\. In the Sessions header, the same control changes into a close button while search is open\./,
    'the original approved introduction must survive verbatim inside the broadened description',
  );
  assert.match(section, /pre-existing bot-face system/i);
  assert.match(section, /HermexAvatar\.swift and HermesAvatarSize.*new in this branch/is);
  assert.match(section, /HermesMobile\/Config\/HermesSpacing\.swift/, 'HermesAvatarSize now lives in HermesSpacing.swift, not BotProfileAppearance.swift');
  assert.match(section, /HermesAvatarSize is defined in HermesMobile\/Config\/HermesSpacing\.swift, not in the pre-existing bot-appearance files/i);
  assert.match(section, /BotAvatarMarkView/);
  assert.match(section, /BotAnimatedFaceView/);
  assert.match(section, /BotInteractiveFaceView/);
  assert.match(section, /HermesMobile\/Features\/Bots\/BotAvatarStore\.swift/);
  assert.match(section, /HermesMobile\/Features\/Bots\/BotFaceMotion\.swift/);
  // BotMarkPreview is composed inside AvatarFamilyGallery (the section's own `render`), not inlined
  // as a literal `variants.items` entry — see the Avatar named/custom size API tests above.
  assert.match(section, /render:\s*\(\)\s*=>\s*<AvatarFamilyGallery/);
  const galleryBody = extractFunctionBody(src, 'AvatarFamilyGallery');
  assert.match(galleryBody, /<BotMarkPreview/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function BotMarkPreview/);
});

// Issue #607 semantic-accuracy follow-up: ServerAvatarBadge is declared `private struct` inside
// SettingsView.swift, so no agent outside that file can instantiate it — it must not remain listed
// as a canonical (externally constructible) symbol, even though it stays truthfully documented as
// adopted production evidence in prose/usedIn.
test('Issue #607 follow-up: Hermes Avatar\'s canonicalSymbols exclude the private ServerAvatarBadge while keeping it truthful in prose/usedIn', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Avatar');
  const ref = extractHermesReferenceBlock(section);
  const canonical = extractBracketBlock(ref, /canonicalSymbols:\s*\[/);

  assert.doesNotMatch(canonical, /ServerAvatarBadge/, 'ServerAvatarBadge is private (SettingsView.swift) and must not be listed as a canonical/externally-constructible symbol');
  assert.match(canonical, /HermexAvatar/, 'expected the real, externally usable HermexAvatar to remain canonical');
  assert.match(canonical, /HermesAvatarSize/, 'expected the real, externally usable HermesAvatarSize to remain canonical');
  assert.match(section, /ServerAvatarBadge/, 'ServerAvatarBadge must remain truthfully documented in prose/usedIn, just not as a canonical symbol');
});

test('Row Divider documents the shared SwiftUI HermexDivider as a new, foundation-only component with no production call site', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Row Divider');
  assert.match(section, /HermexDivider/);
  assert.match(section, /No global free-floating opacity token/);
  assert.match(section, /HermesMobile\/Features\/Shared\/HermexDivider\.swift/);
  assert.doesNotMatch(section, /HermesMobile\/Features\/Settings\/SettingsView\.swift/, 'SettingsView.swift does not import HermexDivider.swift and must not be cited as a caller');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Shared\/SectionCard\.swift/, 'SectionCard.swift does not import HermexDivider.swift and must not be cited as a caller');
  assert.match(section, /FOUNDATION_ONLY_STATUS|no production call site/i);
  assert.match(section, /<HermexDividerPreview/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function HermexDividerPreview/);
});

test('Tag is display-only, documents every Tag.Size case as a new foundation-only component, and truthfully states production\'s six independent capsule pills (still in their own pre-existing files, including SessionRowView.swift) have not migrated onto it', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Tag');
  assert.match(section, /always display-only/i);
  assert.doesNotMatch(section, /Inline Reference Link/, 'Inline Reference Link is fully retired and must no longer be named as Tag\'s interactive counterpart');
  assert.doesNotMatch(section, /accessibilityRole="link"|onPress/, 'Tag must document no interactive prop, example, or styling');
  for (const size of ['.compact', '.regular', '.prominent']) {
    assert.ok(section.includes(size), `expected the ${size} size case to be documented`);
  }
  assert.doesNotMatch(section, /\.micro\b/, 'Tag.Size has no .micro case in production — it must not be documented');
  assert.match(section, /isDecorative/);
  assert.match(section, /HermesMobile\/Features\/Shared\/Tag\.swift/);
  assert.doesNotMatch(section, /StatusCapsule\.swift/, 'StatusCapsule.swift does not exist in this worktree — Tag.swift is the real, only source file');
  for (const notCallSite of [
    'HermesMobile/Features/SessionList/SessionListItem.swift',
    'HermesMobile/Features/Tasks/TasksView.swift',
    'HermesMobile/Features/Workspace/GitWorkspaceView.swift',
    'HermesMobile/Features/Settings/DefaultProfilePickerView.swift',
    'HermesMobile/Features/Settings/SettingsView.swift',
  ]) {
    assert.doesNotMatch(section, new RegExp(notCallSite.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), `${notCallSite} does not import Tag.swift and must not be cited as a migrated call site`);
  }
  assert.match(section, /unmigrated capsule-style implementations/i);
  assert.match(section, /<TagGallery/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function TagGallery/);
});

// Correction (production reconciliation): production's Tag.Size enum (StatusCapsule.swift) has only
// .compact/.regular/.prominent cases — no .micro. The catalog previously invented a fourth, 4/2-padding
// "micro" size for Sessions' Cached/Read-only/source tags that no production call site actually uses.
test('Correction (production reconciliation): the Tag gallery has no micro size — Sessions\' Cached/Read-only/source tags render at the retained compact (8/2 padding) size', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'TagGallery');
  assert.doesNotMatch(body, /micro/i, 'the TagGallery preview must not render or caption a micro size');
  assert.doesNotMatch(body, /hPad=\{4\}/, 'no TagSwatch may use the retired 4pt micro horizontal padding');
  assert.match(body, /Cached/);
  assert.match(body, /Read-only/);
  assert.match(body, /claude-code/);
  assert.match(body, /size: compact \(8\/2 padding\)/);
});

// Issue #607 (Round 2, hermex-dsf-round-2-content-r1): Inline Reference Link is retired outright —
// its own ComposerChipRendering evidence is now documented inside Composer's own Composer Chip
// subsystem coverage (see the Composer Chip tests below), not as a standalone tappable-link entry.
test('Inline Reference Link no longer exists as a Component — no section id, no HermesSectionId union entry, no nav entry, and no preview export/import/render reference anywhere in the catalog', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /'Inline Reference Link'/, 'no reference to the retired Inline Reference Link id may remain, including in the HermesSectionId union, nav, or alternatives');
  assert.doesNotMatch(sectionsSrc, /<InlineReferenceLinkPreview/, 'no section may still render the retired preview');
  assert.doesNotMatch(sectionsSrc, /InlineReferenceLinkPreview/, 'no import of the retired preview may remain');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  assert.doesNotMatch(navBlockMatch[0], /Inline Reference Link/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.doesNotMatch(previewsSrc, /export function InlineReferenceLinkPreview/, 'the retired preview component must be deleted, not left as dead code');
});

test('Buttons documents every HermexButtonPressOnlyStyle.Chrome case and every HermexButtonEmphasis value as a new, foundation-only pair of ButtonStyles, names the shared applyingHermexButtonPressFeedback helper and optional haptics, and truthfully states that production\'s ChatTactileButtonStyle/.chatTactile and ChatDecisionButtonStyle/.chatDecision remain the real, current, unmigrated implementation', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Buttons');
  for (const chrome of ['.icon', '.compactControl', '.capsule', '.card', '.thumbnail']) {
    assert.ok(section.includes(chrome), `expected HermexButtonPressOnlyStyle.Chrome case ${chrome}`);
  }
  for (const emphasis of ['.primary', '.secondary', '.destructive']) {
    assert.ok(section.includes(emphasis), `expected HermexButtonEmphasis value ${emphasis}`);
  }
  assert.match(section, /HermesMobile\/Features\/Shared\/HermexButton\.swift/, 'expected the new, foundation-only Buttons source file');
  assert.match(section, /applyingHermexButtonPressFeedback/, 'expected the one shared press-feedback helper both ButtonStyles call');
  assert.match(section, /haptic/i, 'expected optional, opt-in haptics to be documented');
  assert.match(section, /Reduce Motion/);
  assert.match(section, /<ButtonDecisionAndTactilePreview/);

  // ChatTactileButtonStyle/.chatTactile and ChatDecisionButtonStyle/.chatDecision are the real,
  // current, unmigrated production implementation (18+ .chatTactile( call sites; the approval
  // overlay and bot pending-request card both call .chatDecision( directly) — they must be named as
  // such, never framed as "retired" or confined to a historical-only note.
  assert.match(section, /ChatTactileButtonStyle\.swift/, 'expected ChatTactileButtonStyle.swift named as the real, unchanged production file');
  assert.match(section, /\.chatTactile\(/, 'expected .chatTactile( named as a real, current production call');
  assert.match(section, /\.chatDecision\(/, 'expected .chatDecision( named as a real, current production call');
  assert.doesNotMatch(section, /retired|succeeds the retired|renamed/i, 'must not claim ChatTactileButtonStyle/ChatDecisionButtonStyle were retired, renamed, or succeeded — they are still the real production implementation');
  assert.match(section, /no \.hermexPressOnly\(_:\) call site exists in production yet/i);

  const pendingRequestSection = extractHermesSection(src, 'Pending Request');
  assert.match(pendingRequestSection, /\.chatTactile\(|\.chatDecision\(/, 'expected Pending Request to name the real .chatTactile(/.chatDecision( call sites its decision controls actually use');
  assert.doesNotMatch(pendingRequestSection, /\.hermexPressOnly\(|\.hermex\(_:emphasis:/, 'Pending Request must not claim its decision controls use the new, unadopted HermexButton API');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function ButtonDecisionAndTactilePreview/);
  const body = extractFunctionBody(previewsSrc, 'ButtonDecisionAndTactilePreview');
  assert.match(body, /HermexButtonPressOnlyStyle/);
});

test('the generic Button component gains a destructive variant backed by existing DS_SEMANTIC tokens, and the retained template catalog demonstrates it', () => {
  const typesSrc = read('native/components/Button/Button.types.ts');
  assert.match(typesSrc, /'destructive'/);

  const implSrc = read('native/components/Button/Button.tsx');
  assert.match(implSrc, /destructive:\s*\{/);
  assert.match(implSrc, /DS_SEMANTIC\.emphasis\.negative/);
  assert.match(implSrc, /DS_SEMANTIC\.shade\.negative/);
  assert.doesNotMatch(implSrc, /#[0-9a-fA-F]{3,8}/, 'the new variant must reuse existing semantic tokens, never a hardcoded hex');

  const templateSrc = read(CATALOG_EXAMPLE_PATH);
  assert.match(templateSrc, /variant:\s*'destructive'/);
});

// Root-cause fix (React Native Web Button rendering): `Animated.createAnimatedComponent(Pressable)`
// reserves its `style` prop for animated interpolation, so the function-valued
// `style={({ pressed }) => [...]}` Pressable itself supports was never invoked on web — every style
// depending on it (background, border, padding/sizing) silently dropped, rendering every documented
// Button transparent, borderless, and label-sized. The fix tracks `pressed` as plain state (the same
// pattern already used for `focused`) so `style` stays a plain array on every platform, rather than
// splitting into two nested Pressable/Animated.View layers.
test('Button fixes the reproduced React Native Web rendering bug by never passing a function to the Animated-wrapped Pressable\'s style prop, while preserving press-scale feedback, Reduce Motion, and accessibility semantics', () => {
  const implSrc = read('native/components/Button/Button.tsx');
  assert.match(implSrc, /const AnimatedPressable = Animated\.createAnimatedComponent\(Pressable\);/);
  assert.match(implSrc, /const \[pressed, setPressed\] = useState\(false\);/, 'expected pressed to be tracked as plain state, the same pattern as the existing focused state');
  assert.match(implSrc, /setPressed\(true\)/, 'expected handlePressIn to set pressed state');
  assert.match(implSrc, /setPressed\(false\)/, 'expected handlePressOut to clear pressed state');

  const returnMatch = implSrc.match(/return \(\s*<AnimatedPressable[\s\S]*?\n  \);\n\}/);
  assert.ok(returnMatch, 'expected to find the AnimatedPressable returned from ButtonImpl');
  const animatedPressableJsx = returnMatch[0];
  assert.doesNotMatch(
    animatedPressableJsx,
    /style=\{\s*\(\s*\{\s*pressed/,
    'the Animated-wrapped Pressable must never receive a function-valued style — it is silently dropped on React Native Web',
  );
  assert.match(animatedPressableJsx, /style=\{\[/, 'expected a plain style array, not a function, on the Animated-wrapped Pressable');
  assert.match(animatedPressableJsx, /variantStyle\.container/, 'expected the variant background to remain part of that plain style array');
  assert.match(animatedPressableJsx, /transform: \[\{ scale: scaleAnim \}\]/, 'expected press-scale feedback to be preserved');
  assert.match(implSrc, /useReduceMotion/, 'expected Reduce Motion handling to be preserved');
  assert.match(implSrc, /accessibilityRole="button"/);
  assert.match(implSrc, /accessibilityState=\{accessibilityState\}/);
});

test('Skeleton Loading is a new, foundation-only static primitive — no continuous shimmer introduced, and production\'s existing loading placeholders truthfully stated as not migrated onto it', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Skeleton Loading');
  assert.match(section, /foundation-only/i);
  assert.match(section, /HermesMobile\/Features\/Shared\/SkeletonPlaceholder\.swift/);
  assert.doesNotMatch(section, /HermesMobile\/Features\/SessionList\/SessionListComponents\.swift/, 'must not be cited as a SkeletonPlaceholder caller — it does not import it');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Insights\/ProviderLimitsCard\.swift/, 'must not be cited as a SkeletonPlaceholder caller — it does not import it');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Chat\/ChatTranscriptSupportingViews\.swift/, 'must not be cited as a SkeletonPlaceholder caller — it does not import it');
  assert.match(section, /none imports SkeletonPlaceholder\.swift/i);
  assert.match(section, /<HermesSkeletonGallery/, 'the static gallery, not the animated Shimmer, must be this section\'s primary render');
  assert.doesNotMatch(section, /<ShimmerFamilyGallery/, 'the animated Shimmer must not be this section\'s primary render');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function HermesSkeletonGallery/);
  const staticBody = extractFunctionBody(previewsSrc, 'HermesSkeletonGallery');
  assert.doesNotMatch(staticBody, /Animated\.|useNativeDriver/, 'the static gallery must render plain (non-animated) shapes');
  for (const shapeHint of ['skeletonTextLine', 'skeletonCircle', 'skeletonRect', 'skeletonRoundedRect', 'skeletonCard']) {
    assert.ok(staticBody.includes(shapeHint), `expected the static gallery to render the ${shapeHint} shape`);
  }
  assert.match(staticBody, /Block/, 'expected the rectangle specimen to be named as the reusable block shape');
  assert.match(staticBody, /SkeletonGroup/, 'expected a grouped composition with one accessibility announcement');

  // The catalog's own animated Shimmer remains available as a distinct, non-primary reference.
  assert.match(previewsSrc, /export function ShimmerFamilyGallery/);
  assert.match(previewsSrc, /variant="circle"/);
});

test('List / ListItem and SessionListItem.swift are new, foundation-only in this branch — SessionRowView.swift genuinely still exists and is not "retired", and no picker sheet or BotInboxView has migrated onto ListItem', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'List / ListItem');
  assert.match(section, /Picker Row/);
  assert.match(section, /SessionListItem/);
  assert.match(section, /HermesMobile\/Features\/Shared\/ListItem\.swift/);
  assert.match(section, /HermesMobile\/Features\/SessionList\/SessionListItem\.swift/, 'SessionListItem.swift is itself new in this branch, with no production caller');
  assert.doesNotMatch(section, /HermesMobile\/Features\/SessionList\/SessionListComponents\.swift/, 'must not claim SessionListComponents.swift wraps the new SessionListItem — it keeps its own pre-existing row implementation');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Bots\/BotsInboxView\.swift/, 'must not claim BotsInboxView.swift migrated onto ListItem');
  assert.doesNotMatch(section, /SessionRowView\.swift no longer exists|retired SessionRowView/i, 'SessionRowView.swift genuinely still exists in this worktree and is actively used — it was never split or retired');
  assert.match(section, /<ListItemFamilyGallery/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function ListItemFamilyGallery/);
  const body = extractFunctionBody(previewsSrc, 'ListItemFamilyGallery');
  assert.match(body, /Picker configuration/);
  assert.match(body, /SessionListItem composition/);

  // Ground truth, independent of the catalog text: SessionRowView.swift must actually exist in this
  // worktree, so the catalog can never truthfully claim it was split or retired.
  assert.ok(existsSync(path.join(ROOT, '../HermesMobile/Features/SessionList/SessionRowView.swift')), 'SessionRowView.swift must exist in the target worktree');
});

// Issue #607 (Popover Menu family slice, test-first phase): `HermexList` gains a second, explicit
// `.compactOverlay` style — plain/transparent chrome, hidden separators, compact overlay-appropriate
// insets, and bounded internal scrolling — while `.standard` stays the default and keeps its current
// output. The style is cataloged as part of the List family itself, not only inside Popover Menu.
// Written before the Swift API and this catalog documentation exist (see HermexListTests.swift), so
// this is expected to fail red until Task 6/8 land the style and its catalog entry together.
test('List / ListItem documents the new HermexList .compactOverlay style (standard remains the default) and the List gallery demonstrates it', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'List / ListItem');
  assert.match(section, /compactOverlay/, 'expected the List / ListItem entry to document the new .compactOverlay style');
  assert.match(section, /\.standard/, 'expected the entry to name .standard as the preserved default style');
  assert.match(section, /HermexPopoverMenu|Popover Menu/, 'expected the entry to note compactOverlay is exercised by Popover Menu');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'ListItemFamilyGallery');
  assert.match(body, /compactOverlay/, 'expected the List gallery to demonstrate the compact-overlay style alongside the unchanged standard specimen');
});

// Correction (final-review source accuracy): List / ListItem's canonicalSymbols, Swift usage
// example, and source paths all point at the real native ListItem.swift, so its structured
// compositionSlots/machineConfigurations must describe that native anatomy — not the React Native
// catalog reconstruction's own metadata/trailing/loading surface, which has no native equivalent.
test('Correction (final-review source accuracy): List / ListItem\'s compositionSlots describe the real native ListItem.swift anatomy (leading, title, titleAccessory, subtitle, trailingAccessory, in that order) and machineConfigurations expose native ListItemState.isPending/isDisabled and HermexList.Style.compactOverlay, never metadata/trailing/Pressable/loading', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'List / ListItem');
  const ref = extractHermesReferenceBlock(section);

  const slotsSrc = extractBracketBlock(ref, /compositionSlots:\s*\[/);
  const slotNames = [...slotsSrc.matchAll(/\{\s*name:\s*'([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(slotNames, ['leading', 'title', 'titleAccessory', 'subtitle', 'trailingAccessory'], 'expected the exact native ListItem.swift composition slot sequence');
  assert.doesNotMatch(slotsSrc, /name:\s*'metadata'/, 'metadata is a React Native catalog-reconstruction-only slot with no native ListItem.swift equivalent');
  assert.doesNotMatch(slotsSrc, /name:\s*'trailing'/, 'trailing is a React Native catalog-reconstruction-only slot name; native Swift ListItem only exposes trailingAccessory');
  assert.doesNotMatch(slotsSrc, /Pressable/, 'native SwiftUI ListItem has no Pressable; that is a React Native-only concept');

  const configsSrc = extractBracketBlock(ref, /machineConfigurations:\s*\[/);
  assert.doesNotMatch(configsSrc, /loading:\s*true/, 'loading: true is a React Native catalog-reconstruction-only prop with no native ListItem machine configuration');
  assert.match(configsSrc, /'ListItemState\.isPending':\s*true/, 'expected a native ListItemState.isPending machine configuration');
  assert.match(configsSrc, /'ListItemState\.isDisabled':\s*true/, 'expected a native ListItemState.isDisabled machine configuration');
  assert.match(configsSrc, /'HermexList\.Style':\s*'\.compactOverlay'/, 'expected the native HermexList.Style.compactOverlay machine configuration to remain');
});

// Correction (2026-09-26 catalog/production reconciliation): Picker Row's retired shared metrics
// helpers (PickerRowMetrics.minHeight/cornerRadius, pickerSelectionPill(isSelected:)) were replaced
// in the final production tree by ListItem's own ListItemMetrics.minHeight/.cornerRadius and
// listItemSelectionPill(isSelected:) — the reusable-geometry facts table must not still cite the
// retired names/source file as active.
test('Correction (production reconciliation): the reusable-geometry facts table no longer cites the retired PickerRowMetrics/ModelPickerSheet.swift pairing', () => {
  const src = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(src, /PickerRowMetrics/, 'PickerRowMetrics was retired in favor of ListItemMetrics; no active reference/token data may still cite it');
  assert.doesNotMatch(src, /pickerSelectionPill/, 'pickerSelectionPill was retired in favor of listItemSelectionPill');
});

test('Picker Row no longer exists as a standalone family — no section id, no nav entry, and no dedicated preview component', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /id:\s*'Picker Row'/);
  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  assert.doesNotMatch(navBlockMatch[0], /Picker Row/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.doesNotMatch(previewsSrc, /export function PickerRowPreview/);
});

// Issue #607 (Round 2, hermex-dsf-round-2-content-r1): Disclosure Row is retired outright, replaced
// by Transcript Log Row — a production-adopted entry documenting the real, adopted
// TranscriptLogRowView.swift directly, with no separate foundation-only DisclosureRow.swift
// reconstruction, no DisclosureRowMetrics duplicate, and no "Disclosure Row" catalog contract left
// anywhere in the file.
test('Transcript Log Row replaces Disclosure Row entirely: production-adopted status, TranscriptLogRowView.swift as the only source path, and no surviving Disclosure Row/DisclosureRow.swift/DisclosureRowMetrics catalog contract', () => {
  const src = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(src, /'Disclosure Row'/, 'no reference to the retired Disclosure Row id may remain, including in the HermesSectionId union, nav, or alternatives');
  assert.doesNotMatch(src, /HermesMobile\/Features\/Chat\/DisclosureRow\.swift/, 'DisclosureRow.swift is deleted and must not be cited as a source path');
  assert.doesNotMatch(src, /DisclosureRowMetrics/, 'DisclosureRowMetrics no longer exists and must not be cited anywhere');

  const section = extractHermesSection(src, 'Transcript Log Row');
  assert.match(section, /HermesMobile\/Features\/Chat\/TranscriptLogRowView\.swift/, 'expected TranscriptLogRowView.swift as the real, adopted source path');

  const state = extractAdoptionState(section);
  assert.equal(state, 'production-adopted', 'expected Transcript Log Row to state production-adopted status, since TranscriptLogRowView.swift is the real, unchanged, already-adopted row');

  const ref = extractHermesReferenceBlock(section);
  assert.match(ref, /compact transcript activity|summary.*detail.*status.*copy|bounded expandable body/is, 'expected useWhen to describe compact transcript activity with a summary/detail/status/copy/bounded expandable body');
  assert.match(ref, /independently expandable collection/i, 'expected avoidWhen to route a general independently-expandable collection elsewhere');
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Accordion List'), 'expected Accordion List as a structured alternative');
});

test('Transcript Log Row preserves the real production copy/accessibility contract: the exact "Copied"/"Copy" strings and both expanded/collapsed accessibility hints', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Transcript Log Row');
  assert.match(section, /Copied/);
  assert.match(section, /Copy/);
  assert.match(section, /Double tap to hide details\. Long press to copy\./, 'expected the exact expanded-state accessibility hint TranscriptLogRowView.swift uses');
  assert.match(section, /Double tap to show details\. Long press to copy\./, 'expected the exact collapsed-state accessibility hint TranscriptLogRowView.swift uses');
});

// DSR2-11: production's bodyIndent is a derived metric (iconWidth + rowSpacing = 20 + 8 = 28pt), not
// the stale pre-migration 26pt literal it replaced — both catalog records must agree with the code.
test('Correction (DSR2-11): both catalog records of TranscriptLogRowMetrics.bodyIndent state 28pt (iconWidth 20 + HermesSpacing.s8 8), matching the native TranscriptLogRowView.swift computed value, with no surviving 26pt record', () => {
  const nativeSrc = read('../HermesMobile/Features/Chat/TranscriptLogRowView.swift');
  assert.match(nativeSrc, /static let iconWidth: CGFloat = 20/, 'expected the native iconWidth to still be 20');
  assert.match(nativeSrc, /static let rowSpacing: CGFloat = HermesSpacing\.s8/, 'expected the native rowSpacing to still derive from HermesSpacing.s8');
  assert.match(nativeSrc, /static let bodyIndent: CGFloat = iconWidth \+ rowSpacing/, 'expected bodyIndent to still be derived, not a literal');

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const records = [...sectionsSrc.matchAll(/\{\s*name:\s*'TranscriptLogRowMetrics\.bodyIndent'[\s\S]*?\},/g)].map((m) => m[0]);
  assert.equal(records.length, 2, 'expected exactly two catalog records of TranscriptLogRowMetrics.bodyIndent (the human props table and the machine GEOMETRY_FACTS table)');
  for (const record of records) {
    assert.doesNotMatch(record, /26pt|default:\s*'26'/, 'stale 26pt bodyIndent value must not remain in either record');
    assert.match(record, /28pt|default:\s*'28'/, 'expected the corrected 28pt bodyIndent value in every record');
  }
});

// Correction (production reconciliation), carried forward for Round 2: production's row uses one
// token-sized downward chevron and rotates it upward from the actual expansion state. The catalog
// follows the same state model instead of swapping glyphs or rendering an arbitrary fixed direction.
test('Correction (production reconciliation): the Transcript Log Row preview rotates one downward shared Icon upward from actual expansion state', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /import\s*\{[^}]*\bDS_ICON_SIZE\b[^}]*\}\s*from\s*'\.\.\/\.\.\/\.\.\/tokens'/, 'expected DS_ICON_SIZE to be imported rather than an arbitrary chevron size literal');
  const chevronBody = extractFunctionBody(previewsSrc, 'DisclosureChevron');
  assert.match(chevronBody, /name="chevron-down"\s+size=\{DS_ICON_SIZE\.\w+\}/);
  assert.match(chevronBody, /rotate:\s*expanded\s*\?\s*'180deg'\s*:\s*'0deg'/);
  assert.doesNotMatch(chevronBody, /chevron-up/, 'rotation, not a second icon, owns the expanded state');

  for (const fnName of ['TranscriptLogRowPreview', 'TranscriptActivityPreview']) {
    const body = extractFunctionBody(previewsSrc, fnName);
    assert.doesNotMatch(body, /['"]⌄['"]|['"]›['"]/, `expected ${fnName} to render no chevron glyph literal`);
    assert.match(body, /<DisclosureChevron expanded=\{[^}]+\}\s*\/>/, `expected ${fnName} to pass actual expansion state to the shared chevron`);
  }

  const section = extractHermesSection(read(HERMES_SECTIONS_PATH), 'Transcript Log Row');
  assert.doesNotMatch(section, /logChevron/, 'the removed logChevron style must not still be referenced');
  assert.match(section, /<TranscriptLogRowPreview/);

  assert.match(previewsSrc, /export function TranscriptLogRowPreview/);
});

test('the reusable-geometry facts table and Hermex Radius & Geometry cite only the real, adopted TranscriptLogRowMetrics/TranscriptLogRowView.swift — no DisclosureRowMetrics duplicate survives anywhere', () => {
  const src = read(HERMES_SECTIONS_PATH);
  assert.match(src, /TranscriptLogRowMetrics/, 'TranscriptLogRowMetrics is the real, adopted symbol in TranscriptLogRowView.swift and must be cited as the geometry facts\' authoritative source');
  assert.match(src, /HermesMobile\/Features\/Chat\/TranscriptLogRowView\.swift/, 'TranscriptLogRowView.swift genuinely still exists in this worktree');
  assert.doesNotMatch(src, /DisclosureRowMetrics/, 'DisclosureRowMetrics no longer exists and must not be cited as a duplicate source');

  const geometrySection = extractHermesSection(src, 'Hermex Radius & Geometry');
  assert.match(geometrySection, /TranscriptLogRowMetrics/);
});

test('the still-unadopted Radius/Geometry proposal\'s retained-exception fact cites TranscriptLogRowMetrics, not the retired DisclosureRowMetrics', () => {
  const proposal = read(HERMES_TOKEN_PROPOSAL_PATH);
  assert.doesNotMatch(proposal, /DisclosureRowMetrics/, 'DisclosureRowMetrics no longer exists in the final production tree');
  assert.match(proposal, /name:\s*'TranscriptLogRowMetrics\.bodyWindowHeight'/);
});

test('Attachment documents the new, foundation-only AttachmentFileType/AttachmentTile family, Compact Card composition, and the mini-preview staying outside Card, without claiming a production call site', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Attachment');
  assert.match(section, /HermesMobile\/Features\/Shared\/AttachmentFileType\.swift/);
  assert.match(section, /HermesMobile\/Features\/Shared\/AttachmentTile\.swift/);
  assert.match(section, /Compact Card/);
  assert.match(section, /<AttachmentTileGallery/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function AttachmentTileGallery/);
  const body = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');
  assert.match(body, /Compact Card/);
  assert.match(body, /Compact attachment preview/);
  assert.match(body, /File fallback/);
  assert.match(body, /Loading/);
  assert.match(body, /Failure/);
  assert.match(body, /attachmentRemove/);
});

// Correction (design-system-foundation truthfulness pass): compactCardSurface(cornerRadius:) and
// HermexCard.swift do not exist as a real dependency of MessageBubbleView.swift or
// ChatComposerAttachmentStripView.swift — neither file imports HermexCard.swift in this branch.
// Attachment must state this as foundation-only, not as an adopted production composition.
test('Correction (design-system-foundation truthfulness pass): Attachment states its Compact-Card composition as foundation-only — MessageBubbleView.swift and ChatComposerAttachmentStripView.swift do not import HermexCard.swift or call compactCardSurface', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Attachment');
  assert.match(section, /foundation-only/i);
  assert.doesNotMatch(section, /HermesMobile\/Features\/Shared\/HermexCard\.swift/, 'Attachment does not depend on HermexCard.swift');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Chat\/MessageBubbleView\.swift/, 'MessageBubbleView.swift does not import AttachmentFileType.swift/AttachmentTile.swift and must not be cited as a caller');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Chat\/ChatComposerAttachmentStripView\.swift/, 'ChatComposerAttachmentStripView.swift does not import AttachmentFileType.swift/AttachmentTile.swift and must not be cited as a caller');
});

// DSR2-15: HermexBanner replaces the legacy Banner.swift as a foundation/catalog component only.
// Existing composer and offline-cache production surfaces remain unchanged.
test('Banner remains foundation-available with zero production call sites, while ChatView.swift and SessionListView.swift keep their independent offline notices', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Banner');
  const ref = extractHermesReferenceBlock(section);

  assert.match(ref, /adoptionStatus:\s*FOUNDATION_AVAILABLE_ADOPTION/, 'expected Banner to remain foundation-available with zero production adoption');
  assert.doesNotMatch(ref, /partially-adopted|main chat composer('s)? error branch/i, 'must not claim a production Banner adoption');

  assert.match(section, /HermesMobile\/Features\/Shared\/HermexBanner\.swift/, 'expected the native source path to be HermexBanner.swift');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Chat\/ChatComposerView\.swift/, 'ChatComposerView.swift must not be cited as a Banner caller');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Shared\/Banner\.swift/, 'expected the stale Banner.swift source path to be gone');

  assert.doesNotMatch(section, /HermesMobile\/Features\/Chat\/ChatView\.swift/, 'ChatView.swift does not import HermexBanner.swift and must not be cited as a caller');
  assert.doesNotMatch(section, /HermesMobile\/Features\/SessionList\/SessionListView\.swift/, 'SessionListView.swift does not import HermexBanner.swift and must not be cited as a caller');
  assert.match(section, /ChatView\.swift and SessionListView\.swift each still implement their own offline-cache notice independently/i, 'expected the offline-cache consolidation narrative itself to remain foundation-only, unaffected by the composer adoption');

  assert.match(section, /zero production|foundation-only|not adopted/i, 'expected implementation notes to state the foundation-only boundary');
});

// Correction (design-system-foundation truthfulness pass), carried forward under Round 2's Composer
// Chip documentation: ComposerChipToken.isInteractiveReference and ComposerChipVisualStyle do not
// exist anywhere in production source — ComposerChipToken.swift and ComposerChipRendering.swift
// render every reference kind through one uniform baked-image chip. Composer's own Composer Chip
// coverage (not a standalone Inline Reference Link entry, which is retired) must state this truthfully.
test('Correction (design-system-foundation truthfulness pass): Composer\'s Composer Chip documentation states there is no ComposerChipVisualStyle/isInteractiveReference split in production — every reference renders through one uniform chip', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Composer');
  assert.match(section, /no ComposerChipVisualStyle type, no isInteractiveReference property/i);
  assert.match(section, /HermesMobile\/Features\/Chat\/ComposerChipRendering\.swift/);
});

// Controller correction (2026-09-26, gap 1), retitled for Round 2: Reference Chip was superseded — it
// named the same ComposerChipRendering drawing path Tag's display-only capsule pills and Composer's
// own Composer Chip subsystem coverage already document their own halves of (inert skill/bot/file/
// quote references vs. a separate, unrelated capsule styling), so keeping it as a third, separate
// Components entry duplicated the taxonomy the approved specification actually adopted (§4.6). It
// must no longer exist as its own section id, nav entry, preview export, or active-family reference;
// the ComposerChipRendering evidence itself must survive, split across Tag/Composer.
test('Reference Chip no longer exists as a standalone Component — no section id, no nav entry, no preview export — and Tag/Composer carry the ComposerChipRendering split instead', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /id:\s*'Reference Chip'/, 'Reference Chip must no longer be a registered SectionDef');
  assert.doesNotMatch(sectionsSrc, /'Reference Chip'/, 'no reference to the retired Reference Chip id may remain, including in the HermesSectionId union or nav');
  assert.doesNotMatch(sectionsSrc, /<ReferenceChipPreview/, 'no section may still render the retired preview');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  assert.doesNotMatch(navBlockMatch[0], /Reference Chip/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.doesNotMatch(previewsSrc, /export function ReferenceChipPreview/, 'the retired preview component must be deleted, not left as dead code');

  // Tag and Composer both reference the real, unified ComposerChipRendering drawing path —
  // truthfully, as one uniform chip renderer with no distinct visual/interactive split today, not as
  // evidence of an adopted Tag/Composer-Chip migration.
  const tagSection = extractHermesSection(sectionsSrc, 'Tag');
  assert.match(tagSection, /ComposerChipRendering\.swift/, 'expected Tag to reference the real composer chip rendering path');
  assert.match(tagSection, /pre-existing, separately-implemented capsule styling|separate, pre-existing drawing path/i);

  const composerSection = extractHermesSection(sectionsSrc, 'Composer');
  assert.match(composerSection, /ComposerChipRendering\.swift/, 'expected Composer\'s own Composer Chip documentation to reference the real composer chip rendering path');
  assert.match(composerSection, /uniform baked-image chip/i);
});

test('every Hermex-owned component-family section is reachable from Components — Hermex; native TopNav stays outside it', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const navBlockMatch = src.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const ids = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);

  for (const id of [
    'Hermes Avatar', 'Hermes Card', 'Attachment', 'Hermes Banner', 'Row Divider', 'Tag',
    'Search', 'Buttons', 'Hermes Checkbox', 'Skeleton Loading',
    'List / ListItem', 'Transcript Log Row', 'Composer Toolbar',
  ]) {
    assert.ok(ids.includes(id), `expected "${id}" in the Components — Hermex nav group`);
  }
  assert.ok(!ids.includes('Hermes TopNav'), 'native TopNav belongs in Native iOS — Hermex, not Components — Hermex');
});

test('Checkbox is a new, foundation-only Components — Hermex entry (no production call site) that reuses the real generic catalog Checkbox, documents checked/unchecked/disabled/focus/interactive/row-owned-indicator configurations, and stays distinct from Radio/Toggle/status-checkmark controls', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /\| 'Hermes Checkbox'/, "expected 'Hermes Checkbox' in the HermesSectionId union");
  const section = extractHermesSection(sectionsSrc, 'Hermes Checkbox');
  assert.match(section, /hermesReference:\s*\{/);
  assert.match(section, /row-owned/i, 'expected the row-owned indicator configuration to be documented');
  assert.match(section, /accessibility-hidden/i, 'expected the decorative/accessibility-hidden behavior of the row-owned configuration to be documented');
  assert.match(section, /never a checkbox nested inside another control|controls are never nested/i);
  assert.match(section, /\bToggle\b/, 'expected Checkbox to be distinguished from native Toggle (not the nonexistent "Switch")');
  assert.doesNotMatch(section, /use Switch/, 'Switch is not a Hermex entry or a SwiftUI control');
  assert.match(section, /\bRadio\b/, 'expected Checkbox to be distinguished from Radio');
  assert.match(section, /Tag/, 'expected Checkbox to be distinguished from a Tag-style status/completion mark');
  assert.match(section, /HermesMobile\/Features\/Shared\/HermexCheckbox\.swift/);
  assert.doesNotMatch(section, /HermesMobile\/Features\/Bots\/BotPendingRequestCard\.swift/, 'BotPendingRequestCard.swift does not import HermexCheckbox.swift and must not be cited as a caller');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Kanban\/KanbanLabView\.swift/, 'KanbanLabView.swift does not import HermexCheckbox.swift and must not be cited as a caller');
  assert.match(section, /<CheckboxFamilyGallery/);

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const ids = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(ids.includes('Hermes Checkbox'), 'expected "Hermes Checkbox" in the Components — Hermex nav group');

  assert.match(sectionsSrc, /import\s*\{[^}]*\bCheckboxFamilyGallery\b[^}]*\}\s*from\s*'\.\/HermesComponentFamiliesPreviews'/);
});

test('the generic catalog Checkbox supports an omittable onChange for a row-owned, accessibility-hidden indicator, without a duplicate Hermex-specific component', () => {
  const implSrc = read('native/components/Checkbox/Checkbox.tsx');
  assert.match(implSrc, /onChange\?:\s*\(checked:\s*boolean\)\s*=>\s*void/, 'expected onChange to be optional');
  assert.match(implSrc, /accessibilityElementsHidden/, 'expected the row-owned configuration to hide the decorative box from assistive tech');
  assert.match(implSrc, /importantForAccessibility="no-hide-descendants"/);
  const rowOwnedBranchMatch = implSrc.match(/if \(!onChange\) \{([\s\S]*?)\n  \}/);
  assert.ok(rowOwnedBranchMatch, 'expected an explicit branch for the row-owned (no onChange) configuration');
  assert.doesNotMatch(rowOwnedBranchMatch[1], /accessibilityRole="checkbox"/, 'a non-interactive indicator must not still claim the checkbox accessibility role');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function CheckboxFamilyGallery/);
  const body = extractFunctionBody(previewsSrc, 'CheckboxFamilyGallery');
  assert.match(body, /<Checkbox checked=\{false\} onChange=\{\(\) => \{\}\} label="Unchecked"/, 'expected an unchecked instance');
  assert.match(body, /<Checkbox checked=\{true\} onChange=\{\(\) => \{\}\} label="Checked"/, 'expected a checked instance');
  assert.match(body, /disabled/, 'expected a disabled instance');
  assert.match(body, /<CheckboxRowOwnedDemo/, 'expected a row-owned indicator demo');
  const rowOwnedBody = extractFunctionBody(previewsSrc, 'CheckboxRowOwnedDemo');
  assert.match(rowOwnedBody, /<ListItem/, 'expected the row-owned demo to compose the real ListItem');
  const rowOwnedCheckboxTag = rowOwnedBody.match(/<Checkbox\b[\s\S]*?\/>/);
  assert.ok(rowOwnedCheckboxTag, 'expected a row-owned Checkbox instance');
  assert.match(rowOwnedCheckboxTag[0], /checked=\{[^}]+\}/, 'expected the row-owned Checkbox to receive its visual checked state');
  assert.match(rowOwnedCheckboxTag[0], /colors=\{HERMEX_SELECTION_CONTROL_COLORS\}/, 'expected the row-owned indicator to use the Hermex visual color mapping');
  assert.doesNotMatch(rowOwnedCheckboxTag[0], /onChange=/, 'expected the row-owned Checkbox instance to omit onChange');
  assert.match(rowOwnedBody, /selected=\{/, 'expected the owning ListItem to expose its own selected state');
  assert.doesNotMatch(previewsSrc, /export function HermexCheckbox\b/, 'must not introduce a duplicate Hermex-specific checkbox component');
});

// Correction (#607 follow-up 2): the previous "Input Field" entry mis-registered production's native
// text entry as a Components — Hermex entry that reused the generic template InputField's
// floating-label visual — production never adopts that look. It was replaced by a "Text Input" entry
// under Native iOS — Hermex documenting the real native SwiftUI controls (TextField, SecureField,
// TextEditor, `.searchable`) with an honest native-style reconstruction instead.
//
// Issue #607 (Text Input family slice, Round 2 final taxonomy — hermex-dsf-round-2-content-r1): Text
// Input's variants are exactly Default, Password, and Code — HermexTextField, HermexSecureField, and
// HermexCodeInput (HermexTextInput.swift) — over native TextField/SecureField/a 4–8-digit native
// TextField-backed one-time-code entry, the same ownership-flip pattern Search went through for
// `.hermexSearch` over `.searchable`. The retired HermexNumberField/ParseableFormatStyle typed-number
// path and any "Number" variant guidance are gone. Multiline stays truthfully native (TextEditor, not
// a newly owned wrapper) and Search stays its own separate Components family rather than a Text Input
// variant.
test('Issue #607 (Round 2 final taxonomy): Text Input has exactly three variants — Default (HermexTextField), Password (HermexSecureField), and Code (HermexCodeInput) — with no HermexNumberField/ParseableFormatStyle/typed-number-formatting/Number-variant guidance anywhere', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /\| 'Input Field'/, "the retired 'Input Field' id must no longer appear in the HermesSectionId union");
  assert.match(sectionsSrc, /\| 'Text Input'/, "expected 'Text Input' in the HermesSectionId union");

  const section = extractHermesSection(sectionsSrc, 'Text Input');
  assert.match(section, /hermesReference:\s*\{/);
  assert.match(section, /HermexTextField/, 'expected the entry to name the Hermex-owned HermexTextField wrapper (Default variant)');
  assert.match(section, /HermexSecureField/, 'expected the entry to name the Hermex-owned HermexSecureField wrapper (Password variant)');
  assert.match(section, /HermexCodeInput/, 'expected the entry to name the Hermex-owned HermexCodeInput component (Code variant)');
  assert.match(section, /\bDefault\b/, 'expected the Default variant to be named exactly');
  assert.match(section, /\bPassword\b/, 'expected the Password variant to be named exactly');
  assert.match(section, /\bCode\b/, 'expected the Code variant to be named exactly');

  assert.doesNotMatch(section, /HermexNumberField/, 'expected HermexNumberField to be fully removed');
  assert.doesNotMatch(section, /ParseableFormatStyle/, 'expected the removed typed Number Field\'s format-style path to be gone');
  assert.doesNotMatch(section, /TextField\(value:format:\)|TextField\(_:value:format:\)/, 'expected the retired native typed TextField(value:format:) path to no longer be named');
  assert.doesNotMatch(section, /Number [Vv]ariant|['"]Number['"]/, 'expected no Number variant guidance to remain');

  assert.match(section, /\b4.{0,3}8\b.*digit|4–8 digits|between 4 and 8 digits/i, 'expected the Code variant to document a 4–8 digit length range');
  assert.match(section, /paste|autofill|one[- ]time[- ]code/i, 'expected the Code variant to document paste/one-time-code autofill');
  assert.match(section, /one (?:native )?editor|single (?:native )?TextField/i, 'expected the Code variant to document exactly one native editing surface');
  assert.doesNotMatch(section, /auto-submit|onComplete/i, 'expected no auto-submit implication for the Code variant');

  assert.match(section, /TextEditor/, 'expected TextEditor to remain named as a truthful native multiline alternative');
  assert.doesNotMatch(section, /<InputField\b/, 'must not render the generic template InputField as if it were production UI');
  assert.doesNotMatch(section, /<NativeTextInputPreview/, 'expected the retired native-only preview name to be gone from this entry\'s render reference');
  assert.match(section, /generic template InputField/i, 'expected the entry to explicitly disclaim the generic template InputField');

  const ref = extractHermesReferenceBlock(section);
  assert.doesNotMatch(ref, /\.searchable/, 'Search must not be listed as a Text Input variant/prop');
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Search'), 'expected a reciprocal Search alternative');

  const state = extractAdoptionState(section);
  assert.equal(state, 'foundation-available', 'expected foundation-available, not native-platform, once the wrappers ship');
  assert.match(section, /foundation-available on this branch|are foundation-available/i, 'expected the adoptionStatus detail to state the wrappers are foundation-available on this branch');
  assert.match(section, /zero production screens use them/i, 'expected the adoptionStatus detail to truthfully report zero production adoption');
  assert.match(section, /remain unchanged/i, 'expected the adoptionStatus detail to state current direct native call sites remain unchanged');
  assert.match(section, /separate (?:adoption )?issue/i, 'expected migration to be scoped to a separate issue');
  assert.doesNotMatch(section, /adoptionStatus:\s*\{\s*state:\s*'production-adopted'/, 'Text Input must not claim production adoption');

  assert.match(section, /HermesMobile\/Features\/Shared\/HermexTextInput\.swift/, 'expected implementationNotes.sourcePaths to cite the new HermexTextInput.swift wrappers');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const nativeIOSGroupMatch = navBlockMatch[0].match(/label:\s*'Native iOS',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(nativeIOSGroupMatch, 'expected the Native iOS — Hermex nav group');
  assert.deepEqual(
    [...nativeIOSGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]),
    ['Hermes TopNav'],
    'expected Text Input to move out of Native iOS, leaving only Hermes TopNav there',
  );

  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const componentIds = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(!componentIds.includes('Input Field'), 'Input Field must no longer live in Components — Hermex');
  assert.ok(componentIds.includes('Text Input'), 'expected Text Input to move into the Components — Hermex nav group');
  assert.ok(componentIds.includes('Search'), 'Search is a Components — Hermex entry, not a Native iOS entry');

  assert.doesNotMatch(
    sectionsSrc,
    /import\s*\{[^}]*\bInputField\b[^}]*\}\s*from\s*'\.\.\/\.\.\/components'/,
    'hermesSections.tsx must no longer import the generic template InputField',
  );

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.doesNotMatch(previewsSrc, /export function NativeTextInputPreview/, 'expected the retired native-only preview to be gone');
  assert.match(section, /<HermexTextInputFamilyGallery/, 'expected Text Input to render the renamed Hermex family preview');
  assert.match(previewsSrc, /export function HermexTextInputFamilyGallery/);
  const body = extractFunctionBody(previewsSrc, 'HermexTextInputFamilyGallery');
  assert.match(body, /secureTextEntry/, 'expected an interactive secure-entry example');
  assert.doesNotMatch(body, /multiline/, 'must not demonstrate a multiline variant — TextEditor stays native, not a Text Input variant');
  assert.doesNotMatch(body, /accessibilityRole="search"/, 'must not demonstrate a search variant — Search stays its own family, not a Text Input variant');
  assert.doesNotMatch(body, /keyboardType=/, 'the Default/Password specimens must not imply a caller-facing typed-number keyboard policy — the retired Number variant is gone');
  assert.match(body, /onChangeText/, 'expected interactive entry, not a static mock');

  const codeSpecimenBody = extractFunctionBody(previewsSrc, 'HermexCodeInputSpecimen');
  assert.match(codeSpecimenBody, /keyboardType="number-pad"/, 'expected the approved Code variant to demonstrate the approved numeric keyboard intent');
  assert.match(codeSpecimenBody, /textContentType="oneTimeCode"/, 'expected the approved Code variant to demonstrate one-time-code content type');
  assert.doesNotMatch(previewsSrc, /keyboardType="decimal-pad"|keyboardType="numeric"/, 'must not reintroduce a locale-formatted typed-number keyboard policy anywhere in the catalog');
});

// DSR2-06 (correction): the Code Input specimen must actually reconstruct the approved component —
// one native TextInput editor per specimen, a decorative digit-box row hidden from accessibility,
// lengths 4/6/8, partial/complete/error/disabled states, and mutually exclusive helper/error text —
// not a bare TextField with both a helper and an error caption shown at once.
test('Correction (DSR2-06): the Code Input catalog specimen reconstructs one native TextInput per specimen behind a decorative, accessibility-hidden digit-box row, across lengths 4/6/8 and partial/complete/error/disabled states, with helper and error text mutually exclusive', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const specimenBody = extractFunctionBody(previewsSrc, 'HermexCodeInputSpecimen');

  assert.match(specimenBody, /<TextInput/, 'expected exactly one native TextInput editor per specimen');
  assert.match(specimenBody, /accessibilityElementsHidden/, 'expected the decorative digit-box row to be hidden from assistive technology');
  assert.match(specimenBody, /importantForAccessibility="no-hide-descendants"/, 'expected the decorative digit-box row to be hidden from assistive technology on Android/web');
  assert.match(specimenBody, /onChangeText/, 'expected interactive entry, not a static mock');
  assert.match(specimenBody, /replace\(\/\[\^0-9\]\/g,\s*''\)/, 'expected ASCII-digit-only filtering on entry');
  assert.match(specimenBody, /\.slice\(0,\s*length\)/, 'expected excess digits to be truncated to the configured length');
  assert.doesNotMatch(specimenBody, /onSubmitEditing|onComplete/, 'expected no auto-submit implication when the configured length is reached');

  // Helper and error must be mutually exclusive — an error-ternary followed by a helper-ternary,
  // never both rendered unconditionally in the same specimen.
  assert.match(specimenBody, /errorText\s*\?[\s\S]*?:\s*helperText\s*\?/, 'expected error text to replace helper text, never both shown at once');

  const galleryBody = extractFunctionBody(previewsSrc, 'HermexTextInputFamilyGallery');
  for (const length of [4, 6, 8]) {
    assert.match(galleryBody, new RegExp(`length=\\{${length}\\}`), `expected a Code Input specimen at length ${length}`);
  }
  assert.match(galleryBody, /partial/i, 'expected a partial-entry state to be demonstrated');
  assert.match(galleryBody, /complete/i, 'expected a complete-entry state to be demonstrated');
  assert.match(galleryBody, /errorText="Enter all 6 digits\."/, 'expected the approved error state to be demonstrated');
  assert.match(galleryBody, /disabled\b/, 'expected a disabled state to be demonstrated');
});

// Issue #607 (Round 2 final taxonomy, DSR2-06): the exact approved Default/Password/Code samples —
// label/prompt pairs for Default and Password, and label/helper/error text for Code.
test('Text Input\'s three variant samples carry the exact approved labels/prompts/helper/error text: Default ("Name" / "Enter your name"), Password ("Password" / "Enter your password"), Code ("Verification code" / "Enter the 6-digit code." / "Enter all 6 digits.")', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Text Input');

  assert.match(section, /Name/);
  assert.match(section, /Enter your name/);
  assert.match(section, /Password/);
  assert.match(section, /Enter your password/);
  assert.match(section, /Verification code/);
  assert.match(section, /Enter the 6-digit code\./);
  assert.match(section, /Enter all 6 digits\./);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'HermexTextInputFamilyGallery');
  assert.match(body, /Name/);
  assert.match(body, /Enter your name/);
  assert.match(body, /Password/);
  assert.match(body, /Enter your password/);
  assert.match(body, /Verification code/);
});

// Issue #607 (Bottom Sheet family slice): a Hermex-owned Components entry for HermexBottomSheet — a
// content scaffold supplied to native SwiftUI `.sheet` (never a replacement for it), composing a
// NavigationStack, the existing TopNav (via native `.toolbar` at modal-appropriate placements), an
// unconstrained body slot (native List or arbitrary content), and an optional horizontal/vertical
// footer pinned with `.safeAreaInset`. Foundation-only: no production sheet adopts it in this slice.
test('Issue #607: Bottom Sheet becomes a Hermex-owned Components entry (HermexBottomSheet over native `.sheet`, composing TopNav + an unconstrained body slot + an optional horizontal/vertical footer), truthfully claiming zero production adoption and distinguishing itself from Dialog and a full-screen destination', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /\| 'Bottom Sheet'/, "expected 'Bottom Sheet' in the HermesSectionId union");

  const section = extractHermesSection(sectionsSrc, 'Bottom Sheet');
  assert.match(section, /hermesReference:\s*\{/);
  assert.match(section, /HermexBottomSheet/, 'expected the entry to name the Hermex-owned HermexBottomSheet scaffold');
  assert.match(section, /NavigationStack/, 'expected the entry to document the owned NavigationStack');
  assert.match(section, /TopNav/, 'expected the entry to document composing the existing TopNav');
  assert.match(section, /\.cancellationAction/, 'expected the entry to document the modal-appropriate leading placement');
  assert.match(section, /\.confirmationAction/, 'expected the entry to document the modal-appropriate trailing placement');
  assert.match(section, /native List or arbitrary content|a native `?List`? or arbitrary content/i, 'expected the entry to document the body slot accepting List or arbitrary content');
  assert.match(section, /footerAxis/, 'expected the entry to document the footerAxis prop');
  assert.match(section, /horizontal/i);
  assert.match(section, /vertical/i);
  assert.match(section, /\.safeAreaInset/, 'expected the entry to document native safeAreaInset footer pinning');
  assert.match(section, /detents/i, 'expected the entry to state the caller keeps owning detents');
  assert.match(section, /drag indicator/i, 'expected the entry to state the caller keeps owning the drag indicator');
  assert.match(section, /interactive-dismiss/i, 'expected the entry to state the caller keeps owning interactive-dismiss policy');
  assert.match(section, /dismissal/i, 'expected the entry to state the caller keeps owning dismissal');
  assert.match(section, /Reduce Motion/, 'expected the entry to state native SwiftUI owns Reduce Motion');
  assert.match(section, /presentation motion|native SwiftUI (?:alone )?owns/i, 'expected the entry to state native SwiftUI owns presentation motion');

  const ref = extractHermesReferenceBlock(section);
  assert.match(ref, /Dialog/, 'expected avoidWhen to distinguish Bottom Sheet from the next approved Dialog family');
  assert.match(ref, /NavigationLink|navigationDestination|full-screen/i, 'expected avoidWhen/alternatives to distinguish Bottom Sheet from a full-screen/navigation destination');
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.length > 0, 'expected at least one structured alternative');

  const state = extractAdoptionState(section);
  assert.equal(state, 'foundation-available');
  assert.match(section, /foundation-available on this branch/i, 'expected the adoptionStatus detail to state foundation-available on this branch');
  assert.match(section, /zero production screens use it/i, 'expected the adoptionStatus detail to truthfully report zero production adoption');
  assert.match(section, /remain unchanged|unchanged/i, 'expected the adoptionStatus detail to state existing production sheets remain unchanged');
  assert.match(section, /separate adoption issue/i, 'expected migration to be scoped to a separate adoption issue');
  assert.doesNotMatch(section, /adoptionStatus:\s*\{\s*state:\s*'production-adopted'/, 'Bottom Sheet must not claim production adoption');

  assert.match(section, /HermesMobile\/Features\/Shared\/HermexBottomSheet\.swift/, 'expected implementationNotes.sourcePaths to cite HermexBottomSheet.swift');
  assert.match(section, /generic template catalog/i, 'expected the entry to name the generic template catalog it is distinct from');
  assert.match(section, /own BottomSheet component/i, 'expected the entry to explicitly disclaim the generic template\'s own BottomSheet component');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const componentIds = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(componentIds.includes('Bottom Sheet'), 'expected Bottom Sheet to be registered in the Components — Hermex nav group');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(section, /<HermexBottomSheetFamilyGallery/, 'expected Bottom Sheet to render its own family gallery');
  assert.match(previewsSrc, /export function HermexBottomSheetFamilyGallery/);
  assert.match(previewsSrc, /function BottomSheetSpecimen/, 'expected a shared specimen helper for the gallery\'s two demonstrated combinations');
  const specimenBody = extractFunctionBody(previewsSrc, 'BottomSheetSpecimen');
  const galleryBody = extractFunctionBody(previewsSrc, 'HermexBottomSheetFamilyGallery');
  const body = specimenBody + galleryBody;
  assert.match(specimenBody, /<TopNav/, 'expected the gallery to reuse the real TopNav reconstruction');
  assert.match(galleryBody, /<List>/, 'expected the gallery to demonstrate a native List body using the real List reconstruction');
  assert.match(galleryBody, /<ListItem/, 'expected the List body demonstration to use the real ListItem reconstruction');
  assert.match(galleryBody, /footerAxis="horizontal"/, 'expected the gallery to demonstrate a horizontal footer axis');
  assert.match(galleryBody, /footerAxis="vertical"/, 'expected the gallery to demonstrate a vertical footer axis');
  assert.doesNotMatch(previewsSrc, /from '\.\.\/\.\.\/components\/BottomSheet'/, 'must not import the generic template BottomSheet component');
  assert.doesNotMatch(body, /<BottomSheet[\s>]/, 'must not compose the generic template BottomSheet component');
  assert.doesNotMatch(body, /DragGesture|Animated\.(Value|timing)/, 'must not invent custom drag/animated behavior in the reconstruction');
});

// Issue #607 (Dialog family slice): a Hermex-owned Components entry for HermexDialog — a fully
// custom, always-centered modal mounted through the shared same-window overlay host, never a
// native `.alert`/`.sheet`/`fullScreenCover`/`Menu`/`.popover`. Non-dismissible dimmed backdrop, an
// always-present standard close button, a generic header/body, and a caller-chosen horizontal or
// vertical footer. Foundation-only: no production confirmation/alert adopts it in this slice. The
// visible sidebar/title label stays the plain 'Dialog' even though the internal id is namespaced
// 'Hermes Dialog' to avoid colliding with the retained template catalog's own bare 'Dialog' id.
test('Issue #607: Dialog becomes a Hermex-owned Components entry (HermexDialog mounted through the shared same-window overlay host, non-dismissible backdrop, always-present close button, no scrolling or text input), truthfully claiming zero production adoption and distinguishing itself from Bottom Sheet', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /\| 'Hermes Dialog'/, "expected 'Hermes Dialog' in the HermesSectionId union");

  const section = extractHermesSection(sectionsSrc, 'Hermes Dialog');
  assert.match(section, /displayName:\s*'Dialog'/, "expected the visible label to stay the plain 'Dialog', not the namespaced id");
  assert.match(section, /hermesReference:\s*\{/);
  assert.match(section, /HermexDialog/, 'expected the entry to name the Hermex-owned HermexDialog component');
  assert.match(section, /hermexDialog\(isPresented:footerAxis:header:content:footer:\)|\.hermexDialog\(/, 'expected the entry to name the hermexDialog(...) presentation modifier');
  assert.match(section, /same-window overlay host|HermexSameWindowOverlay/i, 'expected the entry to document the shared same-window overlay host');
  assert.match(section, /close button/i, 'expected the entry to document the always-present standard close button');
  assert.match(section, /never dismiss|does not dismiss|dimmed backdrop never dismisses/i, 'expected the entry to state the backdrop never dismisses Dialog');
  assert.match(section, /never scrolls|no internal scrolling|does not scroll/i, 'expected the entry to state Dialog never scrolls');
  assert.match(section, /text input|text field/i, 'expected the entry to state Dialog excludes text input');
  assert.match(section, /footerAxis/, 'expected the entry to document the footerAxis prop');
  assert.match(section, /horizontal/i);
  assert.match(section, /vertical/i);
  assert.match(section, /Escape/i, 'expected the entry to document accessibility Escape');
  assert.match(section, /heading/i, 'expected the entry to document heading-first focus/reading order');
  assert.match(section, /focus/i);
  assert.match(section, /Reduce Motion/, 'expected the entry to document the Reduce Motion fallback');

  const ref = extractHermesReferenceBlock(section);
  assert.match(ref, /Bottom Sheet/, 'expected alternatives to name Bottom Sheet for forms/long content');
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.length > 0, 'expected at least one structured alternative');

  const state = extractAdoptionState(section);
  assert.equal(state, 'foundation-available');
  assert.match(section, /foundation-available on this branch/i, 'expected the adoptionStatus detail to state foundation-available on this branch');
  assert.match(section, /zero production screens use it/i, 'expected the adoptionStatus detail to truthfully report zero production adoption');
  assert.match(section, /separate adoption issue/i, 'expected migration to be scoped to a separate adoption issue');
  assert.doesNotMatch(section, /adoptionStatus:\s*\{\s*state:\s*'production-adopted'/, 'Dialog must not claim production adoption');

  assert.match(section, /HermesMobile\/Features\/Shared\/HermexDialog\.swift/, 'expected implementationNotes.sourcePaths to cite HermexDialog.swift');
  assert.match(section, /generic template catalog/i, 'expected the entry to name the generic template catalog it is distinct from');
  assert.match(section, /own Dialog/i, 'expected the entry to explicitly disclaim the generic template\'s own Dialog component');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const componentIds = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(componentIds.includes('Hermes Dialog'), 'expected Hermes Dialog to be registered in the Components — Hermex nav group');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(section, /<DialogFamilyGallery/, 'expected Dialog to render its own family gallery');
  assert.match(previewsSrc, /export function DialogFamilyGallery/);
  assert.match(previewsSrc, /function DialogSpecimen/, 'expected a shared specimen helper for the gallery\'s demonstrated combinations');
  const specimenBody = extractFunctionBody(previewsSrc, 'DialogSpecimen');
  const galleryBody = extractFunctionBody(previewsSrc, 'DialogFamilyGallery');
  const body = specimenBody + galleryBody;
  assert.match(galleryBody, /footerAxis="horizontal"/, 'expected the gallery to demonstrate a horizontal footer axis');
  assert.match(galleryBody, /footerAxis="vertical"/, 'expected the gallery to demonstrate a vertical footer axis');
  assert.match(body, /destructive/i, 'expected the gallery to demonstrate a destructive action');
  assert.doesNotMatch(previewsSrc, /from '\.\.\/\.\.\/components\/Dialog'/, 'must not import a generic template Dialog component');
  assert.doesNotMatch(body, /<Dialog[\s>]/, 'must not compose a generic template Dialog component');
  assert.doesNotMatch(body, /onPress=\{\(\) => \{\s*\/\/ dismiss/i, 'the backdrop specimen must not simulate background-tap dismissal');
});

// Issue #607 (Popover Menu family slice, test-first phase): a Hermex-owned Components entry for the
// not-yet-implemented `HermexPopoverMenu` — a fully custom, always trigger-anchored menu mounted
// through the same shared same-window overlay host and `HermexOverlayLifecycle` as Dialog, never a
// native `Menu`/`.contextMenu`/`.popover`. Simple stable-ID action rows only (title, optional symbol,
// enabled state, standard/destructive role), rendered through `HermexList(style: .compactOverlay)` +
// `ListItem`. This test is written before `HermexPopoverMenu.swift` and its catalog entry exist, so it
// is expected to fail red until Task 8 lands both together.
test('Issue #607: Popover Menu becomes a Hermex-owned Components entry (HermexPopoverMenu mounted through the shared same-window overlay host, always trigger-anchored with above/below flip and safe-area clamp, simple action rows via HermexList(style: .compactOverlay) + ListItem), truthfully claiming zero production adoption and distinguishing itself from Dialog and Bottom Sheet', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /\| 'Hermes Popover Menu'/, "expected 'Hermes Popover Menu' in the HermesSectionId union");

  const section = extractHermesSection(sectionsSrc, 'Hermes Popover Menu');
  assert.match(section, /displayName:\s*'Popover Menu'/, "expected the visible label to be the plain 'Popover Menu'");
  assert.match(section, /hermesReference:\s*\{/);
  assert.match(section, /HermexPopoverMenu/, 'expected the entry to name the Hermex-owned HermexPopoverMenu component');
  assert.match(section, /hermexPopoverMenu\(isPresented:accessibilityLabel:actions:\)|\.hermexPopoverMenu\(/, 'expected the entry to name the hermexPopoverMenu(...) presentation modifier');
  assert.match(section, /same-window overlay host|HermexSameWindowOverlay/i, 'expected the entry to document reuse of the shared same-window overlay host');
  assert.match(section, /HermexOverlayLifecycle/, 'expected the entry to document reuse of the shared overlay lifecycle, not a bespoke one');
  assert.match(section, /anchored/i, 'expected the entry to state the menu is always trigger-anchored');
  assert.match(section, /flip/i, 'expected the entry to document the above/below flip');
  assert.match(section, /safe.area/i, 'expected the entry to document safe-area clamping');
  assert.doesNotMatch(section, /adapts? (?:into|to) a sheet|adapts? (?:into|to) a dialog/i, 'must state the menu never adapts into a sheet or centered dialog');
  assert.match(section, /HermexList\(style:\s*\.compactOverlay\)|compactOverlay/, 'expected the entry to document composing HermexList(style: .compactOverlay)');
  assert.match(section, /ListItem/, 'expected the entry to document reusing ListItem row anatomy');
  assert.match(section, /accessibilityLabel/, 'expected the entry to document the required caller-supplied accessibility label');
  assert.match(section, /disabled/i, 'expected the entry to document disabled row behavior');
  assert.match(section, /destructive/i, 'expected the entry to document destructive row semantics');
  assert.match(section, /first enabled/i, 'expected the entry to document initial focus moving to the first enabled action');
  assert.match(section, /Escape/i, 'expected the entry to document accessibility Escape dismissal');
  assert.match(section, /outside tap|tapping outside/i, 'expected the entry to document outside-tap dismissal without acting');
  assert.match(section, /exactly once|exactly-once/i, 'expected the entry to document the exactly-once action/dismissal guarantee');
  assert.match(section, /nested (?:sub)?menus?|submenus?/i, 'expected the entry to state v1 excludes nested submenus');
  assert.match(section, /toggles?/i, 'expected the entry to state v1 excludes toggles');
  assert.match(section, /selection model/i, 'expected the entry to state v1 excludes persistent selection models');

  const ref = extractHermesReferenceBlock(section);
  assert.match(ref, /Dialog/, 'expected alternatives to name Dialog for a full-attention modal decision');
  assert.match(ref, /Bottom Sheet/, 'expected alternatives to name Bottom Sheet for forms/long content');
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.length > 0, 'expected at least one structured alternative');

  const state = extractAdoptionState(section);
  assert.equal(state, 'foundation-available');
  assert.match(section, /foundation-available on this branch/i, 'expected the adoptionStatus detail to state foundation-available on this branch');
  assert.match(section, /zero production screens use it/i, 'expected the adoptionStatus detail to truthfully report zero production adoption');
  assert.match(section, /separate adoption issue/i, 'expected migration to be scoped to a separate adoption issue');
  assert.doesNotMatch(section, /adoptionStatus:\s*\{\s*state:\s*'production-adopted'/, 'Popover Menu must not claim production adoption');

  assert.match(section, /HermesMobile\/Features\/Shared\/HermexPopoverMenu\.swift/, 'expected implementationNotes.sourcePaths to cite HermexPopoverMenu.swift');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const componentIds = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(componentIds.includes('Hermes Popover Menu'), 'expected Hermes Popover Menu to be registered in the Components — Hermex nav group');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(section, /<PopoverMenuFamilyGallery/, 'expected Popover Menu to render its own family gallery');
  assert.match(previewsSrc, /export function PopoverMenuFamilyGallery/);
  assert.match(previewsSrc, /function PopoverMenuSpecimen/, 'expected a shared specimen helper for the gallery\'s demonstrated combinations');
  const specimenBody = extractFunctionBody(previewsSrc, 'PopoverMenuSpecimen');
  const galleryBody = extractFunctionBody(previewsSrc, 'PopoverMenuFamilyGallery');
  const body = specimenBody + galleryBody;
  assert.match(galleryBody, /below/i, 'expected the gallery to demonstrate placement below the trigger');
  assert.match(galleryBody, /above/i, 'expected the gallery to demonstrate the above-flip placement');
  assert.match(galleryBody, /clamp/i, 'expected the gallery to demonstrate a horizontal safe-area clamp specimen');
  assert.match(body, /disabled/i, 'expected the gallery to demonstrate a disabled row');
  assert.match(body, /destructive/i, 'expected the gallery to demonstrate a destructive row');
  assert.match(galleryBody, /scroll/i, 'expected the gallery to demonstrate an overflowing/scrolling action list');
  assert.doesNotMatch(previewsSrc, /from '\.\.\/\.\.\/components\/Popover'/, 'must not import a generic template Popover component');
  assert.doesNotMatch(previewsSrc, /from '\.\.\/\.\.\/components\/Menu'/, 'must not import a generic template Menu component');
  assert.doesNotMatch(body, /<Menu[\s>]/, 'must not compose a native-style Menu component');
});

test('Popover Menu stays action-only and directs persistent selection to Selection Sheet instead of adding a selection API of its own', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Hermes Popover Menu');
  const ref = extractHermesReferenceBlock(section);
  assert.match(ref, /Selection Sheet/i, 'expected Popover Menu to name Selection Sheet as where persistent selection belongs');
  assert.match(section, /selection model/i, 'expected Popover Menu to keep stating v1 excludes a persistent selection model');
});

// ─── Issue #607 (Selection Sheet slice, test-first phase): retires the unused Hermex Dropdown ───
// foundation/gallery/nav entry and replaces its intended fixed-option-selection role with a
// caller-presented `HermexSelectionSheet` — content composed from the existing Bottom Sheet, TopNav,
// List/ListItem, and row-owned Radio/Checkbox indicators, supporting immediate single selection and
// staged multi-selection with optional caller-controlled Search. These tests are written before
// `HermexSelectionSheet.swift` and its catalog entry exist, and before `HermexDropdown.swift`/its
// gallery are removed, so they are expected to fail red until the Selection Sheet slice lands both
// the retirement and the addition together.

test('Issue #607: Hermes Dropdown is fully retired from the catalog — no section id, nav entry, display name, or family gallery remains, while the unrelated generic template Dropdown stays available', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);

  assert.doesNotMatch(sectionsSrc, /id:\s*'Hermes Dropdown'/, 'expected the Hermes Dropdown SectionDef to be removed');
  assert.doesNotMatch(sectionsSrc, /\| 'Hermes Dropdown'/, 'expected Hermes Dropdown to be removed from the HermesSectionId union');
  assert.doesNotMatch(sectionsSrc, /DropdownFamilyGallery/, 'expected no remaining reference to DropdownFamilyGallery in hermesSections.tsx');
  assert.doesNotMatch(previewsSrc, /export function DropdownFamilyGallery/, 'expected DropdownFamilyGallery to no longer be exported');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const componentIds = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(!componentIds.includes('Hermes Dropdown'), 'expected Hermes Dropdown to be removed from the Components — Hermex nav group');

  // The generic, unrelated template Dropdown stays available to its own consumer — this slice
  // only retires Hermex's own Dropdown reference layer entry, never the shared generic component.
  assert.ok(
    existsSync(path.join(ROOT, 'native/components/Dropdown/Dropdown.tsx')),
    'expected the generic catalog Dropdown component to remain available to unrelated consumers',
  );
});

test('Issue #607: Selection Sheet becomes a Hermes-owned Components entry (HermexSelectionSheet composed from Bottom Sheet, TopNav, List/ListItem, and row-owned Radio/Checkbox indicators, caller-owned .sheet presentation, immediate single commit, staged multi Done/Cancel, optional caller-controlled Search), truthfully claiming zero production adoption', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /\| 'Hermes Selection Sheet'/, "expected 'Hermes Selection Sheet' in the HermesSectionId union");

  const section = extractHermesSection(sectionsSrc, 'Hermes Selection Sheet');
  assert.match(section, /displayName:\s*'Selection Sheet'/, "expected the visible label to be the plain 'Selection Sheet'");
  assert.match(section, /hermesReference:\s*\{/);
  assert.match(section, /HermexSelectionSheet/, 'expected the entry to name the Hermex-owned HermexSelectionSheet component');
  assert.match(section, /caller.own(?:s|ed)[^.]*\.sheet|\.sheet[^.]*caller.own/i, 'expected the entry to document caller-owned .sheet presentation');
  assert.match(section, /Bottom Sheet/i, 'expected the entry to document composing Bottom Sheet');
  assert.match(section, /TopNav/i, 'expected the entry to document composing TopNav');
  assert.match(section, /ListItem/, 'expected the entry to document composing List/ListItem rows');
  assert.match(section, /Radio/, 'expected the entry to document the row-owned Radio indicator for single selection');
  assert.match(section, /Checkbox/, 'expected the entry to document the row-owned Checkbox indicator for multi selection');
  assert.match(section, /Search/i, 'expected the entry to document optional caller-controlled Search');
  assert.match(section, /caller[^.]*(?:filter|query)|(?:filter|query)[^.]*caller/i, 'expected the entry to document caller-owned filtering/query, not component-owned filtering');
  assert.match(section, /single[^.]*(?:commit|dismiss)|commit[^.]*single/i, 'expected the entry to document immediate single-selection commit');
  assert.match(section, /Done/, 'expected the entry to document the multi-selection Done action');
  assert.match(section, /Cancel/, 'expected the entry to document the Cancel/discard action');
  assert.match(section, /disabled/i, 'expected the entry to document disabled option behavior');

  const ref = extractHermesReferenceBlock(section);
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.length > 0, 'expected at least one structured alternative');

  const state = extractAdoptionState(section);
  assert.equal(state, 'foundation-available');
  assert.match(section, /foundation-available/i, 'expected the adoptionStatus detail to state foundation-available');
  assert.match(section, /zero production/i, 'expected the adoptionStatus detail to truthfully report zero production adoption');
  assert.doesNotMatch(section, /adoptionStatus:\s*\{\s*state:\s*'production-adopted'/, 'Selection Sheet must not claim production adoption');

  assert.match(section, /HermesMobile\/Features\/Shared\/HermexSelectionSheet\.swift/, 'expected implementationNotes.sourcePaths to cite HermexSelectionSheet.swift');

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const componentIds = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(componentIds.includes('Hermes Selection Sheet'), 'expected Hermes Selection Sheet to be registered in the Components — Hermex nav group');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(section, /<SelectionSheetFamilyGallery/, 'expected Selection Sheet to render its own family gallery');
  assert.match(previewsSrc, /export function SelectionSheetFamilyGallery/);
  const galleryBody = extractFunctionBody(previewsSrc, 'SelectionSheetFamilyGallery');
  assert.match(galleryBody, /single/i, 'expected the gallery to demonstrate single selection');
  assert.match(galleryBody, /multi/i, 'expected the gallery to demonstrate staged multi-selection');
  assert.match(galleryBody, /Cancel/, 'expected the gallery to demonstrate Cancel discarding the staged draft');
  assert.match(galleryBody, /Done/, 'expected the gallery to demonstrate Done committing the staged draft');
  assert.match(galleryBody, /disabled/i, 'expected the gallery to demonstrate a disabled option');
  assert.match(galleryBody, /[Nn]o results/, 'expected the gallery to demonstrate a Search no-results specimen');
  assert.match(galleryBody, /(?:20|twenty)/i, 'expected the gallery to demonstrate a 20+ option scrolling list');

  const singleBody = extractFunctionBody(previewsSrc, 'SelectionSheetSingleDemo');
  const lockedTitleIndex = singleBody.indexOf('title="Locked profile"');
  assert.notEqual(lockedTitleIndex, -1, 'expected a rendered Locked profile row');
  const lockedRowStart = singleBody.lastIndexOf('<ListItem', lockedTitleIndex);
  const lockedRowEnd = singleBody.indexOf('/>', lockedTitleIndex);
  assert.ok(lockedRowStart !== -1 && lockedRowEnd !== -1, 'expected a complete Locked profile ListItem tag');
  const lockedRow = singleBody.slice(lockedRowStart, lockedRowEnd + 2);
  assert.match(lockedRow, /disabled/, 'expected Locked profile to expose disabled semantics');
  assert.match(lockedRow, /onPress=/, 'expected the disabled option to remain one disabled ListItem button target rather than being demoted to static content');

  const searchBody = extractFunctionBody(previewsSrc, 'SelectionSheetSearchDemo');
  assert.match(searchBody, /ref=\{searchInputRef\}/, 'expected Selection Sheet Search to expose the input focus target');
  assert.match(searchBody, /accessibilityLabel="Clear search"/, 'expected a named clear control in the optional Search specimen');
  assert.match(searchBody, /minWidth:\s*44[\s\S]{0,80}minHeight:\s*44|minHeight:\s*44[\s\S]{0,80}minWidth:\s*44/, 'expected the Search clear control to retain an independent 44pt hit target');
  assert.match(searchBody, /searchInputRef\.current\?\.focus\(\)/, 'expected clearing Search to restore input focus after emptying the caller-owned query');

  assert.doesNotMatch(previewsSrc, /from '\.\.\/\.\.\/components\/Dropdown'/, 'must not import the generic template Dropdown component into the Hermex Selection Sheet gallery');
  assert.doesNotMatch(galleryBody, /<Dropdown[\s>]/, 'must not compose the generic template Dropdown component');
});

// ─── Controller correction (2026-09-29, Popover Menu rendered-fidelity gaps 1–3) ────────────────
// A rendered-fidelity check of the family gallery this Task 8 slice already added found three real
// gaps between what the specimens/copy promise and what the source actually does: (1) the above
// placement specimen only swapped styles, never its render order, so it still painted below its
// trigger just like the below example; (2) the interactive demo's caption promises outside-tap and
// Escape dismissal that the source never wired up; (3) the same demo claims its action runs "after
// exit completed" while actually calling setOpen(false) and setLastAction(...) together, with no
// exit phase at all. These three tests pin down the real fix, not just the promised copy.
test('Controller correction (2026-09-29, Popover Menu rendered-fidelity gap 1): the above-placement specimen renders its surface before its trigger in source order (not just a style swap), so it actually paints above the trigger the way the below specimen paints below it', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const specimenBody = extractFunctionBody(previewsSrc, 'PopoverMenuSpecimen');

  const conditionalMatch = specimenBody.match(/placement === 'above'\s*\?\s*\(([\s\S]*?)\)\s*:\s*\(([\s\S]*?)\)\s*;/);
  assert.ok(conditionalMatch, "expected a `placement === 'above' ? (...) : (...)` conditional actually choosing render order, not only a style lookup");
  const [, aboveBranch, belowBranch] = conditionalMatch;

  const surfaceIdxAbove = aboveBranch.indexOf('{surface}');
  const triggerIdxAbove = aboveBranch.indexOf('{trigger}');
  assert.ok(surfaceIdxAbove !== -1 && triggerIdxAbove !== -1, 'expected both {surface} and {trigger} in the above branch');
  assert.ok(surfaceIdxAbove < triggerIdxAbove, 'expected the surface before the trigger when placement is "above", so it paints above it');

  const triggerIdxBelow = belowBranch.indexOf('{trigger}');
  const surfaceIdxBelow = belowBranch.indexOf('{surface}');
  assert.ok(triggerIdxBelow !== -1 && surfaceIdxBelow !== -1, 'expected both {trigger} and {surface} in the below branch');
  assert.ok(triggerIdxBelow < surfaceIdxBelow, 'expected the trigger before the surface when placement is "below"');

  assert.match(
    previewsSrc,
    /popoverSpecimen:\s*\{[^}]*flexGrow:\s*1[^}]*maxWidth:\s*'100%'/,
    'expected the popover specimen wrapper (shared by the above/scroll/interactive specimens) to keep the existing responsive flexGrow/maxWidth convention instead of assuming 220px always fits',
  );
});

test('Controller correction (2026-09-29, Popover Menu rendered-fidelity gap 2): the interactive Popover Menu demo wires a real outside-tap backdrop and a real Escape keydown handler instead of only promising both in its caption copy', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const demoBody = extractFunctionBody(previewsSrc, 'PopoverMenuInteractiveDemo');

  const backdropMatch = demoBody.match(/<Pressable\b[\s\S]*?style=\{preview\.popoverBackdrop\}[\s\S]*?\/>/);
  assert.ok(backdropMatch, 'expected a real backdrop Pressable using the existing preview.popoverBackdrop style, not only the trigger');
  assert.match(backdropMatch[0], /onPress=\{/, 'expected the backdrop to carry a real dismiss onPress, not be purely decorative');

  assert.match(
    demoBody,
    /Platform\.OS\s*!==\s*'web'\s*\|\|\s*typeof document === 'undefined'/,
    "expected the same Platform.OS === 'web' / typeof document guard CatalogShell already uses before touching document listeners",
  );
  assert.match(demoBody, /document\.addEventListener\('keydown',/, 'expected a real keydown listener, not just caption copy promising Escape dismissal');
  assert.match(demoBody, /event\.key === 'Escape'/, 'expected the keydown handler to check specifically for the Escape key');
  assert.match(demoBody, /document\.removeEventListener\('keydown',/, "expected the keydown listener to be torn down again, not leaked past the demo's own open state/unmount");
});

test('Controller correction (2026-09-29, Popover Menu rendered-fidelity gap 3): the interactive Popover Menu demo runs its accepted action only after a real exit phase completes, reusing the catalog\'s own overlay-exit motion value, accepts at most one pending action, and cancels it if the demo unmounts mid-exit', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const demoBody = extractFunctionBody(previewsSrc, 'PopoverMenuInteractiveDemo');

  assert.doesNotMatch(
    demoBody,
    /setOpen\(false\);\s*setLastAction\(/,
    'must not close and set the last action together at press time — that is the exact reported bug: no exit phase at all',
  );

  assert.match(demoBody, /Animated\.timing\(opacity,\s*\{/, 'expected a real Animated.timing transition driving entry/exit, not an immediate setState');
  assert.match(
    demoBody,
    /HERMES_MOTION_BUNDLES\['motion\.overlay\.exit'\]\.durationMs/,
    "expected the exit duration to reuse the catalog's own existing motion.overlay.exit token instead of an invented number",
  );

  const renameMatch = demoBody.match(/title="Rename"\s+onPress=\{([^}]*)\}/);
  const deleteMatch = demoBody.match(/title="Delete"\s+onPress=\{([^}]*)\}/);
  assert.ok(renameMatch && deleteMatch, 'expected Rename/Delete rows with their own onPress handlers');
  assert.doesNotMatch(renameMatch[1], /setLastAction/, "Rename's onPress must hand off to the shared exit path, not set lastAction directly");
  assert.doesNotMatch(deleteMatch[1], /setLastAction/, "Delete's onPress must hand off to the shared exit path, not set lastAction directly");

  const exitFinishMatch = demoBody.match(/\.start\(\(\{\s*finished\s*\}\)\s*=>\s*\{([\s\S]*?)\}\);/);
  assert.ok(exitFinishMatch, 'expected an exit Animated.timing(...).start(({ finished }) => { ... }) completion callback');
  assert.match(exitFinishMatch[1], /setLastAction\(/, 'expected lastAction to be committed only inside the exit-complete callback, after the surface has actually left');

  assert.match(demoBody, /useRef\(false\)/, 'expected a ref-based re-entrancy guard so a second exit request cannot replace/duplicate the pending action');
  assert.match(demoBody, /mountedRef\.current\s*=\s*false/, 'expected an unmount flag so a completing exit cannot commit state after the demo is gone');
  assert.match(demoBody, /opacity\.stopAnimation\(\)/, 'expected unmount to stop the in-flight animation rather than let a stale completion fire later');
});

// Search becomes a custom Hermex-owned shared foundation component: one canonical `HermexSearchField`
// plus a `.hermexSearch(...)` convenience modifier that composes it as a persistent top content inset.
// Native `.searchable` forwarding and `SearchFieldPlacement` are retired for the visible experience —
// the system-backed `TextField` still owns text editing, selection, dictation, IME/composition, and
// platform accessibility. Production screens stay on their existing eight direct `.searchable` call
// sites — migration is a separate issue. The preview becomes an interactive Hermex Search family
// demonstration with custom Hermex field chrome (not a bare native reconstruction), and its
// adoptionStatus truthfully reports zero production adoption.
test('Search is a custom Hermex-owned HermexSearchField/.hermexSearch foundation with native .searchable/SearchFieldPlacement retired, a truthful zero-adoption status, and an interactive family preview with custom chrome', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const search = extractHermesSection(sectionsSrc, 'Search');

  assert.match(search, /HermexSearchField/, 'expected the Search entry to name the canonical HermexSearchField component');
  assert.match(search, /`\.hermexSearch/, 'expected the Search entry to name the Hermex-owned .hermexSearch composition modifier');
  assert.match(search, /system-backed `TextField`|system-backed TextField/i, 'expected the Search entry to state the native TextField still owns text editing');
  assert.doesNotMatch(search, /`\.searchable`\s*forwarding|forwards straight to native `\.searchable`/i, 'native .searchable forwarding is retired');
  assert.doesNotMatch(search, /SearchFieldPlacement/, 'SearchFieldPlacement is retired; Hermex cannot truthfully reproduce native navigation-drawer placement');

  const state = extractAdoptionState(search);
  assert.equal(state, 'foundation-available', 'expected Search to remain foundation-available, not production-adopted, in this slice');
  assert.match(search, /eight existing|eight current/i, 'expected the adoptionStatus detail to name the eight unchanged production .searchable callers');
  assert.match(search, /deferred to a separate issue|scoped to a separate issue|separate issue|separate slice/i, 'expected the adoptionStatus/notes to state migration is deferred to another slice/issue');
  assert.doesNotMatch(search, /adoptionStatus:\s*\{\s*state:\s*'production-adopted'/, 'Search must not claim production adoption');

  assert.match(search, /HermesMobile\/Features\/Shared\/HermexSearch\.swift/, 'expected implementationNotes.sourcePaths to cite HermexSearch.swift');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.doesNotMatch(previewsSrc, /export function NativeSearchPreview/, 'expected the retired native-only preview name to be gone');
  assert.match(search, /<SearchFamilyGallery/, 'expected Search to render the Hermex Search family preview');
  assert.match(previewsSrc, /export function SearchFamilyGallery/);
  const gallery = extractFunctionBody(previewsSrc, 'SearchFamilyGallery');
  assert.match(gallery, /onChangeText=\{setQuery\}|onChangeText=\{[^}]*setQuery[^}]*\}/, 'expected interactive query entry');
  assert.match(gallery, /accessibilityLabel="Clear search"/, 'expected the clear action to name "Clear search"');
  assert.match(gallery, /minWidth:\s*44[\s\S]{0,80}minHeight:\s*44|minHeight:\s*44[\s\S]{0,80}minWidth:\s*44/, 'expected the clear control to keep an independent 44pt hit target');
  assert.match(gallery, /ref=\{searchInputRef\}/, 'expected the search input to expose a focus target');
  assert.match(gallery, /searchInputRef\.current\?\.focus\(\)/, 'expected clearing search to restore focus to the input after the clear control unmounts');
  assert.match(gallery, /disabled|isEnabled/i, 'expected a disabled specimen');
  assert.match(gallery, /onSubmitEditing/, 'expected submit handling via onSubmitEditing');
  assert.match(gallery, /submitCount === 1 \? ['"]time['"] : ['"]times['"]/, 'expected the live submit caption to say one time and multiple times');
  assert.match(gallery, /No results for/, 'expected a caller-owned no-results demonstration, not a generic empty state');
  assert.match(
    gallery,
    /custom Hermex|Hermex field chrome|Hermex-owned chrome/i,
    'expected the gallery caption to describe custom Hermex field chrome, not a bare native reconstruction',
  );
});

test('Materials — Hermex holds exactly Adaptive Glass, and Patterns — Hermex holds Content Unavailable, Pending Request, Transcript Activity, and Composer', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const navBlockMatch = src.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');

  const materialsMatch = navBlockMatch[0].match(/label:\s*'Materials',\s*\n\s*ids:\s*\[([^\]]*)\]/);
  assert.ok(materialsMatch, 'expected the Materials — Hermex nav group');
  const materialsIds = [...materialsMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(materialsIds, ['Adaptive Glass']);

  const patternsMatch = navBlockMatch[0].match(/label:\s*'Patterns',\s*\n\s*ids:\s*\[([^\]]*)\]/);
  assert.ok(patternsMatch, 'expected the Patterns — Hermex nav group');
  const patternsIds = [...patternsMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(patternsIds, ['Content Unavailable', 'Pending Request', 'Transcript Activity', 'Composer']);
});

// ─── Controller corrections (2026-09-26) ────────────────────────────────────────────────────────
// Three acceptance gaps a controller review found in the terminal-success result above: (1) the
// chat loading state must adopt a real shared SwiftUI primitive, not stay merely documented as a
// retained local implementation; (2) List/ListItem's public API must actually implement what
// "List / ListItem" already claims (title-adjacent slot, description/metadata, loading); (3)
// Divider must own its opacity as a component prop instead of the preview hacking it in via
// external `style`.

test('Correction (2026-09-26): the catalog-only animated Shimmer gallery copy names the shared production SkeletonPlaceholder primitive rather than contradicting it', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const previewBody = extractFunctionBody(previewsSrc, 'ShimmerFamilyGallery');
  assert.match(previewBody, /shared `?SkeletonPlaceholder`? primitive/i);
  assert.doesNotMatch(
    previewBody,
    /uses SwiftUI's platform `?\.redacted\(reason: \.placeholder\)`? directly/i,
    'the rendered preview copy must not contradict the shared production skeleton adoption',
  );
});

test('Correction (2026-09-26): the generic catalog Shimmer honors system Reduce Motion with a static fallback, observed at runtime, with no new dependency', () => {
  const implSrc = read('native/components/Shimmer/Shimmer.tsx');
  assert.match(
    implSrc,
    /import\s*\{[^}]*\bAccessibilityInfo\b[^}]*\}\s*from\s*'react-native'/,
    'expected AccessibilityInfo imported from react-native — the same module HermesMotionReference.tsx already uses, no new dependency',
  );
  assert.match(implSrc, /AccessibilityInfo\.isReduceMotionEnabled\(\)/, 'expected the initial-state check, same pattern as HermesMotionReference.tsx');
  assert.match(
    implSrc,
    /AccessibilityInfo\.addEventListener\(\s*'reduceMotionChanged'/,
    'expected runtime Reduce Motion changes to be observed, not only checked once at mount',
  );
  assert.match(implSrc, /reduceMotion/, 'expected a reduceMotion-driven code path in Breathing/Shimmer');
});

test('Correction (2026-09-26): the generic catalog Divider owns opacity as a component prop with a translucent default, and the preview demonstrates it via the prop instead of external style opacity', () => {
  const implSrc = read('native/components/Divider/Divider.tsx');
  assert.match(implSrc, /opacity\??:\s*number/, 'expected an opacity prop on DividerProps');
  assert.match(implSrc, /opacity\s*=\s*0\.\d+/, 'expected a translucent (< 1) default opacity applied by the component itself');
  assert.match(implSrc, /DS_SEMANTIC\.element\.divider/, 'expected the adaptive semantic divider color to stay in place');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const previewBody = extractFunctionBody(previewsSrc, 'HermexDividerPreview');
  assert.doesNotMatch(previewBody, /style=\{\{[^}]*opacity/, 'the preview must not apply opacity through external style anymore');
  assert.match(previewBody, /<Divider opacity=/, 'expected the preview to demonstrate the component-owned opacity prop');

  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Row Divider');
  assert.match(section, /generic catalog Divider/i);
  assert.match(section, /component-owned opacity/i);
  assert.match(section, /HermexDivider owns its SwiftUI opacity and pixel geometry/);
});

test('Correction (2026-09-26): ListItem genuinely supports a title-adjacent slot, description/metadata, and a loading state, while staying compatible with existing subtitle/footer/trailingText/trailingSubtext/trailing callers', () => {
  const implSrc = read('native/components/ListItem/ListItem.tsx');

  // New independently-optional slots/state.
  assert.match(implSrc, /titleAccessory/, 'expected a title-adjacent icon/custom node slot');
  assert.match(implSrc, /description/, 'expected a description slot (documented alias for subtitle)');
  assert.match(implSrc, /metadata/, 'expected a metadata slot (documented alias for footer)');
  assert.match(implSrc, /loading\??:\s*boolean/, 'expected a loading prop');

  // Existing callers must not break — every prior prop name must remain in the type.
  for (const name of ['subtitle', 'footer', 'trailingText', 'trailingSubtext', 'trailing']) {
    assert.match(implSrc, new RegExp(`${name}\\??:`), `expected the existing ${name} prop to still exist`);
  }

  // Loading uses the shared Shimmer/SkeletonGroup family, announced once, and is never pressable.
  assert.match(implSrc, /SkeletonGroup/, 'expected loading to use the shared SkeletonGroup so it announces once, not once per block');
  assert.match(implSrc, /Shimmer/, 'expected loading to render Shimmer placeholders, not a bespoke loading view');
  assert.match(implSrc, /if\s*\(loading\)/, 'expected an explicit loading branch');

  // A loading row must never remain pressable (loading returns early above); a commit-pending row is
  // also never pressable (see the "Correction (gap 4)" tests below for its own exact commitPending
  // gating). A merely-disabled row still renders through this same Pressable branch — see the
  // "Correction (accordion accessibility, 2026-09-28)" tests below for why it must keep real button
  // semantics instead of being demoted to a plain View.
  assert.match(implSrc, /isInteractive\s*=\s*!!onPress\s*&&\s*!commitPending/, 'expected the interactive branch to stay gated off only for a loading (returned above) or commit-pending row, not merely a disabled one');
  const pressableBlock = implSrc.match(/if\s*\(isInteractive\)\s*\{[\s\S]*?<Pressable[\s\S]*?<\/Pressable>[\s\S]*?\}/);
  assert.ok(pressableBlock, 'expected a Pressable branch guarded by isInteractive');
});

test('Correction (final-review truthfulness pass): the ListItem preview\'s SessionListItem-composition caption truthfully distinguishes the live production SessionRowView (wrapped by SessionInteractiveRow) from the new, foundation-only SessionListItem', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'ListItemFamilyGallery');
  assert.doesNotMatch(
    body,
    /SessionRowView\.swift no longer exists|retired SessionRowView|split into SessionListItem/i,
    'SessionRowView.swift genuinely still exists and is the real, adopted production row — it was never retired or split',
  );
  assert.match(body, /SessionRowView/, 'expected the caption to name SessionRowView as production\'s real, live session row');
  assert.match(body, /SessionInteractiveRow/, 'expected the caption to name SessionInteractiveRow as the caller that wraps it in production');
  assert.match(body, /wraps SessionRowView/, 'expected the caption to state SessionInteractiveRow wraps SessionRowView, not SessionListItem');
  assert.match(body, /SessionListItem/, 'expected the caption to still name the foundation SessionListItem composition');
  assert.match(body, /foundation-only|no production call site/i, 'expected the caption to state SessionListItem is unadopted/foundation-only');
  assert.doesNotMatch(body, /highlights? a search match inside the title/i, 'SessionRowView keeps its title plain; production highlights the match in a separate excerpt line below it');
  assert.match(body, /separate highlighted\s+excerpt line beneath the title/, 'expected the caption to describe the production SessionSearchExcerpt anatomy truthfully');
});

test('Correction (2026-09-26): the ListItem preview visibly exercises the title-adjacent slot, description/metadata, trailing data/accessory, disabled, and loading configurations', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const previewBody = extractFunctionBody(previewsSrc, 'ListItemFamilyGallery');
  assert.match(previewBody, /titleAccessory=/);
  assert.match(previewBody, /description=/);
  assert.match(previewBody, /metadata=/);
  assert.match(previewBody, /trailingText=/);
  assert.match(previewBody, /trailingSubtext=/);
  assert.match(previewBody, /disabled/);
  assert.match(previewBody, /loading/);
  assert.match(previewBody, /title="Login"/);
  assert.match(previewBody, /description="feature\/auth"/);
  assert.match(previewBody, /metadata="2 files"/);
  assert.doesNotMatch(previewBody, /title="Fix the login flow"/);
});

test('Correction (2026-09-26): List / ListItem no longer claims a prop the component does not implement — loading is documented alongside the other slots', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'List / ListItem');
  assert.match(section, /loading/i, 'expected the loading state to be documented now that it is implemented');
  assert.match(section, /title-adjacent/i);
  assert.match(section, /description/i);
  assert.match(section, /metadata/i);
});

// Controller correction (2026-09-26, gap 4): the List/ListItem section already claimed selected,
// commit-pending, an accessibility-label override, Dynamic Type reflow, and an independently
// operable trailing action, but the component only implemented loading/disabled — the rest were
// copy without a real API behind them. Each assertion below pins one concrete, previously-missing
// piece of that real API.
test('Correction (gap 4): ListItem exposes a real selected accessibility state, distinct from disabled/loading', () => {
  const implSrc = read('native/components/ListItem/ListItem.tsx');
  assert.match(implSrc, /selected\?:\s*boolean/, 'expected a selected prop on ListItemProps');
  assert.match(implSrc, /selected(?:,)?\s*=\s*false/, 'expected selected to default to false');
  assert.match(implSrc, /accessibilityState=\{\{[^}]*selected/, 'expected accessibilityState to carry the real selected value, not just disabled');
});

test('Correction (gap 4): ListItem has a distinct commitPending state that renders real content (never a generic Shimmer skeleton) and stays non-interactive', () => {
  const implSrc = read('native/components/ListItem/ListItem.tsx');
  assert.match(implSrc, /commitPending\?:\s*boolean/, 'expected a commitPending prop, distinct from loading');
  assert.doesNotMatch(
    implSrc,
    /if\s*\(commitPending\)\s*\{\s*return\s*\(\s*<SkeletonGroup/,
    'commit-pending must not become a generic skeleton row — it must render the row\'s real title/content with its own pending indicator',
  );
  assert.match(implSrc, /commitPending/g);
});

test('Correction (gap 4): ListItem accepts an accessibility-label override, used verbatim instead of the computed title+description default', () => {
  const implSrc = read('native/components/ListItem/ListItem.tsx');
  assert.match(
    implSrc,
    /accessibilityLabel\?:\s*string/,
    'expected an accessibilityLabel override prop on ListItemProps, alongside the existing computed default',
  );
  assert.match(
    implSrc,
    /accessibilityLabel\s*\?\?\s*\[title,\s*resolvedDescription\]\.filter\(Boolean\)\.join\(', '\)/,
    'expected the override to take priority over the computed title+description label, not replace it unconditionally',
  );
});

test('Correction (gap 4): ListItem\'s trailing accessory sits outside the row\'s own selecting Pressable, so it stays independently focusable/operable rather than being swallowed by the row\'s combined accessibility label', () => {
  const implSrc = read('native/components/ListItem/ListItem.tsx');
  const pressableMatch = implSrc.match(/<Pressable[\s\S]*?<\/Pressable>/);
  assert.ok(pressableMatch, 'expected a Pressable element in ListItem.tsx');
  assert.doesNotMatch(
    pressableMatch[0],
    /trailingGroup/,
    'the trailing accessory must not be nested inside the row-selecting Pressable — VoiceOver collapses an accessible Pressable\'s subviews into one element, and touch on a nested Pressable is fragile; it must be a sibling instead',
  );
});

test('Correction (gap 4): the ListItem preview exercises selected, commitPending, the accessibility-label override, and an independently-operable trailing action alongside a pressable row', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const previewBody = extractFunctionBody(previewsSrc, 'ListItemFamilyGallery');
  assert.match(previewBody, /selected/);
  assert.match(previewBody, /commitPending/);
  assert.match(previewBody, /accessibilityLabel=/);
  // An independently-operable trailing action: a real interactive element (not plain text) passed as
  // `trailing`, alongside a row that is itself pressable (`onPress`).
  assert.match(previewBody, /onPress=\{[^}]*\}[\s\S]{0,400}trailing=\{<Button/);
});

// Issue #607 semantic-accuracy follow-up: the catalog's `loading`/SkeletonGroup prop is a React
// Native catalog-reconstruction concept with no equivalent in native ListItem.swift — the native
// `ListItem` instead models a pending row with `ListItemState.isPending` rendering a single-row
// `ProgressView`, a different concept from the catalog's multi-slot Shimmer/SkeletonGroup loading
// placeholder. Both must be named accurately and the catalog-only one must be explicitly scoped.
test('Issue #607 follow-up: List / ListItem scopes SkeletonGroup to the React Native catalog reconstruction only and separately documents the real native ListItemState.isPending/ProgressView pending row', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'List / ListItem');

  assert.doesNotMatch(
    section,
    /A loading row announces "Loading" once via SkeletonGroup instead of once per Shimmer block\./,
    'must not state SkeletonGroup grouping as if it were native Swift ListItem accessibility behavior',
  );
  assert.match(section, /SkeletonGroup/, 'SkeletonGroup should still be documented as the catalog reconstruction\'s own loading mechanism');
  assert.match(section, /React Native catalog reconstruction|catalog-only|catalog reconstruction/i, 'expected SkeletonGroup to be explicitly scoped to the catalog reconstruction, not native Swift');
  assert.match(section, /ListItemState\.isPending/, 'expected the real native Swift pending state to be named');
  assert.match(section, /ProgressView/, 'expected the real native Swift pending indicator to be named');
});

// ─── Component families and Patterns (2026-09-26 revised specification) ─────────────────────────
// Source-contract tests for the approved four-group taxonomy (Foundations/Materials/Components/
// Patterns), Materials' Adaptive Glass, Card's Section/Request/Compact variants, the Banner family,
// unified Buttons, display-only Tag + Inline Reference Link, Picker Row's removal, static Skeleton,
// and the four Patterns entries. Written against, and passing against, the implementation landed in
// this same change — see the final report for the RED baseline captured before that implementation.

test('Adaptive Glass documents all six required states: Liquid Glass, Material fallback, opaque Reduce Transparency fallback, Increased Contrast stroke, interactive/non-interactive, and clipped-ancestor fallback', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Adaptive Glass');
  assert.match(section, /Liquid Glass/);
  assert.match(section, /Material · Fallback|Material \(fallback\)|Material fallback/);
  assert.match(section, /Opaque · Reduce Transparency|Opaque \(Reduce Transparency\)/);
  assert.match(section, /Increased Contrast/);
  assert.match(section, /non-interactive/i);
  assert.match(section, /interactive · isInteractive|interactive \(isInteractive: true\)/i);
  assert.match(section, /clipped-ancestor fallback/i);
  assert.match(section, /inheritsClipping/);
});

test('Card documents Section Card, Request Card, and an explicitly-named Compact Card, with Compact Card never a silent padding override', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Card');
  assert.match(section, /Section Card/);
  assert.match(section, /Request Card/);
  assert.match(section, /Compact Card/);
  assert.match(section, /explicitly.named|explicit.*compact density|never a silent (?:caller-side )?padding override/i);
  assert.match(section, /<CardChromePreview[^>]*kind="request"/);
  assert.match(section, /<CardChromePreview[^>]*kind="compact"/);
});

test('Card exposes the outlined white-surface variant used by the Tip Jar card instead of reconstructing it locally', () => {
  const implSrc = read('native/components/Card/Card.tsx');
  const section = extractHermesSection(read(HERMES_SECTIONS_PATH), 'Hermes Card');

  assert.match(implSrc, /export type CardSurface = 'elevated' \| 'outlined'/);
  assert.match(implSrc, /surface\?:\s*CardSurface/);
  assert.match(implSrc, /cardOutlined:\s*\{[^}]*borderColor:\s*DS_SEMANTIC\.border\.light/s);
  assert.match(section, /Outlined Card/);
  assert.match(section, /<CardChromePreview[^>]*kind="outlined"/);
  assert.match(section, /canonical outlined Card treatment/i);
});

test('Hermex Buttons document the gold brand-primary action and Typography exposes 16pt label and body roles', () => {
  const sectionsSrc = read('native/catalog/hermes/hermesSections.tsx');
  const previewsSrc = read('native/catalog/hermes/HermesComponentFamiliesPreviews.tsx');
  const buttons = extractHermesSection(sectionsSrc, 'Buttons');

  assert.match(buttons, /brandPrimary/);
  assert.match(buttons, /Gold 500/i);
  assert.match(previewsSrc, /Brand primary/);
  assert.match(previewsSrc, /HERMES_COLOR_RAMPS\.Gold\[500\]/);
  assert.match(sectionsSrc, /label: \{ fontSize: 16, fontWeight: '600'/);
  assert.match(sectionsSrc, /body: \{ fontSize: 16/);
});

// Controller correction (2026-09-26, gap 2): the generic Card only had a fixed 16pt-all-around
// default; the Card/Attachment previews faked Compact Card with a plain `View`, so the
// approved Compact Card density had no real, testable API behind it. Card itself must now expose an
// explicit density configuration, default unchanged at 16pt on every edge, and the previews claiming
// Compact Card must render the real component with that density — not a local recon `View`.
test('Correction (gap 2): the generic Card exposes an explicit density prop (default/compact); default padding stays exactly 16 on every edge, and compact is an explicit, reduced, token-based value — never a silent override', () => {
  const implSrc = read('native/components/Card/Card.tsx');
  assert.match(implSrc, /density\?:\s*CardDensity/, 'expected an explicit density prop on Card');
  assert.match(implSrc, /export type CardDensity = 'default' \| 'compact'/, "expected the density type to be exactly 'default' | 'compact'");
  assert.match(implSrc, /card:\s*\{[^}]*padding:\s*DS_SPACING\[800\]/s, 'expected Card\'s own default padding to remain the 16pt token (DS_SPACING[800]) on every edge');
  assert.match(implSrc, /cardCompact:\s*\{\s*padding:\s*DS_SPACING\[600\]/, "expected an explicit cardCompact style using a smaller token, never re-using the 16pt default");
  assert.doesNotMatch(implSrc, /paddingVertical|paddingHorizontal/, 'default padding must stay uniform (one `padding`, not separate vertical/horizontal overrides) so it is 16pt on every edge, not just some');
});

test('Correction (gap 2): the Card and Attachment previews render the real Card component with density="compact" for every claimed Compact Card composition, not a local recon View', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /import\s*\{[^}]*\bCard\b[^}]*\}\s*from\s*'\.\.\/\.\.\/components'/, 'expected hermesSections.tsx to import the real generic Card component');
  const cardChromePreviewBody = extractFunctionBody(sectionsSrc, 'CardChromePreview');
  assert.match(cardChromePreviewBody, /<Card\b/, 'expected CardChromePreview to render the real Card component');
  assert.match(cardChromePreviewBody, /density=\{kind === 'compact' \? 'compact' : 'default'\}/, "expected CardChromePreview to pass the real density prop, driven by its own `kind`");
  assert.doesNotMatch(cardChromePreviewBody, /cardContentCompact/, 'the fake local compact-padding style must no longer be used now that Card owns real density');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /import\s*\{[^}]*\bCard\b[^}]*\}\s*from\s*'\.\.\/\.\.\/components'/, 'expected the Attachment preview file to import the real Card component');
  const attachmentBody = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');
  assert.match(attachmentBody, /<Card density="compact"/, 'expected the normal (non-mini) Attachment tiles to compose the real Card with density="compact", not a plain View');
});

// ─── Attachment token/color/component-composition slice (2026-09-26 catalog owner brief) ─────────
// Mirrors production's newly-adopted HermesAttachmentSize (HermesMobile/Config/HermesAttachmentSize.
// swift) and HermesIconSize.extraLarge. This catalog slice needs its own source-of-truth module (not
// a duplicate of the spacing/radius scale, not catalog chrome), real Hermex color-ramp values instead
// of local hex/rgb literals, real Icon/Button composition instead of text glyphs, and a full-box
// Shimmer/SkeletonGroup loading placeholder instead of a hand-built "Uploading…" tile.
const HERMES_ATTACHMENT_SIZE_PATH = 'native/catalog/hermes/hermesAttachmentSize.ts';

test('hermesAttachmentSize.ts defines the exact adopted HermesAttachmentSize component-size tokens and HermesIconSize.extraLarge, independent of the catalog\'s own spacing/radius scale', () => {
  assert.ok(existsSync(path.join(ROOT, HERMES_ATTACHMENT_SIZE_PATH)), `${HERMES_ATTACHMENT_SIZE_PATH} should exist as the Attachment size token source of truth`);
  const src = read(HERMES_ATTACHMENT_SIZE_PATH);
  assert.match(src, /export const HERMES_ATTACHMENT_SIZE = \{/);
  const expected = {
    compactPreview: 30,
    messageGridCell: 118,
    composerImage: 96,
    composerImageAccessibility: 108,
    fileIconPanelWidth: 58,
    fileIconPanelHeight: 68,
    fileIconPanelWidthAccessibility: 76,
    fileIconPanelHeightAccessibility: 84,
    composerFileTextWidth: 128,
    composerFileTextWidthAccessibility: 160,
    composerFileTileWidth: 222,
    composerFileTileWidthAccessibility: 280,
    composerFileTileMinHeight: 92,
    composerFileTileMinHeightAccessibility: 112,
    composerStripHeight: 108,
    composerStripHeightAccessibility: 132,
    messageFileTextInset: 18,
    removeControl: 24,
    removeOverlap: 6,
    accessibilityVerticalPadding: 10,
  };
  for (const [key, value] of Object.entries(expected)) {
    assert.match(src, new RegExp(`${key}:\\s*${value}\\b`), `expected HERMES_ATTACHMENT_SIZE.${key} === ${value}`);
  }
  assert.doesNotMatch(src, /HERMES_ICON_SIZE_EXTRA_LARGE/, 'HermesIconSize.extraLarge now lives solely in the canonical ./hermesIconSize module, not duplicated here');
  assert.doesNotMatch(src, /from\s*'\.\.\/\.\.\/\.\.\/tokens'/, 'this module must not depend on the catalog\'s own spacing/radius scale — it is a standalone, Attachment-specific size table, not catalog chrome or a spacing token');
});

test('AttachmentTileGallery sizes its examples from the adopted HermesAttachmentSize/HermesIconSize tokens, not local hardcoded geometry', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(
    previewsSrc,
    /import\s*\{[^}]*HERMES_ATTACHMENT_SIZE[^}]*\}\s*from\s*'\.\/hermesAttachmentSize'/,
    'expected HermesComponentFamiliesPreviews.tsx to import the adopted Attachment size tokens from ./hermesAttachmentSize',
  );
  assert.match(
    previewsSrc,
    /import\s*\{\s*HERMES_ICON_SIZE\s*\}\s*from\s*'\.\/hermesIconSize'/,
    'expected HermesComponentFamiliesPreviews.tsx to import HermesIconSize.extraLarge from the canonical ./hermesIconSize module',
  );
  const body = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');
  for (const key of [
    'compactPreview', 'fileIconPanelWidth', 'fileIconPanelHeight',
    'fileIconPanelWidthAccessibility', 'fileIconPanelHeightAccessibility', 'composerFileTileWidth',
    'composerFileTileMinHeight', 'composerFileTextWidth', 'messageFileTextInset', 'removeControl',
    'removeOverlap', 'messageGridCell',
  ]) {
    assert.match(body, new RegExp(`HERMES_ATTACHMENT_SIZE\\.${key}\\b`), `expected AttachmentTileGallery to size an example from HERMES_ATTACHMENT_SIZE.${key}`);
  }
  assert.match(body, /HERMES_ICON_SIZE\.extraLarge\b/, 'expected the file-type icon to render at the adopted HermesIconSize.extraLarge');
  assert.doesNotMatch(body, /width:\s*96\b|height:\s*96\b|width:\s*168\b/, 'the old hand-picked 96/168 geometry must be replaced by the adopted token references above');
});

test('Attachment file-type colors come from the adopted HERMES_COLOR_RAMPS, never local hex/rgb literals', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(
    previewsSrc,
    /import\s*\{[^}]*HERMES_COLOR_RAMPS[^}]*\}\s*from\s*'\.\/hermesColorCatalogData'/,
    'expected HermesComponentFamiliesPreviews.tsx to import the adopted color ramp data',
  );
  const body = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');
  assert.doesNotMatch(body, /#[0-9A-Fa-f]{3,8}\b/, 'no local hex color literals may remain in the Attachment gallery');
  assert.doesNotMatch(body, /rgba?\(/i, 'no local rgb/rgba color literals may remain in the Attachment gallery');
  for (const [type, ramp] of [['text-like', 'Blue'], ['PDF', 'Red'], ['archive', 'Orange'], ['unknown/default', 'Neutral']]) {
    assert.match(body, new RegExp(`HERMES_COLOR_RAMPS\\.${ramp}\\[500\\]`), `expected the ${type} file-type color to come from HERMES_COLOR_RAMPS.${ramp}[500]`);
  }

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Attachment');
  for (const mapping of [
    'spreadsheet → Green 500', 'text-like → Blue 500', 'PDF → Red 500', 'archive → Orange 500', 'unknown/default → Neutral 500',
  ]) {
    assert.ok(section.includes(mapping), `expected the Attachment section prose to document the file-color mapping "${mapping}"`);
  }
});

test('Attachment renders real Icon/Button composition instead of text glyphs, for the file icon and remove control, and the failure tile no longer depicts a caller-owned Retry control', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');
  // Scoped to the glyph as rendered JSX text content (`>×<`), not the character in general — "×" is
  // also legitimate multiplication notation in this same gallery's own dimension prose (e.g. "58×68pt").
  for (const glyph of ['▤', '▢', '⋯', '×', '⚠️']) {
    assert.ok(!body.includes(`>${glyph}<`), `expected the retired text-glyph-as-icon "${glyph}" to be replaced by a real Icon`);
  }
  assert.match(body, /<Icon\b[^>]*name="paperclip"/, 'expected the file-type icon to be a real Icon, not a text glyph');
  assert.match(body, /<Icon\b[^>]*name="(?:alert-circle|triangle-alert)"/, 'expected the failure badge to be a real Icon, not an emoji');
  assert.match(body, /<Button\b[^>]*iconName="clear"/, 'expected the remove control to compose the real Button, not a plain View with an "×" Text');
  // Issue #607 final correction pass: AttachmentTile.swift defines no Retry/failure-badge affordance
  // — that recovery UI is caller-owned production chrome, not part of this foundation family — so the
  // smallest accurate result removes it rather than relabeling it (see the dedicated correction test).
  assert.doesNotMatch(body, /label="Retry"/, 'expected the caller-owned Retry control to be removed from this foundation-only family');
});

test('Attachment loading state is a single full-box Shimmer/SkeletonGroup placeholder, not the retired hand-built "Uploading…" tile', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(
    previewsSrc,
    /import\s*\{[^}]*\b(?:Shimmer|SkeletonGroup)\b[^}]*\}\s*from\s*'\.\.\/\.\.\/components'/,
    'expected HermesComponentFamiliesPreviews.tsx to import Shimmer/SkeletonGroup',
  );
  const body = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');
  assert.doesNotMatch(body, /Uploading…/, 'the retired hand-built loading tile text must be removed');
  assert.match(body, /<Shimmer\b[^>]*variant="container"/, 'expected a single full-box container Shimmer standing in for the whole attachment tile while loading');
  assert.doesNotMatch(body, /claims? (?:a |the )?measurable upload progress/i, 'the loading example itself must not claim to represent measurable upload progress');

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Attachment');
  assert.match(section, /indefinite loading only/i, 'expected the section prose to state the Skeleton represents indefinite loading only, never a measurable upload percentage');
});

test('Attachment section documents HermesAttachmentSize geometry, states no new global spacing/radius/color family was created, and preserves the native-primitives-underneath framing', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(
    sectionsSrc,
    /import\s*\{[^}]*HERMES_ATTACHMENT_SIZE[^}]*\}\s*from\s*'\.\/hermesAttachmentSize'/,
    'expected hermesSections.tsx to import the adopted Attachment size tokens as its documentation source of truth',
  );
  assert.match(
    sectionsSrc,
    /import\s*\{\s*HERMES_ICON_SIZE\s*\}\s*from\s*'\.\/hermesIconSize'/,
    'expected hermesSections.tsx to import HermesIconSize.extraLarge from the canonical ./hermesIconSize module',
  );
  const section = extractHermesSection(sectionsSrc, 'Attachment');
  for (const key of [
    'compactPreview', 'messageGridCell', 'composerImage', 'composerImageAccessibility', 'fileIconPanelWidth',
    'fileIconPanelHeight', 'composerFileTextWidth', 'composerFileTextWidthAccessibility', 'composerFileTileWidth',
    'composerFileTileWidthAccessibility', 'composerFileTileMinHeight', 'composerFileTileMinHeightAccessibility',
    'composerStripHeight', 'composerStripHeightAccessibility', 'messageFileTextInset', 'removeControl',
    'removeOverlap', 'accessibilityVerticalPadding',
  ]) {
    assert.match(section, new RegExp(`HERMES_ATTACHMENT_SIZE\\.${key}\\b`), `expected the Attachment section to document HermesAttachmentSize.${key}`);
  }
  assert.match(section, /HERMES_ICON_SIZE\.extraLarge\b/, 'expected the Attachment section to document HermesIconSize.extraLarge');
  assert.match(section, /no new (?:global )?spacing[^.]*radius scale/i, 'expected the section to state HermesAttachmentSize is not a new global spacing/radius scale');
  assert.match(section, /no new color family/i, 'expected the section to state no new color family was introduced');
  assert.match(section, /native SwiftUI[^.]*remain/i, 'expected the section to restate that native/platform primitives remain underneath the Hermex compositions');
});

// ─── Attachment acceptance-parity correction (2026-09-27 controller inspection) ────────────────
test('Correction (attachment parity): the message attachment example is sized from HERMES_ATTACHMENT_SIZE.messageGridCell, not a raw 168 width baked into messageFileTile', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.doesNotMatch(previewsSrc, /width:\s*168\b/, 'the raw 168 message-tile width must no longer appear anywhere in the previews file');
  const body = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');
  assert.match(
    body,
    /<Card density="compact" style=\{\[preview\.messageFileTile,\s*gridCellSize\]\}/,
    'expected the message attachment Card to size itself from HERMES_ATTACHMENT_SIZE.messageGridCell (via gridCellSize) at the call site, not a fixed width on the shared style object',
  );
  const messageCard = body.match(/<Card density="compact" style=\{\[preview\.messageFileTile,\s*gridCellSize\]\}>([\s\S]*?)<\/Card>/)?.[1] ?? '';
  assert.match(messageCard, /<Icon[^>]+HERMES_ICON_SIZE\.extraLarge/, 'message tile should render the file glyph directly in its vertical production anatomy');
  assert.match(messageCard, /preview\.tileName/, 'message tile should render its centered filename with the compact message-tile text style');
  assert.match(messageCard, /preview\.tileExt/, 'message tile should render its extension label below the filename');
  assert.doesNotMatch(messageCard, /preview\.fileIconPanel|preview\.composerTileText|preview\.composerTileDetail/, 'message tile must not reuse the horizontal composer icon-panel/text-detail anatomy that makes the 118pt tile clip');
  const messageStyle = previewsSrc.match(/messageFileTile:\s*\{([\s\S]*?)\n\s*\},/)?.[1] ?? '';
  assert.doesNotMatch(messageStyle, /flexDirection:\s*'row'/, 'message tile style should stay vertically stacked like GridAttachmentCell.fileCell');
  assert.match(messageStyle, /justifyContent:\s*'center'/, 'message tile contents should be centered inside the fixed square');
});

test('Correction (attachment parity): ComposerPatternPreview\'s embedded Attachment example composes the same adopted HermesAttachmentSize/HermesIconSize/HERMES_COLOR_RAMPS tokens and real Icon as AttachmentTileGallery, not raw 44×52 geometry, hex/rgba literals, or a text-glyph icon', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'ComposerPatternPreview');
  // Scoped to just the embedded Attachment example's own <Card>...</Card> markup, not the whole
  // function body — ComposerPatternPreview also renders a Composer Chip example immediately after
  // it, which legitimately keeps its own raw hex per that subsystem's own styling.
  const cardStart = body.indexOf('<Card density="compact"');
  assert.notEqual(cardStart, -1, 'expected the Composer pattern to render a Card density="compact" Attachment example');
  const cardEnd = body.indexOf('</Card>', cardStart);
  assert.notEqual(cardEnd, -1, 'expected the Composer pattern\'s Attachment Card to have a matching closing tag');
  const attachmentMarkup = body.slice(cardStart, cardEnd);
  assert.doesNotMatch(attachmentMarkup, /width:\s*44\b|height:\s*52\b/, 'the raw 44×52 icon-panel geometry must be replaced by HERMES_ATTACHMENT_SIZE.fileIconPanelWidth/fileIconPanelHeight');
  assert.doesNotMatch(attachmentMarkup, /#[0-9A-Fa-f]{3,8}\b/, 'no local hex color literals may remain in the Composer pattern\'s Attachment example');
  assert.doesNotMatch(attachmentMarkup, /rgba?\(/i, 'no local rgb/rgba color literals may remain in the Composer pattern\'s Attachment example');
  assert.ok(!attachmentMarkup.includes('>▤<'), 'expected the retired text-glyph-as-icon "▤" to be replaced by a real Icon');
  assert.match(attachmentMarkup, /<Icon\b[^>]*name="paperclip"/, 'expected the Composer pattern\'s file-type icon to be a real Icon, not a text glyph');
  assert.match(attachmentMarkup, /HERMES_ATTACHMENT_SIZE\.fileIconPanelWidth\b/, 'expected the Composer pattern\'s icon panel to size from HERMES_ATTACHMENT_SIZE.fileIconPanelWidth');
  assert.match(attachmentMarkup, /HERMES_ATTACHMENT_SIZE\.fileIconPanelHeight\b/, 'expected the Composer pattern\'s icon panel to size from HERMES_ATTACHMENT_SIZE.fileIconPanelHeight');
  assert.match(attachmentMarkup, /HERMES_ICON_SIZE\.extraLarge\b/, 'expected the Composer pattern\'s file icon to render at the adopted HermesIconSize.extraLarge');
  assert.match(attachmentMarkup, /HERMES_COLOR_RAMPS\.Blue\[100\]/, 'expected the Composer pattern\'s icon panel background to come from HERMES_COLOR_RAMPS.Blue[100]');
  assert.match(attachmentMarkup, /HERMES_COLOR_RAMPS\.Blue\[500\]/, 'expected the Composer pattern\'s icon/extension tint to come from HERMES_COLOR_RAMPS.Blue[500]');
});

test('Correction (attachment parity): hermesAttachmentSize.ts cites the real adopted Swift source path (HermesMobile/Config/HermesSpacing.swift), not the nonexistent HermesAttachmentSize.swift', () => {
  const src = read(HERMES_ATTACHMENT_SIZE_PATH);
  assert.match(src, /HermesMobile\/Config\/HermesSpacing\.swift/, 'expected the doc comment to cite the real Swift source path, HermesMobile/Config/HermesSpacing.swift');
  assert.doesNotMatch(src, /HermesAttachmentSize\.swift/, 'the nonexistent HermesAttachmentSize.swift path must no longer be cited');
});

test('Banner documents Information, Warning, Error, Success, and Offline variants with optional icon/action, inset/full-width presentation, and decorative icon semantics, and consolidates the offline-cache duplicates', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Banner');
  assert.match(section, /Information, Warning, Error, Success, and Offline variants/);
  assert.match(section, /decorative/i);
  assert.match(section, /<BannerFamilyGallery/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'BannerFamilyGallery');
  for (const variant of ['variant="info"', 'variant="warning"', 'variant="negative"', 'variant="positive"']) {
    assert.ok(body.includes(variant), `expected the Banner gallery to demonstrate ${variant}`);
  }
  assert.match(body, /Offline/);
  assert.match(body, /action=\{\{/, 'expected an optional action example');
  assert.match(body, /Inset presentation/);
  assert.doesNotMatch(body, /accessibilityHidden/, 'decorative-icon semantics come from Banner\'s own default, not a per-preview override');
});

// Correction (final-review example/source parity): the "Description-only inset banner" usage
// example's own title claims inset presentation, but its Swift code never passed the native
// presentation argument HermexBanner.swift actually exposes — it would really render full-width.
test('Correction (final-review example/source parity): Banner\'s "Description-only inset banner" usage example actually passes the native inset presentation argument', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Banner');
  const ref = extractHermesReferenceBlock(section);
  const examplesSrc = extractBracketBlock(ref, /usageExamples:\s*\[/);
  const match = examplesSrc.match(/name:\s*'Description-only inset banner'[\s\S]*?code:\s*`([\s\S]*?)`/);
  assert.ok(match, 'expected a "Description-only inset banner" usage example');
  assert.match(match[1], /presentation:\s*\.inset\b/, 'expected the Description-only inset banner example to pass presentation: .inset');
});

// DSR2-15: title and description are independently caller-optional on the native HermexBanner —
// title+description, title-only, and description-only are all supported content combinations, with
// no interactive collapse/disclosure state (omission is a caller content choice). The preview must
// demonstrate all three combinations plus a composer-style error composition example, and must
// never render an empty title placeholder for the description-only case.
test('Banner\'s human copy and preview name the native HermexBanner API and demonstrate title+description, title-only, description-only, and a composer-style error composition, with no production-adoption claim or empty title placeholder', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Banner');

  assert.match(section, /HermexBanner/, 'expected the human copy to name the native HermexBanner API');
  assert.match(section, /HermesMobile\/Features\/Shared\/HermexBanner\.swift/, 'expected the human copy/source paths to cite HermexBanner.swift');
  assert.doesNotMatch(section, /collapsible|interactive collapse|disclosure/i, 'expected guidance to describe caller-configurable omission, not an interactive collapse/disclosure state');
  assert.match(section, /(caller|independently)[^.]*optional/i, 'expected guidance to state title/description are independently caller-optional');

  assert.match(section, /name:\s*'title'/, 'expected props to document an optional title');
  assert.match(section, /name:\s*'description'/, 'expected props to document an optional description');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'BannerFamilyGallery');

  // Scope title/description presence to each individual <Banner ... /> element's own attribute
  // list, not the whole gallery body — a whole-body regex can't tell "this element has title but
  // not description" from "some element somewhere has title, some other element has description".
  const bannerTags = [...body.matchAll(/<Banner\b[^>]*\/?>/gs)].map((m) => m[0]);
  assert.ok(bannerTags.length > 0, 'expected at least one <Banner ... /> element in the gallery');
  const hasTitle = (tag) => /\btitle=/.test(tag);
  const hasDescription = (tag) => /\bdescription=/.test(tag);
  assert.ok(bannerTags.some((tag) => hasTitle(tag) && hasDescription(tag)), 'expected a title+description example');
  assert.ok(bannerTags.some((tag) => hasTitle(tag) && !hasDescription(tag)), 'expected a title-only example');
  assert.ok(bannerTags.some((tag) => !hasTitle(tag) && hasDescription(tag)), 'expected a description-only example');
  assert.ok(
    bannerTags.every((tag) => !/title=""/.test(tag)),
    'expected the description-only example to omit the title prop entirely, never pass an empty title placeholder',
  );
  assert.match(body, /composer/i, 'expected the preview to demonstrate a composer-style error composition example');
  assert.doesNotMatch(section, /partially-adopted|main chat composer('s)? error branch/i, 'the composition example must not be presented as production adoption');

  // Correction (DSR2-15): a whole-body attribute check alone can't tell whether an omitted prop
  // actually renders nothing — the generic Banner previously defaulted a missing title/description to
  // a placeholder string, so the "title-only"/"description-only" specimens rendered the other
  // region's placeholder anyway. Assert the root cause is fixed in the component itself.
  const bannerSrc = read('native/components/Banner/Banner.tsx');
  assert.doesNotMatch(bannerSrc, /title\s*=\s*'Banner title'/, 'must not default title to a placeholder string');
  assert.doesNotMatch(bannerSrc, /description\s*=\s*'Description text goes here'/, 'must not default description to a placeholder string');
  assert.match(bannerSrc, /\{title \? \(/, 'expected the standard callout\'s title to render only when a title is actually supplied, not an always-rendered Text node');
});

test('Issue #607: Banner\'s standard layout puts a description-only banner\'s description in the header row beside the icon, not behind an icon-only header plus an indented descriptionPad second row', () => {
  const bannerSrc = read('native/components/Banner/Banner.tsx');

  // A shared description/link node, reusable in either position, so the header-row and
  // descriptionPad renderings can never drift apart in what content/link logic they show.
  assert.match(bannerSrc, /const descriptionNode = description \|\| link \? \(/, 'expected a shared description/link node reusable in both the header row and the indented second row');

  // The header row must fall back to that node — in the title's own primary-position style — when
  // title is absent, instead of rendering only the icon (plus an optional trailingIcon). Scoped to
  // the standard callout's own `body` (not the collapsible callout's separate header row above it).
  // Slice through the separately gated title+description row because the icon may legitimately use
  // a nested first-line alignment box inside this header row.
  const standardBodyStart = bannerSrc.indexOf('const body = (pressed: boolean) => (');
  assert.ok(standardBodyStart >= 0, 'expected the standard callout\'s body to be defined');
  const headerRowStart = bannerSrc.indexOf('<View style={[styles.headerRow, styles.standardHeaderRow]}>', standardBodyStart);
  assert.ok(headerRowStart >= 0, 'expected the standard callout to compose its shared row with the native-parity top-alignment override');
  const headerRowEnd = bannerSrc.indexOf('{title && descriptionNode ? (', headerRowStart);
  assert.ok(headerRowEnd >= 0, 'expected the separately gated title+description row after the header row');
  const headerRow = bannerSrc.slice(headerRowStart, headerRowEnd);
  assert.match(headerRow, /:\s*descriptionNode\s*\?\s*\(/, 'expected the header row to render descriptionNode in place of an absent title');
  assert.match(headerRow, /styles\.title,\s*styles\.titleFlex/, 'expected the promoted description to reuse the title\'s own primary-position style, not a secondary/quieter one');

  // Native HermexBanner uses HStack(alignment: .top). The reconstruction must preserve that anatomy:
  // a wrapping description-only message starts beside the icon instead of vertically centering the
  // icon against the full multi-line text block.
  assert.match(
    bannerSrc,
    /standardHeaderRow:\s*\{[\s\S]*?alignItems:\s*'flex-start'/,
    'expected the icon and primary text region to top-align like native HermexBanner',
  );
  assert.match(
    headerRow,
    /style=\{\[styles\.headerRow, styles\.standardHeaderRow\]\}/,
    'expected the native-parity top alignment on the standard Banner row without changing the separate collapsible reconstruction',
  );

  // The indented second row (descriptionPad) must stay gated on title being present, so it never
  // renders for a description-only banner — the bug this fixes.
  assert.match(bannerSrc, /\{title && descriptionNode \? \(/, 'expected the descriptionPad second row to render only when title is also present');
});

test('Banner\'s hermesReference has no production usedIn entry and cites only its foundation source', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Banner');
  const ref = extractHermesReferenceBlock(section);

  assert.doesNotMatch(ref, /usedIn:\s*\[/, 'expected no production usedIn entries for foundation-only Banner');
  assert.match(ref, /HermesMobile\/Features\/Shared\/HermexBanner\.swift/, 'expected implementationNotes.sourcePaths to include HermexBanner.swift');
  assert.doesNotMatch(ref, /HermesMobile\/Features\/Chat\/ChatComposerView\.swift/, 'expected no production source path');
  assert.match(ref, /zero production|foundation-only|not adopted/i, 'expected the zero-adoption boundary to be explicit');
});

test('Buttons documents extra-small through large sizes, all four content configurations, and disabled/pending states', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Buttons');
  assert.match(section, /extraSmall \| small \| medium \| large/);
  assert.match(section, /glass surface option/i);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'ButtonDecisionAndTactilePreview');
  assert.match(body, /size="extraSmall"/);
  assert.match(body, /size="small"/);
  assert.match(body, /size="medium"/);
  assert.match(body, /size="large"/);
  assert.match(body, /Label only/);
  assert.match(body, /showLabel=\{false\}/, 'expected an icon-only example');
  assert.match(body, /iconPosition="leading"/);
  assert.match(body, /iconPosition="trailing"/);
  assert.match(body, /Disabled and pending/);
  assert.match(body, /disabled onPress/);
  assert.match(body, /loading onPress/);
});

test('the generic Button component gains an extraSmall size, extending the existing size scale downward without removing any existing size', () => {
  const typesSrc = read('native/components/Button/Button.types.ts');
  assert.match(typesSrc, /'large' \| 'medium' \| 'small' \| 'extraSmall'/);

  const implSrc = read('native/components/Button/Button.tsx');
  assert.match(implSrc, /extraSmall:\s*\{/);
  for (const size of ['large', 'medium', 'small']) {
    assert.match(implSrc, new RegExp(`${size}:\\s*\\{`), `expected the existing ${size} size to remain defined`);
  }
});

// Controller correction (2026-09-26, gap 3): "Press Feedback" was documented as the default but never
// implemented in the generic Button — only its resting/pressed background color changed. The approved
// specification requires a real slight scale + opacity response, Reduce-Motion-safe (scale suppressed,
// not merely eased) by reading the same system AccessibilityInfo signal the rest of this catalog
// already uses (Shimmer.tsx, HermesMotionReference.tsx) — no new dependency.
test('Correction (gap 3): the generic Button implements real default Press Feedback — a slight scale response on press, driven by Animated, suppressed under system Reduce Motion — with haptics untouched (absent)', () => {
  const implSrc = read('native/components/Button/Button.tsx');
  assert.match(
    implSrc,
    /import\s*\{[^}]*\bAnimated\b[^}]*\}\s*from\s*'react-native'/,
    'expected Animated imported from react-native to drive the real press-scale response',
  );
  assert.match(
    implSrc,
    /import\s*\{[^}]*\bAccessibilityInfo\b[^}]*\}\s*from\s*'react-native'/,
    'expected AccessibilityInfo imported from react-native — same pattern as Shimmer.tsx/HermesMotionReference.tsx, no new dependency',
  );
  assert.match(implSrc, /AccessibilityInfo\.isReduceMotionEnabled\(\)/, 'expected the initial Reduce Motion check');
  assert.match(
    implSrc,
    /AccessibilityInfo\.addEventListener\(\s*'reduceMotionChanged'/,
    'expected runtime Reduce Motion changes to be observed, not only checked once at mount',
  );
  assert.match(implSrc, /scaleAnim/, 'expected an Animated.Value driving the press scale');
  assert.match(
    implSrc,
    /reduceMotion\s*\?[^:]*:\s*PRESS_SCALE|!reduceMotion\s*&&/s,
    'expected the scale response to be explicitly suppressed under Reduce Motion, not merely re-timed',
  );
  assert.doesNotMatch(implSrc, /expo-haptics|Haptics\./, 'physical haptics must remain absent from the web/catalog Button — Press Feedback here is visual only');
});

test('Correction (gap 3): the Buttons preview documents the real four-way emphasis mapping (including Neutral) and demonstrates the Adaptive Glass surface as a style composition, never a new Button variant', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'ButtonDecisionAndTactilePreview');
  // Issue #607 final correction pass: native Neutral has a subtle fill with no border — the generic
  // secondary variant's own fill, not the fill-less tertiary variant — distinguished from Secondary
  // (same fill plus an explicit border) by that border alone. See the dedicated Buttons correction
  // test below for the full emphasis-mapping assertion.
  assert.match(body, /label="Neutral"\s+variant="secondary"/, 'expected a Neutral-role example — the accurate mapping needs all four Hermex emphasis roles demonstrated, not three');
  assert.match(body, /Neutral/);
  assert.match(
    body,
    /neutral.*secondary|secondary.*neutral/is,
    'expected the mapping caption to name the accurate neutral → secondary-fill pairing, not silently drop the Neutral role',
  );
  assert.match(body, /Adaptive Glass/);
  assert.match(body, /style composition|composing Adaptive Glass|not a (?:new|separate) (?:Button )?variant/i);

  const typesSrc = read('native/components/Button/Button.types.ts');
  assert.doesNotMatch(typesSrc, /'glass'/, 'Glass must stay a style composition, never a duplicated Button variant enum value');
});

test('List / ListItem documents an accessibility-label override and Dynamic Type layout adaptation, matching the generic component\'s real behavior', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'List / ListItem');
  assert.match(section, /accessibility-label override|overridable/i);
  assert.match(section, /Dynamic Type/);
});

test('Transcript Log Row documents its Buttons and Divider composition alongside Hermex typography/spacing/radius/motion', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Transcript Log Row');
  assert.match(section, /Hermex typography, spacing, radius, motion, Buttons, and Divider/);
});

// Correction (final-review source accuracy): TranscriptLogRowView.swift's ViewBuilder slots are
// icon, accessory, status, and expandedBody — the collapsed-row status word has no catalog slot at
// all, and the expanded scrollable body was misnamed "detail", which is really the separate `detail:
// String?` initializer value shown in the collapsed row, not the expanded generic body. Current-base
// integration correction (PR #974): current master added the optional generic `accessory` slot
// between `icon` and `status`; see the focused contract test below for its full shape.
test('Correction (final-review source accuracy): Transcript Log Row\'s compositionSlots match TranscriptLogRowView.swift exactly — icon, accessory, status, and expandedBody, in that order', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Transcript Log Row');
  const ref = extractHermesReferenceBlock(section);

  const slotsSrc = extractBracketBlock(ref, /compositionSlots:\s*\[/);
  const slotNames = [...slotsSrc.matchAll(/\{\s*name:\s*'([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(slotNames, ['icon', 'accessory', 'status', 'expandedBody'], 'expected the exact native TranscriptLogRowView.swift composition slot sequence');
});

// Current-base integration correction (PR #974): current master added an optional generic
// `accessory` ViewBuilder slot to TranscriptLogRowView, rendered trailing before the chevron at
// ordinary Dynamic Type sizes and moved below the summary/detail at accessibility sizes. The row
// ignores the accessory's own child accessibility semantics, so a caller that supplies one must
// fold its meaning into `accessibilityLabel`. This test pins that corrected contract in the catalog.
test('Current-base integration correction (PR #974): Transcript Log Row\'s catalog entry documents the optional accessory slot\'s shape, both adaptive placements, the accessibility-label fold requirement, and a usage example that demonstrates it', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Transcript Log Row');
  const ref = extractHermesReferenceBlock(section);

  const slotsSrc = extractBracketBlock(ref, /compositionSlots:\s*\[/);
  const slotNames = [...slotsSrc.matchAll(/\{\s*name:\s*'([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(
    slotNames,
    ['icon', 'accessory', 'status', 'expandedBody'],
    'expected composition slots icon, accessory, status, expandedBody in that exact order'
  );

  const slotObjects = splitTopLevelObjects(slotsSrc);
  const accessorySlotSrc = slotObjects.find((s) => /name:\s*'accessory'/.test(s));
  assert.ok(accessorySlotSrc, 'expected an accessory compositionSlots entry');
  assert.match(accessorySlotSrc, /order:\s*1\b/, 'expected accessory to be order 1, between icon (0) and status (2)');
  assert.match(accessorySlotSrc, /required:\s*false/, 'expected accessory to be optional');
  assert.match(accessorySlotSrc, /cardinality:\s*'one'/, 'expected accessory cardinality to be one');
  assert.match(accessorySlotSrc, /acceptedContent:\s*\[[^\]]*'text'[^\]]*\]/, 'expected accessory to accept text content');
  assert.match(accessorySlotSrc, /acceptedContent:\s*\[[^\]]*'generic-view'[^\]]*\]/, 'expected accessory to accept generic-view content');
  assert.match(accessorySlotSrc, /role:\s*'trailing-accessory'/, 'expected accessory role to be trailing-accessory');
  assert.match(accessorySlotSrc, /interactionOwnership:\s*'none'/, 'expected accessory to be noninteractive');
  assert.match(
    accessorySlotSrc,
    /accessibilityOwnership:\s*'component-owned'/,
    'expected accessory accessibilityOwnership to be component-owned, since the row ignores child semantics and requires callers to fold meaning into accessibilityLabel'
  );

  assert.match(
    section,
    /ordinary Dynamic Type sizes[^.]*trailing[^.]*before the chevron/i,
    'expected the catalog to describe ordinary-size trailing placement before the chevron'
  );
  assert.match(
    section,
    /accessibility sizes[^.]*below the summary\/detail/i,
    'expected the catalog to describe the accessibility-size placement below the summary/detail'
  );
  assert.match(
    section,
    /ignores (its )?(own )?child accessibility semantics/i,
    'expected the catalog accessibility prose to state that child accessibility semantics are ignored'
  );
  assert.match(
    section,
    /fold(s)? (its |the accessory's )?meaning into `?accessibilityLabel`?/i,
    'expected the catalog accessibility prose to require folding accessory meaning into accessibilityLabel'
  );

  const examplesSrc = extractBracketBlock(ref, /usageExamples:\s*\[/);
  assert.match(examplesSrc, /accessory:\s*\{/, 'expected a usage example demonstrating the optional accessory closure');
  assert.match(examplesSrc, /accessibilityLabel:\s*"[^"]*[+−-][^"]*"/, 'expected the usage example\'s accessibilityLabel to include the accessory\'s meaning');
});

// Controller correction (2026-09-26, gap 5), carried forward for Round 2: the preview rendered a
// disconnected, underlined "Expand/Collapse" text control below a non-interactive log row — the row
// itself never exposed accessibilityRole/expanded state and wasn't what a user would actually press.
// The real production row (TranscriptLogRowView) is itself the tappable disclosure.
test('Correction (gap 5): the Transcript Log Row preview is itself the interactive, Button-like disclosure row — no disconnected underlined Expand/Collapse control — and exposes real expanded/collapsed accessibility state', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'TranscriptLogRowPreview');
  assert.doesNotMatch(body, /textDecorationLine:\s*'underline'/, 'the disconnected underlined Expand/Collapse text control must be removed');
  assert.doesNotMatch(body, />\s*\{expanded \? 'Collapse' : 'Expand'\}/, 'no separate "Collapse"/"Expand" text label toggling the row from outside it');
  assert.match(body, /<Pressable/, 'expected the log row to be a real Pressable');
  assert.match(body, /onPress=\{\(\)\s*=>\s*setExpanded/, 'expected the log row Pressable itself to toggle expanded on its own onPress');
  assert.match(body, /accessibilityRole="button"/, 'expected the log row Pressable to expose accessibilityRole="button"');
  assert.match(body, /accessibilityState=\{\{\s*expanded\s*\}\}/, 'expected the log row Pressable to expose accessibilityState.expanded');

  // Summary, optional detail/status, body, and copy behavior must all be visibly covered.
  assert.match(body, /logStatus/i, 'expected an optional detail/status element alongside the summary');
  assert.match(body, /onLongPress/, 'expected a long-press-to-copy reconstruction of the real row\'s copy behavior');

  // No animation is introduced — expand/collapse stays an immediate, Reduce-Motion-safe show/hide.
  assert.doesNotMatch(body, /Animated\.|useNativeDriver/, 'expand/collapse must stay a static, non-animated show/hide in this browser reference');
});

test('Content Unavailable documents Empty, No results, Error, Unavailable, and Custom variants composing icon treatment, typography, spacing, and Buttons, with optional description plus primary/secondary actions, as a new foundation-only pattern', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Content Unavailable');
  assert.match(section, /new, foundation-only reusable pattern/);
  assert.match(section, /composes Hermex icon treatment, typography, spacing, and Buttons/);
  for (const variant of ["key: 'empty'", "key: 'no-results'", "key: 'error'", "key: 'unavailable'", "key: 'custom'"]) {
    assert.ok(section.includes(variant), `expected the ${variant} Content Unavailable variant`);
  }
  assert.match(section, /primaryAction/);
  assert.match(section, /secondaryAction/);

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /id:\s*'ContentUnavailableView'/, 'the direct-platform-usage id must be gone, replaced by the Hermex-owned pattern');
});

// Correction (#607 follow-up 2): the catalog's own ContentUnavailablePreview laid its primary and
// secondary actions out with `flexDirection: 'row'`, contradicting production HermexContentUnavailable
// .swift's `VStack(spacing: HermesSpacing.s8) { actionButtons }`, which stacks them vertically with the
// primary action first whenever both are present. The Custom variant and the "With primary + secondary
// actions" state both render two actions, so both must exercise the corrected vertical layout.
test('Correction (#607 follow-up 2): the Content Unavailable catalog preview stacks primary and secondary actions vertically, primary first, matching HermexContentUnavailable.swift\'s VStack — not a horizontal row', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const body = extractFunctionBody(sectionsSrc, 'ContentUnavailablePreview');
  assert.doesNotMatch(body, /flexDirection:\s*'row'/, 'the two-action layout must not be a horizontal row');

  const primaryIndex = body.indexOf('Retry');
  const secondaryIndex = body.indexOf('Learn more');
  assert.notEqual(primaryIndex, -1, 'expected a primary action example');
  assert.notEqual(secondaryIndex, -1, 'expected a secondary action example');
  assert.ok(primaryIndex < secondaryIndex, 'expected the primary action to render above/before the secondary action');

  const section = extractHermesSection(sectionsSrc, 'Content Unavailable');
  assert.match(section, /key: 'custom', name: 'Custom', node: <ContentUnavailablePreview variant="custom" primaryAction secondaryAction/, 'expected the Custom variant to exercise both actions');
  assert.match(section, /key: 'with-actions', name: 'With primary \+ secondary actions', node: <ContentUnavailablePreview primaryAction secondaryAction/, 'expected the "With primary + secondary actions" state to exercise both actions');
});

// Controller correction (production reconciliation): HermexContentUnavailable.swift is confirmed adopted for
// the four picker sheets' loading/error/empty states (ModelPickerSheet, DefaultProfilePickerView,
// CronJobSkillsPicker, CronJobConfigurationPickers) — ContentUnavailableView.search(text:)'s own
// no-results treatment intentionally stays a direct call even at those same call sites, and other
// screens (e.g. TasksView, SkillsView, MemoryView) still call ContentUnavailableView directly. The
// section must say "partially adopted", not "currently no Hermex-owned source file" / "Target
// architecture ... owned by a dedicated production workstream" — and must not overclaim full
// migration.
test('Correction (design-system-foundation truthfulness pass): Content Unavailable states foundation-only status — HermexContentUnavailable.swift has no production call site, and every screen (including the four picker sheets, Kanban, and Usage) still calls the native ContentUnavailableView directly', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Content Unavailable');
  assert.doesNotMatch(section, /partially adopted/i, 'HermexContentUnavailable.swift has zero production call sites — it must not be described as partially adopted');
  assert.match(section, /HermesMobile\/Features\/Shared\/HermexContentUnavailable\.swift/);
  for (const picker of [
    'HermesMobile/Features/Shared/ModelPickerSheet.swift',
    'HermesMobile/Features/Settings/DefaultProfilePickerView.swift',
    'HermesMobile/Features/Tasks/CronJobSkillsPicker.swift',
    'HermesMobile/Features/Tasks/CronJobConfigurationPickers.swift',
  ]) {
    assert.doesNotMatch(section, new RegExp(picker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), `${picker} does not import HermexContentUnavailable.swift and must not be cited as an adopted call site`);
  }
  assert.match(section, /30 production files/i);
  assert.match(section, /68 source references/i);
});

// ─── Explicit full-screen placement (HermexContentUnavailable.Layout) ───────────────────────────

test('Content Unavailable documents the additive layout prop (.intrinsic default / .fullScreen) in its Props table, truthfully, with no production adoption claim', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Content Unavailable');
  assert.match(
    section,
    /name:\s*'layout'/,
    'expected a documented "layout" prop',
  );
  assert.match(
    section,
    /'\.intrinsic'\s*\|\s*'\.fullScreen'|"'intrinsic'\s*\|\s*'fullScreen'"/,
    'expected the layout prop\'s type to name both .intrinsic and .fullScreen',
  );
  assert.match(section, /one[- ]third/i, 'expected the layout prop description to name the one-third placement, truthfully');
  assert.doesNotMatch(section, /partially adopted/i, 'the new layout API must not be described as adopted in production — it is foundation-only, same as the rest of this entry');
});

test('Content Unavailable adds a bounded, phone-like full-screen-placement catalog specimen showing content beginning around one-third down, as a new States / Configurations item', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Content Unavailable');
  assert.match(
    section,
    /key:\s*'full-screen'[\s\S]{0,120}name:\s*'Full-screen placement'/,
    'expected a "Full-screen placement" States / Configurations item',
  );

  const previewMatch = section.match(/node:\s*<(\w+)\s*\/>\s*\},\s*\n\s*\],\s*\n\s*\},\s*\n\s*hermesReference:/);
  assert.ok(previewMatch, 'expected the full-screen states item to reference a dedicated preview component');
  const previewName = previewMatch[1];

  const previewBody = extractFunctionBody(sectionsSrc, previewName);
  // The preview's own outer frame is a style-sheet reference (recon.<name>), not an inline literal —
  // resolve it to its actual declaration to check the frame is "bounded, phone-like": a fixed,
  // finite width/height, not an unbounded flex fill.
  const frameStyleMatch = previewBody.match(/<View style=\{recon\.(\w+)\}>/);
  assert.ok(frameStyleMatch, 'expected the preview\'s outer View to reference a recon.<name> frame style');
  const frameStyleName = frameStyleMatch[1];
  const frameDeclIdx = sectionsSrc.indexOf(`${frameStyleName}:`);
  assert.ok(frameDeclIdx > -1, `expected a recon.${frameStyleName} style declaration`);
  // Scans a window after the frame style's own declaration (covering it and its immediate sibling
  // style(s), e.g. a top-spacer keyed off the same frame) rather than the whole multi-thousand-line
  // file, so this doesn't accidentally match an unrelated width/height/fraction elsewhere.
  const frameRegion = sectionsSrc.slice(frameDeclIdx, frameDeclIdx + 400);
  assert.match(frameRegion, /width:\s*\d/, 'expected the preview frame to declare a fixed width');
  assert.match(frameRegion, /height:\s*\d/, 'expected the preview frame to declare a fixed height');
  // Content begins ~1/3 down: a spacer/offset sized to roughly a third of the frame's own height,
  // the same relationship HermexContentUnavailable.swift computes via GeometryReader's `/ 3`.
  assert.match(frameRegion, /\/\s*3\b/, 'expected the preview to reserve roughly one third of the frame height above the content cluster');
});

test('Pending Request documents Request Card composition and preserves the domain-owned request-state disclaimer', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Pending Request');
  assert.match(section, /Request Card/);
  assert.match(section, /domain-owned states/);
  assert.match(section, /approval, denial, clarification, pending, disabled, success, failure, cancellation, and recovery/);
});

test('Transcript Activity documents Turn Summary Disclosure, the Activity Disclosure Row, a grouped-tool-history control, assistant message content, and message metadata, preserving domain ownership', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Transcript Activity');
  assert.match(section, /Turn Summary Disclosure/);
  assert.match(section, /Activity Disclosure Row/);
  assert.match(section, /grouped-tool-history control/);
  assert.match(section, /assistant message content/i);
  assert.match(section, /message metadata/i);
  assert.match(section, /Domain ownership boundary preserved/);
});

test('Composer documents composition of the composer surface, Input Field, Buttons, Tag, Composer Chip, Attachment, Adaptive Glass, and status/validation feedback, while preserving domain ownership of text editing, draft persistence, and send/stop lifecycle', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Composer');
  assert.match(section, /composer surface, an input field, Buttons, Tag, Composer Chip, Attachment, Adaptive Glass/);
  assert.match(section, /text editing, keyboard interaction, draft persistence, attachments, runtime selection, voice input, and send\/stop lifecycle/);
  assert.match(section, /<ComposerPatternPreview/);

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function ComposerPatternPreview/);
});

// Issue #607 (Round 2): Composer documents the Composer Chip subsystem inline (production ownership,
// not a standalone HermexComposerChip API) — recognized skill/workspace-file/bot-mention/quote inline
// with editable/transcript text, distinct from a standalone action/destination/status/filter/
// attachment outside text, with Button/List-ListItem/Tag/Attachment as alternatives.
test('Composer documents Composer Chip as an inline text-embedded subsystem owned by production (not a standalone HermexComposerChip API), citing ComposerChipToken/ComposerChipRendering/ComposerChipTextView, with use/avoid guidance and Button/List-ListItem/Tag/Attachment alternatives', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Composer');
  assert.match(section, /Composer Chip/);
  assert.doesNotMatch(section, /struct HermexComposerChip|HermexComposerChip\(/, 'must not document a standalone HermexComposerChip API — Composer Chip stays a production subsystem, not a new Hermex component');
  for (const sourcePath of [
    'HermesMobile/Features/Chat/ComposerChipToken.swift',
    'HermesMobile/Features/Chat/ComposerChipRendering.swift',
    'HermesMobile/Features/Chat/ComposerChipTextView.swift',
  ]) {
    assert.match(section, new RegExp(sourcePath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), `expected Composer Chip documentation to cite ${sourcePath}`);
  }
  assert.match(section, /recognized skill,? workspace file,? bot mention,? or quote/i, 'expected use guidance for a recognized skill/workspace file/bot mention/quote inline with editable/transcript text');
  assert.match(section, /standalone action, destination, status, filter, or attachment/i, 'expected avoid guidance for a standalone action/destination/status/filter/attachment outside text');

  const ref = extractHermesReferenceBlock(section);
  const alts = extractAlternativeNames(ref);
  for (const expected of ['Buttons', 'List / ListItem', 'Tag', 'Attachment']) {
    assert.ok(alts.includes(expected), `expected Composer Chip's alternatives to include "${expected}"`);
  }
});

// Controller correction (2026-09-26, gap 6): Transcript Activity rendered the same single log row
// (now TranscriptLogRowPreview) as the standalone Transcript Log Row entry, plus prose — not a
// composite of its five documented pieces. It needs its own preview genuinely composing all five.
test('Correction (gap 6): Transcript Activity renders a real composite preview of Turn Summary Disclosure, the Activity Disclosure Row, a grouped-tool-history control, assistant message content, and message metadata — not the standalone Transcript Log Row preview reused verbatim', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Transcript Activity');
  assert.match(section, /<TranscriptActivityPreview/, 'expected Transcript Activity to render its own composite preview, not <TranscriptLogRowPreview />');
  assert.doesNotMatch(section, /<TranscriptLogRowPreview/, 'must no longer reuse the standalone Transcript Log Row preview verbatim as this pattern\'s own render');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function TranscriptActivityPreview/);
  const body = extractFunctionBody(previewsSrc, 'TranscriptActivityPreview');
  assert.match(body, /accessibilityState=\{\{\s*expanded(?::\s*\w+)?\s*\}\}/, 'expected a genuine Turn Summary Disclosure with its own expand/collapse state');
  assert.match(body, /Thinking|Turn Summary/i, 'expected a labeled turn-summary disclosure, distinct from a plain tool-call log row');
  assert.match(body, /accessibilityRole="button"/, 'expected the grouped-tool-history control to be a real, focusable control');
  assert.match(body, /(?:more tool call|tool calls|Show \d)/i, 'expected a grouped-tool-history control (e.g. "Show N more tool calls")');
  assert.match(body, /<Button\b/, 'expected the grouped-tool-history control to compose the real Button component, per Buttons\' own family');
  assert.match(body, /assistant/i, 'expected assistant message content');
  assert.match(body, /Domain ownership/i, 'expected the domain-ownership boundary to be restated alongside the composite, not only in the section prose');
});

// Controller correction (2026-09-26, gap 6): the Composer preview mocked its input as bare Text (not
// a real text field), its send action as a plain View (not the real Button), and never demonstrated
// Tag or a chip reference at all — three of the eight composed pieces the section's own copy already
// claims were missing from the rendered preview.
//
// Correction (#607 follow-up 2): the composer text field originally composed the generic template
// InputField, which visibly claims a floating-label look production doesn't use. It now composes a
// native-style TextInput reconstruction instead (see the Text Input entry), so this contract checks
// for that reconstruction rather than the generic InputField.
//
// Issue #607 (Round 2): the retired Inline Reference Link example is replaced by a real Composer
// Chip example, rendered inline with text rather than as a standalone focusable link.
test('Correction (gap 6): the Composer preview visibly composes a native-style text input reconstruction, the real Button, Tag, a Composer Chip example, and Card-based Attachment, labels its Adaptive Glass treatment, and shows status/validation feedback', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'ComposerPatternPreview');
  assert.doesNotMatch(body, /<InputField\b/, 'must no longer compose the generic template InputField');
  assert.match(body, /<TextInput\b/, 'expected the composer text field to compose a native-style TextInput reconstruction, not a bare Text placeholder');
  assert.match(body, /<Button\b/, 'expected the send action to compose the real generic Button, not a plain View');
  assert.match(body, /<Card density="compact"/, 'expected the composer\'s attachment tile to compose the real Card, per Attachment\'s own Compact Card composition');
  assert.match(body, /Composer Chip/i, 'expected a real Composer Chip example, rendered inline with text');
  assert.doesNotMatch(body, /accessibilityRole="link"/, 'the retired Inline Reference Link\'s standalone focusable-link example must not survive');
  assert.match(body, /Adaptive Glass/, 'expected the composer surface\'s glass treatment to be explicitly labeled, not just implied by an untitled translucent background');
  assert.match(body, /(?:invalid|too long|validation|warning)/i, 'expected explicit validation/status feedback beyond a single "Draft saved" status tag');

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Composer');
  // Domain-ownership copy must survive this preview rework verbatim.
  assert.match(section, /text editing, keyboard interaction, draft persistence, attachments, runtime selection, voice input, and send\/stop lifecycle/);
});

test('the four Patterns entries are the only members of the Patterns — Hermex group, and none of them is affirmatively described as a Card variant per the prohibited-list', () => {
  const src = read(HERMES_SECTIONS_PATH);
  for (const id of ['Content Unavailable', 'Pending Request', 'Transcript Activity', 'Composer']) {
    const section = extractHermesSection(src, id);
    assert.doesNotMatch(section, /is a Card variant|as generic Card props/i);
  }
});

// ─── Issue #607 follow-up: names + Avatar + TopNav + audits (2026-09-26) ────────────────────────
// "Hermex" is only removed from *catalog component display names* (Card, Banner, Checkbox, Avatar).
// Internal section ids can't literally become those bare strings: `sections` in
// HermesDesignSystemCatalog.tsx concatenates hermesSections with the retained template's own
// sections into one array keyed by `def.id` (CatalogShell's `sectionsById`), and the template
// already registers its own unrelated 'Card'/'Banner'/'Checkbox'/'Avatar' entries under those exact
// ids — reusing them here would silently collide in that shared lookup (whichever section is
// spread in last would win, and the other would become unreachable). So the renamed entries keep a
// unique, non-colliding 'Hermes <Name>' id (never starting with "Hermex") and declare `displayName`
// (SectionDef's own opt-in display override) with the plain name actually shown.

test('SectionDef supports an optional displayName, and the section title / sidebar nav label render it over the raw id', () => {
  const typesSrc = read(TYPES_PATH);
  assert.match(typesSrc, /displayName\?:\s*string/, 'expected an optional displayName field on SectionDef');

  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  assert.match(sectionBlockSrc, /\{def\.displayName\s*\?\?\s*def\.id\}/, 'expected the section title to prefer displayName over the raw id');

  const sidebarSrc = read(CATALOG_SIDEBAR_PATH);
  assert.match(sidebarSrc, /labelFor/, 'expected CatalogSidebar to accept a labelFor resolver');
  assert.match(sidebarSrc, /\{label\}/, 'expected NavItem to render the resolved label, not the raw id');

  const shellSrc = read(CATALOG_SHELL_PATH);
  assert.match(shellSrc, /labelFor\s*=\s*\(id[^)]*\)\s*=>\s*sectionsById\.get\(id\)\?\.displayName\s*\?\?\s*id/, 'expected CatalogShell to resolve each id\'s displayName from the same sectionsById map it already builds');
});

test('Foundations token sections keep namespaced internal ids but remove "Hermex" from their visible names', () => {
  const src = read(HERMES_SECTIONS_PATH);
  for (const [id, displayName] of [
    ['Hermex Colors', 'Colors'],
    ['Hermex Spacing', 'Spacing'],
    ['Hermex Typography', 'Typography'],
    ['Hermex Font', 'Font'],
    ['Hermex Motion', 'Motion'],
    ['Hermex Radius & Geometry', 'Radius & Geometry'],
    ['Hermex Shadow', 'Shadow'],
    ['Hermex Iconography', 'Iconography'],
  ]) {
    const section = extractHermesSection(src, id);
    assert.match(
      section,
      new RegExp(`displayName:\\s*'${displayName.replace(/[.*+?^${}()|[\\]\\]/g, '\\$&')}'`),
      `expected ${id} to render as ${displayName}`,
    );
  }
});

test('Card/Banner/Checkbox/Avatar keep unique, non-"Hermex"-prefixed internal ids and declare the plain displayName the brief requires', () => {
  const src = read(HERMES_SECTIONS_PATH);
  for (const stale of ["'Hermex Card'", "'Hermex Banner'", "'Hermex Checkbox'", "'Avatar & Bot Face'"]) {
    assert.ok(!src.includes(stale), `the pre-rename id ${stale} must no longer appear anywhere`);
  }
  for (const [id, displayName] of [
    ['Hermes Card', 'Card'],
    ['Hermes Banner', 'Banner'],
    ['Hermes Checkbox', 'Checkbox'],
    ['Hermes Avatar', 'Avatar'],
  ]) {
    assert.match(src, new RegExp(`\\| '${id}'`), `expected '${id}' in the HermesSectionId union`);
    const section = extractHermesSection(src, id);
    assert.match(section, new RegExp(`displayName:\\s*'${displayName}'`), `expected ${id} to declare displayName: '${displayName}'`);
  }
});

test('no id in the Components — Hermex nav group starts with "Hermex" (Foundations/token-family ids like "Hermex Colors" are out of this rename and keep their prefix)', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const navBlockMatch = src.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const ids = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(ids.length > 0);
  for (const id of ids) {
    assert.ok(!id.startsWith('Hermex'), `component id "${id}" must not start with "Hermex"`);
  }

  const foundationsGroupMatch = navBlockMatch[0].match(/label:\s*'Foundations',\s*\n\s*ids:\s*\[([\s\S]*?)\]/);
  assert.ok(foundationsGroupMatch, 'expected the Foundations — Hermex nav group');
  const foundationsIds = [...foundationsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(foundationsIds.every((id) => id.startsWith('Hermex')), 'Foundations/token-family ids keep their existing "Hermex" prefix — out of this rename\'s scope');
});

test('the Components — Hermex nav group preserves Hermex-owned family order while native TopNav lives in Native iOS', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const navBlockMatch = src.match(/export const hermesNav:[^;]*;/s);
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  const ids = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.deepEqual(ids, [
    'Hermes Avatar', 'Hermes Card', 'Attachment', 'Hermes Banner', 'Hermes Toast', 'Row Divider', 'Tag',
    'Search', 'Text Input', 'Hermes Selection Sheet', 'Hermes Tooltip', 'Segmented Control',
    'Buttons', 'Hermes Checkbox', 'Hermes Radio', 'Skeleton Loading', 'List / ListItem', 'Accordion List', 'Transcript Log Row',
    'Composer Toolbar', 'Bottom Sheet', 'Hermes Dialog', 'Hermes Popover Menu',
  ]);
});

test('the Components — Hermex nav group alphabetizes by visible display name at render time, not raw id', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const navBlockMatch = src.match(/export const hermesNav:[^;]*;/s);
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',([\s\S]*?)ids:\s*\[/);
  assert.match(componentsGroupMatch[1], /alphabetizeByLabel:\s*true/, 'expected the Components — Hermex group to opt into label-based alphabetization');

  const foundationsGroupMatch = navBlockMatch[0].match(/label:\s*'Foundations',([\s\S]*?)ids:\s*\[/);
  assert.doesNotMatch(foundationsGroupMatch[1], /alphabetizeByLabel/, 'Foundations keeps its own intentional sequence, unaffected by the new opt-in');
});

test('sortIds sorts by raw id unless a group opts into label-based alphabetization', () => {
  const typesSrc = read('native/catalog/types.ts');
  assert.match(typesSrc, /alphabetizeByLabel\?:\s*boolean/, 'expected NavGroup to expose the opt-in flag');
  assert.match(
    typesSrc,
    /export function sortIds<TId extends string>\(ids: readonly TId\[\], keyFor\?: \(id: TId\) => string\): TId\[\]/,
    'expected sortIds to accept an optional per-id sort key, defaulting to the raw id',
  );

  for (const path of ['native/catalog/CatalogShell.tsx', 'native/catalog/CatalogSidebar.tsx']) {
    const src = read(path);
    assert.match(src, /g\.alphabetizeByLabel \? labelFor : undefined/, `expected ${path} to thread alphabetizeByLabel through sortIds`);
  }
});

// Correction (2026-09-27): the two tests above only check that a flag is set and that `sortIds`
// exists — neither actually computes the order a reader would see. This test recomputes it, the
// same way `CatalogShell`'s own `labelFor`/`sortIds` do (displayName, falling back to id, then
// localeCompare), and pins the result to a literal, humanly-verifiable alphabetical list — so a
// future id or displayName addition that breaks true alphabetical order fails here, not just in a
// visual review.
test('the Components — Hermex group\'s computed render order is actually alphabetical by display name, not merely flagged as such', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const navBlockMatch = src.match(/export const hermesNav:[^;]*;/s);
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  const ids = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);

  const labelFor = (id) => {
    const section = extractHermesSection(src, id);
    const displayNameMatch = section.match(/displayName:\s*'([^']+)'/);
    return displayNameMatch ? displayNameMatch[1] : id;
  };
  const computedOrder = ids.slice().sort((a, b) => labelFor(a).localeCompare(labelFor(b)));

  assert.deepEqual(computedOrder.map(labelFor), [
    'Accordion List', 'Attachment', 'Avatar', 'Banner', 'Bottom Sheet', 'Buttons', 'Card', 'Checkbox', 'Composer Toolbar', 'Dialog',
    'List / ListItem', 'Popover Menu', 'Radio', 'Row Divider', 'Search',
    'Segmented Control', 'Selection Sheet', 'Skeleton Loading', 'Tag', 'Text Input', 'Toast', 'Tooltip', 'Transcript Log Row',
  ], 'expected the computed labelFor+sortIds order to be truly alphabetical by display name');
});

// ─── Avatar named/custom size API ────────────────────────────────────────────────────────────────

test('Avatar exports an immutable AVATAR_SIZE map (small=32/medium=40/large=48), defaults size to \'medium\', and keeps a numeric custom-size escape hatch', () => {
  const src = read('native/components/Avatar/Avatar.tsx');
  assert.match(src, /export const AVATAR_SIZE = Object\.freeze\(\{/, 'expected an exported, immutable size map');
  assert.match(src, /small:\s*32/);
  assert.match(src, /medium:\s*40/);
  assert.match(src, /large:\s*48/);
  assert.match(src, /export type AvatarSizeName = keyof typeof AVATAR_SIZE/);
  assert.match(src, /size\?:\s*AvatarSizeName \| number/, 'expected size to accept a named step or a raw number');
  assert.match(src, /size = 'medium'/, "expected size to default to 'medium'");
  assert.match(src, /typeof size === 'number' \? size : AVATAR_SIZE\[size\]/, 'expected the numeric escape hatch to bypass the named map entirely');

  const indexSrc = read('native/components/Avatar/index.ts');
  assert.match(indexSrc, /export \{ Avatar, AVATAR_SIZE \} from '\.\/Avatar'/);
  assert.match(indexSrc, /export type \{ AvatarProps, AvatarSizeName \} from '\.\/Avatar'/);
});

test('the Avatar family entry\'s specimens show the three named sizes, one intentional custom size, and the existing image/icon/initials/bot-face variants', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const previewSrc = read('native/catalog/hermes/HermesComponentFamiliesPreviews.tsx');
  const section = extractHermesSection(sectionsSrc, 'Hermes Avatar');
  assert.match(section, /<AvatarFamilyGallery/);
  assert.match(section, /AVATAR_SIZE/, 'expected the props table to reference the exported size map');

  const body = extractFunctionBody(sectionsSrc, 'AvatarFamilyGallery');
  assert.match(body, /size="small"/);
  assert.doesNotMatch(body, /size="medium"/, 'medium is the default — demonstrate it by omission, not by passing the value explicitly');
  assert.match(body, /size="large"/);
  assert.match(body, /size=\{64\}/, 'expected exactly one intentional custom numeric size example');
  assert.match(body, /imageUrl=/, 'expected the image content variant');
  assert.match(body, /iconName="menu"/, 'expected the icon content variant');
  assert.match(body, /initials="JS"/, 'expected an initials content variant beyond the production identity examples');
  assert.match(body, /<IdentityAvatarPreview/, 'expected the existing production identity variants to survive');
  assert.match(body, /<BotMarkPreview/, 'expected the existing bot-face variant to survive');
  assert.match(sectionsSrc, /avatarGallery:\s*\{[^}]*width:\s*'100%'[^}]*minWidth:\s*0/s, 'expected the Avatar gallery to be allowed to shrink inside the Variants column');
  assert.match(sectionsSrc, /avatarPreviewRow:\s*\{[^}]*flexWrap:\s*'wrap'[^}]*width:\s*'100%'[^}]*minWidth:\s*0/s, 'expected Avatar specimen rows to wrap instead of overflowing into Props');
  assert.match(sectionsSrc, /avatarIdentityItem:\s*\{[^}]*maxWidth:\s*'100%'[^}]*minWidth:\s*0[^}]*flexShrink:\s*1/s, 'expected long identity labels to shrink within their row');
  assert.match(previewSrc, /botMarkPreview:\s*\{[^}]*flexBasis:\s*220[^}]*maxWidth:\s*'100%'[^}]*minWidth:\s*0/s, 'expected the bot-face explanation to wrap inside the Avatar specimen row');
  assert.match(previewSrc, /<View style=\{preview\.botMarkPreview\}>/);
});

test('Avatar accepts an optional iconSize override that replaces the default half-diameter icon ratio, without changing existing callers\' default behavior', () => {
  const src = read('native/components/Avatar/Avatar.tsx');
  assert.match(src, /iconSize\?:\s*number/, 'expected an optional iconSize override prop');
  assert.match(src, /const resolvedIconSize = iconSize \?\? Math\.round\(resolvedSize \* 0\.5\)/, 'expected the override to fall back to the existing default half-diameter ratio when omitted, so every existing caller keeps its current icon size');
  assert.match(src, /<Icon name=\{iconName\} size=\{resolvedIconSize\}/, 'expected the icon to render at the resolved (possibly overridden) size');
});

test('AvatarSystemImageIdentityPreview renders the production system-image identity specimen for every HERMES_ICON_AVATAR_PAIRING entry (32→20, 40→24, 48→32), driven from the pairing data rather than duplicated literals or a stale caption', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(previewsSrc, /import \{ HERMES_ICON_AVATAR_PAIRING \} from '\.\/hermesIconSize'/, 'expected the pairing import alongside the existing icon-size import');
  assert.match(previewsSrc, /export function AvatarSystemImageIdentityPreview/);
  const body = extractFunctionBody(previewsSrc, 'AvatarSystemImageIdentityPreview');
  assert.match(body, /Object\.entries\(HERMES_ICON_AVATAR_PAIRING\)/, 'expected the gallery to render every pairing entry, not a hand-duplicated list');
  assert.match(body, /size=\{avatar\}/, 'expected each specimen to use the pairing\'s own avatar diameter');
  assert.match(body, /iconSize=\{icon\}/, 'expected each specimen to use the pairing\'s own icon size override');
  assert.doesNotMatch(body, /\b32\b|\b40\b|\b48\b|\b20\b|\b24\b/, 'must not duplicate a pairing diameter/icon size as a local literal');
  assert.doesNotMatch(body, /Large \(48\)|icon 24/i, 'must not carry the stale hand-typed caption');

  const avatarGallery = extractFunctionBody(sectionsSrc, 'AvatarFamilyGallery');
  assert.match(avatarGallery, /<AvatarSystemImageIdentityPreview\s*\/>/, 'expected the live Avatar family gallery to compose the corrected production pairing specimen');
  assert.doesNotMatch(avatarGallery, /Large \(48\) · icon 24/, 'the stale production pairing must not remain rendered beside the corrected specimen');
});

// ─── TopNav slot contract + specimens ────────────────────────────────────────────────────────────

test('TopNav exposes explicit leadingPrimary/leadingSecondary/center/trailingPrimary/trailingSecondary slots, keeps leading/trailing as backward-compatible fallbacks, and reserves a symmetric per-side minimum width', () => {
  const src = read('native/components/TopNav/TopNav.tsx');
  for (const prop of ['leadingPrimary', 'leadingSecondary', 'trailingPrimary', 'trailingSecondary', 'center']) {
    assert.match(src, new RegExp(`${prop}\\?:\\s*ReactNode`), `expected an explicit ${prop} slot prop`);
  }
  assert.match(src, /resolvedLeadingPrimary\s*=\s*leadingPrimary\s*\?\?\s*leading/, 'expected leadingPrimary to fall back to the deprecated leading prop');
  assert.match(src, /resolvedTrailingPrimary\s*=\s*trailingPrimary\s*\?\?\s*trailing/, 'expected trailingPrimary to fall back to the deprecated trailing prop');
  assert.match(src, /slotGroup:\s*\{[^}]*minWidth:\s*SLOT_SIZE \* 2/s, 'expected each side to reserve a symmetric two-slot minimum width');

  // Existing consumers (Dropdown, the retained template catalog) pass `leading`/`trailing` directly —
  // the fallback above must keep them working without their own call sites changing.
  const dropdownSrc = read('native/components/Dropdown/Dropdown.tsx');
  assert.match(dropdownSrc, /<TopNav[\s\S]*?trailing=\{/, 'expected the pre-existing Dropdown TopNav usage to keep working unchanged');
});

test('the Hermes TopNav entry documents a new, foundation-only ToolbarContent contract with no production call site, that simple screens may keep a native navigation title, and that bottom/keyboard toolbars are out of scope', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /\| 'Hermes TopNav'/, "expected 'Hermes TopNav' in the HermesSectionId union");
  const section = extractHermesSection(sectionsSrc, 'Hermes TopNav');
  assert.match(section, /displayName:\s*'TopNav'/);
  assert.match(section, /ToolbarContent/, 'expected the new ToolbarContent type to be named');
  assert.doesNotMatch(section, /fully adopted/i, 'TopNav.swift has no production call site — it must not be described as fully adopted');
  assert.doesNotMatch(section, /57 top-navigation toolbar blocks/i, 'the "57 blocks across 39 files" migration claim is fabricated and must not appear');
  assert.match(section, /no production file imports or composes the new TopNav\.swift/i);
  assert.match(section, /HermesMobile\/Features\/Shared\/TopNav\.swift/, 'expected the new component source to be linked');
  assert.match(section, /native navigation title/i, 'expected the native-navigation-title escape hatch for simple screens to be documented');
  assert.match(section, /out of scope/i, 'expected bottom/keyboard toolbars to be explicitly scoped out');
  assert.match(section, /[Bb]ottom.*keyboard toolbar|keyboard.*[Tt]oolbar/, 'expected bottom/keyboard toolbars to be named as the excluded concern');
  assert.match(section, /<TopNavFamilyGallery/);
});

test('TopNav specimens cover standard navigation, a modal/editor, and populated two-leading/two-trailing slots', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /export function TopNavFamilyGallery/);
  assert.match(previewsSrc, /topNavActionButton:\s*\{[^}]*minWidth:\s*44[^}]*minHeight:\s*44/s, 'expected TopNav specimen actions to preserve a 44pt hit target');
  assert.match(previewsSrc, /function iconSlotButton[\s\S]*?size="small"[\s\S]*?style=\{preview\.topNavActionButton\}/, 'expected compact TopNav icon visuals inside a 44pt action target');
  const body = extractFunctionBody(previewsSrc, 'TopNavFamilyGallery');

  // Standard navigation.
  assert.match(body, /leadingPrimary=\{iconSlotButton\('chevron-left', 'Back'\)\}/);
  assert.match(body, /trailingPrimary=\{iconSlotButton\('search', 'Search'\)\}/);

  // Modal/editor.
  assert.match(body, /size="small" label="Cancel"[\s\S]*?style=\{preview\.topNavActionButton\}/, 'expected a compact modal Cancel action inside a 44pt target');
  assert.match(body, /size="small" label="Save"[\s\S]*?style=\{preview\.topNavActionButton\}/, 'expected a compact modal Save action inside a 44pt target');

  // Populated two-leading/two-trailing coverage, all four slots at once.
  const fourSlotBlock = body.match(/<TopNav\s+title="quarterly-report\.pdf"[\s\S]*?\/>/);
  assert.ok(fourSlotBlock, 'expected a specimen naming all four optional slots together');
  for (const prop of ['leadingPrimary', 'leadingSecondary', 'trailingSecondary', 'trailingPrimary']) {
    assert.match(fourSlotBlock[0], new RegExp(`${prop}=`), `expected the four-slot specimen to populate ${prop}`);
  }
});

test('the TopNav entry documents that actions retain labels and hit targets, center truncates rather than overlapping actions, and slot order stays semantic', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Hermes TopNav');
  assert.match(section, /accessibilityLabel/, 'expected retained action labels to be documented');
  assert.match(section, /44.{0,3}44pt hit target|hit target/i, 'expected the minimum hit target to be documented');
  assert.match(section, /truncat/i, 'expected center truncation (not overlap) to be documented');
  assert.match(section, /semantic/i, 'expected slot order to be documented as semantic, not just visual');
});

// ─── Attachment/Card radius parity + opaque close-control tokens ────────────────────────────────

test('Correction (attachment parity): normal Attachment outer surfaces reference the same Card radius token as Card (DS_RADIUS.medium), never an independent Attachment-only outer-radius value', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /import\s*\{[^}]*\bDS_RADIUS\b[^}]*\}\s*from\s*'\.\.\/\.\.\/\.\.\/tokens'/, 'expected DS_RADIUS to be imported directly, not a re-derived value');
  const tileBoxMatch = previewsSrc.match(/tileBox:\s*\{[^}]*\}/s);
  assert.ok(tileBoxMatch, 'expected a tileBox style');
  assert.match(tileBoxMatch[0], /borderRadius:\s*DS_RADIUS\.medium/, 'tileBox must reference DS_RADIUS.medium directly');
  assert.doesNotMatch(tileBoxMatch[0], /borderRadius:\s*\d/, 'must not hardcode a numeric radius independent of the shared Card token');

  const cardImplSrc = read('native/components/Card/Card.tsx');
  assert.match(cardImplSrc, /card:\s*\{[^}]*borderRadius:\s*DS_RADIUS\.medium/s, 'expected Card\'s own outer radius to be the same DS_RADIUS.medium token being asserted above');
});

test('Correction (attachment parity): the Attachment remove/close control uses an opaque semantic color token (the "white" Button variant), never the alpha-derived "secondary" variant', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');
  assert.match(body, /variant="white"[\s\S]{0,160}?iconName="clear"/, 'expected the remove control to use the opaque "white" variant');
  assert.doesNotMatch(body, /variant="secondary"[\s\S]{0,160}?iconName="clear"/, 'must not pair the alpha-derived "secondary" variant with the remove control');

  const buttonImplSrc = read('native/components/Button/Button.tsx');
  const whiteVariantMatch = buttonImplSrc.match(/white:\s*\{\s*container:[\s\S]*?label:[^}]*\},\s*\n\s*\}/);
  assert.ok(whiteVariantMatch, 'expected to find the "white" Button variant\'s style block');
  assert.doesNotMatch(whiteVariantMatch[0], /rgba\(/i, 'the opaque "white" variant must never resolve through an alpha/opacity-derived rgba() color');
});

// ─── Foundation branch-status summary (replaces the former production-adoption matrix) ───────────
// Required correction 1: most additions remain foundation-only, while bounded production adoptions
// are stated explicitly per entry. These tests pin down the truthful replacement for the removed
// screen-by-screen PRODUCTION_ADOPTION_AUDIT table.

test('the catalog replaces the former screen-by-screen production-adoption matrix with a compact, truthful branch-status summary — foundation-first with bounded exceptions, not a per-screen adoption audit', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.doesNotMatch(sectionsSrc, /PRODUCTION_ADOPTION_AUDIT/, 'the screen-by-screen adoption matrix must be removed');
  assert.doesNotMatch(sectionsSrc, /HermesProductionAdoptionAuditTable/, 'the screen-by-screen adoption table component must be removed');
  assert.doesNotMatch(sectionsSrc, /function HermesProductionAdoptionAuditTable/);

  assert.match(sectionsSrc, /function HermesFoundationBranchStatusTable/, 'expected a dedicated, truthful branch-status table component');
  assert.match(sectionsSrc, /FOUNDATION_BRANCH_STATUS/);
  assert.match(sectionsSrc, /HermesFoundationBranchStatusTable/, 'expected it to actually be rendered');
  assert.doesNotMatch(sectionsSrc, /id:\s*'[^']*[Aa]doption [Aa]udit[^']*'/, 'the branch-status summary must not be registered as its own nav-linked SectionDef — it belongs in the overview, not repeated per component');

  assert.match(sectionsSrc, /Foundation APIs\/components\/tokens are available in the current repository candidate/i);
  assert.match(sectionsSrc, /Existing\s+production\s+use\s+and\s+any\s+bounded\s+migration\s+in\s+this\s+work\s+are\s+stated\s+explicitly\s+per\s+entry/i);
  assert.match(sectionsSrc, /Branch status/i);
  assert.doesNotMatch(sectionsSrc, /screen-by-screen snapshot of how much of the design system each screen uses/i, 'must not still claim to audit per-screen adoption');

  // None of the specific per-screen "Strong"/"Yes" adoption claims from the removed matrix may
  // survive anywhere in the file.
  for (const stale of [
    "screen: 'Tasks', level: 'Strong'",
    "screen: 'Kanban', level: 'Strong'",
    "screen: 'Skills', level: 'Strong'",
    "screen: 'Memory', level: 'Strong'",
    "screen: 'Usage', level: 'Strong'",
    "'\"Enjoying Hermex?\" (TipJarCard.swift)'",
    "screen: 'Conversation loading', level: 'Yes'",
  ]) {
    assert.ok(!sectionsSrc.includes(stale), `did not expect the retired per-screen adoption claim "${stale}" to survive`);
  }
});

test('the foundation branch-status table names current verified adoption exceptions without claiming that every component has zero production call sites', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const tableMatch = sectionsSrc.match(/const FOUNDATION_BRANCH_STATUS: FoundationStatusRow\[\] = \[[\s\S]*?\n\];/);
  assert.ok(tableMatch, 'expected a FOUNDATION_BRANCH_STATUS array literal');
  const table = tableMatch[0];
  assert.match(table, /AppTheme\.swift/);
  assert.match(table, /HermesProductPalette/);
  assert.match(table, /No production screen reads from them yet/i);
  assert.match(table, /HermexBanner/i, 'expected Banner foundation availability to be named');
  assert.doesNotMatch(table, /main chat composer/i, 'must not claim a new Banner production adoption');
  assert.match(table, /TranscriptLogRowView|Transcript Log Row/i, 'expected the pre-existing production Transcript Log Row adoption to be named');
  assert.doesNotMatch(table, /None has a production call site in this branch/i, 'must not retain the now-false zero-adoption claim');
});

// ─── #607 correction slice: Content Unavailable, HermexList, HermesUsageSize — foundation-only ────

test('Content Unavailable truthfully states Kanban\'s status/filter empty branch and Usage\'s loading/error/empty states, alongside the four picker sheets, all still call the native ContentUnavailableView directly (no HermexContentUnavailable adoption)', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Content Unavailable');
  assert.match(section, /Kanban/);
  assert.match(section, /Usage/);
  assert.doesNotMatch(section, /HermesMobile\/Features\/Kanban\/KanbanLabView\.swift/, 'KanbanLabView.swift does not import HermexContentUnavailable.swift and must not be cited as a caller');
  assert.doesNotMatch(section, /HermesMobile\/Features\/Insights\/InsightsView\.swift/, 'InsightsView.swift does not import HermexContentUnavailable.swift and must not be cited as a caller');
  for (const picker of [
    'HermesMobile/Features/Shared/ModelPickerSheet.swift',
    'HermesMobile/Features/Settings/DefaultProfilePickerView.swift',
    'HermesMobile/Features/Tasks/CronJobSkillsPicker.swift',
    'HermesMobile/Features/Tasks/CronJobConfigurationPickers.swift',
  ]) {
    assert.doesNotMatch(section, new RegExp(picker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), `${picker} does not import HermexContentUnavailable.swift and must not be cited as an adopted call site`);
  }
});

// Foundation split (#607): shared List/ListItem capabilities are new and unadopted. No production
// screen — including Session's main menu and its utility/disclosure rows — has migrated onto them.
test('List / ListItem documents its foundation capabilities without claiming any production adoption, including the deferred Session utility-row migration', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'List / ListItem');
  assert.match(section, /HermexList/);
  assert.doesNotMatch(section, /HermesMobile\/Features\/SessionList\/SessionListView\.swift/, 'SessionListView.swift does not import HermexList.swift and must not be cited as a caller');
  assert.match(section, /hapticFeedbackStyle/, 'expected the opt-in ListItem haptic capability to be documented');
  assert.match(section, /no production caller/i);
  assert.doesNotMatch(section, /retired bespoke SidebarNavButton/i);
  assert.doesNotMatch(section, /Bots\/Tasks\/Kanban\/Skills\/Memory\/Usage/);
});

test('Hermex Spacing catalogs every HermesUsageSize component token by semantic name and value', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const gallery = extractFunctionBody(src, 'HermesSpacingGallery');
  assert.match(gallery, /HERMES_USAGE_SIZE/);
  for (const [name, value] of [
    ['chartHeight', '180'],
    ['legendIndicator', '7'],
    ['balanceBarHeight', '8'],
    ['minimumBalanceFill', '8'],
  ]) {
    assert.match(src, new RegExp(`name:\\s*'HermesUsageSize\\.${name}'[\\s\\S]*?value:\\s*'${value}pt'`));
  }
});

test('Hermex Spacing renders a decision ladder choosing among the existing 12 steps by relationship, not adding new values', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const gallery = extractFunctionBody(src, 'HermesSpacingGallery');
  assert.match(gallery, /HERMES_SPACING_LADDER/, 'expected the gallery to render a data-driven decision ladder');
  assert.match(src, /Decision ladder/);

  const ladderMatch = src.match(/const HERMES_SPACING_LADDER: SpacingLadderRung\[\] = \[([\s\S]*?)\n\];/);
  assert.ok(ladderMatch, 'expected a HERMES_SPACING_LADDER data array');
  const ladderSrc = ladderMatch[1];

  // Every rung's step(s) must be one of the real, already-existing HermesSpacing step names —
  // never a new numeric literal outside that scale (mirrors HERMES_SPACING_STEPS itself, asserted
  // verbatim against hermesTokenProposal.ts elsewhere in this file).
  const approvedSteps = [0, 2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64];
  const stepRefs = [...ladderSrc.matchAll(/space\.(\d+)/g)].map((m) => Number(m[1]));
  assert.ok(stepRefs.length > 0, 'expected the ladder to cite real space.N step names');
  for (const step of stepRefs) {
    assert.ok(approvedSteps.includes(step), `ladder cites space.${step}, which is not one of HermesSpacing's approved steps`);
  }

  // At minimum distinguishes: micro/inline, related controls, compact component padding, default
  // card/screen inset, major content groups, and section separation.
  for (const relationship of [
    /micro.*inline/i,
    /related controls/i,
    /compact component padding/i,
    /card.*screen inset/i,
    /major content groups/i,
    /section separation/i,
  ]) {
    assert.match(ladderSrc, relationship, `expected the decision ladder to cover a rung matching ${relationship}`);
  }
});

// ─── #607 follow-up: catalog framework (two-column Variants, five-line Props clamp) ─────────────

test('a Variants specimen box lays out up to three responsive columns when width permits, falling back naturally as space contracts; on the retained template/framework routes a wide itemsFill slot still stays single-column, but a Hermex main-canvas specimen slot (DSR3-04) opts into the grid even when itemsFill is true; on the retained routes, States/Configurations never opts in — only DSR3-04\'s Hermex main canvas gives States its own grid option', () => {
  const src = read(SECTION_BLOCK_PATH);
  const generalBody = extractFunctionBody(src, 'SectionBlock');
  const hermexBody = extractFunctionBody(src, 'HermexSectionCanvas');
  assert.match(src, /twoColumn\?:\s*boolean/, 'expected SlotItems to accept an opt-in twoColumn flag');
  assert.match(generalBody, /<SlotItems slot=\{def\.variants\} twoColumn \/>/, 'expected only the retained routes\' Variants block to opt in, not States/Configurations');
  assert.doesNotMatch(generalBody, /<SlotItems slot=\{def\.states\}[^/]*twoColumn/, 'the retained template/framework States/Configurations column must not opt into the two-column grid');
  assert.match(hermexBody, /<SlotItems slot=\{def\.states\} twoColumn specimen \/>/, 'DSR3-04: the Hermex main canvas gives States its own two-column specimen option too');
  // A wide itemsFill slot only stays single-column on the retained template/framework routes
  // (no `specimen` prop reaches SlotItems there); a Hermex main-canvas specimen slot (`specimen`
  // true) opts into the same grid even when `itemsFill` is true, since every specimen is already
  // capped at SPECIMEN_COLUMN_MAX_WIDTH regardless of `itemsFill`.
  assert.match(
    src,
    /useGrid\s*=\s*twoColumn\s*&&\s*\(specimen\s*\|\|\s*!slot\.itemsFill\)\s*&&\s*slot\.items\.length > 1/,
    'expected the wrapping grid to apply to multi-item specimen slots while retained-route itemsFill slots remain stacked',
  );
  assert.match(src, /exampleGrid:\s*\{\s*flexDirection:\s*'row',\s*flexWrap:\s*'wrap'/, 'expected a wrapping row style for the two-column grid');
  assert.match(
    src,
    /exampleGrid:\s*\{[^}]*gap:\s*CATALOG_SPECIMEN_GRID_GAP[^}]*justifyContent:\s*'flex-start'/s,
    'expected the itemized specimen grid to use the shared 40px specimen-grid gap and keep incomplete rows left-aligned',
  );
  assert.match(
    src,
    /exampleGridItem:\s*\{[^}]*flexBasis:\s*320[^}]*flexGrow:\s*1[^}]*maxWidth:\s*SPECIMEN_COLUMN_MAX_WIDTH/s,
    'expected container-driven wrapping to keep each item at a comfortable minimum basis and a 402px maximum instead of forcing two cramped viewport-driven columns',
  );
  const slotItems = extractFunctionBody(src, 'SlotItems');
  assert.doesNotMatch(slotItems, /useWindowDimensions|CATALOG_NARROW_BREAKPOINT|isNarrow/);
});

test('DSR3-607: an itemized Hermex main-canvas Variants/States group with itemsFill true (e.g. Hermes Card, Pending Request) still renders through the responsive two-column specimen grid, not the single stacked-column itemsFill layout', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const cardSection = extractHermesSection(sectionsSrc, 'Hermes Card');
  const requestSection = extractHermesSection(sectionsSrc, 'Pending Request');
  for (const section of [cardSection, requestSection]) {
    assert.match(section, /itemsFill:\s*true/, 'expected this fixture section to keep demonstrating an itemsFill slot');
  }
  // The actual rendering rule lives in SectionBlock, scoped by the `specimen` boundary asserted above
  // (SlotItems only ever receives `specimen` from HermexSectionCanvas) — this section-data assertion
  // just pins the real-world fixture the acceptance contract names, so a future edit that removes
  // these itemsFill groups doesn't silently make the grid rule above untested against a real case.
  const src = read(SECTION_BLOCK_PATH);
  assert.match(
    src,
    /useGrid\s*=\s*twoColumn\s*&&\s*\(specimen\s*\|\|\s*!slot\.itemsFill\)/,
    'expected the specimen boundary to be the one place a wide itemsFill slot still reaches the two-column grid',
  );
});

test('DSR3-607: a render()-based Hermex gallery may span three 402px columns plus two gaps and its 16px wrapper inset on a wide viewport', () => {
  const src = read(SECTION_BLOCK_PATH);
  const hermexBody = extractFunctionBody(src, 'HermexSectionCanvas');
  assert.match(hermexBody, /isNarrow/, 'expected HermexSectionCanvas to know the current narrow/wide viewport, like SectionBlock already does');
  assert.match(
    hermexBody,
    /def\.render\s*\?\s*\(\s*<View style=\{\[styles\.specimenColumn,\s*styles\.renderSpecimenColumn,\s*!isNarrow\s*&&\s*styles\.renderSpecimenColumnWide\]\}>\s*\{def\.render\(\)\}\s*<\/View>/s,
    'expected a wide-viewport-only style added alongside the existing specimenColumn/renderSpecimenColumn pair, not a replacement of the narrow-viewport contract',
  );
  assert.match(
    src,
    /renderSpecimenColumnWide:\s*\{\s*maxWidth:\s*SPECIMEN_COLUMN_MAX_WIDTH\s*\*\s*3\s*\+\s*CATALOG_SPECIMEN_GRID_GAP\s*\*\s*2\s*\+\s*CATALOG_SPACE\.lg\s*\*\s*2\s*\}/,
    'expected the wide render wrapper to accommodate three 402px columns, two 40px specimen-grid gaps, and its 16px inset on both sides',
  );
});

test('DSR3-607: the Hermex main canvas is wide enough for three full 402px columns and gives each card 16px padding without widening retained catalog routes', () => {
  const tokensSrc = read(TOKENS_PATH);
  const shellSrc = read(CATALOG_SHELL_PATH);
  const sectionSrc = read(SECTION_BLOCK_PATH);

  assert.match(tokensSrc, /CATALOG_HERMEX_MAX_CONTENT_WIDTH\s*=\s*1416/);
  assert.match(shellSrc, /hasHermexSections\s*=\s*sections\.some\(def\s*=>\s*def\.hermesReference\s*!=\s*null\)/);
  assert.match(shellSrc, /contentContainerStyle=\{\[styles\.mainContent,\s*hasHermexSections\s*&&\s*styles\.mainContentHermex,\s*isNarrow\s*&&\s*styles\.mainContentNarrow\]\}/);
  assert.match(shellSrc, /mainContentHermex:\s*\{\s*maxWidth:\s*CATALOG_HERMEX_MAX_CONTENT_WIDTH\s*\}/);
  assert.match(sectionSrc, /<View style=\{\[styles\.card,\s*styles\.hermexCard\]\}>\{content\}<\/View>/);
  assert.match(sectionSrc, /hermexCard:\s*\{\s*padding:\s*CATALOG_SPACE\.lg\s*\}/);
});

test('DSR3-607 follow-up: render galleries group independent demonstrations into responsive 402px specimen columns instead of stretching component surfaces across the two-column wrapper', () => {
  const src = read(COMPONENT_FAMILIES_PREVIEWS_PATH);

  assert.match(
    src,
    /specimenGroup:\s*\{[^}]*flexBasis:\s*320[^}]*flexGrow:\s*1[^}]*maxWidth:\s*402[^}]*minWidth:\s*0/s,
    'each ordinary render-gallery specimen group should wrap from a comfortable 320px basis and never exceed 402px',
  );
  assert.match(
    src,
    /specimenGrid:\s*\{[^}]*gap:\s*CATALOG_SPECIMEN_GRID_GAP[^}]*justifyContent:\s*'flex-start'/s,
    'render-gallery grids should keep incomplete rows aligned to the leading edge, using the shared 40px specimen-grid gap',
  );
  assert.doesNotMatch(
    src,
    /<PreviewSpecimen\s+wide>|specimenGroupWide|wide\?:\s*boolean/,
    'every gallery specimen should participate in the same 402px column system; composed comparisons must use adjacent bounded specimens rather than an unbounded full-row escape hatch',
  );
  const gridHelper = extractFunctionBody(src, 'PreviewSpecimenGrid');
  assert.doesNotMatch(gridHelper, /useWindowDimensions|CATALOG_NARROW_BREAKPOINT/);
  assert.match(gridHelper, /style=\{preview\.specimenGrid\}/);

  for (const galleryName of [
    'AccordionListFamilyGallery',
    'AttachmentTileGallery',
    'BannerFamilyGallery',
    'CheckboxFamilyGallery',
    'ComposerToolbarFamilyGallery',
    'ListItemFamilyGallery',
    'SearchFamilyGallery',
    'SegmentedControlGallery',
    'SelectionSheetFamilyGallery',
    'ToastFamilyGallery',
    'TopNavFamilyGallery',
  ]) {
    const gallery = extractFunctionBody(src, galleryName);
    assert.match(gallery, /<PreviewSpecimenGrid>/, `${galleryName} should arrange its independent demonstrations in the shared responsive specimen grid`);
    assert.match(gallery, /<PreviewSpecimen(?:\s|>)/, `${galleryName} should bound each independent demonstration as a specimen group`);
  }

  const transcriptActivity = extractFunctionBody(src, 'TranscriptActivityPreview');
  assert.match(transcriptActivity, /<PreviewSpecimen\s/, 'the one composed Transcript Activity specimen should remain a single flow while still respecting the 402px bound');
});

test('a Props row clamps to five lines and only exposes an expand/collapse control once the real content actually exceeds that', () => {
  const src = read(PROPS_TABLE_PATH);
  assert.match(src, /CLAMPED_LINES\s*=\s*5/, 'expected the five-line clamp constant');
  assert.match(src, /onTextLayout=\{/, 'expected a real measurement pass rather than a character-count guess');
  assert.match(src, /setCanExpand\(\(e\.nativeEvent\.lines\?\.length \?\? 0\) > CLAMPED_LINES\)/, 'expected canExpand to reflect the real measured line count, not a heuristic');
  assert.match(src, /measured && canExpand && \(/, 'expected the expand control to render only once content is confirmed to overflow');
  assert.match(src, /accessibilityRole="button"/, 'expected the expand control to be a real button, keyboard and touch reachable');
  assert.match(src, /accessibilityState=\{\{\s*expanded\s*\}\}/, 'expected the control\'s accessibility state to reflect its true expanded/collapsed state');
  assert.match(src, /expanded \? 'Show less' : 'Show more'/, 'expected the visible label to match the true expanded state');
});

// ─── #607 follow-up: AccordionList (collection-level expandable ListItem groups) ────────────────

const ACCORDION_LIST_PATH = 'native/components/AccordionList/AccordionList.tsx';
const LIST_ITEM_COMPONENT_PATH = 'native/components/ListItem/ListItem.tsx';
const COMPONENTS_INDEX_PATH = 'native/components/index.ts';

test('AccordionList exists, is exported, and requires explicit appearance and separator choices', () => {
  assert.ok(existsSync(path.join(ROOT, ACCORDION_LIST_PATH)));
  const accordion = read(ACCORDION_LIST_PATH);
  const index = read(COMPONENTS_INDEX_PATH);
  assert.match(accordion, /appearance:\s*'card'\s*\|\s*'cardless'/);
  assert.match(accordion, /separatorStyle:\s*'none'\s*\|\s*'betweenRows'\s*\|\s*'topAndBottom'\s*\|\s*'all'/);
  assert.doesNotMatch(accordion, /appearance\s*=\s*['"]/);
  assert.doesNotMatch(accordion, /separatorStyle\s*=\s*['"]/);
  assert.match(index, /export \* from '\.\/AccordionList'/);
});

test('AccordionList owns one accessible header press target, header-aligned body rows, and reduced-motion behavior', () => {
  const accordion = read(ACCORDION_LIST_PATH);
  assert.match(accordion, /expanded=\{expanded\}/);
  assert.match(accordion, /AnimatedChevron/);
  assert.match(accordion, /AccessibilityInfo\.isReduceMotionEnabled/);
  assert.match(accordion, /AVATAR_SIZE\.small\s*\+\s*DS_SPACING\[600\]/);
  assert.match(accordion, /React\.cloneElement/);
  assert.doesNotMatch(accordion, /ScrollView/);
});

test('ListItem supports semantic title roles and an indicator inside its row press target', () => {
  const listItem = read(LIST_ITEM_COMPONENT_PATH);
  assert.match(listItem, /titleRole\?:\s*'body'\s*\|\s*'label'/);
  assert.match(listItem, /rowIndicator\?:\s*ReactNode/);
  assert.match(listItem, /expanded\?:\s*boolean/);
  assert.match(listItem, /accessibilityState=\{\{\s*disabled,\s*selected,\s*expanded\s*\}\}/);
  assert.match(listItem, /accessibilityElementsHidden/);
  const rowMainStart = listItem.indexOf('const mainContent');
  const pressableEnd = listItem.indexOf('</Pressable>');
  const indicator = listItem.indexOf('{rowIndicator');
  assert.ok(rowMainStart < indicator && indicator < pressableEnd, 'rowIndicator must stay inside the header Pressable');
});

// Controller correction (accordion accessibility, 2026-09-28): browser DOM inspection of the
// rendered AccordionList catalog found three coupled defects in ListItem, all of which break the
// header's approved "one button, whole header tappable, expanded/collapsed announced" contract.
test('Correction (accordion accessibility, 2026-09-28): ListItem exposes an explicit aria-expanded on its own row Pressable, since react-native-web does not translate accessibilityState.expanded into aria-expanded on its own', () => {
  const implSrc = read(LIST_ITEM_COMPONENT_PATH);
  const pressableBlock = implSrc.match(/if\s*\(isInteractive\)\s*\{[\s\S]*?<Pressable[\s\S]*?<\/Pressable>[\s\S]*?\}/);
  assert.ok(pressableBlock, 'expected a Pressable branch guarded by isInteractive');
  // Preserved from the original contract.
  assert.match(pressableBlock[0], /accessibilityState=\{\{\s*disabled,\s*selected,\s*expanded\s*\}\}/);
  // The actual fix: same escape-hatch convention as HermesReferenceDetails' own DisclosureTrigger —
  // an explicit `aria-expanded` prop is required because react-native-web's accessibility-prop
  // mapping has no case for `accessibilityState.expanded`.
  assert.match(
    pressableBlock[0],
    /aria-expanded=\{expanded\}/,
    'expected an explicit aria-expanded prop wired to the row\'s own expanded state, living on the row\'s Pressable itself',
  );
});

test('Correction (accordion accessibility, 2026-09-28): a disabled row with onPress still renders as a real, disabled button, rather than being demoted to a plain non-interactive View', () => {
  const implSrc = read(LIST_ITEM_COMPONENT_PATH);
  const pressableBlock = implSrc.match(/if\s*\(isInteractive\)\s*\{[\s\S]*?<Pressable[\s\S]*?<\/Pressable>[\s\S]*?\}/);
  assert.ok(pressableBlock, 'expected a Pressable branch guarded by isInteractive');
  assert.match(
    pressableBlock[0],
    /disabled=\{disabled\}/,
    'expected the row\'s real disabled state passed to the Pressable itself, so it cannot activate while still exposing disabled button semantics — not merely folded into accessibilityState while the row falls back to a plain View',
  );
});

test('Correction (accordion accessibility, 2026-09-28): the row-selecting Pressable owns the row\'s visible vertical padding and minimum touch-target height, not just the non-interactive outer wrapper', () => {
  const implSrc = read(LIST_ITEM_COMPONENT_PATH);
  const rowMainStyleMatch = implSrc.match(/rowMain:\s*\{([\s\S]*?)\n {2}\},/);
  assert.ok(rowMainStyleMatch, 'expected a rowMain style block');
  assert.match(
    rowMainStyleMatch[1],
    /paddingVertical:\s*DS_SPACING\[800\]/,
    'expected the Pressable itself to own the row\'s vertical padding, so its own hit rectangle matches the full visible row height',
  );
  assert.match(
    rowMainStyleMatch[1],
    /minHeight:\s*DS_A11Y_MIN_TOUCH_TARGET/,
    'expected the Pressable itself to guarantee the 44pt minimum touch-target height',
  );
});

test('Correction (accordion accessibility, 2026-09-28): the decorative row indicator (e.g. the accordion chevron) is explicitly hidden from the web accessibility tree, not just native', () => {
  const implSrc = read(LIST_ITEM_COMPONENT_PATH);
  // Preserved native hiding.
  assert.match(implSrc, /accessibilityElementsHidden/);
  assert.match(implSrc, /importantForAccessibility="no-hide-descendants"/);
  // The actual fix: `accessibilityElementsHidden`/`importantForAccessibility` are native-only —
  // react-native-web needs its own explicit `aria-hidden` so the chevron can never surface as a
  // separate accessibility element in the browser catalog.
  assert.match(
    implSrc,
    /aria-hidden/,
    'expected an explicit web aria-hidden on the decorative row-indicator wrapper',
  );
});

test('Accordion List is registered in Components — Hermex as available, not adopted', () => {
  const sections = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sections, 'Accordion List');
  assert.match(sections, /label: 'Components'[\s\S]*'Accordion List'/);
  assert.match(section, /available/i);
  assert.doesNotMatch(section, /status:\s*ADOPTED_STATUS/);
  assert.match(section, /HermesMobile\/Features\/Shared\/AccordionList\.swift/);
  assert.doesNotMatch(section, /SessionListView\.swift|SessionListComponents\.swift/);
});

test('Accordion List gallery covers both appearances, all separators, expansion modes, and hierarchy', () => {
  const previews = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previews, 'AccordionListFamilyGallery');
  for (const value of ['card', 'cardless', 'none', 'betweenRows', 'topAndBottom', 'all', 'single', 'multiple']) {
    assert.match(body, new RegExp(value, 'i'));
  }
  assert.match(body, /Loading sessions/);
  assert.match(body, /No sessions/);
  assert.match(body, /Show all sessions/);
  assert.match(body, /Header titles use label typography/);
});

// ─── #607 follow-up: card padding, chevron size, divider alignment, and motion ──────────────────

test('AccordionList composes the shared catalog Card component for its card appearance, rather than hand-reconstructed chrome', () => {
  const accordion = read(ACCORDION_LIST_PATH);
  assert.match(accordion, /import\s*\{[^}]*\bCard\b[^}]*\}\s*from\s*'\.\.\/Card'/, 'expected AccordionList to import the shared Card component');
  assert.match(accordion, /<Card[^>]*surface="outlined"/s, 'expected the card appearance to render an outlined Card');
  assert.doesNotMatch(
    accordion,
    /cardGroup:\s*\{[^}]*borderWidth/s,
    'expected card chrome (border/background/radius) to come from Card, not a hand-rolled cardGroup style',
  );
});

test('AccordionList card appearance keeps Card\'s 16pt horizontal content padding (DS_SPACING[800]) without doubling ListItem\'s own vertical padding', () => {
  const accordion = read(ACCORDION_LIST_PATH);
  assert.match(
    accordion,
    /paddingVertical:\s*0/,
    'expected the Card composition to zero out Card\'s own vertical padding, since ListItem rows already own their vertical rhythm',
  );
});

test('AccordionList cardless appearance adds no Accordion-level horizontal outer padding', () => {
  const accordion = read(ACCORDION_LIST_PATH);
  assert.doesNotMatch(
    accordion,
    /cardlessStack:\s*\{[^}]*padding/s,
    'expected the cardless stack to carry no Accordion-level horizontal outer padding',
  );
});

test('AccordionList header chevron uses the 20pt (md) icon-size step, not the 16pt (sm) default', () => {
  const accordion = read(ACCORDION_LIST_PATH);
  const chevronBlock = accordion.match(/<AnimatedChevron[\s\S]*?\/>/);
  assert.ok(chevronBlock, 'expected an AnimatedChevron element');
  assert.match(chevronBlock[0], /size=\{DS_ICON_SIZE\.md\}/, 'expected the accordion header chevron to opt into the medium icon-size step');
});

test('AccordionList body-row dividers begin at the body row\'s actual text-content alignment (avatar width + header/body gap + ListItem\'s own horizontal inset), not full width', () => {
  const accordion = read(ACCORDION_LIST_PATH);
  assert.match(
    accordion,
    /AVATAR_SIZE\.small\s*\+\s*DS_SPACING\[600\]\s*\+\s*DS_SPACING\[400\]/,
    'expected the body-row divider inset to derive from the avatar width, the header/body gap, and ListItem\'s own horizontal inset',
  );
});

test('AccordionList hides a collapsed section\'s body rows from the accessibility tree (native and web) even though they stay mounted for the collapse animation', () => {
  const accordion = read(ACCORDION_LIST_PATH);
  assert.match(accordion, /accessibilityElementsHidden=\{!expanded\}/, 'expected collapsed body content hidden from native AT');
  assert.match(accordion, /importantForAccessibility=\{expanded \? 'auto' : 'no-hide-descendants'\}/);
  assert.match(accordion, /aria-hidden=\{!expanded\}/, 'expected an explicit web aria-hidden, matching ListItem\'s own escape-hatch convention for react-native-web');
});

test('AccordionList body expansion/collapse visibly animates using existing catalog motion tokens and respects Reduce Motion', () => {
  const accordion = read(ACCORDION_LIST_PATH);
  assert.match(accordion, /Animated\.timing/, 'expected a real Animated.timing-driven expand/collapse, not an instant mount/unmount');
  assert.match(accordion, /DS_MOTION_EASING\.standard/, 'expected the shared standard easing token, not a new one');
  assert.match(accordion, /useNativeDriver:\s*false/, 'expected a JS-driven animation so it also animates in the web preview, matching Banner\'s own collapse');
  assert.match(
    accordion,
    /reduceMotion\s*\?\s*0\s*:\s*DS_MOTION_DURATION\.base/,
    'expected the body collapse duration to respect Reduce Motion the same way the chevron already does',
  );
});

// ─── AI/human selection-guidance contract (#607 human/AI readiness) ─────────────────────────────
// Every current Hermex reference (token group, material, native-iOS pattern, component, pattern)
// must declare four exact structured fields — useWhen, avoidWhen, alternatives, adoptionStatus —
// visible under the exact human labels "Use when" / "Avoid when" / "Alternatives" / "Adoption
// status", and those same facts must survive into the plain-JSON manifest for AI/tool use.

test('types.ts declares the structured Hermex decision-contract fields: HermesAdoptionState (a closed vocabulary), HermesAlternative, HermesAdoptionStatus, and their presence on HermesReferenceMeta', () => {
  const typesSrc = read(TYPES_PATH);
  assert.match(typesSrc, /export type HermesAdoptionState\s*=/, 'expected an exported HermesAdoptionState union');
  for (const state of ['foundation-available', 'production-adopted', 'partially-adopted', 'native-platform', 'reference-only']) {
    assert.ok(typesSrc.includes(`'${state}'`), `expected HermesAdoptionState to include '${state}'`);
  }
  assert.match(typesSrc, /export interface HermesAlternative\s*\{/);
  assert.match(typesSrc, /export interface HermesAlternative[^}]*name:\s*string/s);
  assert.match(typesSrc, /export interface HermesAlternative[^}]*useWhen:\s*string/s);
  assert.match(typesSrc, /export interface HermesAdoptionStatus\s*\{/);
  assert.match(typesSrc, /export interface HermesAdoptionStatus[^}]*state:\s*HermesAdoptionState/s);
  assert.match(typesSrc, /export interface HermesAdoptionStatus[^}]*detail:\s*string/s);

  const metaMatch = typesSrc.match(/export interface HermesReferenceMeta\s*\{[\s\S]*?\n\}/);
  assert.ok(metaMatch, 'expected an exported HermesReferenceMeta interface');
  const meta = metaMatch[0];
  assert.match(meta, /useWhen\?:\s*string/);
  assert.match(meta, /avoidWhen\?:\s*string/);
  assert.match(meta, /alternatives\?:\s*HermesAlternative\[\]/);
  assert.match(meta, /adoptionStatus\?:\s*HermesAdoptionStatus/);
});

test('DSR3-02: HermexSectionCanvas never renders the legacy def.whenToUse "VS" note or a file-path chip — that decision guidance and provenance live only in the Details inspector\'s useWhen/Source sections', () => {
  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  const canvasBody = extractFunctionBody(sectionBlockSrc, 'HermexSectionCanvas');
  assert.doesNotMatch(canvasBody, /WhenToUse/, 'expected no "VS" WhenToUse note on the Hermex main canvas');
  assert.doesNotMatch(canvasBody, /def\.path/, 'expected no file-path chip on the Hermex main canvas');
});

// ─── DSR3-03: the flat, one-column Details inspector content (supersedes the Round 2 three
// supporting-card row and its own per-card SupportingCard disclosure, both removed) ────────────────

test('HermesReferenceDetails renders its eight sections in the exact required flat order: Use when, Avoid when, Alternatives, Props, Accessibility, Adoption status, Source, Implementation notes — with no SupportingCard, no per-section Disclosure, and no side-by-side card row', () => {
  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  const body = extractFunctionBody(detailsSrc, 'HermesReferenceDetails');

  const order = ['Use when', 'Avoid when', 'Alternatives', 'Props', 'Accessibility', 'Adoption status', 'Source', 'Implementation notes'];
  const indices = order.map((label) => {
    const idx = body.indexOf(`label="${label}"`);
    assert.ok(idx > -1, `expected a DetailsSection labeled "${label}"`);
    return idx;
  });
  for (let i = 1; i < indices.length; i++) {
    assert.ok(indices[i] > indices[i - 1], `expected "${order[i]}" to render after "${order[i - 1]}"`);
  }

  assert.doesNotMatch(detailsSrc, /SupportingCard/, 'expected the per-entry SupportingCard component to be fully removed');
  assert.doesNotMatch(detailsSrc, /Decision & product context/, 'the three-card row heading must not remain');
  assert.doesNotMatch(detailsSrc, /Where it appears/, 'destinations render only on the main canvas\'s Screens card now, never a second time in the inspector');
  assert.doesNotMatch(body, /<Disclosure label=/, 'the entry-level Details flow must not gate any of its eight sections behind a per-section Disclosure — the inspector panel itself scrolls');
});

test('HermesReferenceDetails always renders the Alternatives section, falling back to a truthful "No direct alternative." note when an entry intentionally has an empty alternatives array, instead of hiding the section entirely', () => {
  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  assert.match(
    detailsSrc,
    /No direct alternative\./,
    'expected a truthful fallback string for entries with an empty alternatives array',
  );
  assert.doesNotMatch(
    detailsSrc,
    /\{alternatives\.length > 0 \? \(\s*<DetailsSection label="Alternatives">/,
    'expected the whole Alternatives DetailsSection to no longer be gated behind alternatives.length > 0 — it must render unconditionally, with the fallback covering the empty case',
  );
});

test('HermesReferenceDetails renders Props via the shared PropsTable when the entry declares props, and a truthful "This component takes no props." fallback otherwise — the same fallback text the retained template/framework routes already use', () => {
  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  assert.match(detailsSrc, /import\s*\{\s*PropsTable\s*\}\s*from\s*'\.\.\/PropsTable'/, 'expected HermesReferenceDetails to import the shared PropsTable');
  assert.match(detailsSrc, /props\?:\s*PropDef\[\]/, 'expected HermesReferenceDetailsProps to declare an optional props: PropDef[]');
  assert.match(detailsSrc, /<PropsTable props=\{props\}\s*\/>/, 'expected Props to render through PropsTable');
  assert.match(detailsSrc, /This component takes no props\./, 'expected the same truthful empty-props fallback as the retained routes');
});

test('HermesReferenceDetails\'s Source section renders only implementationNotes.sourcePaths, kept separate from the Implementation notes section (status + notes), matching the flat content order\'s two distinct sections', () => {
  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  const sourceBody = extractFunctionBody(detailsSrc, 'SourceContent');
  assert.match(sourceBody, /sourcePaths/);
  assert.doesNotMatch(sourceBody, /\.status\b/, 'Source must not also render implementationNotes.status — that belongs to the separate Implementation notes section');

  const implementationOnlyBody = extractFunctionBody(detailsSrc, 'ImplementationNotesOnlyContent');
  assert.doesNotMatch(implementationOnlyBody, /sourcePaths/, 'Implementation notes must not repeat sourcePaths — Source already rendered them');
  assert.match(implementationOnlyBody, /\.status\b/);
  assert.match(implementationOnlyBody, /\.notes\b/);
});

test('HermesReferenceDetails accepts an accessibilityContent prop (the entry\'s accessibility guidance) and renders it inside the Accessibility section, falling back to the same truthful "No accessibility notes documented." text used elsewhere in the catalog', () => {
  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  assert.match(
    detailsSrc,
    /accessibilityContent\??:\s*React\.ReactNode/,
    'expected HermesReferenceDetailsProps to declare an accessibilityContent: React.ReactNode prop',
  );
  assert.match(detailsSrc, /No accessibility notes documented\./);
  const accessibilityHeadingIdx = detailsSrc.indexOf('label="Accessibility"');
  const propUsageIdx = detailsSrc.indexOf('accessibilityContent', accessibilityHeadingIdx);
  assert.ok(propUsageIdx > -1, 'expected accessibilityContent to be rendered inside the Accessibility DetailsSection');
});

test('HermesReferenceDetails renders meta.useSummary as supporting text under Use when, never as its own duplicate section (Screens destinations already own the main canvas)', () => {
  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  const body = extractFunctionBody(detailsSrc, 'HermesReferenceDetails');
  const useWhenIdx = body.indexOf('label="Use when"');
  const useSummaryIdx = body.indexOf('meta.useSummary');
  const avoidWhenIdx = body.indexOf('label="Avoid when"');
  assert.ok(useWhenIdx > -1 && useSummaryIdx > -1 && avoidWhenIdx > -1, 'expected Use when, useSummary, and Avoid when all present');
  assert.ok(useWhenIdx < useSummaryIdx && useSummaryIdx < avoidWhenIdx, 'expected useSummary to render inside the Use when section, before Avoid when');
});

test('the catalog overview keeps its implementation-only evidence compact instead of inheriting empty Decision and Accessibility cards from section reference details', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const overviewBody = extractFunctionBody(sectionsSrc, 'HermesOverview');
  assert.doesNotMatch(
    overviewBody,
    /<HermesReferenceDetails/,
    'the overview is not a SectionDef reference entry and must not render the three-card section contract around implementation-only evidence',
  );
  assert.match(
    overviewBody,
    /<HermesOverviewImplementationDetails/,
    'expected overview-only evidence to use the compact implementation-details presentation',
  );

  const detailsSrc = read(HERMES_REFERENCE_DETAILS_PATH);
  assert.match(detailsSrc, /export function HermesOverviewImplementationDetails/);
  const compactBody = extractFunctionBody(detailsSrc, 'HermesOverviewImplementationDetails');
  assert.match(compactBody, /<Disclosure label="Implementation notes"/);
  assert.doesNotMatch(compactBody, /Decision & product context|Accessibility/);
});

test('manifest.ts supports an includeTokenGalleries option (default off, preserving the template catalog\'s existing component-only manifest) and carries the structured hermesReference decision fields through to plain JSON', () => {
  const manifestSrc = read('native/catalog/manifest.ts');
  assert.match(manifestSrc, /includeTokenGalleries/, 'expected an includeTokenGalleries option on buildComponentManifest');
  assert.match(manifestSrc, /tokenGallery\?:\s*boolean/, 'expected ComponentManifestEntry to expose its own tokenGallery flag');
  assert.match(manifestSrc, /hermesReference\?:/, 'expected ComponentManifestEntry to expose a hermesReference field');
  assert.match(manifestSrc, /useWhen\?:\s*string/);
  assert.match(manifestSrc, /avoidWhen\?:\s*string/);
  assert.match(manifestSrc, /alternatives:\s*HermesAlternative\[\]/);
  assert.match(manifestSrc, /adoptionStatus\?:\s*HermesAdoptionStatus/);
});

test('Issue #607: manifest.ts declares and serializes structured composition-slot/constraint metadata and implementationNotes (including native sourcePaths), so a tool can distinguish the browser reconstruction from production Swift source', () => {
  const manifestSrc = read('native/catalog/manifest.ts');
  assert.match(manifestSrc, /compositionSlots\?:\s*HermesCompositionSlot\[\]/, 'expected ManifestHermesReference to expose compositionSlots');
  assert.match(manifestSrc, /compositionConstraints\?:\s*HermesCompositionConstraint\[\]/, 'expected ManifestHermesReference to expose compositionConstraints');
  assert.match(manifestSrc, /implementationNotes\?:\s*HermesImplementationNotes/, 'expected ManifestHermesReference to expose implementationNotes');
  assert.match(manifestSrc, /compositionSlots:\s*meta\.compositionSlots/, 'expected buildHermesManifestReference to serialize compositionSlots');
  assert.match(manifestSrc, /compositionConstraints:\s*meta\.compositionConstraints/, 'expected buildHermesManifestReference to serialize compositionConstraints');
  assert.match(manifestSrc, /implementationNotes:\s*meta\.implementationNotes/, 'expected buildHermesManifestReference to serialize implementationNotes (including native sourcePaths)');

  const typesSrc = read('native/catalog/types.ts');
  assert.match(typesSrc, /export interface HermesCompositionSlot/, 'expected a structured HermesCompositionSlot type, not a prose-only blob');
  assert.match(typesSrc, /export interface HermesCompositionConstraint/, 'expected a structured HermesCompositionConstraint type, not a prose-only blob');
  assert.match(typesSrc, /compositionSlots\?:\s*HermesCompositionSlot\[\]/, 'expected HermesReferenceMeta to expose compositionSlots');
  assert.match(typesSrc, /compositionConstraints\?:\s*HermesCompositionConstraint\[\]/, 'expected HermesReferenceMeta to expose compositionConstraints');
});

test('Issue #607: Banner and Composer Toolbar declare truthful structured composition metadata reaching the manifest', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);

  const bannerSection = extractHermesSection(sectionsSrc, 'Hermes Banner');
  const bannerRef = extractHermesReferenceBlock(bannerSection);
  assert.match(bannerRef, /compositionSlots:\s*\[/, 'expected Banner to declare compositionSlots');
  assert.match(bannerRef, /name:\s*'title'/, 'expected Banner\'s compositionSlots to name the title region');
  assert.match(bannerRef, /name:\s*'description'/, 'expected Banner\'s compositionSlots to name the description region');
  assert.match(bannerRef, /name:\s*'icon'/, 'expected Banner\'s compositionSlots to name the icon region');
  assert.match(bannerRef, /name:\s*'action'/, 'expected Banner\'s compositionSlots to name the action region');
  assert.match(bannerRef, /compositionConstraints:\s*\[/, 'expected Banner to declare compositionConstraints');
  assert.match(bannerRef, /kind:\s*'at-least-one-of'/, 'expected Banner\'s constraint kind to be at-least-one-of');
  assert.match(bannerRef, /slots:\s*\['title',\s*'description'\]/, 'expected Banner\'s constraint to govern the title/description slots');

  const composerToolbarSection = extractHermesSection(sectionsSrc, 'Composer Toolbar');
  const composerToolbarRef = extractHermesReferenceBlock(composerToolbarSection);
  assert.match(composerToolbarRef, /compositionSlots:\s*\[/, 'expected Composer Toolbar to declare compositionSlots');
  assert.match(composerToolbarRef, /name:\s*'content'/, 'expected Composer Toolbar\'s compositionSlots to name the content slot');
  assert.match(composerToolbarRef, /cardinality:\s*'zero-or-more'/, 'expected Composer Toolbar\'s content slot to be zero-or-more, not a single value');
  assert.match(composerToolbarRef, /acceptedContent:\s*\['generic-view',\s*'control',\s*'display-only-tag',\s*'future-component'\]/, 'expected Composer Toolbar\'s accepted content categories to be named');
  assert.match(composerToolbarRef, /ownership:/, 'expected Composer Toolbar\'s content slot to document layout vs. child ownership');
});

test('the Hermex catalog builds and exposes its own manifest (including Foundations token galleries, unlike the filtered-out default) directly inside the catalog, discoverable without leaving the default route', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /import\s*\{\s*buildHermesManifestEnvelope\s*\}\s*from\s*'\.\.\/manifest'/, 'expected hermesSections.tsx to import buildHermesManifestEnvelope');
  assert.match(sectionsSrc, /buildHermesManifestEnvelope\(\s*hermesSections,\s*hermesNav\s*\)/, 'expected the Hermex manifest to be built via the versioned envelope, which always includes token galleries');
  assert.match(sectionsSrc, /export function HermesManifest/, 'expected an exported HermesManifest component rendering the built manifest');

  const catalogSrc = hermesCatalogSource();
  assert.match(catalogSrc, /HermesManifest/, 'expected the manifest surface to actually be wired into the rendered Hermex catalog (e.g. inside the Overview), not just defined and unused');
});

test('Issue #607 Slice A: manifest.ts exposes a versioned HermesManifestEnvelope (schemaVersion + runtime + entries) stating the one SwiftUI-production/React-Native-reconstruction runtime fact once, machine-readably, instead of leaving it to per-entry prose', () => {
  const manifestSrc = read('native/catalog/manifest.ts');
  assert.match(manifestSrc, /export interface HermesManifestRuntime\s*\{/, 'expected a structured HermesManifestRuntime type');
  assert.match(manifestSrc, /productionRuntime:\s*'swiftui'/);
  assert.match(manifestSrc, /catalogRuntime:\s*'react-native-documentation-reconstruction'/);
  assert.match(manifestSrc, /export const HERMES_MANIFEST_RUNTIME:\s*HermesManifestRuntime/, 'expected one shared runtime-truth constant, not one per entry');
  assert.match(manifestSrc, /export interface HermesManifestEnvelope\s*\{/);
  assert.match(manifestSrc, /schemaVersion:\s*1/);
  assert.match(manifestSrc, /runtime:\s*HermesManifestRuntime/);
  assert.match(manifestSrc, /entries:\s*ComponentManifestEntry\[\]/);
  assert.match(
    manifestSrc,
    /export function buildHermesManifestEnvelope[\s\S]*?entries:\s*buildComponentManifest\(sections,\s*groups,\s*\{\s*includeTokenGalleries:\s*true\s*\}\)/,
    'expected buildHermesManifestEnvelope to wrap buildComponentManifest with includeTokenGalleries always on, not a second parallel manifest builder',
  );

  // The retained template/framework routes must keep calling buildComponentManifest directly —
  // the envelope is additive, not a breaking replacement of the shared builder's own signature.
  const catalogExampleSrc = read(CATALOG_EXAMPLE_PATH);
  assert.match(catalogExampleSrc, /buildComponentManifest\(sections,\s*nav\)/, 'expected the template route\'s own manifest page to keep calling buildComponentManifest unchanged');
});

test('Issue #607 Slice A: manifest.ts carries displayName through to ComponentManifestEntry, falling back to id for an entry with no override, the same default SectionDef.displayName itself documents', () => {
  const manifestSrc = read('native/catalog/manifest.ts');
  assert.match(manifestSrc, /displayName:\s*string;/, 'expected ComponentManifestEntry to declare a required displayName');
  assert.match(manifestSrc, /displayName:\s*def\.displayName\s*\?\?\s*def\.id/, 'expected buildComponentManifest to fall back to id when displayName is unset');
});

// adoptionStatus is declared either inline ({ state: '...', detail: '...' }) or via one of the two
// shared shorthand constants (FOUNDATION_AVAILABLE_ADOPTION / PRODUCTION_ADOPTED_ADOPTION) that
// hermesSections.tsx defines for its two most common cases — both are read here.
const ADOPTION_SHORTHAND_STATE = {
  FOUNDATION_AVAILABLE_ADOPTION: 'foundation-available',
  PRODUCTION_ADOPTED_ADOPTION: 'production-adopted',
};
function extractAdoptionState(block) {
  const inlineMatch = block.match(/adoptionStatus:\s*\{\s*state:\s*'([^']+)',\s*detail:\s*'[^']+'/);
  if (inlineMatch) return inlineMatch[1];
  const shorthandMatch = block.match(/adoptionStatus:\s*(FOUNDATION_AVAILABLE_ADOPTION|PRODUCTION_ADOPTED_ADOPTION)/);
  if (shorthandMatch) return ADOPTION_SHORTHAND_STATE[shorthandMatch[1]];
  return undefined;
}

test('every current Hermex reference entry (Foundations token groups, Materials, Native iOS patterns, Components, and Patterns) declares useWhen, avoidWhen, a structured alternatives array, and an adoptionStatus with a closed-vocabulary state plus truthful detail', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = [...src.matchAll(/^ {4}id: '([^']+)',/gm)].map((m) => m[1]);
  assert.ok(ids.length >= 30, `expected the full set of Hermex section ids, found ${ids.length}`);

  const ALLOWED_STATES = ['foundation-available', 'production-adopted', 'partially-adopted', 'native-platform', 'reference-only'];

  for (const id of ids) {
    const block = extractHermesSection(src, id);
    assert.match(block, /hermesReference:\s*\{/, `expected "${id}" to declare hermesReference`);
    assert.match(block, /useWhen:\s*'[^']+'/, `expected "${id}" to declare a non-empty hermesReference.useWhen`);
    assert.match(block, /avoidWhen:\s*'[^']+'/, `expected "${id}" to declare a non-empty hermesReference.avoidWhen`);
    assert.match(block, /alternatives:\s*\[/, `expected "${id}" to declare a structured hermesReference.alternatives array`);
    const state = extractAdoptionState(block);
    assert.ok(state, `expected "${id}" to declare adoptionStatus with a state and a non-empty detail`);
    assert.ok(
      ALLOWED_STATES.includes(state),
      `expected "${id}"'s adoptionStatus.state ("${state}") to be one of ${ALLOWED_STATES.join(', ')}`,
    );
  }
});

test('every declared alternatives entry is structured as { name, useWhen } rather than a single prose blob', () => {
  const src = read(HERMES_SECTIONS_PATH);
  // Non-greedy up to the *first* closing bracket — safe because no alternatives entry itself
  // contains a nested array, unlike the broader SectionDef object these are found inside.
  const alternativesBlocks = [...src.matchAll(/alternatives:\s*\[([\s\S]*?)\]/g)].map((m) => m[1]);
  assert.ok(alternativesBlocks.length > 0, 'expected at least one alternatives array in hermesSections.tsx');
  const nonEmptyBlocks = alternativesBlocks.filter((block) => block.trim().length > 0);
  assert.ok(nonEmptyBlocks.length > 0, 'expected at least one non-empty alternatives array (a real alternative exists for some entry)');
  for (const block of nonEmptyBlocks) {
    const entryCount = [...block.matchAll(/\{\s*name:/g)].length;
    assert.ok(entryCount > 0, `expected each non-empty alternatives array to contain at least one { name: ... } entry, got: ${block.slice(0, 120)}`);
    assert.match(block, /name:\s*'[^']+'/, 'expected each alternative entry to declare a name');
    assert.match(block, /useWhen:\s*'[^']+'/, 'expected each alternative entry to declare its own useWhen condition');
  }
});

test('the known Hermes Avatar and Pending Request decision-guidance gaps are closed with real useWhen/avoidWhen content, not merely present-but-empty fields', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const avatar = extractHermesSection(src, 'Hermes Avatar');
  assert.match(avatar, /useWhen:\s*'[^']{20,}'/);
  assert.match(avatar, /avoidWhen:\s*'[^']{20,}'/);
  assert.equal(extractAdoptionState(avatar), 'partially-adopted', 'expected Hermes Avatar to truthfully report a mixed adopted/foundation-only status, not a single blanket claim');

  const pendingRequest = extractHermesSection(src, 'Pending Request');
  assert.match(pendingRequest, /useWhen:\s*'[^']{20,}'/);
  assert.match(pendingRequest, /avoidWhen:\s*'[^']{20,}'/);
  assert.equal(extractAdoptionState(pendingRequest), 'production-adopted', 'expected Pending Request to keep its genuine, already-adopted production status');
});

test('adoptionStatus wording preserves the truthful availability-vs-adoption boundary — a foundation-only entry\'s adoptionStatus must never claim production adoption', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = [...src.matchAll(/^ {4}id: '([^']+)',/gm)].map((m) => m[1]);
  for (const id of ids) {
    const block = extractHermesSection(src, id);
    if (/status:\s*FOUNDATION_ONLY_STATUS/.test(block)) {
      const state = extractAdoptionState(block);
      assert.ok(state, `expected "${id}" to declare adoptionStatus`);
      assert.notEqual(state, 'production-adopted', `"${id}" is foundation-only (no production call site) and must not declare adoptionStatus.state 'production-adopted'`);
    }
  }
});

test('AGENTS.md points agents to the canonical Design System guidance: the shared Swift foundation/component sources, the Hermex catalog, and its machine-readable manifest, and states catalog metadata changes travel with the shared API change', () => {
  const agentsSrc = read('../AGENTS.md');
  assert.match(agentsSrc, /## Design System/);
  assert.match(agentsSrc, /HermesMobile\/Config\//);
  assert.match(agentsSrc, /HermesMobile\/Features\/Shared\//);
  assert.match(agentsSrc, /design-system-catalog\//);
  assert.match(agentsSrc, /manifest/i);
  assert.match(agentsSrc, /same PR/i);
});

test('README.md no longer claims the default Hermex route uses the stale template-heavy main navigation, obsolete section names/counts, or a Manifest page that isn\'t actually on that route', () => {
  const readme = read('README.md');
  assert.doesNotMatch(readme, /Components — Hermex/, 'the two-top-level-prefix ("Components —" / "Tokens —") navigation is retired; README must not still describe it as the default route\'s nav');
  assert.doesNotMatch(readme, /Tokens — Hermex/);

  const hermesSectionIdx = readme.indexOf('## Hermex Design System catalog');
  assert.ok(hermesSectionIdx > -1, 'expected a "Hermex Design System catalog" section in README.md');
  const nextSectionIdx = readme.indexOf('\n## ', hermesSectionIdx + 1);
  const hermesSection = readme.slice(hermesSectionIdx, nextSectionIdx === -1 ? readme.length : nextSectionIdx);
  assert.doesNotMatch(
    hermesSection,
    /"Manifest" page/i,
    'the default Hermex route has no sidebar Manifest page; README\'s own Hermex section must not claim one (the template\'s separate ?catalog=template Manifest page is a different, still-accurate claim outside this section)',
  );
});

test('WHEN_TO_USE.md is a truthful Hermex decision guide: it explains the decision model and points to the structured source of truth rather than re-describing generic template-only components Hermex does not own', () => {
  const whenToUse = read('WHEN_TO_USE.md');
  assert.match(whenToUse, /Hermex/);
  assert.match(whenToUse, /hermesSections\.tsx|hermesReference/, 'expected WHEN_TO_USE.md to point at the structured Hermex source of truth');
  for (const templateOnly of ['SearchField', 'FieldContainer', 'PillRow', 'UnderlineTabs']) {
    assert.doesNotMatch(whenToUse, new RegExp(templateOnly), `WHEN_TO_USE.md must not still describe the generic template-only component "${templateOnly}", which Hermex does not own`);
  }
});

// ─── Semantic-guidance correction (Claude Fable review edd81c9d, 0 Critical / 10 Important /
// 14 Minor) ───────────────────────────────────────────────────────────────────────────────────
// Every test below pins one or more of that review's findings so the corrected useWhen/avoidWhen/
// alternatives content can never silently regress back to the reviewed defects.

// Generic brace-depth extractor for a nested object literal reachable only by a start pattern
// (e.g. `hermesReference: {`), unlike extractFunctionBody (which expects a `function name(...) {`
// header) or extractHermesSection (which is already scoped to one whole SectionDef).
function extractBraceBlock(src, startPattern) {
  const match = src.match(startPattern);
  assert.ok(match, `expected to find a block starting with ${startPattern}`);
  const start = match.index + match[0].length - 1;
  let depth = 0;
  for (let i = start; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth -= 1;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error('unterminated block');
}

const extractHermesReferenceBlock = (sectionSrc) => extractBraceBlock(sectionSrc, /hermesReference:\s*\{/);

// Bracket-depth counterpart to extractBraceBlock, for a `key: [...]` array value that may itself
// contain nested arrays/objects (e.g. compositionSlots' own acceptedContent: [...] per slot) — a
// non-greedy regex up to the first `]` would stop at the first nested array's own close instead of
// the field's own. Returns the array's own inner contents (excluding the outer [ and ]).
function extractBracketBlock(src, startPattern) {
  const match = src.match(startPattern);
  assert.ok(match, `expected to find a block starting with ${startPattern}`);
  const start = match.index + match[0].length - 1;
  assert.equal(src[start], '[', `expected ${startPattern} to be immediately followed by [`);
  let depth = 0;
  for (let i = start; i < src.length; i++) {
    const c = src[i];
    if (c === "'" || c === '"' || c === '`') {
      const quote = c;
      i += 1;
      while (i < src.length && src[i] !== quote) {
        if (src[i] === '\\') i += 1;
        i += 1;
      }
      continue;
    }
    if (c === '[') depth++;
    else if (c === ']') {
      depth -= 1;
      if (depth === 0) return src.slice(start + 1, i);
    }
  }
  throw new Error('unterminated bracket block');
}

const extractAlternativeNames = (referenceBlockSrc) => {
  const match = referenceBlockSrc.match(/alternatives:\s*\[([\s\S]*?)\]/);
  assert.ok(match, 'expected an alternatives array');
  return [...match[1].matchAll(/name:\s*'([^']+)'/g)].map((m) => m[1]);
};

test('Hermex Colors routes semantic roles to their bound Apple Color, restricts non-500 ramp steps to contrast-validated pairings, and classifies semantic roles as documentation-only bindings rather than a fabricated Hermex Swift API', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermex Colors');
  const ref = extractHermesReferenceBlock(section);

  assert.match(ref, /Color\(\.label\)|Color\(\.secondarySystemBackground\)/, 'expected useWhen to route to a real bound Apple Color, not an invented semantic-color type');
  assert.match(ref, /500 step/, 'expected useWhen to name the 500 step for a brand/accent tint');
  assert.match(ref, /non-500/, 'expected avoidWhen to state the non-500 ramp-step restriction');
  assert.match(ref, /contrast validation|contrast-validated/i, 'expected avoidWhen to require contrast validation before consuming a non-500 step');
  assert.match(ref, /no Hermex semantic-color type exists|not a Swift API/, 'expected avoidWhen to disclaim a fabricated Hermex semantic-color Swift API');
  assert.doesNotMatch(ref, /semantic roles.{0,80}foundation-only/is, 'must not classify the semantic roles as an unshipped foundation-only Swift API — they are documentation-only platform-color bindings');
  assert.match(ref, /documentation-only/, 'expected the adoption detail to classify semantic roles as documentation-only bindings');
});

test('Adaptive Glass, Hermes Card, and Pending Request agree on one opaque approval/clarification surface: Pending Request\'s adopted pendingRequestCardSurface, never HermexCard\'s uncalled requestCardSurface', () => {
  const src = read(HERMES_SECTIONS_PATH);

  const glass = extractHermesSection(src, 'Adaptive Glass');
  const glassRef = extractHermesReferenceBlock(glass);
  assert.ok(extractAlternativeNames(glassRef).includes('Pending Request'), 'expected Adaptive Glass to point an unconditionally-opaque approval surface at Pending Request, not at Hermes Card');
  assert.match(glassRef, /pendingRequestCardSurface|unconditionally opaque/, 'expected the Pending Request alternative to explain why (its adopted opaque surface)');

  const card = extractHermesSection(src, 'Hermes Card');
  const cardRef = extractHermesReferenceBlock(card);
  assert.doesNotMatch(cardRef, /Request Card for an approval/i, 'Hermes Card\'s own requestCardSurface has zero call sites — useWhen must not steer readers to it for approval/clarification work');
  assert.doesNotMatch(card, /Request Card for an approval/i, 'the top-level whenToUse prose duplicates useWhen and must be corrected the same way');
  assert.ok(extractAlternativeNames(cardRef).includes('Pending Request'), 'expected Hermes Card to point approval/clarification work at Pending Request');
  assert.match(cardRef, /Pending Request/, 'expected useWhen to route approval/clarification surfaces to the Pending Request pattern');
});

test('Hermes Banner and Hermes Toast never claim Toast self-dismisses; Toast\'s guidance and WHEN_TO_USE.md both state caller-owned dismissal', () => {
  const src = read(HERMES_SECTIONS_PATH);

  const banner = extractHermesSection(src, 'Hermes Banner');
  assert.doesNotMatch(banner, /self-dismiss/i, 'HermexToast has no internal timer or auto-dismiss (HermexToast.swift); Banner must not describe it as self-dismissing');

  const toast = extractHermesSection(src, 'Hermes Toast');
  const toastRef = extractHermesReferenceBlock(toast);
  assert.doesNotMatch(toast, /self-dismiss/i);
  assert.match(toastRef, /caller owns|no auto-dismiss|clear it yourself/i, 'expected Toast\'s useWhen to state caller-owned dismissal');

  const whenToUse = read('WHEN_TO_USE.md');
  assert.doesNotMatch(whenToUse, /self-dismiss/i, 'WHEN_TO_USE.md must not claim Toast self-dismisses');
  assert.match(whenToUse, /caller dismisses/i, 'expected WHEN_TO_USE.md to state the caller owns Toast dismissal');
  // The exclusive-selection distinction (Checkbox vs Radio vs Segmented Control) must survive the edit.
  assert.match(whenToUse, /Segmented Control is also exclusive selection/);
});

test('ToastFamilyGallery adds a compact interactive motion specimen that toggles the generic catalog Toast\'s visible prop, replaying the top-edge slide + opacity transition, alongside the existing static semantic variants and trailing-action specimens', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /function ToastMotionDemo/);
  const demoBody = extractFunctionBody(previewsSrc, 'ToastMotionDemo');
  assert.match(demoBody, /useState/, 'expected the demo to own real toggle state, not a static prop');
  assert.match(demoBody, /onPress=\{\(\) => setVisible/, 'expected a real control that flips the toggle state');
  assert.match(demoBody, /visible=\{visible\}/, 'expected the demo to drive the generic Toast\'s own visible prop from that state');
  assert.match(demoBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Green\[800\]/, 'expected the motion demo to use the same approved dark success surface as the static HermexToast specimen');
  assert.doesNotMatch(demoBody, /variant="success"/, 'the motion demo must not fall back to the generic Toast\'s retired light success treatment');

  const galleryBody = extractFunctionBody(previewsSrc, 'ToastFamilyGallery');
  assert.match(galleryBody, /<ToastMotionDemo/, 'expected the motion demo wired into the existing Toast family gallery');
  // Correction (DSR2-08): the four static specimens survive, but as the approved dark semantic
  // surfaces (Blue.s700/Green.s800/Orange.s800/Red.s700), not the generic Toast's own light-tinted
  // `variant` styles — see the dedicated DSR2-08 test above for the background-override assertions.
  assert.match(galleryBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Blue\[700\]/);
  assert.match(galleryBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Green\[800\]/);
  assert.match(galleryBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Orange\[800\]/);
  assert.match(galleryBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Red\[700\]/);
  assert.match(galleryBody, /action=\{\{ label: 'Undo'/);
});

test('Radio, Selection Sheet, and Segmented Control name each other as reciprocal alternatives, closing the exclusive-selection disambiguation gap WHEN_TO_USE.md already describes; retired Hermes Dropdown is named nowhere', () => {
  const src = read(HERMES_SECTIONS_PATH);

  const radio = extractAlternativeNames(extractHermesReferenceBlock(extractHermesSection(src, 'Hermes Radio')));
  assert.ok(radio.includes('Segmented Control'), 'expected Radio to name Segmented Control');
  assert.ok(radio.includes('Hermes Selection Sheet'), 'expected Radio to name Hermes Selection Sheet');
  assert.ok(!radio.includes('Hermes Dropdown'), 'expected Radio to no longer name retired Hermes Dropdown');

  const selectionSheet = extractAlternativeNames(extractHermesReferenceBlock(extractHermesSection(src, 'Hermes Selection Sheet')));
  assert.ok(selectionSheet.includes('Hermes Radio'), 'expected Selection Sheet to name Hermes Radio');
  assert.ok(selectionSheet.includes('Segmented Control'), 'expected Selection Sheet to name Segmented Control');

  const segmented = extractAlternativeNames(extractHermesReferenceBlock(extractHermesSection(src, 'Segmented Control')));
  assert.ok(segmented.includes('Hermes Radio'), 'expected Segmented Control to name Hermes Radio');
  assert.ok(segmented.includes('Hermes Selection Sheet'), 'expected Segmented Control to name Hermes Selection Sheet');
  assert.ok(!segmented.includes('Hermes Dropdown'), 'expected Segmented Control to no longer name retired Hermes Dropdown');
});

test('Text Input no longer names retired Hermes Dropdown and instead points to Selection Sheet or native Picker for a fixed-option single-selection field', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Text Input');
  assert.doesNotMatch(section, /Hermes Dropdown/, 'expected Text Input to no longer reference retired Hermes Dropdown anywhere');

  const ref = extractHermesReferenceBlock(section);
  const alts = extractAlternativeNames(ref);
  assert.ok(
    alts.includes('Hermes Selection Sheet') || alts.some((name) => /native Picker/i.test(name)),
    'expected Text Input alternatives to point to Selection Sheet or native Picker for a fixed-option single-selection field',
  );
});

test('List/ListItem, Row Divider, and Skeleton Loading state real selection boundaries instead of adoption disclaimers, and name their real neighbors (Card, Accordion List, native containers, Content Unavailable\'s spinner)', () => {
  const src = read(HERMES_SECTIONS_PATH);

  const listItem = extractHermesSection(src, 'List / ListItem');
  const listItemRef = extractHermesReferenceBlock(listItem);
  assert.doesNotMatch(listItemRef, /avoidWhen:\s*'Avoid claiming it replaces/, 'avoidWhen must no longer be a pure adoption disclaimer');
  assert.match(listItemRef, /Card|Accordion List/, 'expected avoidWhen to state the real Card/Accordion List selection boundary');
  const listItemAlts = extractAlternativeNames(listItemRef);
  assert.ok(listItemAlts.includes('Hermes Card'), 'expected List/ListItem to name Hermes Card as an alternative');
  assert.ok(listItemAlts.includes('Accordion List'), 'expected List/ListItem to name Accordion List as an alternative');

  const divider = extractHermesSection(src, 'Row Divider');
  const dividerRef = extractHermesReferenceBlock(divider);
  assert.match(dividerRef, /HermexList|Accordion List/, 'expected avoidWhen to prohibit use inside a container that already owns separators');
  assert.ok(extractAlternativeNames(dividerRef).includes('List / ListItem'), 'expected Row Divider to name List / ListItem as an alternative');

  const skeleton = extractHermesSection(src, 'Skeleton Loading');
  const skeletonRef = extractHermesReferenceBlock(skeleton);
  assert.doesNotMatch(skeletonRef, /Catalog Shimmer/, 'Catalog Shimmer is not a choosable Hermex entry and must no longer be the sole alternative');
  assert.match(skeletonRef, /ProgressView|spinner|indeterminate/i, 'expected Skeleton Loading to route an indeterminate fetch to a spinner alternative');
});

test('Content Unavailable documents its real Swift .loading variant end-to-end: the variant prop type, a rendered Loading specimen, and a useWhen/avoidWhen that includes it and states the partial/transient-failure boundary', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Content Unavailable');
  const ref = extractHermesReferenceBlock(section);

  assert.match(section, /type:\s*"'loading' \|/, 'expected the variant prop type union to lead with \'loading\'');
  assert.match(section, /key: 'loading'/, 'expected a rendered Loading variant specimen in the variants gallery');
  assert.match(ref, /loading/i, 'expected useWhen to mention the loading state');
  assert.match(ref, /Toast or Banner/, 'expected avoidWhen to route a transient failure while content remains visible to Toast/Banner, not this pattern');

  assert.match(src, /'loading'\s*\|\s*'empty'\s*\|\s*'noResults'/, 'expected CONTENT_UNAVAILABLE_COPY (or its type) to include a loading key');
  assert.match(src, /variant === 'loading'/, 'expected the ContentUnavailablePreview reconstruction to render a distinct loading (spinner-only) branch');
});

test('Buttons states a real component-owned-chrome avoidWhen (not adoption-only), names its production alternative, no longer names the retired Inline Reference Link, and its whenToUse sentence about Yes/No/Approve/Deny no longer contradicts itself', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Buttons');
  const ref = extractHermesReferenceBlock(section);

  assert.doesNotMatch(ref, /Inline Reference Link/, 'Inline Reference Link is fully retired and must no longer be named in Buttons\' avoidWhen or alternatives');
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.some((n) => /ChatTactileButtonStyle|ChatDecisionButtonStyle/.test(n)), 'expected Buttons to name its real production analog as an alternative');
  assert.ok(!alts.includes('Inline Reference Link'), 'expected the retired Inline Reference Link to no longer be a structured alternative');

  assert.doesNotMatch(
    section,
    /only needs Reduce-Motion-safe press feedback, including for a Yes\/No\/Approve\/Deny-style choice, which uses \.hermex\(_:emphasis:\) directly/,
    'the whenToUse sentence must no longer contradict itself about which style a Yes/No/Approve/Deny choice uses',
  );
  assert.match(section, /Yes\/No\/Approve\/Deny choice uses \.hermex\(_:emphasis:\)/, 'expected a standalone, non-contradictory sentence stating which style a decision choice uses');
});

test('Checkbox names native Toggle (never the nonexistent "Switch"), and its alternatives cover every control avoidWhen names', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Hermes Checkbox');
  const ref = extractHermesReferenceBlock(section);

  assert.doesNotMatch(section, /use Switch/, 'Switch is not a Hermex entry or a SwiftUI control');
  assert.match(section, /native Toggle/, 'expected Checkbox to name the real SwiftUI control, Toggle');

  const alts = extractAlternativeNames(ref);
  for (const expected of ['Native Toggle', 'List / ListItem', 'Segmented Control', 'Hermes Radio', 'Tag']) {
    assert.ok(alts.includes(expected), `expected Checkbox alternatives to include "${expected}"`);
  }
});

test('Transcript Log Row, Search, and Attachment name the design-time neighbors their own avoidWhen/description already implies', () => {
  const src = read(HERMES_SECTIONS_PATH);

  const disclosure = extractAlternativeNames(extractHermesReferenceBlock(extractHermesSection(src, 'Transcript Log Row')));
  assert.ok(disclosure.includes('Accordion List'), 'expected Transcript Log Row to name Accordion List (Accordion List already names Disclosure Row)');

  const search = extractAlternativeNames(extractHermesReferenceBlock(extractHermesSection(src, 'Search')));
  assert.ok(search.includes('Text Input'), 'expected Search to name Text Input for an inline filter field');

  const attachment = extractAlternativeNames(extractHermesReferenceBlock(extractHermesSection(src, 'Attachment')));
  assert.ok(!attachment.includes('Inline Reference Link'), 'the retired Inline Reference Link must no longer be named by Attachment');
});

test('Pending Request, Transcript Activity, Composer, and Hermex Font state real boundaries/conditions instead of an adoption note, a cross-reference, or a circular restatement', () => {
  const src = read(HERMES_SECTIONS_PATH);

  const pendingRequest = extractHermesReferenceBlock(extractHermesSection(src, 'Pending Request'));
  assert.doesNotMatch(pendingRequest, /avoidWhen:\s*'Avoid reaching for the new, unadopted Buttons family/, 'avoidWhen must state a boundary on the surfaces themselves, not a Buttons-adoption note');
  assert.match(pendingRequest, /needs no user response/i, 'expected avoidWhen to state the real boundary: content needing no user response belongs on a general card');

  const transcript = extractHermesSection(src, 'Transcript Activity');
  const transcriptRef = extractHermesReferenceBlock(transcript);
  assert.doesNotMatch(transcriptRef, /useWhen:\s*'Use it to understand how a transcript turn\\'s collapsible pieces relate to one another\.'/, 'useWhen must become an actionable rule, not "understand how ... relate"');
  assert.match(transcriptRef, /TranscriptLogRowView/, 'expected useWhen to point implementers at TranscriptLogRowView for any individual row');
  assert.match(transcriptRef, /one collapsible row/i, 'expected the Transcript Log Row alternative to state a real condition, not a bare cross-reference');

  const composer = extractAlternativeNames(extractHermesReferenceBlock(extractHermesSection(src, 'Composer')));
  assert.ok(composer.includes('Text Input'), 'expected Composer to name Text Input for a field outside the chat composer');

  const font = extractHermesReferenceBlock(extractHermesSection(src, 'Hermex Font'));
  assert.doesNotMatch(font, /useWhen:\s*'Reach for a named Hermex Typography role — the role alone decides weight and design\.'/, 'useWhen must stop restating Typography\'s own rule');
  assert.ok(extractAlternativeNames(font).includes('Hermex Typography'), 'expected Font to point to Typography for choosing a role');
});

test('The five foundation token groups (Spacing, Radius & Geometry, Motion, Shadow, Iconography) state a real avoidWhen boundary instead of only an adoption disclaimer', () => {
  const src = read(HERMES_SECTIONS_PATH);

  const spacing = extractHermesReferenceBlock(extractHermesSection(src, 'Hermex Spacing'));
  assert.match(spacing, /HermesUsageSize|HermesAttachmentSize/, 'expected Spacing avoidWhen to route component-owned fixed geometry away from the spacing scale');
  assert.match(spacing, /named exception/i, 'expected Spacing avoidWhen to require a named exception for an off-scale value');

  const radius = extractHermesReferenceBlock(extractHermesSection(src, 'Hermex Radius & Geometry'));
  assert.match(radius, /Capsule\(\)/, 'expected Radius & Geometry avoidWhen to route a fully rounded edge to Capsule()');
  assert.match(radius, /ChatComposerMetrics|TranscriptLogRowMetrics|AdaptiveReadableContentWidth/, 'expected avoidWhen to name the feature-scoped geometry that stays outside the scale');

  const motion = extractHermesReferenceBlock(extractHermesSection(src, 'Hermex Motion'));
  assert.match(motion, /feedbackPress/, 'expected Motion avoidWhen to point at a real named Bundle case');
  assert.match(motion, /one-off spring/i, 'expected Motion avoidWhen to prohibit a one-off spring literal');

  const shadow = extractHermesReferenceBlock(extractHermesSection(src, 'Hermex Shadow'));
  assert.match(shadow, /eight roles/i, 'expected Shadow avoidWhen to point at the named-role scale');
  assert.match(shadow, /Outlined Card/, 'expected Shadow avoidWhen to prohibit a shadow on the no-elevation Outlined Card');

  const icon = extractHermesReferenceBlock(extractHermesSection(src, 'Hermex Iconography'));
  assert.match(icon, /literal point size/i, 'expected Iconography avoidWhen to prohibit a literal point size on a new SF Symbol');
  assert.match(icon, /HermesIconSize/, 'expected Iconography avoidWhen to route to the named HermesIconSize scale instead');
});

test('every alternative name across every Hermex catalog entry resolves to a real entry id/displayName or an explicit reviewed native/platform/production allowlist — never a nonexistent control or a non-choosable catalog artifact', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = [...src.matchAll(/^ {4}id: '([^']+)',/gm)].map((m) => m[1]);
  assert.ok(ids.length >= 34, 'expected at least the 34 known Hermex entries');

  const validNames = new Set();
  for (const id of ids) {
    validNames.add(id);
    const block = extractHermesSection(src, id);
    const displayNameMatch = block.match(/displayName:\s*'([^']+)'/);
    if (displayNameMatch) validNames.add(displayNameMatch[1]);
  }

  // Explicit, reviewed allowlist: real native/platform/production analogs that are intentionally
  // not their own catalog entry (see WHEN_TO_USE.md's adoptionStatus guidance) — never grown to
  // launder a name that should instead resolve to a real entry.
  const EXTERNAL_ALTERNATIVE_ALLOWLIST = new Set([
    'SectionCard / SettingsCard (production)',
    'MessageBubbleView / ChatComposerAttachmentStripView (production)',
    'Native Divider (production)',
    'Native List row (production)',
    'Native Toggle',
    'Native navigation title',
    'ChatTactileButtonStyle / ChatDecisionButtonStyle (production)',
    'TranscriptLogRowView (production)',
    'Native ContentUnavailableView',
    'Native NavigationLink / .navigationDestination (production)',
  ]);

  let checkedCount = 0;
  for (const id of ids) {
    const block = extractHermesSection(src, id);
    const ref = extractHermesReferenceBlock(block);
    const names = extractAlternativeNames(ref);
    for (const name of names) {
      checkedCount += 1;
      assert.ok(
        validNames.has(name) || EXTERNAL_ALTERNATIVE_ALLOWLIST.has(name),
        `alternative "${name}" in "${id}" does not resolve to a real catalog entry id/displayName, nor is it on the reviewed native/production allowlist`,
      );
    }
  }
  assert.ok(checkedCount > 15, 'expected the majority of Hermex entries to carry at least one alternative to validate');
});

// ─── Design system follow-up batch A (DSF-01..DSF-04): button/layout consistency ──────────────────
// Extracts one top-level style object literal's own body (from its `<key>: {` line up to the next
// `},`), scoped narrowly so an assertion about one style entry never accidentally matches a
// same-prefixed neighbor (e.g. `dialogFooter` vs `dialogFooterVertical`/`dialogFooterButton`).
const extractStyleEntry = (src, key) => {
  const marker = `${key}: {`;
  const idx = src.indexOf(marker);
  assert.notEqual(idx, -1, `expected a '${key}' style entry`);
  const end = src.indexOf('},', idx);
  assert.notEqual(end, -1, `expected the '${key}' style entry to close with '},'`);
  return src.slice(idx, end);
};

test('Issue #DSF-01: the Dialog catalog specimen centers its header/close row, shrinks the close visual to the compact 24pt XS size, and right-aligns (trailing) the horizontal footer actions', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);

  const headerRow = extractStyleEntry(previewsSrc, 'dialogHeaderRow');
  assert.match(headerRow, /alignItems:\s*'center'/, 'expected the Dialog header row to vertically center the heading and close control');
  assert.doesNotMatch(headerRow, /alignItems:\s*'flex-start'/, 'the header row must no longer use flex-start now that header/close are centered');

  const closeButton = extractStyleEntry(previewsSrc, 'dialogCloseButton');
  assert.match(closeButton, /width:\s*24/, 'expected the close visual to shrink to the compact 24pt XS size (HermexButtonSize.extraSmall.minHeight)');
  assert.match(closeButton, /height:\s*24/, 'expected the close visual to shrink to the compact 24pt XS size (HermexButtonSize.extraSmall.minHeight)');

  const footer = extractStyleEntry(previewsSrc, 'dialogFooter');
  assert.match(footer, /justifyContent:\s*'flex-end'/, 'expected the horizontal Dialog footer to align its actions to the trailing edge');
});

test('Issue #DSF-02: the Hermex Bottom Sheet catalog footer specimen drops its top border, matching HermexBottomSheet.swift, which has no footer Divider', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const footer = extractStyleEntry(previewsSrc, 'bottomSheetFooter');
  assert.doesNotMatch(footer, /borderTopWidth/, 'expected the catalog footer to drop its borderTopWidth');
  assert.doesNotMatch(footer, /borderTopColor/, 'expected the catalog footer to drop its borderTopColor');
});

test('Issue #DSF-02: the Hermex TopNav catalog specimen\'s icon-slot action composes an adaptive-glass surface alongside its existing icon-first, accessibly-labeled treatment', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const iconSlotButtonBody = extractFunctionBody(previewsSrc, 'iconSlotButton');
  assert.match(iconSlotButtonBody, /accessibilityLabel=\{label\}/, 'expected the icon-slot action to keep its meaningful accessibility label');
  assert.match(iconSlotButtonBody, /glass/i, 'expected the icon-slot action to compose an adaptive-glass surface, preferring icons with accessible labels over plain secondary chrome');
});

test('Correction (DSR2-08, supersedes Issue #DSF-03): the Toast catalog gallery no longer renders an extraSmall neutral Button trailing action — HermexToast\'s real trailing action is plain white text, so the gallery demonstrates it via the generic Toast\'s own status-matching `action` shortcut over a dark override background, not a separate Button composition', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'ToastFamilyGallery');
  assert.doesNotMatch(galleryBody, /<Button[^>]*size="extraSmall"/s,
    'expected the retired extraSmall neutral Button trailing-action specimen to be removed');
  assert.doesNotMatch(galleryBody, /actionNode/, 'expected the retired actionNode story to be removed');
  assert.match(galleryBody, /action=\{\{ label: 'Undo'/, 'expected the plain white trailing action to still be demonstrated via the built-in action shortcut');
});

// Correction (Round 2, DSR2-XX): production's SegmentedControlMetrics.trackInset is HermesSpacing.s2
// (2pt), matching the existing 2pt vertical visual-track padding — a fixed 2pt inset on all sides,
// not the previously-pinned 4pt horizontal figure, which no longer matches production source.
test('Issue #DSF-04 (corrected for Round 2): the Hermex Segmented Control catalog\'s fixed-variant track composes a distinct 40pt visual-track background layer (the existing 36pt selected pill plus one HermesSpacing.s2 padding step above and below), not a bare zero vertical padding that produces no visible change, while retaining the fixed 2pt inset on all sides, 44pt segment minimum touch height, and 36pt selected thumb', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);

  const visualTrack = extractStyleEntry(previewsSrc, 'segmentedFixedVisualTrack');
  assert.match(visualTrack, /height:\s*40\b/, 'expected a distinct 40pt visual-track background layer framed at 36pt selected pill height + 2pt padding above/below');

  const track = extractStyleEntry(previewsSrc, 'segmentedFixedTrack');
  assert.match(track, /paddingHorizontal:\s*2\b/, 'expected the fixed 2pt horizontal inset (HermesSpacing.s2, matching SegmentedControlMetrics.trackInset), not the stale 4pt figure');
  assert.doesNotMatch(track, /paddingHorizontal:\s*4\b/, 'the stale 4pt horizontal inset must no longer be documented');

  const touchTarget = extractStyleEntry(previewsSrc, 'segmentedTouchTarget');
  assert.match(touchTarget, /minHeight:\s*44/, 'expected the 44pt segment minimum touch height to be retained');

  const pill = extractStyleEntry(previewsSrc, 'segmentedPill');
  assert.match(pill, /height:\s*36/, 'expected the 36pt selected thumb to be retained');

  const previewBody = extractFunctionBody(previewsSrc, 'FixedSegmentedControlPreview');
  assert.match(previewBody, /segmentedFixedVisualTrack/, 'expected FixedSegmentedControlPreview to compose the 40pt visual-track background layer, not shrink the touch target to match it');
});

test('Issue #DSF-04: the Segmented Control catalog gallery\'s Fixed caption truthfully names the 40pt visual track, the 36pt selected pill inside it, and the 44pt touch target that extends beyond it, instead of attributing this geometry only to the Scrolling variant', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'SegmentedControlGallery');
  const scrollingMarker = 'name="Scrolling"';
  assert.ok(galleryBody.includes(scrollingMarker), 'expected the gallery to still label its Scrolling section');
  const fixedSection = galleryBody.split(scrollingMarker)[0];
  assert.match(fixedSection, /40pt/, 'expected the Fixed caption to name the 40pt visual track');
  assert.match(fixedSection, /36pt/, 'expected the Fixed caption to name the shared 36pt selected pill, not just the Scrolling caption');
  assert.match(fixedSection, /44pt/, 'expected the Fixed caption to name the shared 44pt touch target, not just the Scrolling caption');
  assert.match(fixedSection, /two lines|two-line|wrap/i,
    'expected the Fixed caption to document the approved equal-width, multi-line accessibility fallback');
});

// ─── DSF-07/08/09 (Batch B, RED): Card/Radio/Checkbox catalog color parity ──────────────────────
// Tests-only, written against the design-system-follow-up-plan.md approved mapping before any
// production/catalog source change. Approved values, derived from HERMES_COLOR_RAMPS.Neutral (light
// appearance only — dark adaptation is a documented follow-up, not asserted here, since the web
// catalog renders one static appearance): selected/primary #2D2D2F (Neutral[950]), inverse selected
// foreground / secondary-adjacent light anchor #F9F9FA (Neutral[50]), unselected/standard border
// #AEAEB1 (Neutral[400]). Object/constant names below (HERMEX_CARD_COLORS,
// HERMEX_SELECTION_CONTROL_COLORS) mirror the native HermexCardColors/HermexSelectionControlColors
// naming this same batch adds to HermexCardTests.swift/HermexRadioTests.swift/HermexCheckboxTests.swift
// — a naming choice for this required mapping, not a constraint stated in the plan itself.

test('DSF-07 (Batch B) correction (Issue #607 follow-up): the Hermex Card gallery\'s HERMEX_CARD_COLORS mapping derives only the two real HermexCardColors surface roles from HERMES_COLOR_RAMPS.Neutral, instead of hand-typed hex/rgba literals or a retired component-local border role', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const objMatch = sectionsSrc.match(/const HERMEX_CARD_COLORS[\s\S]*?\};/);
  assert.ok(objMatch, 'expected a top-level HERMEX_CARD_COLORS object in hermesSections.tsx, derived from HERMES_COLOR_RAMPS.Neutral');
  const obj = objMatch[0];
  assert.match(obj, /HERMES_COLOR_RAMPS\.Neutral\[\s*50\s*\]/, 'expected the primary surface to derive from HERMES_COLOR_RAMPS.Neutral[50], mirroring native .adaptive(light: .s50, dark: .s950)');
  assert.match(obj, /HERMES_COLOR_RAMPS\.Neutral\[\s*100\s*\]/, 'expected the secondary/compact surface to derive from HERMES_COLOR_RAMPS.Neutral[100], mirroring native .adaptive(light: .s100, dark: .s900)');
  assert.doesNotMatch(obj, /#[0-9a-fA-F]{3,8}\b/, 'expected HERMEX_CARD_COLORS to derive from the ramp, not a hand-typed hex literal');
  assert.doesNotMatch(obj, /standardBorder/, 'HermexCardColors declares no border role — DSR2-01 moved it to the shared HermexSurfaceBorderColors');
  assert.doesNotMatch(obj, /increasedContrastBorder/, 'HermexCardColors declares no border role — DSR2-01 moved it to the shared HermexSurfaceBorderColors');
});

test('DSF-07 (Batch B) correction (Issue #607 follow-up): the Hermex Card gallery styles for every cataloged variant (default/glass, request-opaque, outlined) use HERMEX_CARD_COLORS for background and the shared HERMEX_SURFACE_BORDER_COLORS for border, instead of local raw color literals or a retired HERMEX_CARD_COLORS border role', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);

  const cardBox = extractStyleEntry(sectionsSrc, 'cardBox');
  assert.match(cardBox, /HERMEX_CARD_COLORS\.primarySurface/, 'expected cardBox (the default/glass and compact variants\' wrapper) to use HERMEX_CARD_COLORS for its background instead of a raw rgba literal');
  assert.match(cardBox, /HERMEX_SURFACE_BORDER_COLORS\.resting/, 'expected cardBox\'s border to use the shared HERMEX_SURFACE_BORDER_COLORS.resting role, not a retired HERMEX_CARD_COLORS border member');
  assert.doesNotMatch(cardBox, /rgba\(/, 'expected the raw rgba background/border literals to be gone from cardBox');
  assert.doesNotMatch(cardBox, /HERMEX_CARD_COLORS\.standardBorder/, 'the retired HERMEX_CARD_COLORS.standardBorder member must be gone from cardBox');

  const cardBoxOpaque = extractStyleEntry(sectionsSrc, 'cardBoxOpaque');
  assert.match(cardBoxOpaque, /HERMEX_CARD_COLORS\.primarySurface/, 'expected cardBoxOpaque (the request-opaque variant) to use HERMEX_CARD_COLORS for its background instead of a raw hex literal');
  assert.match(cardBoxOpaque, /HERMEX_SURFACE_BORDER_COLORS\.resting/, 'expected cardBoxOpaque\'s border to use the shared HERMEX_SURFACE_BORDER_COLORS.resting role, not a retired HERMEX_CARD_COLORS border member');
  assert.doesNotMatch(cardBoxOpaque, /#[0-9a-fA-F]{3,8}\b/, 'expected the raw hex background/border literal to be gone from cardBoxOpaque');
  assert.doesNotMatch(cardBoxOpaque, /HERMEX_CARD_COLORS\.standardBorder/, 'the retired HERMEX_CARD_COLORS.standardBorder member must be gone from cardBoxOpaque');

  // The outlined variant currently relies entirely on the generic template Card's own
  // DS_SEMANTIC.border.light / DS_SEMANTIC.surface.white default — not an explicit Hermex Color
  // mapping. DSF-07 requires an explicit mapping for every variant, including outlined, so
  // CardChromePreview itself must apply a HERMEX_CARD_COLORS/HERMEX_SURFACE_BORDER_COLORS-derived
  // style override for it.
  const cardChromePreviewBody = extractFunctionBody(sectionsSrc, 'CardChromePreview');
  assert.match(
    cardChromePreviewBody,
    /HERMEX_CARD_COLORS/,
    'expected CardChromePreview to apply an explicit HERMEX_CARD_COLORS-derived background to the outlined Card (e.g. via its style prop), not rely solely on the generic template default'
  );
  assert.match(
    cardChromePreviewBody,
    /HERMEX_SURFACE_BORDER_COLORS/,
    'expected CardChromePreview to apply the shared HERMEX_SURFACE_BORDER_COLORS border to the outlined Card instead of a retired HERMEX_CARD_COLORS border member'
  );
});

test('DSF-07 correction (Issue #607 follow-up): HermexSurfaceBorderColors.resting/.increasedContrast — not a retired HermexCardColors.standardBorder/increasedContrastBorder — are documented in the Hermes Card catalog entry with their real light/dark Neutral anchors', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const cardSection = extractHermesSection(sectionsSrc, 'Hermes Card');
  const implementationNotes = extractBraceBlock(cardSection, /implementationNotes:\s*\{/);

  assert.doesNotMatch(implementationNotes, /HermexCardColors\.(?:standardBorder|increasedContrastBorder)/, 'HermexCardColors does not define a border role');
  assert.match(implementationNotes, /HermexSurfaceBorderColors\.resting/, 'expected the real resting border role to be named');
  assert.match(implementationNotes, /HermexSurfaceBorderColors\.increasedContrast/, 'expected the real increasedContrast border role to be named');
  // resting: light Neutral.s600 (#808084), dark Neutral.s400 (#AEAEB1) — this static catalog renders only the light anchor.
  assert.match(implementationNotes, /Neutral\.s600 \/ #808084/i, 'expected the resting role\'s real light anchor (Neutral.s600 / #808084) to be documented');
  assert.match(implementationNotes, /Neutral\.s400 \/ #AEAEB1/i, 'expected the resting role\'s real dark anchor (Neutral.s400 / #AEAEB1) to be documented, since this static catalog only renders the light anchor');
  // increasedContrast: light Neutral.s800 (#58585B), dark Neutral.s200 (#DFDFE1).
  assert.match(implementationNotes, /Neutral\.s800 \/ #58585B/i, 'expected the increasedContrast role\'s real light anchor (Neutral.s800 / #58585B) to be documented');
  assert.match(implementationNotes, /Neutral\.s200 \/ #DFDFE1/i, 'expected the increasedContrast role\'s real dark anchor (Neutral.s200 / #DFDFE1) to be documented');
});

test('DSF-08/09 (Batch B, RED): the generic catalog Radio exposes an optional, backward-compatible color-configuration seam sufficient for Hermex selected/unselected colors, actually consumed by the rendered control, while its own default stays DS_SEMANTIC.emphasis.info when omitted', () => {
  const implSrc = read('native/components/Radio/Radio.tsx');
  const colorsPropMatch = implSrc.match(/colors\?:\s*\{([^}]*)\}/s);
  assert.ok(colorsPropMatch, 'expected an optional `colors` prop on RadioProps');
  assert.match(colorsPropMatch[1], /selected/, 'expected a `selected` color field');
  assert.match(colorsPropMatch[1], /unselectedBorder/, 'expected an `unselectedBorder` color field');
  assert.match(implSrc, /colors\?\.selected/, 'expected the component to actually read colors?.selected when overriding the selected treatment');
  assert.match(implSrc, /colors\?\.unselectedBorder/, 'expected the component to actually read colors?.unselectedBorder when overriding the unselected treatment');
  assert.match(implSrc, /DS_SEMANTIC\.emphasis\.info/, 'the generic template default must remain DS_SEMANTIC.emphasis.info when colors is omitted — backward compatible');
});

test('DSF-08/09 (Batch B, RED): the generic catalog Checkbox exposes an optional, backward-compatible color-configuration seam sufficient for Hermex selected/unselected/inverse colors, actually consumed by the rendered control, while its own default stays DS_SEMANTIC.emphasis.info when omitted', () => {
  const implSrc = read('native/components/Checkbox/Checkbox.tsx');
  const colorsPropMatch = implSrc.match(/colors\?:\s*\{([^}]*)\}/s);
  assert.ok(colorsPropMatch, 'expected an optional `colors` prop on CheckboxProps');
  assert.match(colorsPropMatch[1], /selected/, 'expected a `selected` color field');
  assert.match(colorsPropMatch[1], /selectedForeground|inverse/, 'expected an inverse selected-foreground color field (selectedForeground or inverse)');
  assert.match(colorsPropMatch[1], /unselectedBorder/, 'expected an `unselectedBorder` color field');
  assert.match(implSrc, /colors\?\.selected/, 'expected the component to actually read colors?.selected when overriding the checked treatment');
  assert.match(implSrc, /colors\?\.(selectedForeground|inverse)/, 'expected the component to actually read the inverse foreground override for the checkmark');
  assert.match(implSrc, /colors\?\.unselectedBorder/, 'expected the component to actually read colors?.unselectedBorder when overriding the unchecked treatment');
  assert.match(implSrc, /DS_SEMANTIC\.emphasis\.info/, 'the generic template default must remain DS_SEMANTIC.emphasis.info when colors is omitted — backward compatible');
});

test('DSF-08/09 (Batch B, corrected, RED): the Hermex gallery defines one shared HERMEX_SELECTION_CONTROL_COLORS object using the approved Neutral light values (#2D2D2F selected, #F9F9FA inverse, #8E8E93 unselected border)', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const objMatch = previewsSrc.match(/const HERMEX_SELECTION_CONTROL_COLORS[\s\S]*?\};/);
  assert.ok(objMatch, 'expected a top-level HERMEX_SELECTION_CONTROL_COLORS object');
  const obj = objMatch[0];
  assert.match(obj, /'#2D2D2F'/, 'expected the selected value to be Neutral.s950 (#2D2D2F)');
  assert.match(obj, /'#F9F9FA'/, 'expected the inverse selected-foreground value to be Neutral.s50 (#F9F9FA)');
  // Corrected from the retired Neutral.s400 (#AEAEB1): the review measured that light anchor at
  // ~2.1:1 against the light primary surface, below the 3:1 non-text boundary threshold (WCAG
  // 1.4.11); Neutral.s500 (#8E8E93) is the corrected value, mirroring native HermexSelectionControlColors.
  assert.match(obj, /'#8E8E93'/, 'expected the unselected-border value to be the corrected Neutral.s500 (#8E8E93), not the retired, under-contrast Neutral.s400 (#AEAEB1)');
  assert.doesNotMatch(obj, /'#AEAEB1'/, 'the retired, under-contrast Neutral.s400 unselected-border value must be gone');
});

test('DSF-08 (Batch B, RED): every Hermex Radio specimen — static (unselected/selected/disabled) and grouped interactive — consumes HERMEX_SELECTION_CONTROL_COLORS, and no blue selected state remains in the gallery source', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'RadioFamilyGallery');
  const groupBody = extractFunctionBody(previewsSrc, 'RadioGroupDemo');
  const combined = galleryBody + '\n' + groupBody;

  const radioTagCount = (combined.match(/<Radio\b/g) || []).length;
  const colorsUsageCount = (combined.match(/colors=\{HERMEX_SELECTION_CONTROL_COLORS\}/g) || []).length;
  assert.equal(radioTagCount, 6, 'expected exactly 6 Radio specimens: 3 static (unselected/selected/disabled) + 3 grouped');
  assert.equal(colorsUsageCount, radioTagCount, 'expected every Radio specimen to pass colors={HERMEX_SELECTION_CONTROL_COLORS}');
  assert.doesNotMatch(combined, /DS_SEMANTIC\.emphasis\.info/, 'no blue selected state may remain in the Hermex Radio gallery source — an explanatory swatch alone does not satisfy rendered specimen configuration');
});

test('DSF-09 (Batch B, RED): every Hermex Checkbox specimen — static (unchecked/checked/disabled), standalone interactive, and row-owned — consumes HERMEX_SELECTION_CONTROL_COLORS, and no blue selected state remains in the gallery source', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'CheckboxFamilyGallery');
  const interactiveBody = extractFunctionBody(previewsSrc, 'CheckboxInteractiveDemo');
  const rowOwnedBody = extractFunctionBody(previewsSrc, 'CheckboxRowOwnedDemo');
  const combined = galleryBody + '\n' + interactiveBody + '\n' + rowOwnedBody;

  const checkboxTagCount = (combined.match(/<Checkbox\b/g) || []).length;
  const colorsUsageCount = (combined.match(/colors=\{HERMEX_SELECTION_CONTROL_COLORS\}/g) || []).length;
  assert.equal(checkboxTagCount, 6, 'expected exactly 6 Checkbox specimens: 4 static (unchecked/checked/disabled-unchecked/disabled-checked) + 1 standalone interactive + 1 row-owned');
  assert.equal(colorsUsageCount, checkboxTagCount, 'expected every Checkbox specimen to pass colors={HERMEX_SELECTION_CONTROL_COLORS}');
  assert.doesNotMatch(combined, /DS_SEMANTIC\.emphasis\.info/, 'no blue selected state may remain in the Hermex Checkbox gallery source — an explanatory swatch alone does not satisfy rendered specimen configuration');
});

test('DSF-08/09 correction (RED): Hermes Radio and Hermes Checkbox catalog metadata identify HermexSelectionControlColors as contrast-validated component-scoped pairings, not merely repeating token names, and name the corrected unselectedBorder light anchor', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  for (const id of ['Hermes Checkbox', 'Hermes Radio']) {
    const section = extractHermesSection(sectionsSrc, id);
    const implementationNotes = extractBraceBlock(section, /implementationNotes:\s*\{/);
    assert.match(
      implementationNotes,
      /contrast-validated/i,
      `expected the ${id} implementation notes to explicitly call HermexSelectionControlColors' pairings contrast-validated, not merely repeat their token names`
    );
    assert.match(
      implementationNotes,
      /Neutral\.s500|Neutral\[\s*500\s*\]|#8E8E93/,
      `expected the ${id} implementation notes to name the corrected unselectedBorder light anchor (Neutral.s500 / #8E8E93), replacing the retired, under-contrast Neutral.s400`
    );
  }
});

test('DSF-07/08/09 correction (RED): every non-500 Neutral pairing this batch consumes for selection-control and Card borders satisfies hermesColorCatalogData.ts\'s own per-pairing contrast-validation restriction — computed directly from ramp hex values, not a visual-only pass. Does not weaken or replace that restriction\'s own pinned text, which stays asserted separately below', () => {
  // Mirrors HERMES_COLOR_RAMPS.Neutral in hermesColorCatalogData.ts (pinned by the DSF-07 test
  // above via a regex against the real file); duplicated here as plain numbers because this test
  // only needs the contrast math, not the ramp's own source-of-truth definition.
  const NEUTRAL = { 50: '#F9F9FA', 100: '#F1F1F2', 200: '#DFDFE1', 400: '#AEAEB1', 500: '#8E8E93', 600: '#808084', 800: '#58585B', 900: '#434345', 950: '#2D2D2F' };

  function relativeLuminance(hex) {
    const clean = hex.replace('#', '');
    const r = parseInt(clean.slice(0, 2), 16) / 255;
    const g = parseInt(clean.slice(2, 4), 16) / 255;
    const b = parseInt(clean.slice(4, 6), 16) / 255;
    const linearize = (c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b);
  }

  function contrastRatio(hexA, hexB) {
    const lumA = relativeLuminance(hexA);
    const lumB = relativeLuminance(hexB);
    const lighter = Math.max(lumA, lumB);
    const darker = Math.min(lumA, lumB);
    return (lighter + 0.05) / (darker + 0.05);
  }

  // Selection control unselected border (DSF-08/09 correction): light Neutral[500], dark
  // Neutral[600], against the primary surface pair Card already establishes.
  assert.ok(contrastRatio(NEUTRAL[500], NEUTRAL[50]) >= 3, `light unselectedBorder Neutral[500] must be >=3:1 against the primary surface, got ${contrastRatio(NEUTRAL[500], NEUTRAL[50]).toFixed(2)}`);
  assert.ok(contrastRatio(NEUTRAL[600], NEUTRAL[950]) >= 3, `dark unselectedBorder Neutral[600] must be >=3:1 against the primary surface, got ${contrastRatio(NEUTRAL[600], NEUTRAL[950]).toFixed(2)}`);

  // Selected / selectedForeground: light Neutral[950] vs Neutral[50], dark Neutral[50] vs Neutral[950].
  assert.ok(contrastRatio(NEUTRAL[950], NEUTRAL[50]) >= 4.5, 'selected/selectedForeground must be >=4.5:1 in light appearance');
  assert.ok(contrastRatio(NEUTRAL[50], NEUTRAL[950]) >= 4.5, 'selected/selectedForeground must be >=4.5:1 in dark appearance');

  // Card resting border (HermexSurfaceBorderColors.resting): light Neutral[600], dark Neutral[400],
  // against both the primary (Neutral[50]/Neutral[950]) and secondary (Neutral[100]/Neutral[900])
  // Card surfaces. (Issue #607 follow-up: this pair is .resting, not .increasedContrast — the prior
  // comment/messages here mislabeled it.)
  assert.ok(contrastRatio(NEUTRAL[600], NEUTRAL[50]) >= 3, 'light resting border must be >=3:1 against the primary Card surface');
  assert.ok(contrastRatio(NEUTRAL[600], NEUTRAL[100]) >= 3, 'light resting border must be >=3:1 against the secondary Card surface');
  assert.ok(contrastRatio(NEUTRAL[400], NEUTRAL[950]) >= 3, 'dark resting border must be >=3:1 against the primary Card surface');
  assert.ok(contrastRatio(NEUTRAL[400], NEUTRAL[900]) >= 3, 'dark resting border must be >=3:1 against the secondary Card surface');

  // Card Increased Contrast border (HermexSurfaceBorderColors.increasedContrast): light Neutral[800],
  // dark Neutral[200], against both Card surfaces.
  assert.ok(contrastRatio(NEUTRAL[800], NEUTRAL[50]) >= 3, 'light Increased Contrast border must be >=3:1 against the primary Card surface');
  assert.ok(contrastRatio(NEUTRAL[800], NEUTRAL[100]) >= 3, 'light Increased Contrast border must be >=3:1 against the secondary Card surface');
  assert.ok(contrastRatio(NEUTRAL[200], NEUTRAL[950]) >= 3, 'dark Increased Contrast border must be >=3:1 against the primary Card surface');
  assert.ok(contrastRatio(NEUTRAL[200], NEUTRAL[900]) >= 3, 'dark Increased Contrast border must be >=3:1 against the secondary Card surface');

  // Documents, rather than silently forgets, the pairing this batch retires: the old light
  // unselectedBorder Neutral[400] measured ~2.1:1 against the primary surface and must not return
  // as a consumed, unvalidated pairing.
  assert.ok(contrastRatio(NEUTRAL[400], NEUTRAL[50]) < 3, 'sanity check: the retired light Neutral[400] unselectedBorder stays below 3:1, confirming why DSF-08/09 replaced it with Neutral[500]');
});

test('DSF-08/09 (Batch B, RED): the pre-existing explanatory adaptive-fill swatch remains, but is not the only place the approved color appears — real rendered specimens must consume it too', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /function AdaptiveSelectedFillSwatch/, 'expected the existing explanatory swatch component to remain');
  assert.match(previewsSrc, /colors=\{HERMEX_SELECTION_CONTROL_COLORS\}/, 'expected at least one real Radio/Checkbox specimen (not just the swatch) to consume the approved colors');
});

test('DSF-08/09 rendered parity: the adaptive-fill swatch and family metadata describe Neutral.s950 / Neutral.s50 rather than retired Color.primary black/white', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const swatchBody = extractFunctionBody(previewsSrc, 'AdaptiveSelectedFillSwatch');
  assert.match(swatchBody, /HERMEX_SELECTION_CONTROL_COLORS\.selected/, 'expected the light swatch to use Neutral.s950 via the shared Hermex mapping');
  assert.match(swatchBody, /HERMEX_SELECTION_CONTROL_COLORS\.selectedForeground/, 'expected the dark swatch to use Neutral.s50 via the shared Hermex mapping');
  assert.match(swatchBody, /Light · \{HERMEX_SELECTION_CONTROL_COLORS\.selected\}/, 'expected the rendered light label to show #2D2D2F');
  assert.match(swatchBody, /Dark · \{HERMEX_SELECTION_CONTROL_COLORS\.selectedForeground\}/, 'expected the rendered dark label to show #F9F9FA');
  assert.doesNotMatch(swatchBody, /HERMES_SEMANTIC_COLORS|primary\.preview/, 'the swatch must not retain the retired pure black/white Color.primary source');

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  for (const id of ['Hermes Checkbox', 'Hermes Radio']) {
    const section = extractHermesSection(sectionsSrc, id);
    assert.match(section, /HermexSelectionControlColors/, `${id} must name the component-scoped adaptive mapping`);
    assert.match(section, /Neutral\.s950/, `${id} must document the light selected value`);
    assert.match(section, /Neutral\.s50/, `${id} must document the dark selected value`);
    assert.doesNotMatch(section, /Color\.primary|black in light appearance|white in dark/, `${id} must not describe the retired pure black\/white contract`);
  }
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// ─── Round 2 (hermex-dsf-round-2-content-r1): Composer Toolbar, Popover Menu selection guidance,
// shared surface-border geometry reuse, and manifest/README/WHEN_TO_USE completeness ────────────
// ═══════════════════════════════════════════════════════════════════════════════════════════════

test('Composer Toolbar is a new, foundation-available, zero-adoption Components — Hermex entry documenting HermexComposerToolbar.swift\'s elevated/transparent appearances, fitting/overflowing examples, arbitrary caller content, and one horizontally scrollable row, with no Send/Stop example or ownership', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  assert.match(sectionsSrc, /\| 'Composer Toolbar'/, "expected 'Composer Toolbar' in the HermesSectionId union");

  const section = extractHermesSection(sectionsSrc, 'Composer Toolbar');
  assert.match(section, /hermesReference:\s*\{/);
  assert.match(section, /displayName:\s*'Composer Toolbar'/);
  assert.match(section, /HermesMobile\/Features\/Shared\/HermexComposerToolbar\.swift/, 'expected the real foundation source path');
  assert.match(section, /elevated/i, 'expected the elevated appearance to be documented');
  assert.match(section, /transparent/i, 'expected the transparent appearance to be documented');
  assert.match(section, /(?:fitting|fits)/i, 'expected a fitting-content example');
  assert.match(section, /overflow/i, 'expected an overflowing-content example');
  assert.match(section, /arbitrary caller content/i, 'expected the entry to document arbitrary caller-supplied content');
  assert.match(section, /one horizontally scrollable row|single horizontally scrollable row/i, 'expected the entry to document one horizontally scrollable row');
  assert.doesNotMatch(section, /\bSend\b/, 'must not demonstrate or claim ownership of a Send control');
  assert.doesNotMatch(section, /\bStop\b/, 'must not demonstrate or claim ownership of a Stop control');

  const state = extractAdoptionState(section);
  assert.equal(state, 'foundation-available', 'expected foundation-available status');
  assert.match(section, /zero production (?:screens|call sites|adoption)/i, 'expected the adoptionStatus detail to explicitly state zero production adoption');

  const ref = extractHermesReferenceBlock(section);
  const alts = extractAlternativeNames(ref);
  for (const expected of ['Buttons', 'Hermes Selection Sheet', 'Hermes TopNav']) {
    assert.ok(alts.includes(expected), `expected Composer Toolbar's alternatives to include "${expected}" (Buttons, Selection Sheet, and TopNav)`);
  }

  const navBlockMatch = sectionsSrc.match(/export const hermesNav:[^;]*;/s);
  assert.ok(navBlockMatch, 'expected an exported hermesNav array');
  const componentsGroupMatch = navBlockMatch[0].match(/label:\s*'Components',[\s\S]*?ids:\s*\[([\s\S]*?)\]/);
  assert.ok(componentsGroupMatch, 'expected the Components — Hermex nav group');
  const componentIds = [...componentsGroupMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  assert.ok(componentIds.includes('Composer Toolbar'), 'expected Composer Toolbar to be registered in the Components — Hermex nav group');
});

test('Popover Menu directs a persistent selection to a caller-presented Selection Sheet or a dedicated picker sheet, and names no HermexSelectionPopover', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Hermes Popover Menu');
  const ref = extractHermesReferenceBlock(section);
  assert.match(ref, /persistent selection/i, 'expected avoidWhen to name persistent selection as out of scope');
  assert.match(ref, /caller-presented (?:Selection Sheet|Hermes Selection Sheet)|dedicated picker sheet/i, 'expected avoidWhen/alternatives to direct persistent selection to a caller-presented Selection Sheet or a dedicated picker sheet');
  assert.doesNotMatch(sectionsSrc, /HermexSelectionPopover/, 'HermexSelectionPopover must not exist anywhere in the catalog');
});

test('Selection Sheet documents contentInset with .standard and .none, the 16pt standard default, and no arbitrary CGFloat inset API', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Hermes Selection Sheet');
  assert.match(section, /contentInset/, 'expected contentInset to be documented');
  assert.match(section, /\.standard/, 'expected the .standard case to be documented');
  assert.match(section, /\.none/, 'expected the .none case to be documented');
  assert.match(section, /16pt/, 'expected the 16pt standard default to be documented');
  assert.doesNotMatch(section, /contentInset:\s*CGFloat|contentInset:\s*number/, 'must not document an arbitrary CGFloat/number contentInset API');
});

test('Toast documents all four semantic surfaces (information/success/warning/error) using Blue.s700/Green.s800/Orange.s800/Red.s700, with white icon/message/action content', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Hermes Toast');
  for (const semantic of ['information', 'success', 'warning', 'error']) {
    assert.match(section, new RegExp(semantic, 'i'), `expected the ${semantic} semantic to be documented`);
  }
  assert.match(section, /Blue\.s700|Blue\[700\]/);
  assert.match(section, /Green\.s800|Green\[800\]/);
  assert.match(section, /Orange\.s800|Orange\[800\]/);
  assert.match(section, /Red\.s700|Red\[700\]/);
  assert.match(section, /white/i, 'expected white icon/message/action content to be documented');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'ToastFamilyGallery');

  // Correction (DSR2-08/DSR2-13): the gallery must actually render the approved dark ramp
  // backgrounds — not the generic Toast's own light-tinted `variant` styles, which the props/notes
  // above no longer claim. Assert the real style override, not just documentation prose.
  assert.match(galleryBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Blue\[700\]/, 'expected the information specimen to override the background with Blue[700]');
  assert.match(galleryBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Green\[800\]/, 'expected a success specimen to override the background with Green[800]');
  assert.match(galleryBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Orange\[800\]/, 'expected the warning specimen to override the background with Orange[800]');
  assert.match(galleryBody, /backgroundColor:\s*HERMES_COLOR_RAMPS\.Red\[700\]/, 'expected the error specimen to override the background with Red[700]');
  assert.doesNotMatch(galleryBody, /variant="informational"|variant="success"|variant="warning"|variant="negative"/, 'expected the retired light-tinted variant specimens to be gone, not surviving alongside the dark override');

  // Correction: the retired extraSmall-neutral-HermexButton/actionNode story must be gone.
  assert.doesNotMatch(galleryBody, /actionNode/, 'expected the retired actionNode/extraSmall neutral Button specimen to be removed');
  assert.doesNotMatch(galleryBody, /size="extraSmall"/, 'expected no extraSmall Button composition to remain in the Toast gallery');
  assert.match(galleryBody, /action=\{\{/, 'expected the plain white trailing action to still be demonstrated via the built-in action shortcut');
});

// A shared catalog surface-border reconstruction — mirroring native HermexSurfaceBorderColors
// (resting/focused/increasedContrast anchored at HermesColorRamp.Neutral.s600/s700/s800 light
// values) — replaces each specimen's own local, conflicting border mapping.
test('a shared HERMEX_SURFACE_BORDER_COLORS reconstruction maps resting/focused/increasedContrast from HERMES_COLOR_RAMPS.Neutral[600]/[700]/[800] and is reused by Card, Search, Text Input, and Code Input specimens, replacing local conflicting mappings', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const objMatch = sectionsSrc.match(/const HERMEX_SURFACE_BORDER_COLORS[\s\S]*?\};/);
  assert.ok(objMatch, 'expected a shared top-level HERMEX_SURFACE_BORDER_COLORS object, mirroring native HermexSurfaceBorderColors');
  const obj = objMatch[0];
  assert.match(obj, /resting/i, 'expected a resting border role');
  assert.match(obj, /focused/i, 'expected a focused border role');
  assert.match(obj, /increasedContrast/i, 'expected an increasedContrast border role');
  assert.match(obj, /HERMES_COLOR_RAMPS\.Neutral\[\s*600\s*\]/, 'expected the resting anchor to derive from Neutral[600], mirroring native HermexSurfaceBorderRamp.restingLight');
  assert.match(obj, /HERMES_COLOR_RAMPS\.Neutral\[\s*700\s*\]/, 'expected the focused anchor to derive from Neutral[700], mirroring native HermexSurfaceBorderRamp.focusedLight');
  assert.match(obj, /HERMES_COLOR_RAMPS\.Neutral\[\s*800\s*\]/, 'expected the increasedContrast anchor to derive from Neutral[800], mirroring native HermexSurfaceBorderRamp.increasedContrastLight');

  const cardSection = extractHermesSection(sectionsSrc, 'Hermes Card');
  assert.match(cardSection + sectionsSrc, /HERMEX_SURFACE_BORDER_COLORS/, 'expected Card to reuse the shared surface-border mapping');

  const searchSection = extractHermesSection(sectionsSrc, 'Search');
  assert.match(searchSection + sectionsSrc, /HERMEX_SURFACE_BORDER_COLORS/, 'expected Search to reuse the shared surface-border mapping');

  const textInputSection = extractHermesSection(sectionsSrc, 'Text Input');
  assert.match(textInputSection + sectionsSrc, /HERMEX_SURFACE_BORDER_COLORS/, 'expected Text Input (including its Code Input specimen) to reuse the shared surface-border mapping');
});

test('Search\'s clear-control and magnifier visible edge insets match while the clear target remains 44pt', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'SearchFamilyGallery');
  assert.match(body, /minWidth:\s*44[\s\S]{0,80}minHeight:\s*44|minHeight:\s*44[\s\S]{0,80}minWidth:\s*44/, 'expected the clear control to keep its independent 44pt hit target');
  assert.match(body, /preview\.searchClearTarget/, 'expected the clear control to use the shared searchClearTarget alignment style, not a one-off inline style');

  // Correction (DSR2-03/DSR2-14): the two dead style entries this test previously checked
  // (searchMagnifierIcon/searchClearIcon) were never referenced by any rendered element, so they
  // could not fail on the actual specimen. Assert the live styles the rendered elements really
  // consume instead: the clear glyph aligns flush with its 44pt target's trailing edge (so the
  // target can expand inward without adding visible trailing whitespace), and the field's own
  // paddingHorizontal is the single source of both the magnifier's and the clear glyph's visible
  // edge inset — so they necessarily match without a second, independently-tuned inset.
  assert.doesNotMatch(previewsSrc, /searchMagnifierIcon/, 'expected the unused searchMagnifierIcon style to be removed');
  assert.doesNotMatch(previewsSrc, /searchClearIcon:/, 'expected the unused searchClearIcon style to be removed');

  const targetMatch = previewsSrc.match(/searchClearTarget:\s*\{([^}]*)\}/);
  assert.ok(targetMatch, 'expected a searchClearTarget style entry');
  assert.match(targetMatch[1], /alignItems:\s*'flex-end'/, 'expected the clear glyph to align flush with its target\'s trailing edge, not centered');

  const fieldMatch = previewsSrc.match(/searchField:\s*\{([\s\S]*?)\n\s*\},/);
  assert.ok(fieldMatch, 'expected a searchField style entry');
  assert.match(fieldMatch[1], /paddingHorizontal:\s*12/, 'expected the field\'s own 12pt horizontal padding to be the single source of both icons\' visible edge inset');
});

test('Accordion List\'s header and body text columns align from the same derived geometry', () => {
  const accordionSrc = read(ACCORDION_LIST_PATH);
  const indentMatch = accordionSrc.match(/(?:headerTextIndent|bodyTextIndent|textColumnIndent)\s*=\s*([^;\n]+)/);
  assert.ok(indentMatch, 'expected a single derived indent value shared by the header and body text columns');
  assert.match(accordionSrc, /AVATAR_SIZE\.small\s*\+\s*DS_SPACING\[600\]/, 'expected the shared indent to derive from the same AVATAR_SIZE.small + DS_SPACING[600] geometry already used for the header chevron column');
});

// ─── Manifest/metadata completeness (DSR2-XX): every affected entry carries a complete decision
// contract, and every cited source path actually exists in the repository ─────────────────────────

test('every entry affected by Round 2 (Text Input, Transcript Log Row, Composer, Composer Toolbar, Hermes Popover Menu, Hermes Selection Sheet, Hermes Toast) declares nonempty useWhen/avoidWhen/alternatives/adoptionStatus and accessibility guidance', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  for (const id of ['Text Input', 'Transcript Log Row', 'Composer', 'Composer Toolbar', 'Hermes Popover Menu', 'Hermes Selection Sheet', 'Hermes Toast']) {
    const section = extractHermesSection(sectionsSrc, id);
    const ref = extractHermesReferenceBlock(section);
    assert.match(ref, /useWhen:\s*'[^']+'/, `expected "${id}" to declare a nonempty useWhen`);
    assert.match(ref, /avoidWhen:\s*'[^']+'/, `expected "${id}" to declare a nonempty avoidWhen`);
    const alts = extractAlternativeNames(ref);
    assert.ok(alts.length > 0, `expected "${id}" to declare at least one alternative`);
    assert.match(ref, /adoptionStatus:\s*\{/, `expected "${id}" to declare adoptionStatus`);
    assert.match(section, /a11y:|accessibility/i, `expected "${id}" to carry accessibility guidance`);
  }
});

test('every Round 2 source path cited by implementationNotes.sourcePaths actually exists in the repository', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  for (const id of ['Text Input', 'Transcript Log Row', 'Composer Toolbar']) {
    const section = extractHermesSection(sectionsSrc, id);
    const implementationNotes = extractBraceBlock(section, /implementationNotes:\s*\{/);
    const sourcePathsMatch = implementationNotes.match(/sourcePaths:\s*\[([\s\S]*?)\]/);
    assert.ok(sourcePathsMatch, `expected "${id}" to declare implementationNotes.sourcePaths`);
    const sourcePaths = [...sourcePathsMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
    assert.ok(sourcePaths.length > 0, `expected "${id}" to cite at least one source path`);
    for (const sourcePath of sourcePaths) {
      assert.ok(existsSync(path.join(ROOT, '..', sourcePath)), `expected cited source path "${sourcePath}" (from "${id}") to exist in the repository`);
    }
  }
});

test('the manifest builder and its schema remain unchanged — the new Round 2 sections are derived from the same human adoptionStatus data, not a duplicated constant or a new query/generated tool', () => {
  const manifestSrc = read('native/catalog/manifest.ts');
  const typesSrc = read(TYPES_PATH);
  assert.match(manifestSrc, /export function buildComponentManifest/, 'expected the existing manifest builder to remain the single source of truth');
  assert.doesNotMatch(manifestSrc, /require\(['"]child_process['"]\)|execSync|spawnSync/, 'must not introduce new query/generated tooling into the manifest builder');
  assert.match(typesSrc, /adoptionStatus/, 'expected the manifest schema (types.ts) to remain referenced, not replaced');
});

// ─── README / WHEN_TO_USE guidance updates ──────────────────────────────────────────────────────

test('README.md and WHEN_TO_USE.md state the Round 2 guidance: Popover Menu is immediate-action-only with persistent selection routed to Selection Sheet, Text Input variants are Default/Password/Code, Transcript Log Row replaces Disclosure Row, Composer Toolbar is foundation-available with zero production adoption, and Composer Chip is documented inside Composer with no standalone HermexComposerChip', () => {
  const whenToUse = read('WHEN_TO_USE.md');
  assert.match(whenToUse, /immediate.action/i, 'expected WHEN_TO_USE.md to state Popover Menu is immediate-action-only');
  assert.match(whenToUse, /Selection Sheet/i, 'expected WHEN_TO_USE.md to route persistent selection to Selection Sheet or a dedicated sheet');
  assert.match(whenToUse, /Default.{0,5}Password.{0,5}Code|Default,? Password,? and Code/i, 'expected WHEN_TO_USE.md to state Text Input\'s Default/Password/Code variants');
  assert.match(whenToUse, /Transcript Log Row/i, 'expected WHEN_TO_USE.md to name Transcript Log Row as Disclosure Row\'s replacement');
  assert.match(whenToUse, /Composer Toolbar/i, 'expected WHEN_TO_USE.md to name Composer Toolbar as foundation-available with zero production adoption');
  assert.match(whenToUse, /Composer Chip/i, 'expected WHEN_TO_USE.md to document Composer Chip inside Composer');
  assert.doesNotMatch(whenToUse, /HermexComposerChip/, 'must not claim a standalone HermexComposerChip API exists');
  assert.doesNotMatch(whenToUse, /Disclosure Row/, 'the retired Disclosure Row must no longer be named as current guidance');
  assert.doesNotMatch(whenToUse, /Inline Reference Link/, 'the retired Inline Reference Link must no longer be named as current guidance');
});

// ─── DSR3-03 correction: the Round 2 per-card SupportingCard measured-overflow disclosure is fully
// removed — the Details inspector panel itself scrolls, so no individual section needs its own
// collapse/expand affordance any more. The catalog overview keeps its own separate, compact,
// collapsible Implementation notes path (HermesOverviewImplementationDetails/Disclosure), unaffected.

test('SupportingCard and its SUPPORTING_CARD_COLLAPSED_HEIGHT measured-overflow mechanism are fully removed from HermesReferenceDetails.tsx — the Details inspector panel itself scrolls, so no per-section card needs its own collapse/expand control', () => {
  const src = read(HERMES_REFERENCE_DETAILS_PATH);
  assert.doesNotMatch(src, /SupportingCard/);
  assert.doesNotMatch(src, /SUPPORTING_CARD_COLLAPSED_HEIGHT/);
  assert.doesNotMatch(src, /supportingRow|supportingCardNarrow/);
});

test('the catalog overview keeps its own separate, compact, collapsible Implementation notes path (HermesOverviewImplementationDetails/Disclosure) fully unaffected by the entry-level SupportingCard removal', () => {
  const src = read(HERMES_REFERENCE_DETAILS_PATH);
  assert.match(src, /export function HermesOverviewImplementationDetails/);
  const overviewBody = extractFunctionBody(src, 'HermesOverviewImplementationDetails');
  assert.match(overviewBody, /<Disclosure label="Implementation notes">/, 'expected the overview to keep its own separate, compact Disclosure path');
  assert.match(src, /accessibilityRole="button"/);
  assert.match(src, /accessibilityState=\{\{\s*expanded\s*\}\}/);
  assert.match(src, /aria-expanded=\{expanded\}/);
  assert.match(src, /<AnimatedChevron/);
});

// ─── DSR3-02/04: the Hermex main canvas — Variants/States/Screens (or Tokens for a token gallery),
// every specimen column capped at 402px with 16px padding ────────────────────────────────────────

test('DSR3-02/04: SectionBlock defines the exact Hermex main-canvas card labels, the 402px specimen-column cap, and its 16px (CATALOG_SPACE.lg) padding', () => {
  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  assert.match(sectionBlockSrc, /label: 'Variants'/);
  assert.match(sectionBlockSrc, /label: 'States'/);
  assert.match(sectionBlockSrc, /label: 'Screens'/);
  assert.match(sectionBlockSrc, /No production screens use this yet/);
  assert.match(sectionBlockSrc, /SPECIMEN_COLUMN_MAX_WIDTH\s*=\s*402/);
  assert.match(sectionBlockSrc, /padding:\s*CATALOG_SPACE\.lg/);
  const hermexBody = extractFunctionBody(sectionBlockSrc, 'HermexSectionCanvas');
  assert.match(
    hermexBody,
    /def\.render\s*\?\s*\(\s*<View style=\{\[styles\.specimenColumn,\s*styles\.renderSpecimenColumn,\s*!isNarrow\s*&&\s*styles\.renderSpecimenColumnWide\]\}>\s*\{def\.render\(\)\}\s*<\/View>/s,
    'expected render()-based Hermex galleries to use the same capped, padded specimen-column contract as itemized variants instead of filling the whole card, widening to two specimen columns on a wide viewport (#607)',
  );
  assert.doesNotMatch(sectionBlockSrc, /render\(\)-based entry[\s\S]{0,200}unconstrained by this cap/);
});

test('DSR3-02: the Hermex main canvas (HermexSectionCanvas) renders no Props or Accessibility card, while the retained template/framework routes (the exported SectionBlock function body) keep both', () => {
  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  const hermexBody = extractFunctionBody(sectionBlockSrc, 'HermexSectionCanvas');
  assert.doesNotMatch(hermexBody, /label: 'Props'/);
  assert.doesNotMatch(hermexBody, /label: 'Accessibility'/);

  const generalBody = extractFunctionBody(sectionBlockSrc, 'SectionBlock');
  assert.match(generalBody, /label: 'Props'/);
  assert.match(generalBody, /label: 'Accessibility'/);
});

test('DSR3-02: the Hermex main canvas\'s Screens card renders only destination.screen and destination.path — never destination.effect, a screenshot, a catalog/DEBUG fixture, or a hypothetical destination', () => {
  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  const screensBody = extractFunctionBody(sectionBlockSrc, 'ScreensContent');
  assert.match(screensBody, /destination\.screen/);
  assert.match(screensBody, /destination\.path/);
  assert.doesNotMatch(screensBody, /destination\.effect/);
  assert.doesNotMatch(screensBody, /screenshot|DEBUG fixture/i);
  assert.match(screensBody, /No production screens use this yet/, 'expected the exact approved empty copy, with no trailing period');
  assert.doesNotMatch(screensBody, /No production screens use this yet\./, 'the approved empty copy has no trailing period');
});

test('DSR3-02: foundation-only Hermes Card exposes no production Screens destinations', () => {
  const section = extractHermesSection(read(HERMES_SECTIONS_PATH), 'Hermes Card');
  const reference = extractHermesReferenceBlock(section);
  const usedIn = reference.match(/usedIn:\s*\[([\s\S]*?)\]/);

  assert.match(reference, /no production call site|no screen imports it yet/i);
  assert.ok(
    !usedIn || usedIn[1].trim() === '',
    'Hermes Card has zero production callers, so its Screens card must use the exact empty state rather than list analogous SectionCard/SettingsCard destinations',
  );
});

test('DSR3-02: a Hermex tokenGallery entry\'s main canvas renders only a Tokens card — no Variants, States, or Screens card at all', () => {
  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  const hermexBody = extractFunctionBody(sectionBlockSrc, 'HermexSectionCanvas');
  const tokenGalleryIdx = hermexBody.indexOf('if (def.tokenGallery)');
  assert.ok(tokenGalleryIdx > -1, 'expected an explicit def.tokenGallery branch in HermexSectionCanvas');
  const tokenGalleryReturnEnd = hermexBody.indexOf('\n  }', tokenGalleryIdx);
  const tokenGalleryBranch = hermexBody.slice(tokenGalleryIdx, tokenGalleryReturnEnd === -1 ? undefined : tokenGalleryReturnEnd);
  assert.doesNotMatch(tokenGalleryBranch, /label: 'Variants'|label: 'States'|label: 'Screens'|ScreensContent/);
  assert.match(tokenGalleryBranch, /fullWidthLabel\s*\?\?\s*'Tokens'/);
});

test('DSR3-02: the retained template/framework routes (CatalogExample.tsx, CatalogFrameworkExample.tsx) never set hermesReference, so they always render through the unchanged two-column SectionBlock path, never HermexSectionCanvas', () => {
  const templateSrc = read(CATALOG_EXAMPLE_PATH);
  assert.doesNotMatch(templateSrc, /hermesReference:/, 'the retained template route must not adopt hermesReference — that would divert it onto the Hermex-only main canvas');
});

// ─── DSR3-03: the single 600px Details inspector — CatalogShell owns one selected-section state and
// renders exactly one CatalogDetailsInspector; SectionBlock's Details button is its only trigger ───

test('CatalogDetailsInspector.tsx exports the exact required props type and function component', () => {
  const src = read('native/catalog/CatalogDetailsInspector.tsx');
  assert.match(src, /export interface CatalogDetailsInspectorProps\s*\{/);
  const propsMatch = src.match(/export interface CatalogDetailsInspectorProps\s*\{[\s\S]*?\n\}/);
  assert.ok(propsMatch, 'expected an exported CatalogDetailsInspectorProps interface');
  const propsBody = propsMatch[0];
  assert.match(propsBody, /visible:\s*boolean/);
  assert.match(propsBody, /title:\s*string/);
  assert.match(propsBody, /onDismiss:\s*\(\)\s*=>\s*void/);
  assert.match(propsBody, /children:\s*React\.ReactNode/);
  assert.match(src, /export function CatalogDetailsInspector\(/);
});

test('CatalogDetailsInspector uses a 600px desktop max width and the shared narrow-viewport breakpoint for its full-width fallback, aligned to the right edge as an overlay (never pushing/reflowing sibling content)', () => {
  const src = read('native/catalog/CatalogDetailsInspector.tsx');
  assert.match(src, /INSPECTOR_MAX_WIDTH\s*=\s*600/);
  assert.match(src, /maxWidth:\s*INSPECTOR_MAX_WIDTH/);
  assert.match(src, /width:\s*'100%'/, 'expected the panel to fill up to its own max width rather than a fixed 600px that never shrinks');
  assert.match(src, /useWindowDimensions\(\)/, 'expected the inspector to read the live viewport width');
  assert.match(src, /width\s*<\s*CATALOG_NARROW_BREAKPOINT/, 'expected the full-width fallback to activate at the shared narrow breakpoint, not only once the viewport is already narrower than 600px');
  assert.match(src, /isNarrow\s*&&\s*styles\.panelNarrow/, 'expected the narrow state to select an explicit full-width panel style');
  assert.match(src, /panelNarrow:\s*\{[^}]*maxWidth:\s*'100%'/s, 'expected the narrow style to remove the 600px desktop cap');
  assert.match(src, /justifyContent:\s*'flex-end'/, 'expected the panel to align to the trailing/right edge of its absolutely-positioned overlay root');
  assert.match(src, /StyleSheet\.absoluteFill/, 'expected the overlay root to be an absolutely-positioned fill, never a layout participant that could push sibling content');
  assert.match(src, /root:\s*\{[^}]*overflow:\s*'hidden'/s, 'expected the overlay root to clip the panel\'s translated enter/exit position so motion never creates page-level horizontal overflow');
});

test('CatalogDetailsInspector renders a backdrop that dismisses on press, a visible Close button, and an Escape keydown listener, all wired to onDismiss', () => {
  const src = read('native/catalog/CatalogDetailsInspector.tsx');
  assert.match(src, /onPress=\{onDismiss\}[\s\S]{0,80}accessibilityLabel="Dismiss"|accessibilityLabel="Dismiss"[\s\S]{0,80}onPress=\{onDismiss\}/);
  assert.match(src, /accessibilityLabel="Close"/);
  assert.match(src, /onPress=\{onDismiss\}/);
  assert.match(src, /event\.key === 'Escape'/);
  assert.match(src, /onDismiss\(\)/);
});

test('CatalogDetailsInspector saves the triggering element\'s focus, focuses its own heading on open, traps Tab within the panel while open, and restores the saved focus on close', () => {
  const src = read('native/catalog/CatalogDetailsInspector.tsx');
  assert.match(src, /previouslyFocused/);
  assert.match(src, /document\.activeElement/);
  assert.match(src, /headingRef/);
  assert.match(src, /!visible\s*\|\|\s*!mounted/, 'expected initial focus to wait until the inspector content is mounted');
  assert.match(src, /\[visible,\s*mounted,\s*onDismiss\]/, 'expected the focus effect to rerun when mounted becomes true');
  assert.match(src, /event\.key !== 'Tab'/);
  assert.match(src, /FOCUSABLE_SELECTOR/);
  assert.match(src, /previouslyFocused\.current\?\.focus\?\.\(\)/, 'expected focus to be restored to the saved trigger on close');
});

test('CatalogDetailsInspector Tab trap redirects focus back into the panel when focus sits outside its own focusable sequence (e.g. the programmatically focused heading, tabIndex -1), not just when it exactly matches the first/last focusable element', () => {
  const src = read('native/catalog/CatalogDetailsInspector.tsx');
  assert.match(
    src,
    /!active\s*\|\|\s*!focusable\.includes\(active\)/,
    'expected the Tab handler to detect focus sitting outside the panel\'s own focusable sequence, not just compare against first/last',
  );
  assert.match(
    src,
    /\(event\.shiftKey\s*\?\s*last\s*:\s*first\)\.focus\(\)/,
    'expected Tab/Shift+Tab from outside the focusable sequence to redirect into the panel, honoring direction',
  );
});

test('CatalogDetailsInspector uses the existing Design System motion tokens (DS_MOTION_DURATION/DS_MOTION_EASING) for its enter/exit transition, and drops the spatial transform to an opacity-only change under Reduce Motion', () => {
  const src = read('native/catalog/CatalogDetailsInspector.tsx');
  assert.match(src, /import\s*\{\s*DS_MOTION_DURATION,\s*DS_MOTION_EASING\s*\}\s*from\s*'\.\.\/\.\.\/tokens'/);
  assert.match(src, /if\s*\(!mounted\)\s*return;/, 'expected animation to start only after the inspector is mounted');
  assert.match(src, /\[visible,\s*mounted,\s*progress,\s*reduceMotion\]/, 'expected enter and exit animation to rerun for visible changes on the mounted surface');
  assert.match(src, /const exitDuration\s*=\s*reduceMotion\s*\?\s*0\s*:\s*DS_MOTION_DURATION\.fast/);
  assert.match(src, /setTimeout\(\(\)\s*=>\s*setMounted\(false\),\s*exitDuration\)/, 'expected a token-timed fallback to remove the hidden dialog from the DOM/accessibility tree when RN Web does not deliver Animated.timing\'s finished callback');
  assert.match(src, /clearTimeout\(timeout\)/);
  assert.match(src, /reduceMotion\s*\?\s*\[\]\s*:\s*\[\{\s*translateX\s*\}\]/, 'expected Reduce Motion to drop the translateX transform, keeping only the opacity change');
  assert.match(src, /AccessibilityInfo\.isReduceMotionEnabled/);
});

test('CatalogDetailsInspector introduces no tabs, nested drawer, portal, or new third-party dependency', () => {
  const src = read('native/catalog/CatalogDetailsInspector.tsx');
  assert.doesNotMatch(src, /<Modal\b|from 'react-native'\s*;\s*\n[\s\S]*\bModal\b/, 'expected a plain absolutely-positioned overlay, never a rendered React Native Modal');
  assert.doesNotMatch(src, /\btabs\b|Tab\.Navigator|TabView/i);
  const importSources = [...src.matchAll(/from '([^']+)'/g)].map((m) => m[1]);
  for (const source of importSources) {
    assert.ok(
      source === 'react' || source === 'react-native' || source.startsWith('.'),
      `expected only relative and react/react-native imports — no new third-party dependency (found "${source}")`,
    );
  }
});

test('CatalogShell owns exactly one selected-details state and renders exactly one CatalogDetailsInspector; SectionBlock\'s Details button is its only entry point — no per-card button, sticky handle, tabs, or second inspector mechanism', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  assert.match(shellSrc, /import\s*\{\s*CatalogDetailsInspector\s*\}\s*from\s*'\.\/CatalogDetailsInspector'/);
  assert.match(shellSrc, /useState<SectionDef<TId>\s*\|\s*null>\(null\)/);
  const inspectorUsages = [...shellSrc.matchAll(/<CatalogDetailsInspector/g)];
  assert.strictEqual(inspectorUsages.length, 1, 'expected exactly one CatalogDetailsInspector instance');
  assert.doesNotMatch(shellSrc, /StickyHandle|TabView|Tab\.Navigator/);

  const sectionBlockSrc = read(SECTION_BLOCK_PATH);
  const detailsButtonUsages = [...sectionBlockSrc.matchAll(/<HermexDetailsButton/g)];
  assert.strictEqual(detailsButtonUsages.length, 1, 'expected exactly one Details button call site inside HermexSectionCanvas, not one per card');
});

test('CatalogShell passes onOpenDetails to SectionBlock only for a Hermex reference entry, and makes the underlying catalog pointer-inert and accessibility-hidden while the inspector is open', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  assert.match(shellSrc, /onOpenDetails=\{def\.hermesReference\s*\?\s*handleOpenDetails\s*:\s*undefined\}/);
  assert.match(shellSrc, /pointerEvents=\{selectedDetails\s*\?\s*'none'\s*:\s*'auto'\}/);
  assert.match(shellSrc, /aria-hidden=\{selectedDetails\s*!=\s*null\}/);
  assert.match(shellSrc, /importantForAccessibility=\{selectedDetails\s*\?\s*'no-hide-descendants'\s*:\s*'auto'\}/);
});

test('DSR3-03: the Details inspector\'s flat content order (Use when, Avoid when, Alternatives, Props, Accessibility, Adoption status, Source, Implementation notes) is fed by CatalogShell from the exact same SectionDef/HermesReferenceMeta the main canvas reads — no duplicated catalog-only data record', () => {
  const shellSrc = read(CATALOG_SHELL_PATH);
  assert.match(shellSrc, /meta=\{selectedDetails\.hermesReference!\}/);
  assert.match(shellSrc, /props=\{selectedDetails\.props\}/);
});

// ─── Task 8: Catalog specimen/metadata/guidance parity for DSR3-01, 05, 06, 07, 08, 09, 10 ─────────

test('Issue #607 round 3/4: the Composer Toolbar gallery reconstruction uses 24px radius and 8px all-around padding (not the superseded 12px radius / 16px padding) and demonstrates an explicit 24px vertical divider specimen', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const elevatedStyleMatch = previewsSrc.match(/composerToolbarElevated:\s*\{[^}]*\}/);
  assert.ok(elevatedStyleMatch, 'expected a composerToolbarElevated style');
  assert.match(elevatedStyleMatch[0], /padding:\s*DS_SPACING\[400\]/, 'expected composerToolbarElevated.padding to use DS_SPACING[400] (8px, matching native HermesSpacing.s8)');
  assert.match(elevatedStyleMatch[0], /borderRadius:\s*DS_RADIUS\.large/, 'expected composerToolbarElevated.borderRadius to use DS_RADIUS.large (24px, matching native HermesRadius.r24)');
  assert.doesNotMatch(elevatedStyleMatch[0], /padding:\s*16\b/, 'the superseded 16px padding must be gone');
  assert.doesNotMatch(elevatedStyleMatch[0], /borderRadius:\s*12\b/, 'the superseded 12px radius must be gone');

  const galleryBody = extractFunctionBody(previewsSrc, 'ComposerToolbarFamilyGallery');
  assert.match(galleryBody, /Divider/, 'expected an explicit divider specimen inside the Composer Toolbar gallery');
  assert.match(previewsSrc, /composerToolbarDivider:\s*\{[^}]*height:\s*24\b/s, 'expected a 24px-tall vertical divider style, matching HermexComposerToolbarDivider\'s HermesSpacing.s24 visible height');
});

test('Issue #607: the Composer Toolbar gallery demonstrates mixed content — a display-only Tag/pill-like specimen alongside a real control — in the same toolbar row, not a button-only concept', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'ComposerToolbarFamilyGallery');
  assert.match(galleryBody, /name="Elevated — mixed content"/, 'expected a mixed-content specimen in the Composer Toolbar gallery');
  assert.match(galleryBody, /<TagSwatch\b/, 'expected the mixed-content specimen to include the display-only Tag reconstruction');
  assert.match(galleryBody, /<Button\b/, 'expected the mixed-content specimen to include a real control');
});

test('DSR3-07: List/ListItem demonstrates a rounded, non-scaling pressed reconstruction (ListItemMetrics.cornerRadius / rounded surface, no scaleEffect/transform: scale) alongside the normal state, plus standard/none content-inset guidance', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'ListItemFamilyGallery');
  assert.match(galleryBody, /[Pp]ressed/, 'expected a pressed-state specimen in the List/ListItem gallery');
  assert.doesNotMatch(previewsSrc, /scaleEffect|transform:\s*\[\{\s*scale/, 'DSR3-07 requires no spatial scale on the pressed treatment');
  assert.match(galleryBody, /\.standard|contentInset/i, 'expected standard/none content-inset guidance to be documented in the List/ListItem gallery');

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const listSection = extractHermesSection(sectionsSrc, 'List / ListItem');
  assert.match(listSection, /contentInset/, 'expected List/ListItem\'s catalog metadata (props) to document the new contentInset seam');
  assert.match(listSection, /\.standard/);
  assert.match(listSection, /\.none/);
});

test('DSR3-06: the Popover Menu reconstruction uses one 16px shell inset and does not stack a second horizontal inset on top of it', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /popoverSurfaceBelow:\s*\{[^}]*padding:\s*16\b[^}]*\}/s, 'expected the Popover surface to apply one 16px shell inset');
  assert.match(previewsSrc, /popoverSurfaceAbove:\s*\{[^}]*padding:\s*16\b[^}]*\}/s, 'expected the above-trigger Popover surface to apply the same 16px shell inset');
  assert.doesNotMatch(previewsSrc, /popoverList:\s*\{[^}]*padding:/s, 'the List wrapper itself must not add a second, stacking horizontal inset on top of the 16px shell inset');
});

test('DSR3-08: the Accordion List gallery demonstrates both a leading-present and a no-leading header specimen, and the reconstruction removes the leading column instead of leaving an empty avatar-width gap', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'AccordionListFamilyGallery');
  assert.match(galleryBody, /leading:\s*null/, 'expected a no-leading header specimen (leading: null)');
  assert.match(previewsSrc, /leading:\s*<Avatar/, 'expected the existing leading-present specimens to remain');

  const accordionSrc = read('native/components/AccordionList/AccordionList.tsx');
  assert.match(accordionSrc, /const hasLeading = header\.leading != null/, 'expected the reconstruction to detect whether a real leading view exists');
  assert.match(accordionSrc, /leading=\{\s*hasLeading\s*\?[^:]+:\s*undefined\s*\}/s, 'expected a no-leading header to omit the fixed avatar-width slot entirely');
  assert.match(accordionSrc, /hasLeading\s*&&\s*styles\.bodyRow/, 'expected no-leading body rows to omit the avatar-derived indentation');
  assert.match(accordionSrc, /hasLeading\s*\?\s*styles\.bodyDividerInset\s*:\s*styles\.bodyDividerInsetNoLeading/, 'expected no-leading body dividers to use only the row text inset');

  const swiftSrc = read('../HermesMobile/Features/Shared/AccordionList.swift');
  assert.match(swiftSrc, /bodyLeadingInset\s*=\s*hasHeaderLeading\s*\?[^:]+:\s*HermesSpacing\.s0/, 'expected native AccordionList to keep zero avatar-derived body indent on the no-leading initializer path');
});

test('DSR3-09: the Selection Sheet gallery demonstrates both a multi-select horizontal and a multi-select vertical footer specimen', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'SelectionSheetFamilyGallery');
  assert.match(galleryBody, /[Hh]orizontal/, 'expected a multi-select horizontal footer specimen');
  assert.match(galleryBody, /[Vv]ertical/, 'expected a multi-select vertical footer specimen');
  assert.match(previewsSrc, /SelectionSheetMultiHorizontalDemo|SelectionSheetMultiVerticalDemo|footerAxis/, 'expected the multi-select footer specimens to be named after the new footerAxis concept');
});

test('DSR3-05: the Dialog catalog reconstruction\'s dialogCard.gap is 16 (not the stale 12), and HermexDialog.swift\'s own HermexDialogMetrics.contentSpacing is verified as HermesSpacing.s16 for cross-language parity', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const dialogCardMatch = previewsSrc.match(/dialogCard:\s*\{[^}]*\}/);
  assert.ok(dialogCardMatch, 'expected a dialogCard style');
  assert.match(dialogCardMatch[0], /gap:\s*16\b/, 'expected dialogCard.gap to be 16');
  assert.doesNotMatch(dialogCardMatch[0], /gap:\s*12\b/, 'the stale 12px gap must be gone');

  const dialogSwiftSrc = read('../HermesMobile/Features/Shared/HermexDialog.swift');
  assert.match(dialogSwiftSrc, /static let contentSpacing:\s*CGFloat\s*=\s*HermesSpacing\.s16/, 'expected native HermexDialogMetrics.contentSpacing to remain HermesSpacing.s16 — the catalog reconstruction is the only Dialog code path Lane C\'s scope authorizes changing');
});

test('DSR3-10: Search retains its verified equal visible-edge insets and 44x44 clear target — this round makes no source change, only re-verifies it', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(previewsSrc, /searchField:\s*\{[^}]*paddingHorizontal:\s*12\b/s, 'expected Search\'s existing 12px horizontal padding (equal visible-edge inset) to remain unchanged');
  assert.match(previewsSrc, /searchClearTarget[\s\S]{0,400}minWidth:\s*44[\s\S]{0,80}minHeight:\s*44/, 'expected the existing 44x44 clear target to remain unchanged');
});

test('the metadata/README copy no longer describes three inline supporting cards or collapsed per-entry disclosures — it describes the Screens card and the 600px Details inspector instead', () => {
  const readme = read('README.md');
  assert.doesNotMatch(readme, /Decision & product context/);
  assert.doesNotMatch(readme, /collapsed behind its own disclosures/);
  assert.doesNotMatch(readme, /a "Where it appears" disclosure/);
  assert.match(readme, /Details inspector/);
  assert.match(readme, /600px/);
  assert.match(readme, /Screens/);

  const typesSrc = read(TYPES_PATH);
  assert.doesNotMatch(typesSrc, /disclosures/i);
});

// ─── DSR3-607 (round-3 correction): 40px specimen-grid gap, one shared CatalogSpecimenHeader
// (specimen name + anchored, non-modal per-specimen Details popover — distinct from the 600px modal
// CatalogDetailsInspector), and PreviewSpecimen's explicit name/details/fill API ───────────────────

const CATALOG_SPECIMEN_HEADER_PATH = 'native/catalog/CatalogSpecimenHeader.tsx';

test('DSR3-607: CatalogSpecimenHeader exists as the shared specimen name + anchored, non-modal Details popover primitive, capped at 320px and distinct from the 600px modal CatalogDetailsInspector', () => {
  assert.ok(existsSync(path.join(ROOT, CATALOG_SPECIMEN_HEADER_PATH)), 'expected native/catalog/CatalogSpecimenHeader.tsx to exist');
  const src = read(CATALOG_SPECIMEN_HEADER_PATH);
  assert.match(src, /export function CatalogSpecimenHeader/);
  assert.match(src, /maxWidth:\s*(?:POPOVER_MAX_WIDTH|320)/, 'expected the Details popover capped at 320px');
  assert.match(src, /POPOVER_MAX_WIDTH\s*=\s*320/);
  assert.doesNotMatch(src, /from\s+'\.\/CatalogDetailsInspector'/, 'must not import/reuse the section-level 600px modal inspector');
  assert.doesNotMatch(src, /<Modal\b/, 'must be a plain anchored overlay, never a modal sheet');
});

test('DSR3-607: CatalogSpecimenHeader renders no Details trigger when no details are supplied, toggles on a second trigger press, exposes an expanded accessibility state, and dismisses on Escape/outside-press while returning focus to the trigger', () => {
  const src = read(CATALOG_SPECIMEN_HEADER_PATH);
  assert.match(src, /details\s*!=\s*null\s*&&/, 'expected the Details button to render only when details are supplied');
  assert.match(src, /setOpen\(\(?\w*\)?\s*=>\s*!/, 'expected pressing the trigger again to toggle it closed');
  assert.match(src, /accessibilityState=\{\{\s*expanded:\s*open\s*\}\}/);
  assert.match(src, /aria-expanded=\{open\}/, 'expected an explicit aria-expanded, matching this repo\'s react-native-web escape-hatch convention (see ListItem/AccordionList)');
  assert.match(src, /key\s*[!=]==\s*'Escape'/, 'expected Escape to dismiss the open popover');
  assert.match(src, /addEventListener\('mousedown'/, 'expected outside-press dismissal via a document-level pointer listener');
  assert.match(src, /triggerRef[\s\S]{0,80}\.focus\?\.\(\)/, 'expected focus to return to the trigger on dismissal');
});

test('DSR3-607: tokens.ts exposes one shared 40px specimen-grid gap constant, resolving to the existing CATALOG_SPACE[\'3xl\'] step rather than a new magic number', () => {
  const src = read(TOKENS_PATH);
  assert.match(src, /CATALOG_SPECIMEN_GRID_GAP\s*=\s*CATALOG_SPACE\['3xl'\]/);
});

test('DSR3-607: SectionBlock\'s itemized specimen grid and HermesComponentFamiliesPreviews\' custom specimen grid both import and use the one shared 40px CATALOG_SPECIMEN_GRID_GAP constant', () => {
  const sectionSrc = read(SECTION_BLOCK_PATH);
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(sectionSrc, /import\s*\{[^}]*CATALOG_SPECIMEN_GRID_GAP[^}]*\}\s*from\s*'\.\/tokens'/);
  assert.match(sectionSrc, /exampleGrid:\s*\{[^}]*gap:\s*CATALOG_SPECIMEN_GRID_GAP[^}]*justifyContent:\s*'flex-start'/s);
  assert.match(previewsSrc, /import\s*\{[^}]*CATALOG_SPECIMEN_GRID_GAP[^}]*\}\s*from\s*'\.\.\/tokens'/);
  assert.match(previewsSrc, /specimenGrid:\s*\{[^}]*gap:\s*CATALOG_SPECIMEN_GRID_GAP[^}]*justifyContent:\s*'flex-start'/s);
});

test('DSR3-607: every ordinary specimen column stays capped at 402px and owns 16px internal padding, on both the itemized and custom specimen grids', () => {
  const sectionSrc = read(SECTION_BLOCK_PATH);
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(sectionSrc, /specimenColumn:\s*\{[^}]*maxWidth:\s*SPECIMEN_COLUMN_MAX_WIDTH[^}]*padding:\s*CATALOG_SPACE\.lg/s);
  assert.match(previewsSrc, /specimenGroup:\s*\{[^}]*maxWidth:\s*402[^}]*padding:\s*16/s);
});

test('DSR3-607: a block-level itemized specimen (itemsFill true, inside the Hermex specimen grid) stretches to its column\'s inner content width instead of shrink-wrapping', () => {
  const sectionSrc = read(SECTION_BLOCK_PATH);
  assert.match(sectionSrc, /exampleGridItemFill:\s*\{[^}]*alignItems:\s*'stretch'/s);
  assert.match(sectionSrc, /specimen\s*&&\s*slot\.itemsFill\s*\?\s*styles\.exampleGridItemFill\s*:\s*styles\.exampleGridItem/);
});

test('DSR3-607: PreviewSpecimen takes an explicit name, optional details, and an optional screen-fill flag instead of brittle child inspection, and both SlotItems and PreviewSpecimen render their name/Details through the one shared CatalogSpecimenHeader primitive', () => {
  const sectionSrc = read(SECTION_BLOCK_PATH);
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.match(sectionSrc, /import\s*\{\s*CatalogSpecimenHeader\s*\}\s*from\s*'\.\/CatalogSpecimenHeader'/);
  assert.match(sectionSrc, /<CatalogSpecimenHeader name=\{item\.name\} details=\{item\.description\}\s*\/>/);
  assert.match(previewsSrc, /import\s*\{\s*CatalogSpecimenHeader\s*\}\s*from\s*'\.\.\/CatalogSpecimenHeader'/);
  const specimenSignatureMatch = previewsSrc.match(/function PreviewSpecimen\(\{[\s\S]*?\}\)\s*\{/);
  assert.ok(specimenSignatureMatch, 'expected a PreviewSpecimen function declaration');
  const specimenSignature = specimenSignatureMatch[0];
  assert.match(specimenSignature, /name:\s*string/, 'expected an explicit required name prop');
  assert.match(specimenSignature, /details\?:/, 'expected an optional details prop');
  assert.match(specimenSignature, /fill\?:\s*boolean/, 'expected an optional screen-fill prop');
  const specimenFn = extractFunctionBody(previewsSrc, 'PreviewSpecimen');
  assert.match(specimenFn, /<CatalogSpecimenHeader/, 'expected PreviewSpecimen to render its header through the shared primitive');
  assert.doesNotMatch(specimenFn, /children\.toString\(\)|React\.Children\.(?:map|forEach|toArray)/, 'must not rely on brittle child inspection to derive a name/caption');
});

test('DSR3-607: VariantExample carries optional catalog-authored explanation metadata (rendered only via CatalogSpecimenHeader\'s Details popover) instead of inline caption text', () => {
  const typesSrc = read(TYPES_PATH);
  const variantExample = typesSrc.match(/export interface VariantExample\s*\{[\s\S]*?\n\}/);
  assert.ok(variantExample);
  assert.match(variantExample[0], /description\?:\s*React\.ReactNode/);
});

test('DSR3-607: the migrated Hermex custom-gallery specimens pass their catalog explanation copy through PreviewSpecimen\'s details prop instead of an inline caption Text sibling', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  for (const galleryName of [
    'SegmentedControlGallery', 'CheckboxFamilyGallery',
    'AttachmentTileGallery', 'BannerFamilyGallery', 'TopNavFamilyGallery', 'ComposerToolbarFamilyGallery',
    'ToastFamilyGallery',
  ]) {
    const gallery = extractFunctionBody(previewsSrc, galleryName);
    assert.doesNotMatch(gallery, /<Text style=\{preview\.caption\}>/, `${galleryName} should move its catalog explanation copy into PreviewSpecimen's details prop, not render it inline`);
  }
  // ListItemFamilyGallery keeps a couple of `preview.caption`-styled glyphs (a trailing "›" chevron,
  // a "✓" picker checkmark) — those are part of the rendered specimen content itself, not catalog
  // explanation, so only its own long explanatory paragraphs are required to have moved into details.
  const listItemGallery = extractFunctionBody(previewsSrc, 'ListItemFamilyGallery');
  assert.match(listItemGallery, /details=\{[\s\S]*?rendered by this generic RN component/, 'expected the standard-rows explanation inside details');
  assert.match(listItemGallery, /details=\{[\s\S]*?is not a separate family/, 'expected the picker-configuration explanation inside details');
  const searchGallery = extractFunctionBody(previewsSrc, 'SearchFamilyGallery');
  assert.match(searchGallery, /details=\{[\s\S]*?HermexSearchField/, 'expected the Search field\'s explanatory paragraph to move into details, while the live "Submitted N times" status stays inline');
  assert.match(searchGallery, /Submitted \{submitCount\} \{submitUnit\}/, 'expected the live submit-count status text to remain visible, not moved into Details');
  const selectionSheetGallery = extractFunctionBody(previewsSrc, 'SelectionSheetFamilyGallery');
  assert.match(selectionSheetGallery, /details=\{[\s\S]*?query binding/, 'expected Selection Sheet\'s explanatory paragraph to move into details');
});

test('DSR3-607: the composite Transcript Activity specimen keeps its single semantic flow (one PreviewSpecimen, one composed demo) while moving its own trailing catalog explanation into details', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const transcriptActivity = extractFunctionBody(previewsSrc, 'TranscriptActivityPreview');
  assert.match(transcriptActivity, /<PreviewSpecimen\s+name="Transcript Activity"/, 'expected the one composed specimen to keep an explicit name');
  assert.doesNotMatch(transcriptActivity, /<Text style=\{preview\.caption\}>\s*Domain ownership boundary preserved/, 'expected the trailing explanation to move into details, not render inline');
  assert.match(transcriptActivity, /Turn Summary Disclosure/, 'expected the composite\'s own structural sub-labels to remain visible — they are part of the specimen, not catalog explanation');
});

// ─── DSR3-607 round 3: specimen `name` values must stay a concise variant/state/configuration
// identifier — instructional, rationale, comparison, or behavioral-explanation copy belongs in the
// specimen's own `details`/`description`, never inline in the name rendered on the main gallery
// surface. This scans every itemized VariantExample `name` (hermesSections.tsx, identified by its
// preceding sibling `key:` field so unrelated `name:` entries — color swatches, token rows, PropDefs —
// are not swept in) and every custom PreviewSpecimen `name` (HermesComponentFamiliesPreviews.tsx,
// including the `AccordionSeparatorDemo` label folded into its templated name) against a fixed list of
// explanation-like phrases that have leaked into names in the past.
const SPECIMEN_NAME_FORBIDDEN_PHRASES = [
  'tap to',
  'interactive —',
  'consolidates',
  'shown when',
  'composition',
  'coverage',
  'rather than',
  'staged draft',
  'caller-owned',
  'minimum target',
  'past the 20-option threshold',
];

function assertNoForbiddenNamePhrases(names, sourceLabel) {
  for (const name of names) {
    const lower = name.toLowerCase();
    for (const phrase of SPECIMEN_NAME_FORBIDDEN_PHRASES) {
      assert.ok(
        !lower.includes(phrase),
        `${sourceLabel} name "${name}" contains explanation-like phrase "${phrase}" — move it into details/description, keep the name a concise identifier`,
      );
    }
  }
}

test('DSR3-607 round 3: every itemized VariantExample name in hermesSections.tsx stays a concise identifier, free of explanation-like phrases', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const names = [...sectionsSrc.matchAll(/key:\s*'[^']*',\s*name:\s*'([^']*)'/g)].map((m) => m[1]);
  assert.ok(names.length > 0, 'expected to find at least one itemized VariantExample name to check');
  assertNoForbiddenNamePhrases(names, 'hermesSections.tsx VariantExample');
});

test('DSR3-607 round 3: every custom PreviewSpecimen name in HermesComponentFamiliesPreviews.tsx stays a concise identifier, free of explanation-like phrases', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const names = [...previewsSrc.matchAll(/<PreviewSpecimen\s+name=(?:"([^"]*)"|\{`([^`]*)`\})/g)]
    .map((m) => m[1] ?? m[2]);
  assert.ok(names.length > 0, 'expected to find at least one PreviewSpecimen name to check');
  assertNoForbiddenNamePhrases(names, 'HermesComponentFamiliesPreviews.tsx PreviewSpecimen');
  // AccordionSeparatorDemo folds its own `label` prop into a templated PreviewSpecimen name
  // (`Separator style · ${label}`) — that label must stay concise too, since it renders inline.
  const separatorLabels = [...previewsSrc.matchAll(/<AccordionSeparatorDemo\s[\s\S]*?label="([^"]*)"/g)].map((m) => m[1]);
  assert.ok(separatorLabels.length > 0, 'expected to find at least one AccordionSeparatorDemo label to check');
  assertNoForbiddenNamePhrases(separatorLabels, 'HermesComponentFamiliesPreviews.tsx AccordionSeparatorDemo label');
});

test('DSR3-607 round 4: remaining long structural labels move their prop anatomy into Details and keep only the concise variant/state name inline', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);

  assert.doesNotMatch(sectionsSrc, /name:\s*'Clipped-ancestor fallback · inheritsClipping'/);
  assert.match(sectionsSrc, /name:\s*'Clipped ancestor'/);
  assert.match(sectionsSrc, /description:\s*'Clipped-ancestor fallback when inheritsClipping is true\.'/);

  assert.doesNotMatch(previewsSrc, /name="Standard navigation — leadingPrimary \+ center \+ trailingPrimary"/);
  assert.doesNotMatch(previewsSrc, /name="Modal \/ editor — labeled leadingPrimary \+ trailingPrimary"/);
  assert.doesNotMatch(previewsSrc, /name="Adaptive selected fill \(production HermexCheckbox\)"/);
  assert.match(previewsSrc, /name="Standard navigation"[\s\S]*?details=\{/);
  assert.match(previewsSrc, /name="Modal \/ editor"[\s\S]*?details=\{/);
  assert.match(previewsSrc, /name="Adaptive selected fill"[\s\S]*?details=\{/);
});

test('DSR3-607 round 4: screen-width Pending Request, Composer Toolbar, and Transcript Activity surfaces fill the specimen column inner width instead of preserving fixed preview widths', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);

  for (const styleName of ['prCard', 'prBlock', 'prField', 'prChoiceGlass', 'prChoiceOpaque']) {
    assert.match(
      sectionsSrc,
      new RegExp(`${styleName}:\\s*\\{[^}]*width:\\s*'100%'`, 's'),
      `${styleName} should fill the 402px specimen column minus its 16px padding`,
    );
  }

  assert.match(previewsSrc, /logRow:\s*\{[^}]*width:\s*'100%'/s);
  assert.doesNotMatch(previewsSrc, /maxWidth:\s*240/, 'the overflowing Composer Toolbar surface should fill its column; only its inner content should overflow');
  assert.doesNotMatch(previewsSrc, /<Card density="compact" style=\{\{ width:\s*240 \}\}>/);
  assert.match(previewsSrc, /composerToolbarOverflowContent:\s*\{[^}]*minWidth:\s*520[^}]*flexWrap:\s*'nowrap'/s);
  assert.match(previewsSrc, /name="Elevated — overflowing content"[\s\S]*?style=\{preview\.composerToolbarElevated\}[\s\S]*?style=\{\[preview\.row, preview\.composerToolbarOverflowContent\]\}/);
  assert.match(previewsSrc, /name="Transparent — inside Card"[\s\S]*?<Card density="compact" style=\{\{ width:\s*'100%' \}\}>/);
});

test('DSR3-607 round 4: an open specimen Details header raises its stacking context so the anchored popover stays readable above the specimen content it overlays', () => {
  const src = read(CATALOG_SPECIMEN_HEADER_PATH);
  assert.match(src, /style=\{\[styles\.root,\s*open\s*&&\s*styles\.rootOpen\]\}/);
  assert.match(src, /rootOpen:\s*\{[^}]*zIndex:\s*\d+/s);
});

// ─── Issue #607 Slice A: catalog-wide AI-readability completeness ───────────────────────────────
// Every one of the 37 Hermex entries must carry: a non-empty canonicalSymbols list, at least one
// Swift usageExample, explicit (possibly empty) compositionSlots/compositionConstraints, and either
// tokenFacts (Foundations) or machineConfigurations (any other render()-based entry with no
// data-driven variants/states) so the manifest never reports an empty behavioral surface.

const HERMES_FOUNDATIONS_IDS = [
  'Hermex Colors', 'Hermex Spacing', 'Hermex Typography', 'Hermex Font',
  'Hermex Motion', 'Hermex Radius & Geometry', 'Hermex Shadow', 'Hermex Iconography',
];

function allHermesSectionIds(src) {
  const ids = [...src.matchAll(/^ {2}\{\n {4}id: '([^']+)',/gm)].map((m) => m[1]);
  assert.equal(ids.length, 37, `expected exactly 37 Hermex catalog entries, found ${ids.length}`);
  return ids;
}

test('Issue #607 Slice A: types.ts declares HermesUsageExample, HermesMachineConfiguration, and HermesTokenFact, and HermesReferenceMeta exposes all four new structured fields', () => {
  const typesSrc = read(TYPES_PATH);
  assert.match(typesSrc, /export interface HermesUsageExample\s*\{[^}]*name:\s*string[^}]*language:\s*'swift'[^}]*code:\s*string/s);
  assert.match(typesSrc, /export interface HermesMachineConfiguration\s*\{[^}]*name:\s*string/s);
  assert.match(typesSrc, /export interface HermesTokenFact\s*\{[^}]*name:\s*string[^}]*value:\s*string/s);

  const metaMatch = typesSrc.match(/export interface HermesReferenceMeta\s*\{[\s\S]*?\n\}/);
  assert.ok(metaMatch, 'expected an exported HermesReferenceMeta interface');
  const meta = metaMatch[0];
  assert.match(meta, /canonicalSymbols\?:\s*string\[\]/);
  assert.match(meta, /usageExamples\?:\s*HermesUsageExample\[\]/);
  assert.match(meta, /machineConfigurations\?:\s*HermesMachineConfiguration\[\]/);
  assert.match(meta, /tokenFacts\?:\s*HermesTokenFact\[\]/);
});

test('Issue #607 Slice A: manifest.ts serializes canonicalSymbols, usageExamples, machineConfigurations, and tokenFacts through to plain JSON', () => {
  const manifestSrc = read('native/catalog/manifest.ts');
  assert.match(manifestSrc, /canonicalSymbols\?:\s*string\[\]/);
  assert.match(manifestSrc, /usageExamples\?:\s*HermesUsageExample\[\]/);
  assert.match(manifestSrc, /machineConfigurations\?:\s*HermesMachineConfiguration\[\]/);
  assert.match(manifestSrc, /tokenFacts\?:\s*HermesTokenFact\[\]/);
  assert.match(manifestSrc, /canonicalSymbols:\s*meta\.canonicalSymbols/);
  assert.match(manifestSrc, /usageExamples:\s*meta\.usageExamples/);
  assert.match(manifestSrc, /machineConfigurations:\s*meta\.machineConfigurations/);
  assert.match(manifestSrc, /tokenFacts:\s*meta\.tokenFacts/);
});

test('Issue #607 Slice A: exactly 37 Hermex entries exist, in the exact 8/1/1/23/4 Foundations/Materials/Native iOS/Components/Patterns group partition', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = allHermesSectionIds(src);

  const navMatch = src.match(/export const hermesNav:[\s\S]*?\n\];/);
  assert.ok(navMatch, 'expected an exported hermesNav');
  const groupBlocks = [...navMatch[0].matchAll(/label:\s*'([^']+)',[\s\S]*?ids:\s*\[([\s\S]*?)\],/g)];
  const countsByLabel = Object.fromEntries(
    groupBlocks.map(([, label, idsBlock]) => [label, [...idsBlock.matchAll(/'[^']+'/g)].length]),
  );
  assert.deepEqual(
    countsByLabel,
    { Foundations: 8, Materials: 1, 'Native iOS': 1, Components: 23, Patterns: 4 },
    'expected the exact 8/1/1/23/4 group partition',
  );
  const totalGrouped = Object.values(countsByLabel).reduce((a, b) => a + b, 0);
  assert.equal(totalGrouped, 37);
  assert.equal(ids.length, 37);
});

test('Issue #607 Slice A: every one of the 37 Hermex entries declares a non-empty canonicalSymbols list and at least one Swift usageExample', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = allHermesSectionIds(src);

  for (const id of ids) {
    const section = extractHermesSection(src, id);
    const ref = extractHermesReferenceBlock(section);

    const symbolsSrc = extractBracketBlock(ref, /canonicalSymbols:\s*\[/);
    const symbolNames = [...symbolsSrc.matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((m) => m[1]);
    assert.ok(symbolNames.length > 0, `expected "${id}"'s canonicalSymbols to be non-empty`);
    for (const name of symbolNames) {
      assert.ok(name.trim().length > 0, `expected "${id}"'s canonicalSymbols entries to be non-empty strings`);
    }

    const examplesSrc = extractBracketBlock(ref, /usageExamples:\s*\[/);
    const names = [...examplesSrc.matchAll(/name:\s*'([^']+)'/g)];
    assert.ok(names.length > 0, `expected "${id}" to declare at least one usageExamples entry with a name`);
    assert.match(examplesSrc, /language:\s*'swift'/, `expected "${id}"'s usageExamples to declare language: 'swift'`);
    assert.match(examplesSrc, /code:\s*`[^`]+`/, `expected "${id}"'s usageExamples to declare non-empty code`);
  }
});

test('Issue #607 Slice A: every one of the 37 Hermex entries declares explicit compositionSlots and compositionConstraints arrays (empty only for a genuinely atomic/token/native entry), with unique slot names and constraints that reference real slot names', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = allHermesSectionIds(src);

  for (const id of ids) {
    const section = extractHermesSection(src, id);
    const ref = extractHermesReferenceBlock(section);

    const slotsSrc = extractBracketBlock(ref, /compositionSlots:\s*\[/);
    const slotNames = [...slotsSrc.matchAll(/\{\s*name:\s*'([^']+)'/g)].map((m) => m[1]);
    const uniqueSlotNames = new Set(slotNames);
    assert.equal(slotNames.length, uniqueSlotNames.size, `expected "${id}"'s compositionSlots names to be unique, got [${slotNames.join(', ')}]`);

    const constraintsSrc = extractBracketBlock(ref, /compositionConstraints:\s*\[/);
    const constraintSlotNames = [...constraintsSrc.matchAll(/slots:\s*\[([^\]]*)\]/g)]
      .flatMap((m) => [...m[1].matchAll(/'([^']+)'/g)].map((mm) => mm[1]));
    for (const refName of constraintSlotNames) {
      assert.ok(uniqueSlotNames.has(refName), `expected "${id}"'s compositionConstraints to reference a real slot name, got "${refName}" not in [${slotNames.join(', ')}]`);
    }
  }
});

// Splits an array literal's inner source (as returned by extractBracketBlock) into its own
// top-level `{ ... }` object strings, tracking brace depth so a slot's own nested `layout: { ... }`
// object doesn't end the split early — the per-slot counterpart to extractBracketBlock itself.
function splitTopLevelObjects(arraySrc) {
  const objects = [];
  let depth = 0;
  let start = -1;
  for (let i = 0; i < arraySrc.length; i++) {
    const c = arraySrc[i];
    if (c === "'" || c === '"' || c === '`') {
      const quote = c;
      i += 1;
      while (i < arraySrc.length && arraySrc[i] !== quote) {
        if (arraySrc[i] === '\\') i += 1;
        i += 1;
      }
      continue;
    }
    if (c === '{') {
      if (depth === 0) start = i;
      depth += 1;
    } else if (c === '}') {
      depth -= 1;
      if (depth === 0) objects.push(arraySrc.slice(start, i + 1));
    }
  }
  return objects;
}

const HERMES_SLOT_ROLES = new Set([
  'leading-icon', 'leading-accessory', 'leading-action', 'inline-accessory', 'primary-text',
  'secondary-text', 'caption', 'metadata', 'body-content', 'header', 'center-content', 'footer',
  'trailing-action', 'trailing-accessory', 'trigger', 'surface-content',
]);
const HERMES_SLOT_PLACEMENTS = new Set(['component-fixed', 'caller-ordered']);
const HERMES_SLOT_AXES = new Set(['horizontal', 'vertical', 'none']);
const HERMES_SLOT_OVERFLOWS = new Set(['wrap', 'clip', 'scroll', 'truncate', 'not-applicable']);
const HERMES_SLOT_INTERACTION_OWNERSHIPS = new Set(['component-owned', 'child-owned', 'none']);
const HERMES_SLOT_ACCESSIBILITY_OWNERSHIPS = new Set(['component-owned', 'child-owned', 'combined-element']);

test('Issue #607 Slice B: every non-empty compositionSlots entry across all 37 Hermex entries declares a unique 0-based order, a role/overflow/interactionOwnership/accessibilityOwnership from their closed vocabularies, and a layout object with a valid placement/axis/position', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = allHermesSectionIds(src);

  let totalNonEmptySlotEntries = 0;
  let entriesWithNonEmptySlots = 0;

  for (const id of ids) {
    const section = extractHermesSection(src, id);
    const ref = extractHermesReferenceBlock(section);
    const slotsSrc = extractBracketBlock(ref, /compositionSlots:\s*\[/);
    const slotObjects = splitTopLevelObjects(slotsSrc);
    if (slotObjects.length === 0) continue;
    entriesWithNonEmptySlots += 1;

    const orders = [];
    for (const slotSrc of slotObjects) {
      totalNonEmptySlotEntries += 1;
      const nameMatch = slotSrc.match(/name:\s*'([^']+)'/);
      const slotName = nameMatch ? nameMatch[1] : '<unknown>';
      const label = `"${id}".compositionSlots["${slotName}"]`;

      const orderMatch = slotSrc.match(/order:\s*(\d+)/);
      assert.ok(orderMatch, `expected ${label} to declare a numeric order`);
      orders.push(Number(orderMatch[1]));

      const roleMatch = slotSrc.match(/role:\s*'([^']+)'/);
      assert.ok(roleMatch, `expected ${label} to declare a role`);
      assert.ok(HERMES_SLOT_ROLES.has(roleMatch[1]), `expected ${label}'s role "${roleMatch[1]}" to be in the closed HermesCompositionSlotRole vocabulary`);

      const overflowMatch = slotSrc.match(/overflow:\s*'([^']+)'/);
      assert.ok(overflowMatch, `expected ${label} to declare overflow`);
      assert.ok(HERMES_SLOT_OVERFLOWS.has(overflowMatch[1]), `expected ${label}'s overflow "${overflowMatch[1]}" to be in the closed HermesCompositionOverflow vocabulary`);

      const interactionMatch = slotSrc.match(/interactionOwnership:\s*'([^']+)'/);
      assert.ok(interactionMatch, `expected ${label} to declare interactionOwnership`);
      assert.ok(HERMES_SLOT_INTERACTION_OWNERSHIPS.has(interactionMatch[1]), `expected ${label}'s interactionOwnership "${interactionMatch[1]}" to be in the closed vocabulary`);

      const accessibilityMatch = slotSrc.match(/accessibilityOwnership:\s*'([^']+)'/);
      assert.ok(accessibilityMatch, `expected ${label} to declare accessibilityOwnership`);
      assert.ok(HERMES_SLOT_ACCESSIBILITY_OWNERSHIPS.has(accessibilityMatch[1]), `expected ${label}'s accessibilityOwnership "${accessibilityMatch[1]}" to be in the closed vocabulary`);

      const layoutMatch = slotSrc.match(/layout:\s*\{([^}]*)\}/);
      assert.ok(layoutMatch, `expected ${label} to declare a layout object`);
      const layoutSrc = layoutMatch[1];
      const placementMatch = layoutSrc.match(/placement:\s*'([^']+)'/);
      assert.ok(placementMatch && HERMES_SLOT_PLACEMENTS.has(placementMatch[1]), `expected ${label}'s layout.placement to be in the closed vocabulary`);
      const axisMatch = layoutSrc.match(/axis:\s*'([^']+)'/);
      assert.ok(axisMatch && HERMES_SLOT_AXES.has(axisMatch[1]), `expected ${label}'s layout.axis to be in the closed vocabulary`);
      const positionMatch = layoutSrc.match(/position:\s*(?:'([^']+)'|"([^"]+)")/);
      assert.ok(positionMatch && (positionMatch[1] ?? positionMatch[2]).trim().length > 0, `expected ${label}'s layout.position to be a non-empty string`);
    }

    const uniqueOrders = new Set(orders);
    assert.equal(orders.length, uniqueOrders.size, `expected "${id}"'s compositionSlots order values to be unique, got [${orders.join(', ')}]`);
    const sorted = [...orders].sort((a, b) => a - b);
    assert.deepEqual(sorted, orders.map((_, i) => i).length === orders.length ? [...Array(orders.length).keys()] : sorted, `expected "${id}"'s compositionSlots order values to be a stable 0-based sequence, got [${orders.join(', ')}]`);
  }

  assert.ok(entriesWithNonEmptySlots > 0, 'expected at least one entry with non-empty compositionSlots to exercise this test');
  assert.ok(totalNonEmptySlotEntries > 0, 'expected at least one compositionSlots entry to exercise this test');
});

test('Issue #607 Slice B: every one of the 37 Hermex entries declares non-empty implementationNotes.sourcePaths, and every cited path exists in the repository (resolved repo-root-relative, or catalog-relative for a "native/..." catalog reconstruction path)', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = allHermesSectionIds(src);
  const REPO_ROOT = path.join(ROOT, '..');

  for (const id of ids) {
    const section = extractHermesSection(src, id);
    const ref = extractHermesReferenceBlock(section);
    const notes = extractBraceBlock(ref, /implementationNotes:\s*\{/);
    const sourcePathsMatch = notes.match(/sourcePaths:\s*\[([\s\S]*?)\]/);
    assert.ok(sourcePathsMatch, `expected "${id}" to declare implementationNotes.sourcePaths`);
    const sourcePaths = [...sourcePathsMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
    assert.ok(sourcePaths.length > 0, `expected "${id}" to cite at least one source path`);
    for (const sourcePath of sourcePaths) {
      const resolved = sourcePath.startsWith('native/') ? path.join(ROOT, sourcePath) : path.join(REPO_ROOT, sourcePath);
      assert.ok(existsSync(resolved), `expected cited source path "${sourcePath}" (from "${id}") to exist in the repository`);
    }
  }
});

// ─── Issue #607 AI-readability semantic-accuracy correction ─────────────────────────────────────
// A canonical symbol or Swift usage example that names or calls something absent from the entry's
// own cited Swift source is worse than no guidance at all — it sends an agent chasing a symbol or
// call shape that will not compile. These two contracts catch that error class directly: every
// canonicalSymbols entry must resolve to a real declaration in its own entry's cited Swift source
// (or a short, individually reviewed platform-API exception below), and a short, explicit denylist
// of the fabricated symbols/call shapes found in the semantic-accuracy audit must never reappear.

// Real Apple-framework APIs a Hermex component composes but does not itself declare — reviewed
// individually, not a general escape hatch. Each is the exact canonicalSymbols string the one entry
// below declares for a documented platform modifier.
const HERMES_CANONICAL_SYMBOL_PLATFORM_EXCEPTIONS = new Set([
  '.popover(isPresented:)', // Hermes Tooltip: native SwiftUI presentation modifier, not a Hermex declaration.
]);

// Strips a canonicalSymbols string down to the bare identifiers a declaration search can match:
// drops a leading `.` (callable modifier/property syntax), truncates at the first `(` (parameter
// labels aren't declaration text — `appFont(role:)` and `appFont(_:)` strip to the same `appFont`),
// and splits a dotted nested-type/member path (`AppFont.Role`) into segments.
function normalizeCanonicalSymbol(raw) {
  let s = raw.startsWith('.') ? raw.slice(1) : raw;
  const parenIdx = s.indexOf('(');
  if (parenIdx !== -1) s = s.slice(0, parenIdx);
  return s.split('.').filter(Boolean);
}

// A segment is "declared" when the concatenated cited Swift source contains a declaration keyword
// immediately before it — how Swift actually introduces a name — rather than merely containing the
// word somewhere (a comment, a string, or another symbol's name as a substring).
function canonicalSymbolSegmentIsDeclared(segment, swiftSource) {
  const declarationPattern = new RegExp(`\\b(?:struct|class|enum|protocol|func|case|let|var)\\s+${segment}\\b`);
  return declarationPattern.test(swiftSource);
}

test('Issue #607 AI-readability correction: every canonicalSymbols entry resolves to a real declaration in its own entry\'s cited Swift source, or is a reviewed platform-API exception', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = allHermesSectionIds(src);
  const REPO_ROOT = path.join(ROOT, '..');

  let totalSymbols = 0;
  let totalExceptions = 0;

  for (const id of ids) {
    const section = extractHermesSection(src, id);
    const ref = extractHermesReferenceBlock(section);

    const notes = extractBraceBlock(ref, /implementationNotes:\s*\{/);
    const sourcePathsMatch = notes.match(/sourcePaths:\s*\[([\s\S]*?)\]/);
    const sourcePaths = sourcePathsMatch ? [...sourcePathsMatch[1].matchAll(/'([^']+)'/g)].map((m) => m[1]) : [];
    const swiftSourcePaths = sourcePaths.filter((p) => p.endsWith('.swift'));
    const swiftSource = swiftSourcePaths.map((p) => readFileSync(path.join(REPO_ROOT, p), 'utf8')).join('\n');

    const symbolsSrc = extractBracketBlock(ref, /canonicalSymbols:\s*\[/);
    const symbolNames = [...symbolsSrc.matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((m) => m[1]);

    for (const rawSymbol of symbolNames) {
      totalSymbols += 1;
      if (HERMES_CANONICAL_SYMBOL_PLATFORM_EXCEPTIONS.has(rawSymbol)) {
        totalExceptions += 1;
        continue;
      }
      assert.ok(swiftSourcePaths.length > 0, `expected "${id}" to cite at least one .swift source path to resolve canonicalSymbols against`);

      const segments = normalizeCanonicalSymbol(rawSymbol);
      assert.ok(segments.length > 0, `expected "${id}"'s canonicalSymbols entry "${rawSymbol}" to normalize to at least one identifier segment`);
      assert.ok(
        canonicalSymbolSegmentIsDeclared(segments[0], swiftSource),
        `expected "${id}"'s canonicalSymbols entry "${rawSymbol}" (base identifier "${segments[0]}") to resolve to a real declaration in its cited Swift source [${swiftSourcePaths.join(', ')}] — a filename or concept is not a Swift symbol`,
      );
      for (const nested of segments.slice(1)) {
        assert.ok(
          new RegExp(`\\b${nested}\\b`).test(swiftSource),
          `expected "${id}"'s canonicalSymbols entry "${rawSymbol}"'s nested/member segment "${nested}" to appear in its cited Swift source`,
        );
      }
    }
  }

  assert.ok(totalSymbols > 0, 'expected at least one canonicalSymbols entry to exercise this test');
  assert.ok(totalExceptions <= 1, 'expected the reviewed platform-API exception set to stay small and explicit, not grow into a general escape hatch');
});

test('Issue #607 AI-readability correction: known fabricated Swift symbols and call shapes from the semantic-accuracy audit never reappear in the catalog', () => {
  const src = read(HERMES_SECTIONS_PATH);

  // Each entry is a verbatim snippet from the pre-correction catalog, confirmed fabricated against
  // its own cited Swift source during the Issue #607 semantic-accuracy audit (wrong argument label,
  // a type that does not exist, or a member that does not exist on the named type).
  const FORBIDDEN_SNIPPETS = [
    '.appFont(role:',                                   // real modifier is `.appFont(_:)` — no `role:` label.
    'AttachmentTile(',                                  // no such type; AttachmentTile.swift declares AttachmentFileGlyph/AttachmentFileBadge/etc.
    "'AttachmentTile'",
    'SkeletonPlaceholder(',                             // the real View type is `Skeleton`; `.skeletonPlaceholder()` is the modifier.
    "'SkeletonPlaceholder'",
    'HermexCard(',                                      // no such type; the real API is the `.hermexCardSurface(_:cornerRadius:)` modifier.
    'variant: .neutral',                                // HermexBanner's first parameter is positional `_ semantic: Semantic`, case `.offline`.
    'checked: isChecked',                               // HermexCheckbox's property is `isChecked`, not `checked`.
    'HermexBottomSheet(title:',                          // HermexBottomSheet's first parameter is positional `_ title:`.
    'HeaderLogoColor(hex:',                              // HeaderLogoColor is an enum namespace, not an initializable type; use `.color(for:)`.
    '.hermexSearch(title:',                              // real modifier is `.hermexSearch(_:text:prompt:isEnabled:onSubmit:)`.
    'TranscriptTurnFolding\'',                           // no such type; TranscriptTurnFolding.swift declares TranscriptTurnFolds et al.
    'ComposerChipRendering.image(for:',                  // real signature is `.image(label:icon:metrics:traits:isRightToLeft:usesAccentIcon:)`.
    '.modifier(AdaptiveGlassModifier(',                  // private type; the public API is the `.adaptiveGlass(...)` modifier function.
    "'AdaptiveGlassModifier'",                           // private type must not be listed as a canonical (externally constructible) symbol.
    'HermesShadow.controlElevatedResting.lightOpacity',  // HermesShadow is an enum case; `.lightOpacity`/`.radius`/`.y` only exist on `.resolved(for:)`.
    'HermexCardColors.standardBorder',                   // retired by DSR2-01; border roles live on the shared HermexSurfaceBorderColors.resting/.increasedContrast.
    'HermexCardColors.increasedContrastBorder',          // retired by DSR2-01; border roles live on the shared HermexSurfaceBorderColors.resting/.increasedContrast.
    "'ServerAvatarBadge'",                               // private struct (SettingsView.swift); must not be listed as a canonical (externally constructible) symbol.
  ];

  for (const needle of FORBIDDEN_SNIPPETS) {
    assert.ok(!src.includes(needle), `expected the known-fabricated snippet ${JSON.stringify(needle)} to never reappear in hermesSections.tsx`);
  }
});

// ─── Issue #607 Slice B: generated checked-in manifest ──────────────────────────────────────────

const HERMEX_MANIFEST_PATH = 'hermex-manifest.json';
const GENERATE_MANIFEST_SCRIPT_PATH = 'scripts/generate-hermex-manifest.mjs';

test('Issue #607 Slice B: README.md and WHEN_TO_USE.md document the generated manifest, its freshness check, and the design-system-guide lookup/select/receipt commands', () => {
  const readme = read('README.md');
  const whenToUse = read('WHEN_TO_USE.md');
  for (const doc of [readme, whenToUse]) {
    assert.match(doc, /hermex-manifest\.json/, 'expected the doc to name the generated manifest file');
    assert.match(doc, /generate-hermex-manifest\.mjs/, 'expected the doc to name the generator script');
    assert.match(doc, /design-system-guide/, 'expected the doc to name the lookup/receipt CLI');
  }
  assert.match(whenToUse, /receipt/, 'expected WHEN_TO_USE.md to document the receipt subcommand');
});

test('Issue #607 Slice B: hermex-manifest.json exists, is fresh (matches `generate-hermex-manifest.mjs --check`), and is byte-stable across repeated checks', () => {
  assert.ok(existsSync(path.join(ROOT, GENERATE_MANIFEST_SCRIPT_PATH)), 'expected the manifest generator script to exist');
  assert.ok(existsSync(path.join(ROOT, HERMEX_MANIFEST_PATH)), 'expected the checked-in hermex-manifest.json to exist');

  const before = read(HERMEX_MANIFEST_PATH);
  const run = () => execFileSync(process.execPath, [GENERATE_MANIFEST_SCRIPT_PATH, '--check'], { cwd: ROOT, encoding: 'utf8' });
  assert.doesNotThrow(() => run(), 'expected `--check` to pass against the checked-in manifest');
  assert.doesNotThrow(() => run(), 'expected a second `--check` run to also pass, proving `--check` never mutates the file');
  const after = read(HERMEX_MANIFEST_PATH);
  assert.equal(after, before, 'expected hermex-manifest.json bytes to stay unchanged across repeated --check runs');
});

test('Issue #607 Slice B: hermex-manifest.json is a versioned envelope with the exact 37-entry / 8-1-1-23-4 category parity, two-space indentation, and a trailing newline', () => {
  const raw = read(HERMEX_MANIFEST_PATH);
  assert.ok(raw.endsWith('\n') && !raw.endsWith('\n\n'), 'expected exactly one trailing newline');
  assert.doesNotMatch(raw, /\t/, 'expected two-space indentation, not tabs');

  const envelope = JSON.parse(raw);
  assert.equal(envelope.schemaVersion, 1);
  assert.equal(envelope.runtime.productionRuntime, 'swiftui');
  assert.equal(envelope.runtime.catalogRuntime, 'react-native-documentation-reconstruction');
  assert.equal(envelope.entries.length, 37);

  const countsByCategory = {};
  for (const entry of envelope.entries) countsByCategory[entry.category] = (countsByCategory[entry.category] ?? 0) + 1;
  assert.deepEqual(countsByCategory, { Foundations: 8, Materials: 1, 'Native iOS': 1, Components: 23, Patterns: 4 });

  for (const entry of envelope.entries) {
    assert.ok(entry.displayName && entry.displayName.length > 0, `expected "${entry.id}" to carry a non-empty displayName`);
  }
});

test('Issue #607 Slice B: hermex-manifest.json is generated from the live hermesSections/hermesNav source, not a hand-maintained duplicate — generate-hermex-manifest.mjs requires the real hermesSections.tsx/manifest.ts exports rather than re-parsing or re-declaring the catalog data', () => {
  const generatorSrc = read(GENERATE_MANIFEST_SCRIPT_PATH);
  assert.match(generatorSrc, /hermesSections\.tsx/);
  assert.match(generatorSrc, /manifest\.ts/);
  assert.match(generatorSrc, /buildHermesManifestEnvelope/);
  assert.doesNotMatch(generatorSrc, /JSON\.parse\(.*hermesSections/, 'expected the generator to require() the real module, not parse its source text');
});

test('Issue #607 Slice B: the manifest generator stubs React and its JSX runtime as well as React Native, so CI freshness checking does not depend on the later gitignored design-system-catalog/node_modules symlink', () => {
  const generatorSrc = read(GENERATE_MANIFEST_SCRIPT_PATH);
  assert.match(
    generatorSrc,
    /STUBBED_PACKAGE_PREFIXES\s*=\s*\[[^\]]*'react'/s,
    'expected the metadata-only loader to intercept react and react/jsx-runtime before Node module resolution',
  );
  assert.match(generatorSrc, /'react-native'/, 'expected the existing React Native inert stub coverage to remain');
});

test('Issue #607 Slice A: every Foundations entry declares non-empty structured tokenFacts (name + value), reusing this catalog\'s own existing typed token data rather than a second hand-maintained catalogue', () => {
  const src = read(HERMES_SECTIONS_PATH);
  for (const id of HERMES_FOUNDATIONS_IDS) {
    const section = extractHermesSection(src, id);
    const ref = extractHermesReferenceBlock(section);
    const tokenFactsSrc = extractBracketBlock(ref, /tokenFacts:\s*\[/);
    const names = [...tokenFactsSrc.matchAll(/name:\s*/g)];
    assert.ok(names.length > 0, `expected "${id}" to declare at least one tokenFacts entry`);
    assert.match(tokenFactsSrc, /value:\s*/, `expected "${id}"'s tokenFacts entries to declare a value`);
  }
});

test('Issue #607 Slice A: every non-Foundations entry whose live catalog uses a custom render() function with no data-driven variants/states declares non-empty machineConfigurations, so the manifest never reports an empty behavioral surface', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = allHermesSectionIds(src);

  for (const id of ids) {
    if (HERMES_FOUNDATIONS_IDS.includes(id)) continue;
    const section = extractHermesSection(src, id);
    const hasRender = /\brender:\s*\(\)\s*=>/.test(section);
    const hasVariantsOrStates = /\n {4}variants:\s*\{/.test(section) || /\n {4}states:\s*\{/.test(section);
    if (!hasRender || hasVariantsOrStates) continue;

    const ref = extractHermesReferenceBlock(section);
    const configsSrc = extractBracketBlock(ref, /machineConfigurations:\s*\[/);
    const names = [...configsSrc.matchAll(/name:\s*'([^']+)'/g)];
    assert.ok(names.length > 0, `expected "${id}" to declare at least one non-empty machineConfigurations entry`);
  }
});

test('Issue #607 Slice A: every declared alternative name resolves to a current Hermex entry\'s own display name/id or an explicitly reviewed native-platform/current-production alternative', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ids = allHermesSectionIds(src);

  const displayNames = new Set();
  for (const id of ids) {
    const section = extractHermesSection(src, id);
    displayNames.add(id);
    const displayNameMatch = section.match(/^ {4}displayName:\s*'([^']+)',/m);
    if (displayNameMatch) displayNames.add(displayNameMatch[1]);
  }

  const REVIEWED_NATIVE_OR_PRODUCTION_PATTERN = /\(production\)$|^Native /;

  for (const id of ids) {
    const section = extractHermesSection(src, id);
    const ref = extractHermesReferenceBlock(section);
    const altNames = extractAlternativeNames(ref);
    for (const name of altNames) {
      assert.ok(
        displayNames.has(name) || REVIEWED_NATIVE_OR_PRODUCTION_PATTERN.test(name),
        `expected "${id}"'s alternative "${name}" to resolve to a current entry display name or an explicitly reviewed native/production alternative`,
      );
    }
  }
});

// ─── Issue #607 final catalog correction pass (controller-dispositioned content + visual fixes) ──
// Every test below pins one Fable content finding or one Opus visual finding from
// .codex-tmp/final-audits-20261001/{fable-content-audit,opus-visual-audit}.normalized.json. Grouped
// by entry, content first then visual, matching the controller's disposition list.

test('Correction (#607 final pass, Dialog): useWhen states the one-bounded-decision rule and avoidWhen routes a several-settings task to Bottom Sheet/Selection Sheet and anchored actions to Popover Menu', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Hermes Dialog'));

  assert.doesNotMatch(ref, /piece of information/, 'useWhen must no longer position Dialog as an information container');
  assert.match(ref, /\bone\b.{0,20}bounded decision|one decision/i, 'expected useWhen to state the one-bounded-decision rule');
  assert.match(ref, /Confirm\/Cancel|one or two choices|one or two actions/i, 'expected useWhen to allow exactly one or two choices for that one decision');

  assert.match(ref, /Bottom Sheet/, 'expected avoidWhen to route a several-settings task to Bottom Sheet');
  assert.match(ref, /Selection Sheet/, 'expected avoidWhen to route a several-settings task to Selection Sheet');
  assert.match(ref, /Popover Menu/, 'expected avoidWhen/alternatives to name Popover Menu for a short list of anchored actions');

  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Hermes Popover Menu') || alts.includes('Popover Menu'), 'expected Dialog to add Popover Menu as a structured alternative');
  assert.ok(alts.includes('Hermes Selection Sheet') || alts.includes('Selection Sheet'), 'expected Dialog to add Selection Sheet as a structured alternative');
});

test('Correction (#607 final pass, Bottom Sheet): useWhen states a real product job (short form, editable content, multi-option selection/configuration, or a longer scrolling flow), drops the confirmation-flow collision with Dialog, and names Dialog/Selection Sheet as alternatives', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Bottom Sheet');
  const ref = extractHermesReferenceBlock(section);

  assert.match(ref, /more than one decision/i, 'expected useWhen to state the more-than-one-decision product job');
  assert.match(ref, /multi-option selection|configuration workflow|configure.{0,20}settings/i, 'expected useWhen to name multi-option selection/configuration as a job');
  assert.doesNotMatch(section, /a picker, a short form, or a confirmation flow/, 'expected the stale, Dialog-colliding whenToUse clause to be gone');
  assert.doesNotMatch(ref, /next approved, separate Dialog family/, 'expected the stale "next approved, separate Dialog family" wording to be gone now that Dialog ships in this branch');

  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Hermes Dialog') || alts.includes('Dialog'), 'expected Bottom Sheet to name Dialog as an alternative');
  assert.ok(alts.includes('Hermes Selection Sheet') || alts.includes('Selection Sheet'), 'expected Bottom Sheet to name Selection Sheet as an alternative');
});

test('Correction (#607 final pass, Popover Menu): avoidWhen excludes informational content and navigation surfaces, and Tooltip is named as the anchored-information alternative', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Hermes Popover Menu'));

  assert.match(ref, /information|explanatory/i, 'expected avoidWhen to exclude informational/explanatory content');
  assert.match(ref, /navigation surface|destination/i, 'expected avoidWhen to exclude a general navigation surface');
  assert.match(ref, /Tooltip/, 'expected Tooltip to be named as the anchored-information alternative');

  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Hermes Tooltip') || alts.includes('Tooltip'), 'expected Popover Menu to add Tooltip as a structured alternative');
});

test('Correction (#607 final pass, Selection Sheet): alternatives name Bottom Sheet for a several-independent-settings task instead of forcing it into one option list', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Hermes Selection Sheet'));
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Bottom Sheet'), 'expected Selection Sheet to name Bottom Sheet as an alternative');
  assert.match(ref, /independent settings|several settings|fixed option list/i, 'expected the Bottom Sheet alternative to state the one-option-list-vs-several-settings boundary');
});

test('Correction (#607 final pass, Search): the Text Input alternative states the real query-vs-kept-value boundary, routing any filter/lookup field (even inline) to Search', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Search'));
  assert.doesNotMatch(ref, /inline filter or lookup field that is not attached to a navigation surface/, 'expected the stale Text-Input-bound inline-filter wording to be gone');
  assert.match(ref, /name.{0,15}URL.{0,15}credential|credential.{0,15}code/is, 'expected the corrected Text Input alternative to name a kept value such as name/URL/credential/code');
  assert.match(ref, /even inline/i, 'expected the corrected alternative to state that an inline filter is still Search');
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Text Input'), 'expected Search to keep Text Input as the named alternative');
});

test('Correction (#607 final pass, Avatar): useWhen matches real Swift — ServerAvatarBadge, HermexAvatar (system-image only), and Bots\' own face system — never a fabricated generic image/icon/initials Avatar API', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Hermes Avatar'));
  assert.doesNotMatch(ref, /generic catalog Avatar's own image\/icon\/initials precedence/, 'expected the fabricated generic Avatar API recommendation to be gone');
  assert.match(ref, /ServerAvatarBadge/, 'expected useWhen to name ServerAvatarBadge for server/account initials identity');
  assert.match(ref, /HermexAvatar/, 'expected useWhen to name HermexAvatar for a system-image badge at a named size');
  assert.match(ref, /no (?:image or initials mode|photo or initials mode)/i, 'expected useWhen to state HermexAvatar has no image/initials mode');
});

test('Correction (#607 final pass, Colors): useWhen routes a new Hermex component surface/border to the contrast-validated Neutral pairs, not a raw platform color, while keeping text/status bound to Apple system Color', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Hermex Colors'));
  assert.doesNotMatch(ref, /For surfaces, text, borders, and status colors, use the Apple system Color/, 'expected the stale surfaces-use-platform-color sentence to be corrected');
  assert.match(ref, /Color\(\.label\)/, 'expected text/status colors to stay bound to the real Apple system Color (existing coverage)');
  assert.match(ref, /HermexCardColors/, 'expected useWhen to name HermexCardColors for card fills');
  assert.match(ref, /HermexSurfaceBorderColors/, 'expected useWhen to name HermexSurfaceBorderColors for borders');
  assert.match(ref, /HermexSelectionControlColors/, 'expected useWhen to name HermexSelectionControlColors for selection controls');
  assert.match(ref, /rather than a raw platform color|never a raw platform color/i, 'expected useWhen to state the component-scoped-pair-over-platform-color rule');
});

test('Correction (#607 final pass, Content Unavailable): alternatives name Skeleton Loading for a loading state that should preserve replacing-content layout', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Content Unavailable'));
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Skeleton Loading'), 'expected Content Unavailable to name Skeleton Loading as an alternative');
  assert.match(ref, /preserve.{0,20}layout|known geometry/i, 'expected the Skeleton Loading alternative to state the known-geometry boundary');
});

test('Correction (#607 final pass, Tooltip): alternatives name Popover Menu for an anchored action list instead of explanatory content', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Hermes Tooltip'));
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Hermes Popover Menu') || alts.includes('Popover Menu'), 'expected Tooltip to name Popover Menu as an alternative');
});

test('Correction (#607 final pass, Composer): the Text Input alternative no longer sends multiline text to Text Input, since Text Input\'s own entry states TextEditor is not one of its variants', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Composer'));
  assert.doesNotMatch(ref, /ordinary single- or multi-line field outside the chat composer — TextField\/TextEditor/, 'expected the Text Input alternative to stop claiming TextEditor as a Text Input variant');
  const alts = extractAlternativeNames(ref);
  assert.ok(alts.includes('Text Input'), 'expected Composer to keep Text Input as the named alternative');
});

test('Correction (#607 final pass, Font): useWhen states a deciding condition rather than meta-commentary about the entry itself', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const ref = extractHermesReferenceBlock(extractHermesSection(src, 'Hermex Font'));
  assert.doesNotMatch(ref, /This entry states one rule/, 'expected the meta-commentary opening to be replaced by a deciding condition');
  assert.match(ref, /never pass weight or design/i, 'expected useWhen to still state the underlying rule');
});

// ─── Visual/source corrections (Opus) ─────────────────────────────────────────────────────────

test('Correction (#607 final pass, Card): CardChromePreview no longer renders the SectionCard-style uppercase title above the title-less Request/Compact surface modifiers', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const cardChromePreviewBody = extractFunctionBody(sectionsSrc, 'CardChromePreview');
  assert.doesNotMatch(
    cardChromePreviewBody,
    /recon\.cardTitle\}>\{title\}<\/Text>\s*\n\s*<View style=\{!isOutlined/,
    'expected the external recon.cardTitle caption to stop rendering unconditionally above every non-outlined kind',
  );
  const section = extractHermesSection(sectionsSrc, 'Hermes Card');
  assert.match(section, /<CardChromePreview[^>]*kind="request"/);
  assert.match(section, /<CardChromePreview[^>]*kind="compact"/);
});

test('Correction (#607 final pass, Attachment): each mapped file type renders a visually distinct icon (not one generic glyph everywhere), a spreadsheet/tablecells example exists, and the failure specimen no longer depicts a caller-owned Retry control', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'AttachmentTileGallery');

  const iconNames = [...body.matchAll(/<Icon\b[^>]*name="([^"]+)"/g)].map((m) => m[1]);
  const distinctFileIconNames = new Set(iconNames.filter((n) => n !== 'alert-circle' && n !== 'triangle-alert'));
  assert.ok(distinctFileIconNames.size >= 3, `expected at least 3 visually distinct file-type icon names, got: ${[...distinctFileIconNames].join(', ')}`);

  assert.match(body, /spreadsheet/i, 'expected a spreadsheet example in the Attachment gallery');
  assert.match(body, new RegExp('HERMES_COLOR_RAMPS\\.Green\\[500\\]'), 'expected the spreadsheet example to use the documented Green 500 tint');

  assert.doesNotMatch(body, /label="Retry"/, 'expected the caller-owned Retry control to be removed from the foundation-only Attachment family (smallest accurate result)');
  assert.doesNotMatch(body, /preview\.attachmentRetry/, 'expected the retired attachmentRetry style reference to be gone from the gallery');
});

test('Correction (#607 final pass, Attachment prose): no longer claims a Retry Button as part of this foundation family\'s failure specimen', () => {
  const src = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(src, 'Attachment');
  assert.doesNotMatch(section, /plus a Retry Button/, 'expected the Attachment section prose to stop claiming a Retry Button in its failure specimen');
});

test('Correction (#607 final pass, Popover Menu visual): the destructive row no longer renders a visible trailing "Destructive" text accessory; the real native row keeps the meaning in an accessibility hint only', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'PopoverMenuFamilyGallery');
  assert.doesNotMatch(body, /popoverDestructiveText/, 'expected the visible trailing "Destructive" text accessory style to be removed from the destructive row');
  assert.doesNotMatch(body, />\s*Destructive\s*</, 'expected no visible "Destructive" text node in the gallery');
});

test('Correction (#607 final pass, List/ListItem): the Picker configuration depicts native standard selection chrome with a filled primary pill and an automatic inverse checkmark, not a caller-owned accent check', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'ListItemFamilyGallery');
  const pickerStart = body.indexOf('Picker configuration');
  assert.notEqual(pickerStart, -1, 'expected the Picker configuration specimen to still exist');
  const pickerSectionSrc = body.slice(pickerStart, pickerStart + 1200);
  assert.doesNotMatch(pickerSectionSrc, /trailing=\{<Text[^>]*>✓<\/Text>\}/, 'expected the checkmark to stop masquerading as caller-owned trailing accessory content');
  assert.match(pickerSectionSrc, /<ListItemSelectedRowDemo\s+label="GPT-5\.1"/, 'expected a native-faithful static reconstruction of standard selected-row chrome');

  const selectedBody = extractFunctionBody(previewsSrc, 'ListItemSelectedRowDemo');
  assert.match(selectedBody, /listItemSelectedPill/, 'expected the selected row to use the filled selection-pill surface');
  assert.match(selectedBody, /listItemSelectedForeground/, 'expected the selected title and automatic checkmark to use the inverse foreground');
});

test('Correction (#607 final pass, Selection Sheet): Done renders the primary emphasis and Cancel the secondary emphasis in both footer axes, matching HermexSelectionSheet.multiFooter', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'SelectionSheetMultiFooterDemo');
  assert.doesNotMatch(body, /variant="tertiary"\s+label="Cancel"/, 'expected Cancel to stop using the borderless tertiary variant');
  const doneMatches = [...body.matchAll(/variant="([a-z]+)"\s+label="Done"/g)].map((m) => m[1]);
  const cancelMatches = [...body.matchAll(/variant="([a-z]+)"\s+label="Cancel"/g)].map((m) => m[1]);
  assert.equal(doneMatches.length, 2, 'expected exactly two Done buttons (horizontal + vertical axis)');
  assert.equal(cancelMatches.length, 2, 'expected exactly two Cancel buttons (horizontal + vertical axis)');
  for (const variant of doneMatches) assert.equal(variant, 'primary', 'expected Done to use the primary emphasis in every axis');
  for (const variant of cancelMatches) assert.equal(variant, 'secondary', 'expected Cancel to use the secondary emphasis in every axis');
});

test('Correction (#607 final pass, Transcript Log Row): the collapsed row orders the chevron before the compact status glyph (status at the extreme trailing edge), and a statically expanded specimen exists', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'TranscriptLogRowPreview');
  assert.doesNotMatch(body, /fontWeight:\s*'700',\s*color:\s*'#34C759'/, 'expected the wide bold green status word styling to be gone');
  const chevronIndex = body.indexOf('<DisclosureChevron');
  const statusIndex = body.search(/logStatus/i);
  assert.notEqual(chevronIndex, -1, 'expected the chevron to still render');
  assert.notEqual(statusIndex, -1, 'expected a status element to still render');
  assert.ok(chevronIndex < statusIndex, 'expected the chevron to precede the status glyph so status sits at the extreme trailing edge');
  assert.match(body, /Expanded/i, 'expected a statically expanded specimen label');
});

test('Banner visual follow-up: every text region uses the AA semantic foreground, status icons use the native 16pt size in a first-line box, and Offline keeps its orange full-width treatment', () => {
  const bannerSrc = read('native/components/Banner/Banner.tsx');
  assert.match(
    bannerSrc,
    /styles\.title,\s*styles\.titleFlex,\s*\{\s*marginBottom:\s*0\s*\},\s*\{\s*color:\s*contentTextColor\s*\}/,
    'expected title and description-only text to use the per-variant semantic foreground',
  );
  assert.match(
    bannerSrc,
    /styles\.description,\s*styles\.descriptionPad,\s*\{\s*color:\s*contentTextColor\s*\}/,
    'expected supporting description text to use the same per-variant semantic foreground',
  );
  assert.doesNotMatch(bannerSrc, /linkText:[\s\S]{0,120}color:/, 'expected inline Banner links to inherit the semantic foreground rather than switching to a generic blue');
  assert.match(bannerSrc, /size=\{DS_ICON_SIZE\.sm\}/, 'expected the status icon to use the native HermexBanner 16pt small size');
  assert.match(bannerSrc, /statusIconLineBox:[\s\S]{0,180}height:\s*DS_TYPOGRAPHY\.labelSm\.lineHeight[\s\S]{0,100}justifyContent:\s*'center'/, 'expected the status icon to be centered in the title first-line box while the row itself remains top-aligned');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const bannerGalleryBody = extractFunctionBody(previewsSrc, 'BannerFamilyGallery');
  assert.doesNotMatch(bannerGalleryBody, /variant="neutral"\s+icon="alert-circle"/, 'expected the Offline specimen to stop using neutral/alert-circle');
  assert.match(bannerGalleryBody, /icon="(?:wifi-slash|triangle-alert|info-circle)"[\s\S]{0,40}Offline|Offline[\s\S]{0,120}icon="(?:wifi-slash|triangle-alert|info-circle)"/, 'expected the Offline specimen to carry a distinct, non-alert-circle icon override');
});

test('Correction (#607 final pass, Row Divider): a 16pt row-aligned leading-inset specimen is depicted alongside the default s0 specimen', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'HermexDividerPreview');
  assert.match(body, /leadingInset=\{?16\}?|leadingInset.*16|marginLeft:\s*16/i, 'expected a visible 16pt leading-inset specimen');
});

test('Correction (#607 final pass, Text Input): the field label renders as the primary subheadline-semibold treatment, visibly distinct from the footnote helper/error style', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'HermexTextInputFamilyGallery');
  assert.doesNotMatch(body, /style=\{preview\.caption\}>Name<\/Text>/, 'expected the Name field label to stop using the quiet caption style');
  assert.doesNotMatch(body, /style=\{preview\.caption\}>Password<\/Text>/, 'expected the Password field label to stop using the quiet caption style');
  assert.match(body, /style=\{preview\.fieldLabel\}>Name<\/Text>/, 'expected the Name field label to use the distinct, semibold primary field-label style');
  assert.match(body, /style=\{preview\.fieldLabel\}>Password<\/Text>/, 'expected the Password field label to use the distinct, semibold primary field-label style');

  const fieldLabelStyle = previewsSrc.match(/fieldLabel:\s*\{([^}]*)\}/)?.[1] ?? '';
  assert.match(fieldLabelStyle, /fontWeight:\s*'600'/, 'expected the field label style to be semibold');
  assert.match(fieldLabelStyle, /fontSize:\s*15\b/, 'expected the field label style to use the subheadline size (15)');
});

test('Correction (#607 final pass, Dialog visual): the horizontal footer buttons size intrinsically and hug the trailing edge, with no flex: 1 stretching', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  assert.doesNotMatch(previewsSrc.match(/dialogFooterButton:\s*\{[^}]*\}/)?.[0] ?? '', /flex:\s*1/, 'expected the dialogFooterButton style to drop flex: 1 so actions size intrinsically');
});

test('Correction (#607 final pass, Buttons): Neutral composes a subtle fill with no border, and Secondary keeps that fill plus an explicit border, so the two are distinguishable by border alone', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'ButtonDecisionAndTactilePreview');
  assert.doesNotMatch(body, /label="Neutral"\s+variant="tertiary"/, 'expected Neutral to stop using the fill-less tertiary variant');
  assert.match(body, /label="Neutral"\s+variant="secondary"/, 'expected Neutral to compose the generic secondary variant for its subtle fill');
  assert.match(body, /label="Not now"\s+variant="secondary"\s+size="medium"\s+style=\{preview\.buttonSecondaryBordered\}/, 'expected the Secondary specimen to add an explicit border style distinguishing it from Neutral');
});

test('Correction (#607 final pass, Toast): no invented vertical divider renders between the message and action, and the action prop description drops its divider claim', () => {
  const toastSrc = read('native/components/Toast/Toast.tsx');
  assert.match(toastSrc, /showDivider/, 'expected an explicit, backward-compatible showDivider seam on the generic Toast');

  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const toastGalleryBody = extractFunctionBody(previewsSrc, 'ToastFamilyGallery');
  assert.match(toastGalleryBody, /showDivider=\{false\}/, 'expected the Hermex Toast specimen to suppress the generic divider');

  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const toastSection = extractHermesSection(sectionsSrc, 'Hermes Toast');
  assert.doesNotMatch(toastSection, /separated from the message by a vertical divider/, 'expected the action prop description to drop its divider claim');
});

test('Correction (#607 final pass, Tooltip visual): the trigger label describes a tap, not press-and-hold, and the anchored content surface is statically depicted', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const body = extractFunctionBody(previewsSrc, 'TooltipFamilyGallery');
  assert.doesNotMatch(body, /Press and hold the info glyph/, 'expected the press-and-hold heading to be replaced with tap-trigger wording');
  assert.match(body, /\btap\b/i, 'expected the heading to describe the real tap trigger');
  assert.match(body, /280|max-?width/i, 'expected a statically-depicted content surface naming the 280pt max width');
});

test('Correction (#607 final controller follow-up, Banner metadata): Offline maps to the native .offline semantic instead of neutral plus an icon override', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const section = extractHermesSection(sectionsSrc, 'Hermes Banner');
  const ref = extractHermesReferenceBlock(section);

  assert.doesNotMatch(section, /Offline uses neutral with an icon override/i);
  assert.doesNotMatch(ref, /name:\s*'Offline'[\s\S]{0,120}variant:\s*'neutral'/i);
  assert.match(section, /Offline[\s\S]{0,120}\.offline/i, 'expected the catalog metadata to name the real native Offline semantic');
});

test('Correction (#607 final controller follow-up, Search boundary): filter and lookup queries are Search regardless of whether the field sits in navigation, a list, a sheet, or a card', () => {
  const sectionsSrc = read(HERMES_SECTIONS_PATH);
  const searchRef = extractHermesReferenceBlock(extractHermesSection(sectionsSrc, 'Search'));
  const textInputRef = extractHermesReferenceBlock(extractHermesSection(sectionsSrc, 'Text Input'));

  assert.match(searchRef, /query that filters or looks up content/i);
  assert.match(searchRef, /sheet or card/i);
  assert.doesNotMatch(textInputRef, /For a field attached to a navigation surface or searchable list/i);
  assert.match(textInputRef, /query that filters or looks up content/i);
});

test('Correction (#607 final controller follow-up, Toast visual): every rendered Hermex Toast specimen suppresses the generic catalog divider', () => {
  const previewsSrc = read(COMPONENT_FAMILIES_PREVIEWS_PATH);
  const galleryBody = extractFunctionBody(previewsSrc, 'ToastFamilyGallery');
  const motionBody = extractFunctionBody(previewsSrc, 'ToastMotionDemo');
  const staticToastTags = [...galleryBody.matchAll(/<Toast\b[\s\S]*?\/>/g)].map((match) => match[0]);

  assert.equal(staticToastTags.length, 5, 'expected the four semantic specimens plus the trailing-action specimen');
  for (const tag of staticToastTags) {
    assert.match(tag, /showDivider=\{false\}/, `expected every Hermex Toast specimen to suppress the generic divider: ${tag}`);
  }
  assert.match(motionBody, /<Toast\b[\s\S]*?showDivider=\{false\}[\s\S]*?\/>/, 'expected the motion specimen to suppress the generic divider too');
});
