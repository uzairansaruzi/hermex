#!/usr/bin/env python3
"""Validate and import the externally supplied Catalan localization package."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any


PLACEHOLDER_RE = re.compile(
    r"%%|"
    r"%(?:\d+\$)?[-+ #0']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]|"
    r"%[A-Za-z_][A-Za-z0-9_]*|"
    r"\$\{[A-Za-z_][A-Za-z0-9_]*\}"
)
SWIFT_INTERPOLATION_RE = re.compile(r"\\\([^)]*\)")


class PackageError(ValueError):
    pass


@dataclass(frozen=True)
class Span:
    start: int
    end: int


@dataclass(frozen=True)
class Property:
    key: str
    key_start: int
    value_start: int
    value_end: int


def placeholder_counts(value: str) -> Counter[str]:
    return Counter(PLACEHOLDER_RE.findall(value))


def _skip_whitespace(text: str, offset: int) -> int:
    while offset < len(text) and text[offset] in " \t\r\n":
        offset += 1
    return offset


def _scan_string(text: str, offset: int) -> int:
    if text[offset] != '"':
        raise PackageError(f"Expected a JSON string at byte {offset}")
    offset += 1
    while offset < len(text):
        if text[offset] == "\\":
            offset += 2
            continue
        if text[offset] == '"':
            return offset + 1
        offset += 1
    raise PackageError("Unterminated JSON string")


def _scan_value(text: str, offset: int) -> tuple[int, list[Property]]:
    offset = _skip_whitespace(text, offset)
    if offset >= len(text):
        raise PackageError("Expected a JSON value")
    if text[offset] == '"':
        return _scan_string(text, offset), []
    if text[offset] == "{":
        return _scan_object(text, offset)
    if text[offset] == "[":
        return _scan_array(text, offset)
    while offset < len(text) and text[offset] not in ",]} \t\r\n":
        offset += 1
    return offset, []


def _scan_array(text: str, offset: int) -> tuple[int, list[Property]]:
    offset += 1
    while True:
        offset = _skip_whitespace(text, offset)
        if offset >= len(text):
            raise PackageError("Unterminated JSON array")
        if text[offset] == "]":
            return offset + 1, []
        value_end, _ = _scan_value(text, offset)
        offset = _skip_whitespace(text, value_end)
        if text[offset] == ",":
            offset += 1
            continue
        if text[offset] == "]":
            return offset + 1, []
        raise PackageError(f"Unexpected character in array at byte {offset}")


def _scan_object(text: str, offset: int) -> tuple[int, list[Property]]:
    offset += 1
    properties: list[Property] = []
    while True:
        offset = _skip_whitespace(text, offset)
        if offset >= len(text):
            raise PackageError("Unterminated JSON object")
        if text[offset] == "}":
            return offset + 1, properties
        key_start = offset
        key_end = _scan_string(text, offset)
        key = json.loads(text[key_start:key_end])
        offset = _skip_whitespace(text, key_end)
        if offset >= len(text) or text[offset] != ":":
            raise PackageError(f"Expected ':' after {key!r}")
        value_start = _skip_whitespace(text, offset + 1)
        value_end, _ = _scan_value(text, value_start)
        properties.append(Property(key, key_start, value_start, value_end))
        offset = _skip_whitespace(text, value_end)
        if text[offset] == ",":
            offset += 1
            continue
        if text[offset] == "}":
            return offset + 1, properties
        raise PackageError(f"Unexpected character in object at byte {offset}")


def _property(properties: list[Property], name: str) -> Property:
    for item in properties:
        if item.key == name:
            return item
    raise PackageError(f"Missing {name!r} property")


def _source_text(entry: dict[str, Any]) -> str:
    return "\n".join(unit["source"] for unit in entry["units"])


def _expected_placeholders(entry: dict[str, Any]) -> Counter[str]:
    sources = [unit["source"] for unit in entry["units"]]
    if any(SWIFT_INTERPOLATION_RE.search(source) for source in sources):
        return Counter(entry.get("placeholders") or [])
    expected: Counter[str] = Counter()
    for source in sources:
        expected.update(placeholder_counts(source))
    return expected


def validate_document_pair(source: dict[str, Any], returned: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    for field in ("schemaVersion", "sourceLanguage", "targetLanguage", "catalog"):
        if source.get(field) != returned.get(field):
            errors.append(f"header mismatch for {field}")
    source_entries = source.get("entries")
    returned_entries = returned.get("entries")
    if not isinstance(source_entries, list) or not isinstance(returned_entries, list):
        return errors + ["entries must be arrays"]
    if len(source_entries) != len(returned_entries):
        return errors + ["entry count mismatch"]

    seen: set[str] = set()
    for index, (source_entry, returned_entry) in enumerate(zip(source_entries, returned_entries)):
        entry_id = source_entry.get("id", f"entry[{index}]")
        context = f"[{entry_id}]"
        if entry_id in seen:
            errors.append(f"{context}: duplicate ID")
        seen.add(entry_id)
        source_without_target = copy.deepcopy(source_entry)
        returned_without_target = copy.deepcopy(returned_entry)
        source_without_target["target"] = None
        returned_without_target["target"] = None
        if source_without_target != returned_without_target:
            errors.append(f"{context}: source or metadata changed")
            continue

        target = returned_entry.get("target")
        structured = any(
            "substitution" in unit or "variation" in unit
            for unit in source_entry.get("units", [])
        )
        if structured:
            cases = [unit["case"] for unit in source_entry["units"] if "case" in unit]
            if len(cases) != len(set(cases)):
                errors.append(f"{context}: duplicate source plural cases are not supported")
                continue
            if not isinstance(target, dict) or list(target.keys()) != cases:
                errors.append(f"{context}: plural cases must be {cases}")
                continue
            strings = list(target.values())
            for unit in source_entry["units"]:
                case = unit["case"]
                expected = _expected_placeholders(
                    {"units": [unit], "placeholders": source_entry.get("placeholders") or []}
                )
                actual = placeholder_counts(target[case])
                if expected != actual:
                    errors.append(
                        f"{context}: branch {case} placeholder mismatch "
                        f"expected={dict(expected)} actual={dict(actual)}"
                    )
        else:
            if not isinstance(target, str):
                errors.append(f"{context}: target must be a string")
                continue
            strings = [target]

        if any(not isinstance(value, str) or not value.strip() for value in strings):
            errors.append(f"{context}: empty target")
            continue
        if any(SWIFT_INTERPOLATION_RE.search(value) for value in strings):
            errors.append(f"{context}: Swift interpolation remains in target")
        if not structured:
            expected = _expected_placeholders(source_entry)
            actual: Counter[str] = Counter()
            for value in strings:
                actual.update(placeholder_counts(value))
            if expected != actual:
                errors.append(
                    f"{context}: placeholder mismatch expected={dict(expected)} actual={dict(actual)}"
                )
    return errors


def validate_package(
    package: Path,
    repo: Path | None = None,
    check_source_hashes: bool = False,
) -> dict[str, Any]:
    manifest_path = package / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError(f"Cannot read manifest: {error}") from error

    expected_files = manifest.get("batches")
    if not isinstance(expected_files, list) or not expected_files:
        raise PackageError("Manifest has no batches")
    expected_names = sorted(item["file"] for item in expected_files)
    source_names = sorted(path.name for path in (package / "source").glob("*.json"))
    returned_names = sorted(path.name for path in (package / "returned").glob("*.json"))
    if source_names != expected_names or returned_names != expected_names:
        raise PackageError("Source or returned files do not match the manifest")

    if repo is not None:
        actual_revision = subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
        ).strip()
        if check_source_hashes:
            if actual_revision != manifest.get("sourceRevision"):
                raise PackageError(
                    f"Stale package: expected {manifest.get('sourceRevision')}, found {actual_revision}"
                )
            for item in manifest.get("sourceFiles", []):
                path = repo / item["path"]
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                if digest != item["sha256"]:
                    raise PackageError(f"Source changed since extraction: {item['path']}")

    errors: list[str] = []
    totals: Counter[str] = Counter()
    for item in expected_files:
        filename = item["file"]
        try:
            source = json.loads((package / "source" / filename).read_text(encoding="utf-8"))
            returned = json.loads((package / "returned" / filename).read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            errors.append(f"{filename}: malformed JSON: {error}")
            continue
        pair_errors = validate_document_pair(source, returned)
        errors.extend(f"{filename}: {error}" for error in pair_errors)
        totals[source.get("catalog", "unknown")] += len(source.get("entries", []))

    for catalog, expected in manifest.get("catalogs", {}).items():
        if totals[catalog] != expected["entryCount"]:
            errors.append(
                f"{catalog}: manifest says {expected['entryCount']}, found {totals[catalog]}"
            )
    if errors:
        raise PackageError("\n".join(errors))
    return manifest


def returned_entries(package: Path, catalog: str) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for path in sorted((package / "returned").glob("*.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        if document["catalog"] == catalog:
            entries.extend(document["entries"])
    return entries


def _ca_localization(entry: dict[str, Any], english: dict[str, Any]) -> dict[str, Any]:
    target = entry["target"]
    structure = entry.get("sourceStructure")
    if not structure:
        return {
            "stringUnit": {
                "state": "needs_review",
                "value": target,
            }
        }

    root_variations = english.get("variations")
    if isinstance(root_variations, dict):
        localized_variations: dict[str, Any] = {}
        for kind, cases in root_variations.items():
            if not isinstance(cases, dict):
                continue
            localized_variations[kind] = {
                case: {
                    "stringUnit": {
                        "state": "needs_review",
                        "value": target[case],
                    }
                }
                for case in cases
            }
        return {"variations": localized_variations}

    substitutions = english.get("substitutions")
    if not isinstance(substitutions, dict) or len(substitutions) != 1:
        raise PackageError(f"[{entry['id']}] expected one source substitution")
    substitution_name, source_substitution = next(iter(substitutions.items()))
    cases = entry["units"]
    if len(cases) != len(target):
        raise PackageError(f"[{entry['id']}] plural target is incomplete")

    localized_substitution = copy.deepcopy(source_substitution)
    for unit in cases:
        case = unit["case"]
        localized_substitution["variations"]["plural"][case] = {
            "stringUnit": {
                "state": "needs_review",
                "value": target[case],
            }
        }
    template = structure.get("template")
    if not isinstance(template, str):
        raise PackageError(f"[{entry['id']}] plural source has no string template")
    return {
        "stringUnit": {
            "state": "needs_review",
            "value": template,
        },
        "substitutions": {
            substitution_name: localized_substitution,
        },
    }


def add_language_to_catalog(
    catalog_text: str,
    translations: list[dict[str, Any]],
    language: str = "ca",
) -> str:
    parsed = json.loads(catalog_text)
    strings = parsed.get("strings")
    if not isinstance(strings, dict):
        raise PackageError("Catalog has no strings object")
    by_key = {entry["key"]: entry for entry in translations}
    if len(by_key) != len(translations):
        raise PackageError("Duplicate translated keys")
    translatable_keys = {
        key for key, entry in strings.items() if entry.get("shouldTranslate") is not False
    }
    missing = sorted(translatable_keys - set(by_key))
    unneeded = sorted(set(by_key) - translatable_keys)
    if missing or unneeded:
        raise PackageError(f"Catalog key mismatch: missing={missing[:5]} unneeded={unneeded[:5]}")

    _, root_properties = _scan_object(catalog_text, _skip_whitespace(catalog_text, 0))
    strings_property = _property(root_properties, "strings")
    _, string_properties = _scan_object(catalog_text, strings_property.value_start)
    string_spans = {item.key: item for item in string_properties}

    edits: list[tuple[int, str]] = []
    for key, entry in by_key.items():
        entry_property = string_spans[key]
        _, entry_properties = _scan_object(catalog_text, entry_property.value_start)
        localizations_property = _property(entry_properties, "localizations")
        localization_end, localization_properties = _scan_object(
            catalog_text, localizations_property.value_start
        )
        if any(item.key == language for item in localization_properties):
            raise PackageError(f"[{key}] already contains {language}")
        localizations = parsed["strings"][key].get("localizations", {})
        english = localizations.get("en", {})
        ca_value = _ca_localization(entry, english)
        encoded = json.dumps(ca_value, ensure_ascii=False, separators=(", ", " : "))
        if localization_properties:
            insertion = localization_properties[-1].value_end
            line_start = catalog_text.rfind("\n", 0, localization_properties[-1].key_start) + 1
            indent = catalog_text[line_start : localization_properties[-1].key_start]
            if not indent.strip():
                separator = ",\n" + indent
                replacement = separator + f'"{language}" : {encoded}'
            else:
                replacement = f', "{language}" : {encoded}'
        else:
            insertion = localization_end - 1
            replacement = f'"{language}" : {encoded}'
        edits.append((insertion, replacement))

    for position, replacement in sorted(edits, reverse=True):
        catalog_text = catalog_text[:position] + replacement + catalog_text[position:]

    updated = json.loads(catalog_text)
    for key in translatable_keys:
        expected = copy.deepcopy(parsed["strings"][key])
        localizations = parsed["strings"][key].get("localizations", {})
        expected.setdefault("localizations", {})[language] = _ca_localization(
            by_key[key], localizations.get("en", {})
        )
        if updated["strings"][key] != expected:
            raise PackageError(f"[{key}] catalog import changed an unrelated field")
    return catalog_text


def build_small_catalog(entries: list[dict[str, Any]]) -> str:
    result: dict[str, Any] = {
        "sourceLanguage": "en",
        "strings": {},
        "version": "1.0",
    }
    for entry in entries:
        if entry.get("sourceStructure"):
            raise PackageError(f"[{entry['id']}] unsupported structured entry in small catalog")
        if len(entry["units"]) != 1:
            raise PackageError(f"[{entry['id']}] expected one source unit")
        # Small catalogs are used only by code that passes the key itself to the
        # localization API. Keep its source value in catalog format rather than
        # copying Swift runtime interpolation syntax from the handoff.
        source = entry["key"]
        item: dict[str, Any] = {
            "localizations": {
                "en": {
                    "stringUnit": {
                        "state": "translated",
                        "value": source,
                    }
                },
                "ca": {
                    "stringUnit": {
                        "state": "needs_review",
                        "value": entry["target"],
                    }
                },
            }
        }
        if entry.get("comment"):
            item["comment"] = entry["comment"]
        result["strings"][entry["key"]] = item
    return json.dumps(result, ensure_ascii=False, indent=2) + "\n"


def _atomic_write(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(data)
        temporary = Path(handle.name)
    os.replace(temporary, path)


def import_package(package: Path, repo: Path) -> None:
    validate_package(package, repo, check_source_hashes=True)

    localizable_entries = returned_entries(package, "Localizable")
    shortcuts = returned_entries(package, "AppShortcuts")
    info_plist = returned_entries(package, "InfoPlist")
    auxiliary = returned_entries(package, "Auxiliary")
    share = returned_entries(package, "ShareExtension")

    localizable_path = repo / "HermesMobile/Resources/Localizable.xcstrings"
    shortcuts_path = repo / "HermesMobile/Resources/AppShortcuts.xcstrings"
    localizable_text = add_language_to_catalog(
        localizable_path.read_text(encoding="utf-8"), localizable_entries
    )
    shortcuts_text = add_language_to_catalog(
        shortcuts_path.read_text(encoding="utf-8"), shortcuts
    )
    auxiliary_text = build_small_catalog(auxiliary)
    share_text = build_small_catalog(share)
    info_lines = [
        f"{json.dumps(entry['key'], ensure_ascii=False)} = "
        f"{json.dumps(entry['target'], ensure_ascii=False)};"
        for entry in info_plist
    ]

    _atomic_write(localizable_path, localizable_text)
    _atomic_write(shortcuts_path, shortcuts_text)
    _atomic_write(
        repo / "HermesMobile/Resources/Auxiliary.xcstrings",
        auxiliary_text,
    )
    _atomic_write(
        repo / "HermesShareExtension/Resources/ShareExtension.xcstrings",
        share_text,
    )
    _atomic_write(
        repo / "HermesMobile/Resources/ca.lproj/InfoPlist.strings",
        "\n".join(info_lines) + "\n",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "import"))
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument(
        "--check-source",
        action="store_true",
        help="also compare the package snapshot hashes with the current source files",
    )
    args = parser.parse_args()
    try:
        if args.command == "validate":
            manifest = validate_package(
                args.package.resolve(),
                args.repo.resolve(),
                check_source_hashes=args.check_source,
            )
            print(
                f"VALID: {manifest['totalEntries']} entries from "
                f"{manifest['sourceRevision']}"
            )
        else:
            import_package(args.package.resolve(), args.repo.resolve())
            print("IMPORTED")
    except PackageError as error:
        print(f"INVALID: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
