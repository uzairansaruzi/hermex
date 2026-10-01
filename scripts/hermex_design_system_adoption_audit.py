#!/usr/bin/env python3
"""Foundation-only Design System adoption audit.

Scope (read this before extending the contract): this branch adds Hermex Design System
foundation/token/component source files to the repository, but does not migrate any production
screen onto them. This audit protects that foundation layer — it fails closed when a required
foundation file, or one of its small set of load-bearing API snippets, goes missing or drifts — and
freezes five pre-existing production baselines (native segmented controls, direct
ContentUnavailableView calls, direct `.searchable` calls, direct `TextField(` calls, direct
`SecureField(` calls) so a *new* untracked site or an *increased* count fails, without requiring any
existing screen to migrate. It does not require, assert, or check production-screen adoption of any
new component.

It also intentionally does NOT ban `.font`, other typography modifiers, literal colors, or literal
spacing across production generally — there is no sound, ownership-aware contract for banning those
globally yet. Only the five explicitly frozen baselines below are enforced, and only because their
exact current-state counts were verified against this branch's own source before being written here.

Baseline ownership and removal condition: all five frozen baselines (SEGMENTED_CONTROL_BASELINE,
CONTENT_UNAVAILABLE_BASELINE, SEARCHABLE_BASELINE, TEXT_FIELD_BASELINE, SECURE_FIELD_BASELINE) are
owned by whoever lands the next PR that changes one of their call sites — adding, removing, or
migrating one. That PR must update the baseline dict in the same PR to match the new verified state;
this script deliberately fails otherwise, rather than silently drifting. A baseline count may only
ever move down (migration) or a path disappear entirely in the same PR that performs the migration —
never move up, and a path may never appear that was not already in the baseline, without maintainer
review of why a new direct call site was added instead of using the foundation component that
already exists for it.
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

# ─── Frozen native segmented-control baseline ────────────────────────────────────────────────────
# Owner: whoever lands the PR that migrates one of these three files onto the new SegmentedControl
# foundation component (or adds a new direct .pickerStyle(.segmented) call site). Removal condition:
# delete a file's entry here (or lower its count) in the same PR that migrates/removes that call site.
SEGMENTED_CONTROL_BASELINE = {
    "HermesMobile/Features/Insights/InsightsView.swift": 1,
    "HermesMobile/Features/Insights/UsageChartCard.swift": 1,
    "HermesMobile/Features/Tasks/TasksView.swift": 1,
}
SEGMENTED_CONTROL_PATTERN = re.compile(r"\.pickerStyle\(\.segmented\)")

# ─── Frozen direct ContentUnavailableView baseline ───────────────────────────────────────────────
# Owner: whoever lands the PR that migrates one of these call sites onto HermexContentUnavailable (or
# adds a new direct ContentUnavailableView call site). Removal condition: delete a file's entry here
# (or lower its count) in the same PR that migrates/removes that call site. Verified against this
# branch's own source (2026-09-28); HermexContentUnavailable.swift itself and HermesMobileTests/ are
# excluded from this accounting.
CONTENT_UNAVAILABLE_BASELINE = {
    "HermesMobile/Features/Skills/SkillsView.swift": 6,
    "HermesMobile/Features/Workspace/FilePreviewView.swift": 4,
    "HermesMobile/Features/Tasks/CronJobSkillsPicker.swift": 4,
    "HermesMobile/Features/Tasks/CronJobConfigurationPickers.swift": 4,
    "HermesMobile/Features/Settings/DefaultProfilePickerView.swift": 4,
    "HermesMobile/Features/Workspace/GitWorkspaceView.swift": 3,
    "HermesMobile/Features/Workspace/GitCommitView.swift": 3,
    "HermesMobile/Features/Tasks/TasksView.swift": 3,
    "HermesMobile/Features/Shared/ModelPickerSheet.swift": 3,
    "HermesMobile/Features/Settings/ProvidersView.swift": 3,
    "HermesMobile/Features/Kanban/KanbanLabView.swift": 3,
    "HermesMobile/Features/Workspace/FileBrowserView.swift": 2,
    "HermesMobile/Features/Tasks/TaskRunOutputSheet.swift": 2,
    "HermesMobile/Features/SessionList/SessionListView.swift": 2,
    "HermesMobile/Features/Kanban/KanbanCardDetailView.swift": 2,
    "HermesMobile/Features/Insights/InsightsView.swift": 2,
    "HermesMobile/Features/Chat/TranscriptMediaView.swift": 2,
    "HermesMobile/Features/Chat/ChatTranscriptView.swift": 2,
    "HermesMobile/Features/Chat/ChatAttachmentPreviewView.swift": 2,
    "HermesMobile/Features/Bots/BotDelegatedWorkView.swift": 2,
    "HermesMobile/Features/Workspace/WorkspaceManagerView.swift": 1,
    "HermesMobile/Features/Workspace/GitDiffView.swift": 1,
    "HermesMobile/Features/Memory/MemoryView.swift": 1,
    "HermesMobile/Features/Chat/ChatComposerSelectorSheets.swift": 1,
    "HermesMobile/Features/Bots/BotsInboxView.swift": 1,
    "HermesMobile/Features/Bots/BotSearchView.swift": 1,
    "HermesMobile/Features/Bots/BotQuickRepliesEditorView.swift": 1,
    "HermesMobile/Features/Bots/BotProfileEditorView.swift": 1,
    "HermesMobile/Features/Bots/BotChatView.swift": 1,
    "HermesMobile/Features/Bots/BotArtifactPreview.swift": 1,
}
CONTENT_UNAVAILABLE_PATTERN = re.compile(r"\bContentUnavailableView\b")
CONTENT_UNAVAILABLE_EXCLUDED_FILE = "HermesMobile/Features/Shared/HermexContentUnavailable.swift"

# ─── Frozen direct .searchable baseline ──────────────────────────────────────────────────────────
# This branch replaces the old `.hermexSearch(text:placement:prompt:)` foundation wrapper — which
# forwarded straight to native `.searchable` — with a custom `HermexSearchField` view and a
# `.hermexSearch(...)` convenience modifier that composes it as a persistent top content inset.
# HermexSearch.swift itself must never call `.searchable` again, so it is no longer excluded from
# this accounting: a stray `.searchable(` call inside it now fails like any other new, unfrozen call
# site. Production does not migrate any screen in this slice — every current search field keeps
# calling `.searchable` directly. Owner: whoever lands the PR that migrates one of these eight call
# sites onto `.hermexSearch` (or adds a new direct `.searchable` call site). Removal condition:
# delete a file's entry here (or lower its count) in the same PR that migrates/removes that call
# site. Verified against this branch's own source (2026-09-28).
SEARCHABLE_BASELINE = {
    "HermesMobile/Features/Kanban/KanbanLabView.swift": 1,
    "HermesMobile/Features/SessionList/SessionListComponents.swift": 1,
    "HermesMobile/Features/Settings/DefaultProfilePickerView.swift": 1,
    "HermesMobile/Features/Shared/ModelPickerSheet.swift": 1,
    "HermesMobile/Features/Skills/SkillsView.swift": 1,
    "HermesMobile/Features/Tasks/CronJobConfigurationPickers.swift": 1,
    "HermesMobile/Features/Tasks/CronJobSkillsPicker.swift": 1,
    "HermesMobile/Features/Workspace/GitBranchPickerView.swift": 1,
}
SEARCHABLE_PATTERN = re.compile(r"\.searchable\(")

# ─── Frozen direct TextField baseline ────────────────────────────────────────────────────────────
# This branch adds three Hermex-owned Text Input foundation wrappers — `HermexTextField`,
# `HermexSecureField`, `HermexNumberField` (HermexTextInput.swift) — over native `TextField`,
# `SecureField`, and the typed `TextField(value:format:)` path, but does not migrate any production
# screen onto them — every current text field keeps calling `TextField(` directly. Owner: whoever
# lands the PR that migrates one of these call sites onto `HermexTextField`/`HermexNumberField` (or
# adds a new direct `TextField(` call site). Removal condition: delete a file's entry here (or lower
# its count) in the same PR that migrates/removes that call site. Verified against this branch's own
# source (2026-10-01); HermexTextInput.swift itself and HermesMobileTests/ are excluded from this
# accounting. HermexSearch.swift is excluded too, the same way: `HermexSearchField` is a foundation
# component whose approved design keeps the system-backed `TextField` as its editor — that direct
# call is the field's own implementation, not a production call site that should have reached for
# the foundation instead. BotPendingRequestCard's third site is the username field inherited from
# current master (#943); this integration freezes that reviewed upstream state without migrating it.
TEXT_FIELD_BASELINE = {
    "HermesMobile/Features/Kanban/KanbanCardEditorView.swift": 8,
    "HermesMobile/Features/Kanban/KanbanLabView.swift": 5,
    "HermesMobile/Features/Tasks/CronJobEditorSheet.swift": 4,
    "HermesMobile/Features/Bots/BotConnectionView.swift": 3,
    "HermesMobile/Features/Workspace/WorkspaceManagerView.swift": 3,
    "HermesMobile/Features/Bots/BotCreateView.swift": 2,
    "HermesMobile/Features/Bots/BotPendingRequestCard.swift": 3,
    "HermesMobile/Features/Bots/BotProfileEditorView.swift": 2,
    "HermesMobile/Features/Bots/BotRoomCreateView.swift": 2,
    "HermesMobile/Features/Bots/BotsInboxView.swift": 2,
    "HermesMobile/Features/SessionList/SessionListView.swift": 2,
    "HermesMobile/Features/Settings/DefaultProfilePickerView.swift": 2,
    "HermesMobile/Features/Shared/ModelPickerSheet.swift": 2,
    "HermesMobile/Features/Bots/BotQuickRepliesEditorView.swift": 1,
    "HermesMobile/Features/Bots/BotRoomProfileView.swift": 1,
    "HermesMobile/Features/Bots/BotSearchView.swift": 1,
    "HermesMobile/Features/Chat/ChatComposerSelectorSheets.swift": 1,
    "HermesMobile/Features/Chat/ClarificationRequestCard.swift": 1,
    "HermesMobile/Features/Kanban/KanbanCardDetailView.swift": 1,
    "HermesMobile/Features/Onboarding/OnboardingConnectPage.swift": 1,
    "HermesMobile/Features/SessionList/ProjectCreationSheet.swift": 1,
    "HermesMobile/Features/SessionList/SessionRenameSheet.swift": 1,
    "HermesMobile/Features/Settings/SettingsView.swift": 1,
    "HermesMobile/Features/Shared/CustomHeadersEditor.swift": 1,
    "HermesMobile/Features/Tasks/CronJobSkillsPicker.swift": 1,
    "HermesMobile/Features/Workspace/FileBrowserView.swift": 1,
    "HermesMobile/Features/Workspace/GitBranchPickerView.swift": 1,
    "HermesMobile/Features/Workspace/GitCommitView.swift": 1,
}
TEXT_FIELD_PATTERN = re.compile(r"\bTextField\(")
TEXT_FIELD_EXCLUDED_FILES = {
    "HermesMobile/Features/Shared/HermexTextInput.swift",
    "HermesMobile/Features/Shared/HermexSearch.swift",
}

# ─── Frozen direct SecureField baseline ──────────────────────────────────────────────────────────
# Same shape as TEXT_FIELD_BASELINE above, for native `SecureField(` call sites. Owner: whoever lands
# the PR that migrates one of these call sites onto `HermexSecureField` (or adds a new direct
# `SecureField(` call site). Removal condition: delete a file's entry here (or lower its count) in the
# same PR that migrates/removes that call site. Verified against this branch's own source
# (2026-09-28); HermexTextInput.swift itself and HermesMobileTests/ are excluded from this accounting.
SECURE_FIELD_BASELINE = {
    "HermesMobile/Features/Bots/BotPendingRequestCard.swift": 2,
    "HermesMobile/Features/Bots/BotConnectionView.swift": 1,
    "HermesMobile/Features/Onboarding/OnboardingConnectPage.swift": 1,
    "HermesMobile/Features/Settings/DefaultProfilePickerView.swift": 1,
    "HermesMobile/Features/Settings/SettingsView.swift": 1,
    "HermesMobile/Features/Shared/CustomHeadersEditor.swift": 1,
}
SECURE_FIELD_PATTERN = re.compile(r"\bSecureField\(")
SECURE_FIELD_EXCLUDED_FILE = "HermesMobile/Features/Shared/HermexTextInput.swift"


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


def _count_pattern_per_file(pattern: re.Pattern, exclude: set[str] | None = None) -> dict[str, int]:
    exclude = exclude or set()
    counts: dict[str, int] = {}
    for path in (REPO_ROOT / "HermesMobile").rglob("*.swift"):
        rel_path = str(path.relative_to(REPO_ROOT))
        if rel_path in exclude:
            continue
        text = path.read_text(encoding="utf-8")
        occurrences = len(pattern.findall(text))
        if occurrences:
            counts[rel_path] = occurrences
    return counts


def _check_frozen_baseline(label: str, baseline: dict[str, int], live_counts: dict[str, int]) -> list[str]:
    failures = []
    for rel_path, live_count in sorted(live_counts.items()):
        baseline_count = baseline.get(rel_path)
        if baseline_count is None:
            failures.append(
                f"{label}: new, unfrozen call site {rel_path} ({live_count} reference(s)) — "
                f"either use the existing foundation component instead, or update the frozen "
                f"baseline in this same PR with a documented reason"
            )
        elif live_count > baseline_count:
            failures.append(
                f"{label}: {rel_path} increased from {baseline_count} to {live_count} reference(s) — "
                f"either use the existing foundation component instead, or update the frozen "
                f"baseline in this same PR with a documented reason"
            )
    return failures


def check_segmented_control_baseline() -> list[str]:
    live = _count_pattern_per_file(SEGMENTED_CONTROL_PATTERN)
    return _check_frozen_baseline("native segmented control", SEGMENTED_CONTROL_BASELINE, live)


def check_content_unavailable_baseline() -> list[str]:
    live = _count_pattern_per_file(
        CONTENT_UNAVAILABLE_PATTERN, exclude={CONTENT_UNAVAILABLE_EXCLUDED_FILE}
    )
    return _check_frozen_baseline("direct ContentUnavailableView", CONTENT_UNAVAILABLE_BASELINE, live)


def check_searchable_baseline() -> list[str]:
    live = _count_pattern_per_file(SEARCHABLE_PATTERN)
    return _check_frozen_baseline("direct .searchable", SEARCHABLE_BASELINE, live)


def check_text_field_baseline() -> list[str]:
    live = _count_pattern_per_file(TEXT_FIELD_PATTERN, exclude=TEXT_FIELD_EXCLUDED_FILES)
    return _check_frozen_baseline("direct TextField", TEXT_FIELD_BASELINE, live)


def check_secure_field_baseline() -> list[str]:
    live = _count_pattern_per_file(SECURE_FIELD_PATTERN, exclude={SECURE_FIELD_EXCLUDED_FILE})
    return _check_frozen_baseline("direct SecureField", SECURE_FIELD_BASELINE, live)


CHECKS = [
    ("required foundation files", check_required_files),
    ("load-bearing API snippets", check_required_snippets),
    ("icon-size scale", check_icon_scale),
    ("avatar/icon pairing", check_avatar_pairing),
    ("native segmented-control baseline", check_segmented_control_baseline),
    ("direct ContentUnavailableView baseline", check_content_unavailable_baseline),
    ("direct .searchable baseline", check_searchable_baseline),
    ("direct TextField baseline", check_text_field_baseline),
    ("direct SecureField baseline", check_secure_field_baseline),
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

    print("hermex_design_system_adoption_audit: OK — foundation contract intact, baselines unchanged.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
