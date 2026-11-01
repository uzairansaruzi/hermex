#!/usr/bin/env node
// Scans the production Swift source for every `systemName:`/`systemImage:` SF Symbol call site —
// literal string arguments grouped by icon name, and every non-literal (computed) argument/type
// annotation left as its own entry — and (re)writes/validates
// native/catalog/hermes/hermesIconInventory.generated.json. A syntax-light single-pass lexer (see
// `buildCodeMask`) keeps the keyword search from matching inside line/block comments or string
// literal bodies; it does not implement a full Swift grammar, so a handful of lexical boundaries are
// deliberately out of scope — see the comments on `buildCodeMask` and `readStringLiteral` below.
//
// This reproduces the shape `hermesIconInventory.generated.json` already documents (literal name ->
// site list, computed site -> {expression, keyword, callHead}); it does not resolve a computed
// expression's actual icon name(s) — that deeper call-graph trace is
// `hermesIconComputedSiteTrace.generated.json`, produced and maintained separately.
//
// Usage:
//   node scripts/generate-hermex-icon-inventory.mjs            # (re)writes the generated JSON
//   node scripts/generate-hermex-icon-inventory.mjs --check    # fails nonzero if stale/missing

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const CATALOG_ROOT = path.join(__dirname, '..'); // design-system-catalog/
const REPO_ROOT = path.join(CATALOG_ROOT, '..');
const OUTPUT_PATH = path.join(CATALOG_ROOT, 'native/catalog/hermes/hermesIconInventory.generated.json');

// The production Swift targets this scanner treats as authoritative source. HermesMobileTests, the
// Xcode project metadata, and design-system-catalog's own TypeScript/JS reconstruction are
// intentionally excluded — they document or exercise production code but are not production call
// sites themselves.
export const SOURCE_ROOTS = ['HermesMobile', 'HermesShareExtension', 'HermesLiveActivityWidget', 'HermesNotificationService'];

const KEYWORDS = ['systemName', 'systemImage'];
const KEYWORD_PATTERN = new RegExp(`(?<![A-Za-z0-9_])(${KEYWORDS.join('|')})\\s*:(?!:)`, 'g');

// ─── Lexical mask ─────────────────────────────────────────────────────────────────────────────
// Produces one byte per source character: 1 where that character sits in real code, 0 where it sits
// inside a line comment, a (possibly nested) block comment, or a string literal body — including the
// opening/closing quote marks themselves. A keyword match is only accepted when its entire span is
// masked as real code, so prose in a comment, or an example embedded in a string literal, never reads
// as a genuine argument label.
//
// Known lexical boundaries (acceptable for this repository's current source, not a general Swift
// parser): Swift string interpolation (`"\(expr)"`) reopens a code region inside a string — this
// scanner never re-enters that nested expression as code; `readStringLiteral` below instead detects
// the interpolation marker and demotes the whole literal to a computed site. Raw strings
// (`#"..."#`) are not specially recognized. A malformed/unterminated single-line string literal is
// treated as closing at the next newline rather than erroring.
export function buildCodeMask(source) {
  const n = source.length;
  const mask = new Uint8Array(n);
  const CODE = 0, LINE_COMMENT = 1, BLOCK_COMMENT = 2, STRING = 3, TRIPLE_STRING = 4;
  let state = CODE;
  let blockDepth = 0;
  let i = 0;
  while (i < n) {
    const c = source[i];
    const c2 = i + 1 < n ? source[i + 1] : '';
    const c3 = i + 2 < n ? source[i + 2] : '';
    if (state === CODE) {
      if (c === '/' && c2 === '/') { state = LINE_COMMENT; i += 2; continue; }
      if (c === '/' && c2 === '*') { state = BLOCK_COMMENT; blockDepth = 1; i += 2; continue; }
      if (c === '"' && c2 === '"' && c3 === '"') { state = TRIPLE_STRING; i += 3; continue; }
      if (c === '"') { state = STRING; mask[i] = 0; i += 1; continue; }
      mask[i] = 1;
      i += 1;
      continue;
    }
    if (state === LINE_COMMENT) {
      if (c === '\n') { state = CODE; mask[i] = 1; i += 1; continue; }
      i += 1;
      continue;
    }
    if (state === BLOCK_COMMENT) {
      if (c === '/' && c2 === '*') { blockDepth += 1; i += 2; continue; }
      if (c === '*' && c2 === '/') {
        blockDepth -= 1;
        i += 2;
        if (blockDepth === 0) state = CODE;
        continue;
      }
      i += 1;
      continue;
    }
    if (state === STRING) {
      if (c === '\\') { i += 2; continue; } // escape consumes the next character too (mask already 0 by default)
      if (c === '\n') { state = CODE; continue; } // unterminated single-line string: bail out at the newline
      if (c === '"') { state = CODE; i += 1; continue; }
      i += 1;
      continue;
    }
    if (state === TRIPLE_STRING) {
      if (c === '\\') { i += 2; continue; }
      if (c === '"' && c2 === '"' && c3 === '"') { state = CODE; i += 3; continue; }
      i += 1;
      continue;
    }
    i += 1;
  }
  return mask;
}

function buildLineIndex(source) {
  const n = source.length;
  const lineOf = new Int32Array(n + 1);
  let line = 1;
  for (let i = 0; i < n; i++) {
    lineOf[i] = line;
    if (source[i] === '\n') line += 1;
  }
  lineOf[n] = line;
  return lineOf;
}

// Parses a string literal (single-line `"..."` or triple-quoted `"""..."""`) starting exactly at
// `startIndex` (which must point at the opening quote). Returns the literal's raw inner text, the
// index just past the closing quote(s), and whether an unescaped `\(` interpolation marker was seen —
// callers treat an interpolated literal as a computed site, since its final value is not static.
function readStringLiteral(source, startIndex) {
  const n = source.length;
  const isTriple = source[startIndex + 1] === '"' && source[startIndex + 2] === '"';
  let i = startIndex + (isTriple ? 3 : 1);
  let value = '';
  let hasInterpolation = false;
  while (i < n) {
    const c = source[i];
    if (c === '\\') {
      if (source[i + 1] === '(') {
        hasInterpolation = true;
        let depth = 1;
        value += '\\(';
        i += 2;
        while (i < n && depth > 0) {
          if (source[i] === '(') depth += 1;
          else if (source[i] === ')') depth -= 1;
          value += source[i];
          i += 1;
        }
        continue;
      }
      value += c + (source[i + 1] ?? '');
      i += 2;
      continue;
    }
    if (isTriple) {
      if (c === '"' && source[i + 1] === '"' && source[i + 2] === '"') return { value, endIndex: i + 3, hasInterpolation };
    } else {
      if (c === '"') return { value, endIndex: i + 1, hasInterpolation };
      if (c === '\n') return { value, endIndex: i, hasInterpolation };
    }
    value += c;
    i += 1;
  }
  return { value, endIndex: i, hasInterpolation };
}

// A bare type/identifier token (optionally Optional (`?`) or force-unwrapped (`!`), optionally
// dotted member access) with no operator, call, or string seen yet — the shape of a plain type
// annotation like `String` or `String?`, as opposed to a real expression (ternary, call, member
// chain with `??`, etc.).
const BARE_TYPE_OR_IDENTIFIER_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*[?!]?$/;

// Captures a computed argument/type-annotation expression starting right after a `systemName:`/
// `systemImage:` label, up to (but not including) the comma or closing bracket that ends it at the
// same nesting depth — tracking `()`/`[]` and skipping over any nested string literal's own
// commas/brackets. A bare `{` always ends the capture immediately: none of this repository's real
// computed icon-argument expressions (identifiers, member access, ternaries, calls) contain one, so
// its only real meaning here is the start of a computed-property/closure *body* following a type
// annotation (e.g. `var systemImage: String { ... }`) — a construct this expression must stop before,
// not descend into. A stored-property/parameter type annotation has no comma, bracket, or brace to
// close it at all when it is the last sibling on its own line (e.g. `let systemImage: String`, or
// `var systemImage: String = "exclamationmark.triangle"` with a default value, as a whole statement)
// — there, reaching a newline, or a bare `=` default-value assignment, while still at depth 0 with
// nothing but a bare type/identifier captured so far also ends the capture there, rather than
// continuing to swallow the default value or the next, unrelated statement. A real expression (which
// always contains an operator, call, or string before either of those) is unaffected and keeps
// scanning across them.
function readComputedExpression(source, startIndex) {
  const n = source.length;
  let i = startIndex;
  let depth = 0;
  while (i < n) {
    const c = source[i];
    if (c === '"') {
      i = readStringLiteral(source, i).endIndex;
      continue;
    }
    if (c === '{') break;
    if (c === '(' || c === '[') { depth += 1; i += 1; continue; }
    if (c === ')' || c === ']') {
      if (depth === 0) break;
      depth -= 1;
      i += 1;
      continue;
    }
    if (c === ',' && depth === 0) break;
    if (
      depth === 0 &&
      (c === '\n' || (c === '=' && source[i + 1] !== '=')) &&
      BARE_TYPE_OR_IDENTIFIER_PATTERN.test(source.slice(startIndex, i).trim())
    ) break;
    i += 1;
  }
  return source.slice(startIndex, i);
}

function collapseWhitespace(text) {
  return text.trim().replace(/\s+/g, ' ');
}

// Resolves the identifier immediately preceding the nearest enclosing, still-unmatched `(` scanning
// backward from a keyword's start position (skipping comment/string bytes via `mask`) — the call or
// declaration this argument/parameter belongs to. Returns null when no enclosing `(` exists (a bare
// property declaration such as `let systemImage: String`) or when no identifier character sits
// directly before it.
function resolveCallHead(source, mask, keywordStart) {
  let i = keywordStart - 1;
  let depth = 0;
  let openParenIndex = -1;
  while (i >= 0) {
    if (mask[i] === 1) {
      const c = source[i];
      if (c === ')') depth += 1;
      else if (c === '(') {
        if (depth === 0) { openParenIndex = i; break; }
        depth -= 1;
      }
    }
    i -= 1;
  }
  if (openParenIndex === -1) return null;

  let j = openParenIndex - 1;
  while (j >= 0 && (mask[j] === 0 || /\s/.test(source[j]))) j -= 1;
  const end = j;
  while (j >= 0 && mask[j] === 1 && /[A-Za-z0-9_]/.test(source[j])) j -= 1;
  const start = j + 1;
  if (start > end) return null;
  return source.slice(start, end + 1);
}

// Scans one file's already-read source text. Exported so focused tests can exercise the real lexing/
// classification logic directly against fabricated snippets, without writing throwaway fixture files
// into the scanned source tree.
export function scanSwiftSource(source, relativePath) {
  const mask = buildCodeMask(source);
  const lineOf = buildLineIndex(source);
  const literalSites = new Map(); // icon name -> site[]
  const computedSites = [];

  KEYWORD_PATTERN.lastIndex = 0;
  let match;
  while ((match = KEYWORD_PATTERN.exec(source))) {
    const keywordStart = match.index;
    const matchEnd = keywordStart + match[0].length;
    let inCode = true;
    for (let k = keywordStart; k < matchEnd; k++) {
      if (mask[k] !== 1) { inCode = false; break; }
    }
    if (!inCode) continue;

    const keyword = match[1];
    let valueStart = matchEnd;
    while (valueStart < source.length && /\s/.test(source[valueStart])) valueStart += 1;

    const site = `${relativePath}:${lineOf[keywordStart]}`;
    const callHead = resolveCallHead(source, mask, keywordStart);

    if (source[valueStart] === '"') {
      const { value, hasInterpolation, endIndex } = readStringLiteral(source, valueStart);
      if (!hasInterpolation && value.length > 0) {
        if (!literalSites.has(value)) literalSites.set(value, []);
        literalSites.get(value).push(site);
        continue;
      }
      computedSites.push({ site, expression: collapseWhitespace(source.slice(valueStart, endIndex)), keyword, callHead });
      continue;
    }

    const expression = readComputedExpression(source, valueStart);
    computedSites.push({ site, expression: collapseWhitespace(expression), keyword, callHead });
  }

  return { literalSites, computedSites };
}

function listSwiftFiles(rootDir) {
  const results = [];
  const stack = [rootDir];
  while (stack.length > 0) {
    const dir = stack.pop();
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { stack.push(full); continue; }
      if (entry.isFile() && entry.name.endsWith('.swift')) results.push(full);
    }
  }
  return results;
}

function siteSortKey(site) {
  const idx = site.lastIndexOf(':');
  return [site.slice(0, idx), Number(site.slice(idx + 1))];
}

function compareSites(a, b) {
  const [pathA, lineA] = siteSortKey(a);
  const [pathB, lineB] = siteSortKey(b);
  if (pathA !== pathB) return pathA < pathB ? -1 : 1;
  return lineA - lineB;
}

export function scanRepository(repoRoot = REPO_ROOT, sourceRoots = SOURCE_ROOTS) {
  const files = [];
  for (const root of sourceRoots) {
    const absRoot = path.join(repoRoot, root);
    if (!fs.existsSync(absRoot)) continue;
    files.push(...listSwiftFiles(absRoot));
  }
  files.sort();

  const literalSitesByName = new Map();
  const computedSites = [];

  for (const file of files) {
    const relativePath = path.relative(repoRoot, file).split(path.sep).join('/');
    const source = fs.readFileSync(file, 'utf8');
    const { literalSites, computedSites: fileComputedSites } = scanSwiftSource(source, relativePath);
    for (const [name, sites] of literalSites) {
      if (!literalSitesByName.has(name)) literalSitesByName.set(name, []);
      literalSitesByName.get(name).push(...sites);
    }
    computedSites.push(...fileComputedSites);
  }

  const literals = [...literalSitesByName.entries()]
    .map(([name, sites]) => ({ name, count: sites.length, sites: [...sites].sort(compareSites) }))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

  computedSites.sort((a, b) => compareSites(a.site, b.site));

  return { literals, computedSites };
}

function serialize(inventory) {
  return `${JSON.stringify(inventory, null, 2)}\n`;
}

function main() {
  const checkOnly = process.argv.includes('--check');
  const inventory = scanRepository();
  const expected = serialize(inventory);

  if (!checkOnly) {
    fs.writeFileSync(OUTPUT_PATH, expected, 'utf8');
    process.stdout.write(
      `Wrote ${path.relative(CATALOG_ROOT, OUTPUT_PATH)} (${inventory.literals.length} literal names, ${inventory.computedSites.length} computed sites).\n`,
    );
    return;
  }

  if (!fs.existsSync(OUTPUT_PATH)) {
    process.stderr.write(
      `${path.relative(CATALOG_ROOT, OUTPUT_PATH)} does not exist. Regenerate it with: node scripts/generate-hermex-icon-inventory.mjs\n`,
    );
    process.exit(1);
  }
  const actual = fs.readFileSync(OUTPUT_PATH, 'utf8');
  if (actual !== expected) {
    process.stderr.write(
      `${path.relative(CATALOG_ROOT, OUTPUT_PATH)} is stale (does not match a fresh scan of the production Swift source).\n` +
        'Regenerate it with: node scripts/generate-hermex-icon-inventory.mjs\n',
    );
    process.exit(1);
  }
  process.stdout.write(`${path.relative(CATALOG_ROOT, OUTPUT_PATH)} is up to date.\n`);
}

const isMainModule = process.argv[1] != null && path.resolve(process.argv[1]) === __filename;
if (isMainModule) main();
