#!/usr/bin/env python3
"""Foundation-only Design System adoption audit.

Scope (read this before extending the contract): this branch adds Hermex Design System
foundation/token/component source files to the repository, but does not migrate any production
screen onto them. This audit protects that foundation layer — it fails closed when a required
foundation file, or one of its small set of load-bearing API snippets, goes missing or drifts. It does
not require, assert, or check production-screen adoption of any new component, and it does not count
or restrict native-control call sites (segmented pickers, `ContentUnavailableView`, `.searchable`,
`TextField`, `SecureField`) anywhere in production — migrating those is issue-driven work scoped to
separate PRs, not something a regex census in this script can usefully gate.

It also intentionally does NOT ban `.font`, other typography modifiers, literal colors, or literal
spacing across production generally — there is no sound, ownership-aware contract for banning those
globally yet.

This audit also enforces a second, narrower contract: a fail-closed production-disconnection
boundary for three named files (`AppTheme.swift`, `TranscriptLogRowView.swift`,
`CustomAttachmentPicker.swift` — see `PRODUCTION_BOUNDARY_PATTERNS`) that briefly took on direct
dependencies on this foundation during Issue #607 and were deliberately reverted. The boundary check
exists so those reverted dependencies cannot drift back in silently; it does not forbid these files
from adopting the foundation for real, it only requires that adoption be a deliberate, explicit
update to `PRODUCTION_BOUNDARY_PATTERNS` in the same bounded change, not a silent reintroduction.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

# ─── Required foundation source files ────────────────────────────────────────────────────────────
# The canonical foundation/token/component files this branch reconstructs. Every one must exist; a
# missing file fails closed rather than silently disabling the checks that depend on it.
REQUIRED_FOUNDATION_FILES = [
    "HermesMobile/Config/AppFont.swift",
    "HermesMobile/Config/HermesColor.swift",
    "HermesMobile/Config/HermesMotion.swift",
    "HermesMobile/Config/HermesRadius.swift",
    "HermesMobile/Config/HermesShadow.swift",
    "HermesMobile/Config/HermesSpacing.swift",
    "HermesMobile/Features/Shared/HermexCard.swift",
    "HermesMobile/Features/Shared/HermexButton.swift",
    "HermesMobile/Features/Shared/HermexCheckbox.swift",
    "HermesMobile/Features/Shared/HermexRadio.swift",
    "HermesMobile/Features/Shared/HermexSelectionSheet.swift",
    "HermesMobile/Features/Shared/HermexToast.swift",
    "HermesMobile/Features/Shared/HermexTooltip.swift",
    "HermesMobile/Features/Shared/HermexAvatar.swift",
    "HermesMobile/Features/Shared/HermexDivider.swift",
    "HermesMobile/Features/Shared/HermexContentUnavailable.swift",
    "HermesMobile/Features/Shared/HermexSearch.swift",
    "HermesMobile/Features/Shared/HermexTextInput.swift",
    "HermesMobile/Features/Shared/HermexBottomSheet.swift",
    "HermesMobile/Features/Shared/HermexSameWindowOverlay.swift",
    "HermesMobile/Features/Shared/HermexOverlayLifecycle.swift",
    "HermesMobile/Features/Shared/HermexDialog.swift",
    "HermesMobile/Features/Shared/HermexPopoverMenu.swift",
    "HermesMobile/Features/Shared/ListItem.swift",
    "HermesMobile/Features/Shared/HermexList.swift",
    "HermesMobile/Features/Shared/AccordionList.swift",
    "HermesMobile/Features/Shared/SegmentedControl.swift",
    "HermesMobile/Features/Shared/TopNav.swift",
    "HermesMobile/Features/Shared/HermexBanner.swift",
    "HermesMobile/Features/Shared/Tag.swift",
    "HermesMobile/Features/Shared/AttachmentFileType.swift",
    "HermesMobile/Features/Shared/AttachmentTile.swift",
    "HermesMobile/Features/Shared/SkeletonPlaceholder.swift",
    "HermesMobile/Features/Shared/HermexSurfaceBorder.swift",
    "HermesMobile/Features/Shared/HermexComposerToolbar.swift",
    "HermesMobile/Features/Chat/TranscriptLogRowView.swift",
]

# ─── Load-bearing API snippets ────────────────────────────────────────────────────────────────────
# One or two regexes per required file, pinned to the specific declaration a silent rename/removal
# would break — not a full API surface audit. (relative_path, [patterns]).
REQUIRED_SNIPPETS: list[tuple[str, list[str]]] = [
    ("HermesMobile/Config/AppFont.swift", [
        r"enum Role\s*:\s*CaseIterable",
        r"func appFont\(_ role: AppFont\.Role\)\s*->\s*some View",
    ]),
    ("HermesMobile/Config/HermesSpacing.swift", [
        r"enum HermesSpacing\s*\{",
        r"enum HermesIconSize\s*\{",
        r"enum HermesAvatarSize\s*:\s*CGFloat\s*,\s*CaseIterable",
    ]),
    ("HermesMobile/Features/Shared/HermexCard.swift", [
        r"enum HermexCardSurface",
    ]),
    ("HermesMobile/Features/Shared/ListItem.swift", [
        r"struct ListItem<[^>]*>\s*:\s*View",
        r"enum ListItemContentInset\s*:\s*Equatable",
        r"struct ListItemButtonStyle\s*:\s*ButtonStyle",
    ]),
    ("HermesMobile/Features/Shared/HermexList.swift", [
        r"struct HermexList<[^>]*>\s*:\s*View",
        r"case compactOverlay",
        r"rowHorizontalInset:\s*CGFloat\s*=\s*HermesSpacing\.s0",
        r"scrollContentMargin:\s*CGFloat\s*=\s*HermesSpacing\.s0",
    ]),
    ("HermesMobile/Features/Shared/AccordionList.swift", [
        r"struct AccordionList<[^>]*>\s*:\s*View",
        r"extension AccordionList where HeaderLeading == EmptyView",
    ]),
    ("HermesMobile/Features/Shared/HermexButton.swift", [
        r"struct HermexButtonStyle\s*:\s*ButtonStyle",
        r"struct HermexButtonPressOnlyStyle\s*:\s*ButtonStyle",
    ]),
    ("HermesMobile/Features/Shared/SegmentedControl.swift", [
        r"struct SegmentedControl<[^>]*>\s*:\s*View",
    ]),
    ("HermesMobile/Features/Shared/HermexContentUnavailable.swift", [
        r"struct HermexContentUnavailable\s*:\s*View",
    ]),
    ("HermesMobile/Features/Shared/HermexSearch.swift", [
        r"struct HermexSearchField\s*:\s*View",
        r"func hermexSearch\(",
        r"safeAreaInset\(edge:\s*\.top",
    ]),
    ("HermesMobile/Features/Shared/HermexTextInput.swift", [
        r"struct HermexTextField\s*:\s*View",
        r"struct HermexSecureField\s*:\s*View",
        r"struct HermexCodeInput\s*:\s*View",
        r"enum HermexCodeInputNormalizer",
        r"enum HermexCodeInputLayout",
    ]),
    ("HermesMobile/Features/Shared/HermexBottomSheet.swift", [
        r"struct HermexBottomSheet<[^>]*>\s*:\s*View",
        r"enum FooterAxis\s*\{",
    ]),
    ("HermesMobile/Features/Shared/HermexSameWindowOverlay.swift", [
        r"struct HermexSameWindowOverlay<[^>]*>\s*:\s*UIViewControllerRepresentable",
    ]),
    ("HermesMobile/Features/Shared/HermexOverlayLifecycle.swift", [
        r"struct HermexOverlayLifecycle",
        r"struct HermexOverlayActionContext",
    ]),
    ("HermesMobile/Features/Shared/HermexDialog.swift", [
        r"func hermexDialog[<(]",
        r"enum HermexDialogFooterAxis",
    ]),
    ("HermesMobile/Features/Shared/HermexPopoverMenu.swift", [
        r"func hermexPopoverMenu\(",
        r"struct HermexPopoverMenuAction",
        r"static let contentPadding:\s*CGFloat\s*=\s*HermesSpacing\.s16",
        r"contentInset:\s*\.none",
    ]),
    ("HermesMobile/Features/Shared/HermexSelectionSheet.swift", [
        r"struct HermexSelectionSheetOption<",
        r"struct HermexSelectionSheet<",
        r"HermexBottomSheet\(",
        r"enum HermexSelectionSheetFooterAxis\s*:\s*Equatable",
        r"footerAxis:\s*HermexSelectionSheetFooterAxis\s*=\s*\.horizontal",
    ]),
    ("HermesMobile/Features/Shared/HermexBanner.swift", [
        r"struct HermexBanner\s*:\s*View",
        r"let title:\s*Text\?",
        r"let description:\s*Text\?",
    ]),
    ("HermesMobile/Features/Shared/HermexSurfaceBorder.swift", [
        r"enum HermexSurfaceBorderRamp",
        r"enum HermexSurfaceBorderColors",
    ]),
    ("HermesMobile/Features/Shared/HermexComposerToolbar.swift", [
        r"struct HermexComposerToolbar<[^>]*>\s*:\s*View",
        r"enum HermexComposerToolbarAppearance",
        r"struct HermexComposerToolbarEdgeFades",
        r"struct HermexComposerToolbarDivider\s*:\s*View",
    ]),
    ("HermesMobile/Features/Chat/TranscriptLogRowView.swift", [
        r"TranscriptLogRowMetrics",
    ]),
]

# ─── Icon-size scale contract ──────────────────────────────────────────────────────────────────────
# Named top-level HermesIconSize cases must be exactly {12, 16, 20, 24, 32}pt. 14/18/22/28 were
# considered and rejected in the approved design spec; a future edit reintroducing one of them as a
# *named* size (not merely a one-off literal elsewhere) must fail this audit.
APPROVED_ICON_SIZES = {12, 16, 20, 24, 32}
REJECTED_ICON_SIZES = {14, 18, 22, 28}

# ─── Avatar/icon pairing contract ──────────────────────────────────────────────────────────────────
# HermesAvatarSize diameter -> the HermesIconSize.Avatar pairing's icon size. Approved design spec:
# 32pt avatar -> 20pt icon, 40pt avatar -> 24pt icon, 48pt avatar -> 32pt icon.
APPROVED_AVATAR_ICON_PAIRINGS = {32: 20, 40: 24, 48: 32}

# ─── Production disconnection boundary ───────────────────────────────────────────────────────────
# AppTheme.swift, TranscriptLogRowView.swift, and CustomAttachmentPicker.swift briefly gained direct
# dependencies on the Issue #607 foundation and were disconnected again (restored to their
# pre-existing literals/APIs/local implementation — see the PR #974 issue-correction). This check
# fails closed if one of them regains a dependency on a pattern below, so any real future adoption
# has to update this audit deliberately rather than drift back in unnoticed. It is not a permanent
# ban on adopting the foundation in these files — the failure message says so.
PRODUCTION_BOUNDARY_PATTERNS: list[tuple[str, list[str]]] = [
    ("HermesMobile/Config/AppTheme.swift", [r"HermesProductPalette"]),
    (
        "HermesMobile/Features/Chat/TranscriptLogRowView.swift",
        [r"HermesSpacing", r"HermesRadius", r"HermesIconSize", r"HermesMotion", r"AppFont\.Role", r"\.appFont\("],
    ),
    ("HermesMobile/Features/Chat/CustomAttachmentPicker.swift", [r"HermexSameWindowOverlay"]),
]


def _strip_swift_comments(text: str) -> str:
    """Removes `//` and (nesting-aware) `/* ... */` comments from Swift source so a comment that
    merely mentions a forbidden symbol cannot trip a dependency check. Does not treat `//`/`/*`
    found inside a double-quoted string literal as a comment start, and preserves every original
    newline so line-oriented regexes/messages built from the result stay readable."""
    out: list[str] = []
    i, n = 0, len(text)
    in_string = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    i += 2
                    continue
                if text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    i += 2
                    continue
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_production_boundary() -> list[str]:
    failures = []
    for rel_path, patterns in PRODUCTION_BOUNDARY_PATTERNS:
        full_path = REPO_ROOT / rel_path
        if not full_path.is_file():
            continue
        text = _strip_swift_comments(read(rel_path))
        for pattern in patterns:
            if re.search(pattern, text):
                failures.append(
                    f"{rel_path} reintroduces a direct dependency on /{pattern}/ — adopting the Issue #607 "
                    "foundation here requires an explicit adoption update to this audit, not a silent "
                    "reintroduction"
                )
    return failures


def read(rel_path: str) -> str:
    return (REPO_ROOT / rel_path).read_text(encoding="utf-8")


def check_required_files() -> list[str]:
    failures = []
    for rel_path in REQUIRED_FOUNDATION_FILES:
        if not (REPO_ROOT / rel_path).is_file():
            failures.append(f"missing required foundation file: {rel_path}")
    return failures


def check_required_snippets() -> list[str]:
    failures = []
    for rel_path, patterns in REQUIRED_SNIPPETS:
        full_path = REPO_ROOT / rel_path
        if not full_path.is_file():
            # Already reported by check_required_files(); avoid a duplicate/confusing failure.
            continue
        text = read(rel_path)
        for pattern in patterns:
            if not re.search(pattern, text):
                failures.append(f"missing load-bearing snippet in {rel_path}: /{pattern}/")
    return failures


def _named_static_let_values(text: str, enum_name: str) -> dict[str, int]:
    """Top-level `static let <name>: CGFloat = <int>` declarations inside `enum <enum_name> { ... }`
    only — nested enums (e.g. HermesIconSize.Typography/.Avatar) are excluded by stopping at the
    first nested `enum`/`struct` block or the enclosing enum's own closing brace."""
    match = re.search(rf"enum {enum_name}\s*\{{", text)
    if not match:
        return {}
    start = match.end()
    depth = 1
    end = start
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                end = index
                break
    body = text[start:end]
    # Stop at the first nested enum/struct so only this enum's own top-level cases are collected.
    nested = re.search(r"\n\s*(enum|struct)\s+\w+", body)
    if nested:
        body = body[: nested.start()]
    values = {}
    for name, value in re.findall(r"static let (\w+)\s*:\s*CGFloat\s*=\s*(\d+)", body):
        values[name] = int(value)
    return values


def check_icon_scale() -> list[str]:
    rel_path = "HermesMobile/Config/HermesSpacing.swift"
    full_path = REPO_ROOT / rel_path
    if not full_path.is_file():
        return []
    text = read(rel_path)
    values = _named_static_let_values(text, "HermesIconSize")
    if not values:
        return [f"could not find any named HermesIconSize cases in {rel_path}"]
    found = set(values.values())
    failures = []
    missing = APPROVED_ICON_SIZES - found
    if missing:
        failures.append(f"HermesIconSize is missing approved named size(s) {sorted(missing)}pt")
    drifted = found & REJECTED_ICON_SIZES
    if drifted:
        failures.append(
            f"HermesIconSize names rejected size(s) {sorted(drifted)}pt "
            f"(14/18/22/28 were considered and rejected in the approved design spec)"
        )
    extra = found - APPROVED_ICON_SIZES - REJECTED_ICON_SIZES
    if extra:
        failures.append(f"HermesIconSize names unapproved size(s) {sorted(extra)}pt")
    return failures


def check_avatar_pairing() -> list[str]:
    rel_path = "HermesMobile/Config/HermesSpacing.swift"
    full_path = REPO_ROOT / rel_path
    if not full_path.is_file():
        return []
    text = read(rel_path)

    avatar_match = re.search(r"enum HermesAvatarSize[^{]*\{([\s\S]*?)\n\}", text)
    if not avatar_match:
        return [f"could not find enum HermesAvatarSize in {rel_path}"]
    avatar_sizes = {
        name: int(value)
        for name, value in re.findall(r"case (\w+)\s*=\s*(\d+)", avatar_match.group(1))
    }

    pairing_match = re.search(r"enum Avatar\s*\{([\s\S]*?)\n\s*\}", text)
    if not pairing_match:
        return [f"could not find the nested HermesIconSize.Avatar pairing enum in {rel_path}"]
    icon_names = dict(
        re.findall(r"static let (\w+)\s*=\s*HermesIconSize\.(\w+)", pairing_match.group(1))
    )
    icon_sizes = _named_static_let_values(text, "HermesIconSize")

    failures = []
    for avatar_name, diameter in avatar_sizes.items():
        icon_case_name = icon_names.get(avatar_name)
        if icon_case_name is None:
            failures.append(f"HermesIconSize.Avatar has no pairing for HermesAvatarSize.{avatar_name}")
            continue
        icon_size = icon_sizes.get(icon_case_name)
        expected = APPROVED_AVATAR_ICON_PAIRINGS.get(diameter)
        if expected is None:
            failures.append(f"HermesAvatarSize.{avatar_name} ({diameter}pt) is not an approved avatar diameter")
            continue
        if icon_size != expected:
            failures.append(
                f"HermesAvatarSize.{avatar_name} ({diameter}pt) pairs with HermesIconSize.{icon_case_name} "
                f"({icon_size}pt) — expected {expected}pt (see APPROVED_AVATAR_ICON_PAIRINGS)"
            )
    return failures


CHECKS = [
    ("required foundation files", check_required_files),
    ("load-bearing API snippets", check_required_snippets),
    ("icon-size scale", check_icon_scale),
    ("avatar/icon pairing", check_avatar_pairing),
    ("production disconnection boundary", check_production_boundary),
]


def run(root: pathlib.Path = REPO_ROOT) -> list[str]:
    global REPO_ROOT
    REPO_ROOT = root
    failures: list[str] = []
    for _, check in CHECKS:
        failures.extend(check())
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=REPO_ROOT,
        help="Repository root to audit (defaults to this script's own repository).",
    )
    args = parser.parse_args(argv)

    failures = run(args.root.resolve())

    if failures:
        print(f"hermex_design_system_adoption_audit: FAILED ({len(failures)} issue(s))", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("hermex_design_system_adoption_audit: OK — foundation contract intact.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
