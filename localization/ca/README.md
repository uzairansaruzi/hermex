# Catalan localization package

This directory contains the externally supplied Catalan (`ca`) localization for
Hermex. The package currently mirrors upstream source revision
`b15b4eb4e7f49001e1c627fc24b4f48384511858` (plus the two catalogues this branch owns, whose
checksums were taken from `issue/1505-catalan-localization`).

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

- 3,140 `Localizable` entries in 63 batches
- 11 App Shortcut phrases
- 7 system permission descriptions
- 5 auxiliary app/widget entries
- 5 share-extension entries

## Return invariants

- Source keys, source values, comments, IDs, placeholders, structures, and
  metadata remain unchanged.
- Every target is non-empty and uses the catalog's compact placeholder form.
- Root plural and named-substitution entries retain every source case, and each
  branch keeps the placeholders of its own source branch.
- Every target uses state `needs_review`.
- A stale source revision, malformed file, missing or duplicate ID, changed
  source field, missing case, or placeholder mismatch rejects the entire import.

## Validation and import

The importer is a build step, never an edit: it validates the whole package and
adds only `ca` localization blocks, so the catalogues must not be edited by hand.

`validate` runs on any checkout:

```zsh
python3 scripts/catalan_localization.py validate --package localization/ca --repo .
```

`import` additionally requires the checkout's `HEAD` to equal the manifest's
`sourceRevision` and each source file to match its recorded checksum, so it runs
on a tree that holds the pinned sources — not on this branch, which already
carries `ca`:

```zsh
git worktree add /tmp/hermex-src b15b4eb4e7f49001e1c627fc24b4f48384511858

# Auxiliary.xcstrings and ShareExtension.xcstrings are added by this branch, so
# the pinned revision does not contain them; their recorded checksums describe
# the branch's copies. Put those copies in place before importing.
git show HEAD:HermesMobile/Resources/Auxiliary.xcstrings \
  > /tmp/hermex-src/HermesMobile/Resources/Auxiliary.xcstrings
mkdir -p /tmp/hermex-src/HermesShareExtension/Resources
git show HEAD:HermesShareExtension/Resources/ShareExtension.xcstrings \
  > /tmp/hermex-src/HermesShareExtension/Resources/ShareExtension.xcstrings

# run this branch's importer against that checkout
python3 scripts/catalan_localization.py import --package localization/ca --repo /tmp/hermex-src
```

The importer reads every catalogue in the checkout it is pointed at, `--repo`,
and rewrites all five of them (`Localizable`, `AppShortcuts`, `Auxiliary`,
`ShareExtension` and `ca.lproj/InfoPlist.strings`); copy those five files back
onto the branch. Skipping the two branch-owned catalogues makes the run stop
with `FileNotFoundError` on `Auxiliary.xcstrings`, because the pinned revision
does not have them. Running `import --package localization/ca --repo .` on the
feature branch reports `Stale package: expected …, found …` by design, and is
not the supported way to reproduce the catalogue.

The importer validates the whole package before writing anything, then adds only
the `ca` localization blocks. Existing language data and untouched catalog bytes
are preserved.
