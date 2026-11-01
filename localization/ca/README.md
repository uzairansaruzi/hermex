# Catalan localization package

This directory contains the externally supplied Catalan (`ca`) localization for
Hermex source revision `f35a52cba986b0299b490092d936bb83d89a93aa`.

All target-language copy came from an external human translator. Codex performed
extraction, structural conversion, validation, and integration only.

## Contents

- `manifest.json`: source revision, source checksums, batch list, catalog counts,
  translation state, and import policy.
- `source/`: English source snapshots. Every target is null.
- `returned/`: the translator's completed return packages. Target fields only
  differ from `source/`.
- `glossary.md`: the external translator's terminology and style guidance.

The package contains:

- 2,785 `Localizable` entries in 56 batches
- 11 App Shortcut phrases
- 7 system permission descriptions
- 5 auxiliary app/widget entries
- 5 share-extension entries

## Return invariants

- Source keys, source values, comments, IDs, placeholders, structures, and
  metadata remain unchanged.
- Every target is non-empty and uses the catalog's compact placeholder form.
- Root plural and named-substitution entries retain every source case.
- Every target uses state `needs_review`.
- A stale source revision, malformed file, missing or duplicate ID, changed
  source field, missing case, or placeholder mismatch rejects the entire import.

## Validation and import

From the repository root:

```zsh
python3 scripts/catalan_localization.py validate --package localization/ca --repo .
python3 scripts/catalan_localization.py import --package localization/ca --repo .
```

The importer validates the whole package before writing anything, then adds only
the `ca` localization blocks. Existing language data and untouched catalog bytes
are preserved.
