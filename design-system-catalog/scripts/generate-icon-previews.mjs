#!/usr/bin/env node
// Renders the Hermex Iconography catalog's authoritative 230-name SF Symbol union through the
// real iOS UIKit runtime (icon-renderer/, a SwiftPM XCTest bundle) on an iOS Simulator, then
// extracts the rendered PNGs into native-preview/public/generated-icons/ for the browser catalog
// to load. Those browser assets are checked in so ordinary catalog startup remains browser-only;
// rerun this command explicitly whenever the source-derived inventory changes. The same simulator
// run also renders the catalog's five default icon-size steps (12/16/20/24/32pt, mirroring
// HERMES_ICON_SIZE in hermesIconSize.ts) for the shared `star.fill` size-scale demo glyph directly
// at each point size — real, point-accurate assets the size-scale and Avatar-pairing galleries use
// instead of resizing the single 32pt overview asset — into
// native-preview/public/generated-icons/sizes/.
//
// This is explicit, simulator-backed regeneration only — a separate, deliberate step
// (`npm run generate:icons`), never an implicit pre-step of the ordinary browser catalog launch
// (`npm run web`, which starts Expo directly and never invokes Xcode/simctl). It is always strict:
// fails nonzero (process.exit(1)) if Xcode/Simulator prerequisites are unavailable, any SF Symbol is
// unresolved, rendering fails, either attachment count is wrong, or output is partial. Without a
// regenerated asset for a given glyph, the browser catalog shows that tile's honest, per-icon
// "Glyph unavailable in browser" fallback (HermesIconReference.tsx) rather than failing to load.
//
// The destination Simulator must be named explicitly via the required HERMEX_ICON_SIMULATOR_UDID
// env var — never guessed via `simctl` device discovery, which would select non-reproducible,
// machine-local state. Never creates/deletes devices, never selects a macOS/AppKit destination.
// Pass --force to re-render even when a matching manifest is already on disk.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, copyFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const EXPECTED_COUNT = 230;

// Mirrors HERMES_ICON_SIZE's five steps (xs/small/medium/large/extraLarge) in
// native/catalog/hermes/hermesIconSize.ts — kept as a plain literal here (like EXPECTED_COUNT
// above) rather than transpiling that TypeScript module into this script; a dedicated contract
// test pins the two in sync instead.
const SIZE_SCALE_SYMBOL_NAME = 'star.fill';
const SIZE_STEP_POINTS = [12, 16, 20, 24, 32];

// Marks "generation unavailable" (missing platform/tooling/available-Simulator prerequisites) so
// --optional mode can downgrade exactly this case to a warning + exit 0, while every other failure
// (compile, render, missing symbol, wrong/partial count, export) still propagates and fails the
// process in both modes.
class PrerequisiteUnavailableError extends Error {}

const CATALOG_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const RENDERER_DIR = path.join(CATALOG_ROOT, 'icon-renderer');
const GENERATED_NAMES_PATH = path.join(RENDERER_DIR, 'Tests/IconRenderTests/GeneratedNames.swift');
const OUTPUT_DIR = path.join(CATALOG_ROOT, 'native-preview/public/generated-icons');
const OUTPUT_MANIFEST_PATH = path.join(OUTPUT_DIR, 'manifest.json');
const SIZE_OUTPUT_DIR = path.join(OUTPUT_DIR, 'sizes');
const SIZE_OUTPUT_MANIFEST_PATH = path.join(SIZE_OUTPUT_DIR, 'manifest.json');

function buildIconNames() {
  const inventory = JSON.parse(readFileSync(path.join(CATALOG_ROOT, 'native/catalog/hermes/hermesIconInventory.generated.json'), 'utf8'));
  const trace = JSON.parse(readFileSync(path.join(CATALOG_ROOT, 'native/catalog/hermes/hermesIconComputedSiteTrace.generated.json'), 'utf8'));
  const literalNames = inventory.literals.map((entry) => entry.name);
  const computedNames = trace.entries.flatMap((entry) => entry.resolvedNames);
  return [...new Set([...literalNames, ...computedNames])].sort((a, b) => a.localeCompare(b));
}

function sizeAssetFileName(pointSize) {
  return `${SIZE_SCALE_SYMBOL_NAME}-${pointSize}pt.png`;
}

function alreadyGenerated(names) {
  if (!existsSync(OUTPUT_MANIFEST_PATH) || !existsSync(SIZE_OUTPUT_MANIFEST_PATH)) return false;
  let manifest;
  let sizeManifest;
  try {
    manifest = JSON.parse(readFileSync(OUTPUT_MANIFEST_PATH, 'utf8'));
    sizeManifest = JSON.parse(readFileSync(SIZE_OUTPUT_MANIFEST_PATH, 'utf8'));
  } catch {
    return false;
  }
  if (!Array.isArray(manifest.names) || manifest.names.length !== names.length) return false;
  if (manifest.names.some((name, i) => name !== names[i])) return false;
  if (!names.every((name) => existsSync(path.join(OUTPUT_DIR, `${name}.png`)))) return false;

  if (sizeManifest.icon !== SIZE_SCALE_SYMBOL_NAME || !Array.isArray(sizeManifest.sizes)) return false;
  if (sizeManifest.sizes.length !== SIZE_STEP_POINTS.length) return false;
  if (sizeManifest.sizes.some((entry, i) => entry.pointSize !== SIZE_STEP_POINTS[i] || entry.file !== sizeAssetFileName(SIZE_STEP_POINTS[i]))) return false;
  return SIZE_STEP_POINTS.every((pointSize) => existsSync(path.join(SIZE_OUTPUT_DIR, sizeAssetFileName(pointSize))));
}

function writeGeneratedNamesSwift(names) {
  const literal = names.map((name) => JSON.stringify(name)).join(', ');
  const sizePointsLiteral = SIZE_STEP_POINTS.join(', ');
  const contents =
    `// Generated by scripts/generate-icon-previews.mjs — do not edit by hand, and never commit.\n` +
    `let iconRenderNames: [String] = [${literal}]\n` +
    `let iconSizeStepSymbolName = ${JSON.stringify(SIZE_SCALE_SYMBOL_NAME)}\n` +
    `let iconSizeStepPoints: [Int] = [${sizePointsLiteral}]\n`;
  writeFileSync(GENERATED_NAMES_PATH, contents, 'utf8');
}

// Resolves the concrete Simulator UDID to pass to xcodebuild, or throws
// PrerequisiteUnavailableError when Xcode tooling isn't usable or the required env var is unset.
// Never creates/deletes devices; never resolves to a macOS/AppKit destination; never guesses a
// destination via `simctl` device discovery — that would select non-reproducible, machine-local
// state, so the caller must name it explicitly.
function checkPrerequisites() {
  try {
    execFileSync('xcodebuild', ['-version'], { stdio: 'ignore' });
  } catch (error) {
    throw new PrerequisiteUnavailableError(`xcodebuild is not available (${error.code === 'ENOENT' ? 'not installed' : error.message})`);
  }

  const override = process.env.HERMEX_ICON_SIMULATOR_UDID;
  if (!override) {
    throw new PrerequisiteUnavailableError(
      'HERMEX_ICON_SIMULATOR_UDID is not set — explicit icon regeneration requires naming a destination Simulator explicitly, never guessing one',
    );
  }
  return override;
}

function runSimulatorRender(udid) {
  const resultBundlePath = path.join(mkdtempSync(path.join(tmpdir(), 'hermex-icon-render-')), 'IconRender.xcresult');
  execFileSync(
    'xcodebuild',
    ['test', '-scheme', 'HermexIconRenderer-Package', '-destination', `id=${udid}`, '-resultBundlePath', resultBundlePath],
    { cwd: RENDERER_DIR, stdio: 'inherit' },
  );
  return resultBundlePath;
}

function exportAttachments(resultBundlePath) {
  const outputPath = path.join(path.dirname(resultBundlePath), 'attachments');
  execFileSync('xcrun', ['xcresulttool', 'export', 'attachments', '--path', resultBundlePath, '--output-path', outputPath, '--filter', '*.png'], {
    stdio: 'inherit',
  });
  const manifest = JSON.parse(readFileSync(path.join(outputPath, 'manifest.json'), 'utf8'));
  const attachments = manifest.flatMap((entry) => entry.attachments);
  return { outputPath, attachments };
}

function main() {
  const optional = process.argv.includes('--optional');

  const names = buildIconNames();
  if (names.length !== EXPECTED_COUNT) {
    throw new Error(`expected the authoritative icon union to contain ${EXPECTED_COUNT} names, found ${names.length}`);
  }

  const force = process.argv.includes('--force');
  if (!force && alreadyGenerated(names)) {
    console.log(`generate-icon-previews: ${OUTPUT_DIR} already has all ${EXPECTED_COUNT} glyphs — skipping simulator render (pass --force to regenerate).`);
    return;
  }

  let udid;
  try {
    udid = checkPrerequisites();
  } catch (error) {
    if (optional && error instanceof PrerequisiteUnavailableError) {
      console.warn(`generate-icon-previews: skipping simulator-rendered icon previews (${error.message}) — the browser catalog will show its "Glyph unavailable in browser" fallback.`);
      return;
    }
    throw error;
  }

  mkdirSync(RENDERER_DIR + '/Tests/IconRenderTests', { recursive: true });
  writeGeneratedNamesSwift(names);

  console.log(`generate-icon-previews: rendering ${names.length} SF Symbols plus ${SIZE_STEP_POINTS.length} size-scale specimens through UIImage(systemName:) on Simulator ${udid}…`);
  const resultBundlePath = runSimulatorRender(udid);
  const { outputPath, attachments } = exportAttachments(resultBundlePath);

  const indexPattern = /^icon_(\d+)_/;
  const sizePattern = /^icon_size_(\d+)_/;
  const overviewAttachments = attachments.filter((a) => indexPattern.test(a.suggestedHumanReadableName));
  const sizeAttachments = attachments.filter((a) => sizePattern.test(a.suggestedHumanReadableName));

  if (overviewAttachments.length !== EXPECTED_COUNT) {
    throw new Error(`expected ${EXPECTED_COUNT} overview rendered PNG attachments, found ${overviewAttachments.length} — refusing to write a partial catalog`);
  }
  if (sizeAttachments.length !== SIZE_STEP_POINTS.length) {
    throw new Error(`expected ${SIZE_STEP_POINTS.length} size-scale rendered PNG attachments, found ${sizeAttachments.length} — refusing to write a partial catalog`);
  }

  mkdirSync(OUTPUT_DIR, { recursive: true });
  for (const attachment of overviewAttachments) {
    const match = attachment.suggestedHumanReadableName.match(indexPattern);
    const name = names[Number(match[1])];
    copyFileSync(path.join(outputPath, attachment.exportedFileName), path.join(OUTPUT_DIR, `${name}.png`));
  }
  writeFileSync(OUTPUT_MANIFEST_PATH, `${JSON.stringify({ schemaVersion: 1, count: names.length, names }, null, 2)}\n`, 'utf8');

  mkdirSync(SIZE_OUTPUT_DIR, { recursive: true });
  for (const attachment of sizeAttachments) {
    const match = attachment.suggestedHumanReadableName.match(sizePattern);
    const pointSize = Number(match[1]);
    copyFileSync(path.join(outputPath, attachment.exportedFileName), path.join(SIZE_OUTPUT_DIR, sizeAssetFileName(pointSize)));
  }
  const sizeManifest = {
    schemaVersion: 1,
    icon: SIZE_SCALE_SYMBOL_NAME,
    sizes: SIZE_STEP_POINTS.map((pointSize) => ({ pointSize, file: sizeAssetFileName(pointSize) })),
  };
  writeFileSync(SIZE_OUTPUT_MANIFEST_PATH, `${JSON.stringify(sizeManifest, null, 2)}\n`, 'utf8');

  rmSync(path.dirname(resultBundlePath), { recursive: true, force: true });

  console.log(
    `generate-icon-previews: wrote ${names.length} glyphs to ${path.relative(CATALOG_ROOT, OUTPUT_DIR)} ` +
      `and ${SIZE_STEP_POINTS.length} size-scale specimens to ${path.relative(CATALOG_ROOT, SIZE_OUTPUT_DIR)}.`,
  );
}

try {
  main();
} catch (error) {
  console.error(`generate-icon-previews failed: ${error.message}`);
  process.exit(1);
}
