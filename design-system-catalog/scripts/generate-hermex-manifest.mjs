#!/usr/bin/env node
// Generates design-system-catalog/hermex-manifest.json — a deterministic, checked-in snapshot of
// the live canonical hermesSections/hermesNav catalog data, serialized through the same
// buildHermesManifestEnvelope() the catalog's own in-browser "Machine-readable manifest" disclosure
// calls (HermesManifestJSON in hermesSections.tsx). This script adds no dependency: it loads the
// real .ts/.tsx source through the `typescript` package already vendored under
// native-preview/node_modules, transpiling each file (no type-checking — tsc already covers that)
// and requiring it under Node via a CommonJS extension hook. It never renders UI — React Native and
// its sibling packages are replaced by inert stand-ins (see `installInertStubs` below) only so that
// `require()`-ing a .tsx file that references them at module scope (StyleSheet.create(...), JSX
// element literals inside data arrays, etc.) does not throw; no stub is ever asked to draw anything.
//
// Usage:
//   node scripts/generate-hermex-manifest.mjs            # (re)writes hermex-manifest.json
//   node scripts/generate-hermex-manifest.mjs --check     # fails nonzero if the checked-in file is stale/missing

import { createRequire } from 'node:module';
import Module from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const CATALOG_ROOT = path.join(__dirname, '..'); // design-system-catalog/
const OUTPUT_PATH = path.join(CATALOG_ROOT, 'hermex-manifest.json');
const HERMES_SECTIONS_ENTRY = path.join(CATALOG_ROOT, 'native/catalog/hermes/hermesSections.tsx');
const MANIFEST_ENTRY = path.join(CATALOG_ROOT, 'native/catalog/manifest.ts');
const TYPESCRIPT_PATH = path.join(CATALOG_ROOT, 'native-preview/node_modules/typescript');

const requireFromHere = createRequire(import.meta.url);
const ts = requireFromHere(TYPESCRIPT_PATH);

// Every module specifier below never contributes to the manifest's actual data (it is UI
// chrome/rendering only); its real package is never loaded or rendered — only an inert stand-in
// that satisfies `require()` at module-evaluation time, per the "inert module stubs" allowance.
// React itself is included so the transpiled `react/jsx-runtime` imports are also inert and the
// generator works before CI creates the catalog-root node_modules symlink used only by tsc.
const STUBBED_PACKAGE_PREFIXES = ['react', 'react-native', 'expo', '@expo/'];

function isStubbedSpecifier(request) {
  return STUBBED_PACKAGE_PREFIXES.some((prefix) => request === prefix || request.startsWith(`${prefix}/`) || request.startsWith(`${prefix}-`));
}

// A single inert "component" value — a no-op function. Never invoked through React (nothing here
// ever renders), so its only job is to be a valid `require()` export for whatever name a real
// react-native/expo module would have exported (View, Text, Pressable, Svg, Path, ...).
function makeInertExport(name) {
  const inert = () => null;
  inert.displayName = name;
  return inert;
}

// Builds one inert stub module for a given package specifier, covering the handful of named
// exports this catalog's data/preview files actually call directly (StyleSheet.create, Platform.OS/
// select, Dimensions.get, ...) and falling back to a plain inert export for everything else, via a
// Proxy, so a yet-unenumerated import never breaks the hook.
function makeInertModule(specifier) {
  const known = {
    StyleSheet: {
      create: (styles) => styles,
      flatten: (style) => style,
      compose: (a, b) => [a, b],
      absoluteFillObject: {},
      hairlineWidth: 1,
    },
    Platform: {
      OS: 'ios',
      Version: 26,
      select: (spec) => (spec && 'ios' in spec ? spec.ios : spec?.default),
      isPad: false,
      isTV: false,
    },
    Dimensions: { get: () => ({ width: 390, height: 844, scale: 3, fontScale: 1 }) },
    PixelRatio: { get: () => 3, getFontScale: () => 1, roundToNearestPixel: (n) => n },
    I18nManager: { isRTL: false },
    Appearance: { getColorScheme: () => 'light', addChangeListener: () => ({ remove() {} }) },
    AccessibilityInfo: {
      isScreenReaderEnabled: () => Promise.resolve(false),
      isReduceMotionEnabled: () => Promise.resolve(false),
      addEventListener: () => ({ remove() {} }),
    },
    useWindowDimensions: () => ({ width: 390, height: 844, scale: 3, fontScale: 1 }),
    useColorScheme: () => 'light',
    Easing: new Proxy({}, { get: () => (x) => x }),
    Animated: new Proxy({ Value: function Value(v) { this._v = v; }, createAnimatedComponent: (c) => c }, {
      get(target, prop) {
        if (prop in target) return target[prop];
        return makeInertExport(String(prop));
      },
    }),
  };
  const cache = new Map();
  const stub = new Proxy(known, {
    get(target, prop) {
      if (prop === '__esModule') return true;
      if (prop === 'default') return stub;
      if (prop in target) return target[prop];
      if (!cache.has(prop)) cache.set(prop, makeInertExport(`${specifier}.${String(prop)}`));
      return cache.get(prop);
    },
    has() {
      return true;
    },
  });
  return stub;
}

const TS_COMPILER_OPTIONS = {
  module: ts.ModuleKind.CommonJS,
  moduleResolution: ts.ModuleResolutionKind.NodeJs,
  jsx: ts.JsxEmit.ReactJSX,
  target: ts.ScriptTarget.ES2020,
  esModuleInterop: true,
  resolveJsonModule: true,
};

function installInertStubs() {
  const originalLoad = Module._load;
  Module._load = function patchedLoad(request, parent, isMain) {
    if (isStubbedSpecifier(request)) return makeInertModule(request);
    return originalLoad.call(this, request, parent, isMain);
  };
  return () => {
    Module._load = originalLoad;
  };
}

function installTypeScriptLoader() {
  const compileAndRun = (module, filename) => {
    const source = fs.readFileSync(filename, 'utf8');
    const { outputText } = ts.transpileModule(source, {
      compilerOptions: TS_COMPILER_OPTIONS,
      fileName: filename,
    });
    module._compile(outputText, filename);
  };
  const previousTs = Module._extensions['.ts'];
  const previousTsx = Module._extensions['.tsx'];
  Module._extensions['.ts'] = compileAndRun;
  Module._extensions['.tsx'] = compileAndRun;
  return () => {
    if (previousTs) Module._extensions['.ts'] = previousTs;
    else delete Module._extensions['.ts'];
    if (previousTsx) Module._extensions['.tsx'] = previousTsx;
    else delete Module._extensions['.tsx'];
  };
}

function loadCanonicalCatalogData() {
  const restoreStubs = installInertStubs();
  const restoreLoader = installTypeScriptLoader();
  try {
    const hermesSectionsModule = requireFromHere(HERMES_SECTIONS_ENTRY);
    const manifestModule = requireFromHere(MANIFEST_ENTRY);
    const { hermesSections, hermesNav } = hermesSectionsModule;
    const { buildHermesManifestEnvelope } = manifestModule;
    if (!Array.isArray(hermesSections) || !Array.isArray(hermesNav) || typeof buildHermesManifestEnvelope !== 'function') {
      throw new Error('expected hermesSections.tsx to export hermesSections/hermesNav and manifest.ts to export buildHermesManifestEnvelope');
    }
    return buildHermesManifestEnvelope(hermesSections, hermesNav);
  } finally {
    restoreLoader();
    restoreStubs();
  }
}

function serializeEnvelope(envelope) {
  // Two-space indentation, one trailing newline, no wall-clock timestamp — every value in the
  // envelope is derived from the canonical source data above, so this is already byte-deterministic
  // for a given hermesSections.tsx/manifest.ts/types.ts (no extra sorting needed: object property
  // order follows the fixed construction order in manifest.ts, and entry order follows the fixed
  // hermesSections array order).
  return `${JSON.stringify(envelope, null, 2)}\n`;
}

function main() {
  const checkOnly = process.argv.includes('--check');
  const envelope = loadCanonicalCatalogData();
  const expected = serializeEnvelope(envelope);

  if (!checkOnly) {
    fs.writeFileSync(OUTPUT_PATH, expected, 'utf8');
    process.stdout.write(`Wrote ${path.relative(CATALOG_ROOT, OUTPUT_PATH)} (${envelope.entries.length} entries).\n`);
    return;
  }

  if (!fs.existsSync(OUTPUT_PATH)) {
    process.stderr.write(
      `${path.relative(CATALOG_ROOT, OUTPUT_PATH)} does not exist. Regenerate it with: node scripts/generate-hermex-manifest.mjs\n`,
    );
    process.exit(1);
  }
  const actual = fs.readFileSync(OUTPUT_PATH, 'utf8');
  if (actual !== expected) {
    process.stderr.write(
      `${path.relative(CATALOG_ROOT, OUTPUT_PATH)} is stale (does not match the live hermesSections/hermesNav catalog data).\n` +
        'Regenerate it with: node scripts/generate-hermex-manifest.mjs\n',
    );
    process.exit(1);
  }
  process.stdout.write(`${path.relative(CATALOG_ROOT, OUTPUT_PATH)} is up to date.\n`);
}

main();
