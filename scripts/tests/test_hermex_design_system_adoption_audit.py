"""Run with: python3 -m unittest scripts.tests.test_hermex_design_system_adoption_audit -v

Fixture-based tests for scripts/hermex_design_system_adoption_audit.py. Each test builds a minimal,
self-contained fake repository tree under a temporary directory — never the real repository — so the
audit's checks can be exercised in isolation, including against the live repository only in the one
test reserved for that (test_passes_against_the_real_repository).
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "hermex_design_system_adoption_audit.py"
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

loader = importlib.machinery.SourceFileLoader("hermex_design_system_adoption_audit", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
audit = importlib.util.module_from_spec(spec)
loader.exec_module(audit)


VALID_APP_FONT = """
import SwiftUI
enum AppFont {
    enum Role: CaseIterable {
        case body
    }
}
extension View {
    func appFont(_ role: AppFont.Role) -> some View {
        self
    }
}
""".strip()

VALID_HERMES_SPACING = """
enum HermesSpacing {
    static let s16: CGFloat = 16
}

enum HermesIconSize {
    static let xs: CGFloat = 12
    static let small: CGFloat = 16
    static let medium: CGFloat = 20
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 32

    enum Avatar {
        static let small = HermesIconSize.medium
        static let medium = HermesIconSize.large
        static let large = HermesIconSize.extraLarge
    }
}

enum HermesAvatarSize: CGFloat, CaseIterable {
    case small = 32
    case medium = 40
    case large = 48
}
""".strip()

SIMPLE_SNIPPETS = {
    "HermesMobile/Features/Shared/HermexCard.swift": "enum HermexCardSurface { case glass }",
    "HermesMobile/Features/Shared/HermexButton.swift": (
        "struct HermexButtonStyle: ButtonStyle {}\nstruct HermexButtonPressOnlyStyle: ButtonStyle {}"
    ),
    "HermesMobile/Features/Shared/HermexCheckbox.swift": "struct HermexCheckbox: View {}",
    "HermesMobile/Features/Shared/HermexRadio.swift": "struct HermexRadio: View {}",
    "HermesMobile/Features/Shared/AccordionList.swift": (
        "struct AccordionList<Item: Identifiable>: View {}\n"
        "extension AccordionList where HeaderLeading == EmptyView {\n"
        "    init() {}\n"
        "}"
    ),
    "HermesMobile/Features/Shared/HermexSelectionSheet.swift": (
        "import SwiftUI\n"
        "struct HermexSelectionSheetOption<Value: Hashable>: Identifiable {\n"
        "    let value: Value\n"
        "    var id: Value { value }\n"
        "}\n"
        "enum HermexSelectionSheetFooterAxis: Equatable {\n"
        "    case horizontal\n"
        "    case vertical\n"
        "}\n"
        "struct HermexSelectionSheet<Value: Hashable>: View {\n"
        "    init(\n"
        "        _ title: LocalizedStringKey,\n"
        "        selections: Binding<Set<Value>>,\n"
        "        footerAxis: HermexSelectionSheetFooterAxis = .horizontal\n"
        "    ) {}\n"
        "    var body: some View {\n"
        "        HermexBottomSheet(\"Select\") { EmptyView() }\n"
        "    }\n"
        "}"
    ),
    "HermesMobile/Features/Shared/HermexToast.swift": "struct HermexToast: View {}",
    "HermesMobile/Features/Shared/HermexTooltip.swift": "struct HermexTooltip: View {}",
    "HermesMobile/Features/Shared/HermexAvatar.swift": "struct HermexAvatar: View {}",
    "HermesMobile/Features/Shared/HermexDivider.swift": "struct HermexDivider: View {}",
    "HermesMobile/Features/Shared/HermexContentUnavailable.swift": "struct HermexContentUnavailable: View {}",
    "HermesMobile/Features/Shared/ListItem.swift": (
        "struct ListItem<Leading: View>: View {}\n"
        "enum ListItemContentInset: Equatable {\n"
        "    case standard\n"
        "    case none\n"
        "}\n"
        "struct ListItemButtonStyle: ButtonStyle {}"
    ),
    "HermesMobile/Features/Shared/HermexList.swift": (
        "struct HermexList<Content: View>: View {\n"
        "    enum Style {\n"
        "        case standard\n"
        "        case compactOverlay\n"
        "    }\n"
        "}\n"
        "enum HermexListCompactOverlayMetrics {\n"
        "    static let rowHorizontalInset: CGFloat = HermesSpacing.s0\n"
        "    static let scrollContentMargin: CGFloat = HermesSpacing.s0\n"
        "}"
    ),
    "HermesMobile/Features/Shared/SegmentedControl.swift": "struct SegmentedControl<Value: Hashable>: View {}",
    "HermesMobile/Features/Shared/TopNav.swift": "struct TopNav: ToolbarContent {}",
    "HermesMobile/Features/Shared/HermexBanner.swift": (
        "struct HermexBanner: View {\n"
        "    let title: Text?\n"
        "    let description: Text?\n"
        "}"
    ),
    "HermesMobile/Features/Shared/HermexSurfaceBorder.swift": (
        "enum HermexSurfaceBorderRamp {}\nenum HermexSurfaceBorderColors {}"
    ),
    "HermesMobile/Features/Shared/HermexComposerToolbar.swift": (
        "enum HermexComposerToolbarAppearance {}\n"
        "struct HermexComposerToolbar<Content: View>: View {}\n"
        "struct HermexComposerToolbarEdgeFades {}\n"
        "struct HermexComposerToolbarDivider: View {}"
    ),
    "HermesMobile/Features/Chat/TranscriptLogRowView.swift": "enum TranscriptLogRowMetrics {}",
    "HermesMobile/Features/Shared/Tag.swift": "struct Tag: View {}",
    "HermesMobile/Features/Shared/AttachmentFileType.swift": "enum AttachmentFileType {}",
    "HermesMobile/Features/Shared/AttachmentTile.swift": "struct AttachmentTile: View {}",
    "HermesMobile/Features/Shared/SkeletonPlaceholder.swift": "struct SkeletonPlaceholder: View {}",
    "HermesMobile/Features/Shared/HermexSearch.swift": (
        "import SwiftUI\n"
        "struct HermexSearchField: View {\n"
        "    var body: some View { EmptyView() }\n"
        "}\n"
        "extension View {\n"
        "    func hermexSearch(\n"
        "        _ titleKey: LocalizedStringKey,\n"
        "        text: Binding<String>\n"
        "    ) -> some View {\n"
        "        safeAreaInset(edge: .top, spacing: 0) {\n"
        "            HermexSearchField(titleKey, text: text)\n"
        "        }\n"
        "    }\n"
        "}"
    ),
    "HermesMobile/Features/Shared/HermexTextInput.swift": (
        "struct HermexTextField: View {}\n"
        "struct HermexSecureField: View {}\n"
        "enum HermexCodeInputNormalizer {}\n"
        "enum HermexCodeInputLayout {}\n"
        "struct HermexCodeInput: View {}"
    ),
    "HermesMobile/Features/Shared/HermexBottomSheet.swift": (
        "struct HermexBottomSheet<Content: View>: View {\n"
        "    enum FooterAxis {\n"
        "        case horizontal\n"
        "        case vertical\n"
        "    }\n"
        "}"
    ),
    "HermesMobile/Features/Shared/HermexSameWindowOverlay.swift": (
        "struct HermexSameWindowOverlay<Overlay: View>: UIViewControllerRepresentable {}"
    ),
    "HermesMobile/Features/Shared/HermexOverlayLifecycle.swift": (
        "struct HermexOverlayLifecycle {}\nstruct HermexOverlayActionContext {}"
    ),
    "HermesMobile/Features/Shared/HermexDialog.swift": (
        "enum HermexDialogFooterAxis {\n"
        "    case horizontal\n"
        "    case vertical\n"
        "}\n"
        "extension View {\n"
        "    func hermexDialog() -> some View { self }\n"
        "}"
    ),
    "HermesMobile/Features/Shared/HermexPopoverMenu.swift": (
        "struct HermexPopoverMenuAction {}\n"
        "enum HermexPopoverMenuMetrics {\n"
        "    static let contentPadding: CGFloat = HermesSpacing.s16\n"
        "}\n"
        "extension View {\n"
        "    func hermexPopoverMenu(\n"
        "        isPresented: Binding<Bool>,\n"
        "        accessibilityLabel: Text,\n"
        "        actions: [HermexPopoverMenuAction]\n"
        "    ) -> some View { self }\n"
        "}\n"
        "// row usage: ListItem(..., contentInset: .none, ...)\n"
    ),
    "HermesMobile/Config/HermesColor.swift": "enum HermesColorRamp {}",
    "HermesMobile/Config/HermesMotion.swift": "enum HermesMotion {}",
    "HermesMobile/Config/HermesRadius.swift": "enum HermesRadius {}",
    "HermesMobile/Config/HermesShadow.swift": "enum HermesShadow {}",
}


def write(root: pathlib.Path, rel_path: str, content: str) -> None:
    full_path = root / rel_path
    full_path.parent.mkdir(parents=True, exist_ok=True)
    full_path.write_text(content, encoding="utf-8")


def build_valid_fixture_tree(root: pathlib.Path) -> None:
    write(root, "HermesMobile/Config/AppFont.swift", VALID_APP_FONT)
    write(root, "HermesMobile/Config/HermesSpacing.swift", VALID_HERMES_SPACING)
    for rel_path, snippet in SIMPLE_SNIPPETS.items():
        write(root, rel_path, snippet)
    write(
        root,
        "HermesMobile/Features/Insights/InsightsView.swift",
        "struct InsightsView: View {\n    var body: some View { Picker(\"\", selection: .constant(0)) { }.pickerStyle(.segmented) }\n}",
    )
    write(
        root,
        "HermesMobile/Features/Tasks/TasksView.swift",
        "struct TasksView: View {\n    var body: some View { Picker(\"\", selection: .constant(0)) { }.pickerStyle(.segmented) }\n}",
    )
    write(
        root,
        "HermesMobile/Features/Skills/SkillsView.swift",
        "struct SkillsView: View {\n    var body: some View { ContentUnavailableView(\"Empty\", systemImage: \"tray\") }\n}",
    )
    write(
        root,
        "HermesMobile/Features/SessionList/SessionListComponents.swift",
        "struct SessionListComponents: View {\n    var body: some View { List {}.searchable(text: .constant(\"\"), prompt: \"Search sessions\") }\n}",
    )
    write(
        root,
        "HermesMobile/Features/Onboarding/OnboardingConnectPage.swift",
        (
            "struct OnboardingConnectPage: View {\n"
            "    var body: some View { TextField(\"Server\", text: .constant(\"\")) }\n"
            "    var body2: some View { SecureField(\"Password\", text: .constant(\"\")) }\n"
            "}"
        ),
    )


class RequiredFilesAndSnippetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def test_valid_foundation_passes(self):
        build_valid_fixture_tree(self.root)
        self.assertEqual(audit.run(self.root), [])

    def test_scope_documentation_does_not_claim_native_control_census_enforcement(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for forbidden in [
            "frozen baseline",
            "SEGMENTED_CONTROL_BASELINE",
            "CONTENT_UNAVAILABLE_BASELINE",
            "SEARCHABLE_BASELINE",
            "TEXT_FIELD_BASELINE",
            "SECURE_FIELD_BASELINE",
            "check_segmented_control_baseline",
            "check_content_unavailable_baseline",
            "check_searchable_baseline",
            "check_text_field_baseline",
            "check_secure_field_baseline",
        ]:
            self.assertNotIn(forbidden, source)

    def test_development_guide_describes_the_foundation_only_audit_contract(self):
        source = (REPO_ROOT / "DEVELOPMENT.md").read_text(encoding="utf-8")
        for forbidden in [
            "frozen legacy",
            "native `.pickerStyle(.segmented)` call sites",
            "direct `ContentUnavailableView` call sites",
            "baseline owner/removal-condition rule",
        ]:
            self.assertNotIn(forbidden, source)
        self.assertIn("does not count or restrict native-control call sites", source)
        self.assertIn("32→20, 40→24, 48→32", source)

    def test_missing_required_file_fails(self):
        build_valid_fixture_tree(self.root)
        (self.root / "HermesMobile/Features/Shared/HermexCard.swift").unlink()
        failures = audit.run(self.root)
        self.assertTrue(
            any("missing required foundation file" in f and "HermexCard.swift" in f for f in failures),
            failures,
        )

    def test_missing_required_snippet_fails(self):
        build_valid_fixture_tree(self.root)
        write(self.root, "HermesMobile/Features/Shared/HermexCard.swift", "// no HermexCardSurface here")
        failures = audit.run(self.root)
        self.assertTrue(
            any("missing load-bearing snippet" in f and "HermexCard.swift" in f for f in failures),
            failures,
        )

    def test_missing_bottom_sheet_foundation_file_fails(self):
        build_valid_fixture_tree(self.root)
        (self.root / "HermesMobile/Features/Shared/HermexBottomSheet.swift").unlink()
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing required foundation file" in f and "HermexBottomSheet.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_drifted_bottom_sheet_declaration_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexBottomSheet.swift",
            "// HermexBottomSheet renamed away, no FooterAxis either",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexBottomSheet.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_bottom_sheet_missing_footer_axis_enum_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexBottomSheet.swift",
            "struct HermexBottomSheet<Content: View>: View {}",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexBottomSheet.swift" in f and "FooterAxis" in f
                for f in failures
            ),
            failures,
        )

    def test_missing_dialog_foundation_file_fails(self):
        build_valid_fixture_tree(self.root)
        (self.root / "HermesMobile/Features/Shared/HermexDialog.swift").unlink()
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing required foundation file" in f and "HermexDialog.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_drifted_dialog_declaration_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexDialog.swift",
            "// HermexDialog renamed away, no hermexDialog( either",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexDialog.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_dialog_missing_footer_axis_enum_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexDialog.swift",
            "extension View {\n    func hermexDialog() -> some View { self }\n}",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexDialog.swift" in f and "HermexDialogFooterAxis" in f
                for f in failures
            ),
            failures,
        )

    # ─── Selection Sheet family slice / Dropdown retirement (Issue #607, test-first phase) ────────
    # `HermexSelectionSheet.swift` does not exist yet and `HermexDropdown.swift` has not been
    # deleted yet — Task 3 of the Selection Sheet implementation plan ships the retirement and the
    # addition together. Until then these tests pin the contract that slice must satisfy.

    def test_missing_selection_sheet_foundation_file_fails(self):
        build_valid_fixture_tree(self.root)
        (self.root / "HermesMobile/Features/Shared/HermexSelectionSheet.swift").unlink()
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing required foundation file" in f and "HermexSelectionSheet.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_drifted_selection_sheet_declaration_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexSelectionSheet.swift",
            "// HermexSelectionSheet renamed away, no HermexSelectionSheetOption either",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexSelectionSheet.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_selection_sheet_missing_bottom_sheet_composition_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexSelectionSheet.swift",
            (
                "struct HermexSelectionSheetOption<Value: Hashable>: Identifiable {\n"
                "    let value: Value\n"
                "    var id: Value { value }\n"
                "}\n"
                "struct HermexSelectionSheet<Value: Hashable>: View {\n"
                "    var body: some View { EmptyView() }\n"
                "}"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f
                and "HermexSelectionSheet.swift" in f
                and "HermexBottomSheet" in f
                for f in failures
            ),
            "expected the audit to require Selection Sheet to compose HermexBottomSheet(, not a "
            f"bespoke presentation: {failures}",
        )

    def test_the_audit_module_no_longer_declares_the_retired_hermex_dropdown_foundation_requirement(self):
        # Confirms REQUIRED_FOUNDATION_FILES was swapped, not merely extended: the audit itself must
        # no longer require HermexDropdown.swift once Selection Sheet replaces it as the registered
        # Hermex foundation for this role.
        self.assertNotIn("HermesMobile/Features/Shared/HermexDropdown.swift", audit.REQUIRED_FOUNDATION_FILES)
        self.assertIn("HermesMobile/Features/Shared/HermexSelectionSheet.swift", audit.REQUIRED_FOUNDATION_FILES)

    # ─── Popover Menu family slice (test-first phase) ────────────────────────────────────────────
    # `HermexPopoverMenu.swift` and `HermexList`'s `case compactOverlay` do not exist yet — Task 7/8
    # of the implementation plan ship them, along with the audit's own REQUIRED_FOUNDATION_FILES/
    # REQUIRED_SNIPPETS additions, in the same PR. Until then these three regressions are expected
    # to fail red: they pin the contract the *next* audit update must satisfy, not the current one.

    def test_missing_popover_menu_foundation_file_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexPopoverMenu.swift",
            (
                "extension View {\n"
                "    func hermexPopoverMenu() -> some View { self }\n"
                "}\n"
                "struct HermexPopoverMenuAction {}\n"
            ),
        )
        (self.root / "HermesMobile/Features/Shared/HermexPopoverMenu.swift").unlink()
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing required foundation file" in f and "HermexPopoverMenu.swift" in f
                for f in failures
            ),
            "expected the audit to require HermexPopoverMenu.swift once the Popover Menu slice "
            f"lands; currently red because it is not yet a required foundation file: {failures}",
        )

    def test_drifted_popover_menu_declaration_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexPopoverMenu.swift",
            "// HermexPopoverMenu renamed away, no hermexPopoverMenu( either",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexPopoverMenu.swift" in f
                for f in failures
            ),
            "expected the audit to pin hermexPopoverMenu(/HermexPopoverMenuAction once the Popover "
            f"Menu slice lands; currently red because no snippet is required yet: {failures}",
        )

    def test_hermex_list_missing_compact_overlay_case_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexList.swift",
            "struct HermexList<Content: View>: View {}",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexList.swift" in f and "compactOverlay" in f
                for f in failures
            ),
            "expected the audit to pin `case compactOverlay` once the compact-overlay List style "
            f"lands; currently red because it is not yet a required snippet: {failures}",
        )

    def test_missing_same_window_overlay_foundation_file_fails(self):
        build_valid_fixture_tree(self.root)
        (self.root / "HermesMobile/Features/Shared/HermexSameWindowOverlay.swift").unlink()
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing required foundation file" in f and "HermexSameWindowOverlay.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_missing_overlay_lifecycle_foundation_file_fails(self):
        build_valid_fixture_tree(self.root)
        (self.root / "HermesMobile/Features/Shared/HermexOverlayLifecycle.swift").unlink()
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing required foundation file" in f and "HermexOverlayLifecycle.swift" in f
                for f in failures
            ),
            failures,
        )

    # ─── Round 3 shared integration slice ────────────────────────────────────────────────────────
    # `ListItemContentInset`/`ListItemButtonStyle` (ListItem.swift), the compact-overlay zero
    # horizontal inset/margin (HermexList.swift), `HermexPopoverMenuMetrics.contentPadding` plus the
    # Popover row's `contentInset: .none` (HermexPopoverMenu.swift), `HermexComposerToolbarDivider`
    # (HermexComposerToolbar.swift), `AccordionList.swift` itself plus its `HeaderLeading == EmptyView`
    # initializer seam, and `HermexSelectionSheetFooterAxis` plus the default `.horizontal` multi
    # initializer seam (HermexSelectionSheet.swift) all became load-bearing in Round 3. Each of these
    # pins the contract so it fails closed if that declaration disappears again.

    def test_list_item_missing_content_inset_enum_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/ListItem.swift",
            "struct ListItem<Leading: View>: View {}\nstruct ListItemButtonStyle: ButtonStyle {}",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "ListItem.swift" in f and "ListItemContentInset" in f
                for f in failures
            ),
            failures,
        )

    def test_list_item_missing_button_style_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/ListItem.swift",
            "struct ListItem<Leading: View>: View {}\nenum ListItemContentInset: Equatable {\n    case standard\n    case none\n}",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "ListItem.swift" in f and "ListItemButtonStyle" in f
                for f in failures
            ),
            failures,
        )

    def test_hermex_list_compact_overlay_missing_zero_row_horizontal_inset_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexList.swift",
            (
                "struct HermexList<Content: View>: View {\n"
                "    enum Style {\n"
                "        case standard\n"
                "        case compactOverlay\n"
                "    }\n"
                "}\n"
                "enum HermexListCompactOverlayMetrics {\n"
                "    static let scrollContentMargin: CGFloat = HermesSpacing.s0\n"
                "}"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexList.swift" in f and "rowHorizontalInset" in f
                for f in failures
            ),
            failures,
        )

    def test_hermex_list_compact_overlay_missing_zero_scroll_content_margin_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexList.swift",
            (
                "struct HermexList<Content: View>: View {\n"
                "    enum Style {\n"
                "        case standard\n"
                "        case compactOverlay\n"
                "    }\n"
                "}\n"
                "enum HermexListCompactOverlayMetrics {\n"
                "    static let rowHorizontalInset: CGFloat = HermesSpacing.s0\n"
                "}"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexList.swift" in f and "scrollContentMargin" in f
                for f in failures
            ),
            failures,
        )

    def test_hermex_popover_menu_missing_content_padding_constant_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexPopoverMenu.swift",
            (
                "struct HermexPopoverMenuAction {}\n"
                "extension View {\n"
                "    func hermexPopoverMenu(\n"
                "        isPresented: Binding<Bool>,\n"
                "        accessibilityLabel: Text,\n"
                "        actions: [HermexPopoverMenuAction]\n"
                "    ) -> some View { self }\n"
                "}\n"
                "// row usage: ListItem(..., contentInset: .none, ...)\n"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexPopoverMenu.swift" in f and "contentPadding" in f
                for f in failures
            ),
            failures,
        )

    def test_hermex_popover_menu_missing_row_content_inset_none_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexPopoverMenu.swift",
            (
                "struct HermexPopoverMenuAction {}\n"
                "enum HermexPopoverMenuMetrics {\n"
                "    static let contentPadding: CGFloat = HermesSpacing.s16\n"
                "}\n"
                "extension View {\n"
                "    func hermexPopoverMenu(\n"
                "        isPresented: Binding<Bool>,\n"
                "        accessibilityLabel: Text,\n"
                "        actions: [HermexPopoverMenuAction]\n"
                "    ) -> some View { self }\n"
                "}"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "HermexPopoverMenu.swift" in f and "contentInset" in f
                for f in failures
            ),
            failures,
        )

    def test_composer_toolbar_missing_divider_struct_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexComposerToolbar.swift",
            (
                "enum HermexComposerToolbarAppearance {}\n"
                "struct HermexComposerToolbar<Content: View>: View {}\n"
                "struct HermexComposerToolbarEdgeFades {}"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f
                and "HermexComposerToolbar.swift" in f
                and "HermexComposerToolbarDivider" in f
                for f in failures
            ),
            failures,
        )

    def test_missing_accordion_list_foundation_file_fails(self):
        build_valid_fixture_tree(self.root)
        (self.root / "HermesMobile/Features/Shared/AccordionList.swift").unlink()
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing required foundation file" in f and "AccordionList.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_drifted_accordion_list_declaration_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/AccordionList.swift",
            "// AccordionList renamed away, no HeaderLeading == EmptyView seam either",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f and "AccordionList.swift" in f
                for f in failures
            ),
            failures,
        )

    def test_accordion_list_missing_no_leading_header_seam_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/AccordionList.swift",
            "struct AccordionList<Item: Identifiable>: View {}",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f
                and "AccordionList.swift" in f
                and "HeaderLeading" in f
                for f in failures
            ),
            "expected the audit to require the HeaderLeading == EmptyView no-leading initializer seam: "
            f"{failures}",
        )

    def test_selection_sheet_missing_footer_axis_enum_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexSelectionSheet.swift",
            (
                "import SwiftUI\n"
                "struct HermexSelectionSheetOption<Value: Hashable>: Identifiable {\n"
                "    let value: Value\n"
                "    var id: Value { value }\n"
                "}\n"
                "struct HermexSelectionSheet<Value: Hashable>: View {\n"
                "    var body: some View {\n"
                "        HermexBottomSheet(\"Select\") { EmptyView() }\n"
                "    }\n"
                "}"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f
                and "HermexSelectionSheet.swift" in f
                and "HermexSelectionSheetFooterAxis" in f
                for f in failures
            ),
            failures,
        )

    def test_selection_sheet_missing_default_horizontal_multi_seam_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Shared/HermexSelectionSheet.swift",
            (
                "import SwiftUI\n"
                "struct HermexSelectionSheetOption<Value: Hashable>: Identifiable {\n"
                "    let value: Value\n"
                "    var id: Value { value }\n"
                "}\n"
                "enum HermexSelectionSheetFooterAxis: Equatable {\n"
                "    case horizontal\n"
                "    case vertical\n"
                "}\n"
                "struct HermexSelectionSheet<Value: Hashable>: View {\n"
                "    init(\n"
                "        _ title: LocalizedStringKey,\n"
                "        selections: Binding<Set<Value>>,\n"
                "        footerAxis: HermexSelectionSheetFooterAxis\n"
                "    ) {}\n"
                "    var body: some View {\n"
                "        HermexBottomSheet(\"Select\") { EmptyView() }\n"
                "    }\n"
                "}"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "missing load-bearing snippet" in f
                and "HermexSelectionSheet.swift" in f
                and "horizontal" in f
                for f in failures
            ),
            "expected the audit to require the default .horizontal multi initializer seam: "
            f"{failures}",
        )

    def test_icon_scale_drift_fails(self):
        build_valid_fixture_tree(self.root)
        drifted = VALID_HERMES_SPACING.replace(
            "static let extraLarge: CGFloat = 32", "static let extraLarge: CGFloat = 28"
        )
        write(self.root, "HermesMobile/Config/HermesSpacing.swift", drifted)
        failures = audit.run(self.root)
        self.assertTrue(any("rejected size" in f and "28" in f for f in failures), failures)

    def test_icon_scale_missing_approved_size_fails(self):
        build_valid_fixture_tree(self.root)
        missing = VALID_HERMES_SPACING.replace("static let xs: CGFloat = 12\n    ", "")
        write(self.root, "HermesMobile/Config/HermesSpacing.swift", missing)
        failures = audit.run(self.root)
        self.assertTrue(any("missing approved named size" in f and "12" in f for f in failures), failures)

    def test_avatar_pairing_drift_fails(self):
        build_valid_fixture_tree(self.root)
        drifted = VALID_HERMES_SPACING.replace(
            "static let small = HermesIconSize.medium", "static let small = HermesIconSize.small"
        )
        write(self.root, "HermesMobile/Config/HermesSpacing.swift", drifted)
        failures = audit.run(self.root)
        self.assertTrue(
            any("HermesAvatarSize.small" in f and "expected 20pt" in f for f in failures), failures
        )

    def test_native_control_call_sites_are_not_counted_by_the_foundation_audit(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Kanban/KanbanLabView.swift",
            (
                "struct KanbanLabView: View {\n"
                "    var body: some View { Picker(\"\", selection: .constant(0)) { }.pickerStyle(.segmented) }\n"
                "    var body2: some View { List {}.searchable(text: .constant(\"\")) }\n"
                "    var body3: some View { TextField(\"Title\", text: .constant(\"\")) }\n"
                "    var body4: some View { SecureField(\"Token\", text: .constant(\"\")) }\n"
                "    var body5: some View { ContentUnavailableView(\"Empty\", systemImage: \"tray\") }\n"
                "}"
            ),
        )
        failures = audit.run(self.root)
        census_terms = ["segmented", ".searchable", "TextField", "SecureField", "ContentUnavailableView"]
        self.assertFalse(
            any(term in failure for term in census_terms for failure in failures),
            f"native-control usage belongs to separately scoped migration work, not this foundation audit: {failures}",
        )


class Task6TaxonomyRetirementTests(unittest.TestCase):
    """Fixture-independent contracts for the approved final taxonomy (hermex-dsf-round-2-content-r1):
    Text Input's Code variant replaces Number Field, Disclosure Row/Inline Reference Link are fully
    retired, Transcript Log Row and Composer Toolbar are the new/renamed foundation contracts, and
    Popover Menu stays free of a selection API. These read the real repository and the real audit
    module state directly (not the temp fixture tree `RequiredFilesAndSnippetsTests` builds), mirroring
    `test_the_audit_module_no_longer_declares_the_retired_hermex_dropdown_foundation_requirement`
    and `test_passes_against_the_real_repository` above.
    """

    def test_required_foundation_files_include_surface_border_composer_toolbar_and_transcript_log_row_view(self):
        for expected in [
            "HermesMobile/Features/Shared/HermexSurfaceBorder.swift",
            "HermesMobile/Features/Shared/HermexComposerToolbar.swift",
            "HermesMobile/Features/Chat/TranscriptLogRowView.swift",
        ]:
            self.assertIn(
                expected,
                audit.REQUIRED_FOUNDATION_FILES,
                f"expected {expected} to be a required foundation file once Task 6 lands",
            )

    def test_text_input_required_snippets_pin_code_input_and_exclude_number_field(self):
        snippets_by_path = dict(audit.REQUIRED_SNIPPETS)
        patterns = snippets_by_path.get("HermesMobile/Features/Shared/HermexTextInput.swift")
        self.assertIsNotNone(patterns, "expected required snippets for HermexTextInput.swift")
        joined = "\n".join(patterns)
        for expected in [
            "HermexTextField",
            "HermexSecureField",
            "HermexCodeInput",
            "HermexCodeInputNormalizer",
            "HermexCodeInputLayout",
        ]:
            self.assertIn(expected, joined, f"expected a required snippet naming {expected}")
        self.assertNotIn("HermexNumberField", joined, "expected the retired HermexNumberField snippet to be gone")

    def test_hermex_number_field_disclosure_row_and_its_tests_are_fully_retired_from_the_real_repository(self):
        for retired_path in [
            "HermesMobile/Features/Chat/DisclosureRow.swift",
            "HermesMobileTests/DisclosureRowBodyWindowTests.swift",
        ]:
            self.assertFalse(
                (REPO_ROOT / retired_path).exists(),
                f"expected {retired_path} to be deleted, with no shim or deprecation wrapper retained",
            )
        text_input_source = (
            REPO_ROOT / "HermesMobile/Features/Shared/HermexTextInput.swift"
        ).read_text(encoding="utf-8")
        self.assertNotIn("HermexNumberField", text_input_source)
        self.assertNotIn("ParseableFormatStyle", text_input_source)

    def test_catalog_no_longer_registers_inline_reference_link_or_disclosure_row_as_active_entries(self):
        catalog_source = (
            REPO_ROOT / "design-system-catalog/native/catalog/hermes/hermesSections.tsx"
        ).read_text(encoding="utf-8")
        self.assertNotIn("Inline Reference Link", catalog_source)
        self.assertNotIn("id: 'Disclosure Row'", catalog_source)
        self.assertNotIn("DisclosureRowMetrics", catalog_source)
        self.assertIn("Transcript Log Row", catalog_source)

    def test_the_audit_module_no_longer_declares_native_control_censuses(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for name in [
            "SEGMENTED_CONTROL_BASELINE",
            "CONTENT_UNAVAILABLE_BASELINE",
            "SEARCHABLE_BASELINE",
            "TEXT_FIELD_BASELINE",
            "SECURE_FIELD_BASELINE",
        ]:
            self.assertFalse(getattr(audit, name, {}), f"expected {name} to be removed")
            self.assertNotIn(name, source)
        self.assertNotIn("_check_frozen_baseline", source)

    def test_hermex_popover_menu_remains_free_of_a_selection_api(self):
        popover_source = (
            REPO_ROOT / "HermesMobile/Features/Shared/HermexPopoverMenu.swift"
        ).read_text(encoding="utf-8")
        self.assertNotIn("HermexSelectionPopover", popover_source)
        self.assertIn("struct HermexPopoverMenuAction", popover_source)

    # Correction: HermexComposerToolbar( is no longer required to stay confined to its own foundation
    # file and the DEBUG overlay lab — that confinement was a non-adoption restriction, not a legitimate
    # integrity check, and it blocked a real production caller from ever landing. The legitimate fact
    # worth keeping is that the DEBUG overlay lab still demonstrates a real specimen.
    def test_overlay_lab_still_demonstrates_a_real_composer_toolbar_specimen(self):
        pattern = re.compile(r"HermexComposerToolbar\(")
        overlay_lab_src = (REPO_ROOT / "HermesMobile/Features/Shared/HermexOverlayLab.swift").read_text(encoding="utf-8")
        self.assertGreater(
            len(pattern.findall(overlay_lab_src)), 0,
            "expected the DEBUG overlay lab to keep at least one real HermexComposerToolbar specimen",
        )

    def test_new_foundation_and_test_files_have_xcode_project_membership(self):
        pbxproj = (REPO_ROOT / "HermesMobile.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        for filename in [
            "HermexSurfaceBorder.swift",
            "HermexComposerToolbar.swift",
            "HermexSurfaceBorderTests.swift",
            "HermexComposerToolbarTests.swift",
            "HermexCodeInputTests.swift",
        ]:
            self.assertIn(filename, pbxproj, f"expected {filename} to have Xcode project membership")


class DSR2_15BannerTests(unittest.TestCase):
    """Fixture-independent contracts for the foundation-only DSR2-15 Banner family: `HermexBanner`
    replaces the legacy Banner source/tests, title and description remain independently optional,
    the DEBUG overlay lab renders the real component, and production sources gain no new call site."""

    def test_the_audit_module_will_need_to_swap_the_retired_banner_foundation_requirement_for_hermex_banner(self):
        # Pins the wished-for REQUIRED_FOUNDATION_FILES swap (test-first phase): a later audit-script
        # task must remove the retired Banner.swift path and add HermexBanner.swift in its place, the
        # same swap already made for HermexDropdown -> HermexSelectionSheet in RequiredFilesAndSnippetsTests.
        self.assertIn(
            "HermesMobile/Features/Shared/HermexBanner.swift",
            audit.REQUIRED_FOUNDATION_FILES,
            "expected HermexBanner.swift to become a required foundation file once DSR2-15 lands",
        )
        self.assertNotIn(
            "HermesMobile/Features/Shared/Banner.swift",
            audit.REQUIRED_FOUNDATION_FILES,
            "expected the retired Banner.swift to be removed from REQUIRED_FOUNDATION_FILES once HermexBanner.swift replaces it",
        )

    def test_legacy_banner_source_and_tests_are_fully_retired_from_the_real_repository(self):
        for retired_path in [
            "HermesMobile/Features/Shared/Banner.swift",
            "HermesMobileTests/BannerTests.swift",
        ]:
            self.assertFalse(
                (REPO_ROOT / retired_path).exists(),
                f"expected {retired_path} to be deleted, with no shim or deprecation wrapper retained",
            )
        pbxproj = (REPO_ROOT / "HermesMobile.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertIsNone(
            re.search(r"(?<!Hermex)Banner\.swift\b", pbxproj),
            "expected no active pbxproj reference to the legacy production Banner.swift",
        )
        self.assertIsNone(
            re.search(r"(?<!Hermex)BannerTests\.swift\b", pbxproj),
            "expected no active pbxproj reference to the legacy BannerTests.swift",
        )

    def test_hermex_banner_and_its_tests_have_xcode_project_membership(self):
        pbxproj = (REPO_ROOT / "HermesMobile.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        for filename in ["HermexBanner.swift", "HermexBannerTests.swift"]:
            self.assertIn(filename, pbxproj, f"expected {filename} to have Xcode project membership")

    # Correction: HermexBanner( is no longer required to stay confined to its own foundation file and
    # the DEBUG overlay lab, Banner is no longer required to stay unadopted by the Bot composers/offline
    # cache notice sources, and the catalog is no longer required to assert zero production adoption —
    # those were non-adoption restrictions, not legitimate integrity checks, and they blocked a real
    # production caller from ever landing. The legitimate facts worth keeping: the DEBUG overlay lab
    # still demonstrates a real specimen, and the catalog still cites the real HermexBanner.swift source
    # (not the retired Banner.swift).
    def test_overlay_lab_still_demonstrates_a_real_banner_specimen(self):
        pattern = re.compile(r"HermexBanner\(")
        overlay_lab_src = (REPO_ROOT / "HermesMobile/Features/Shared/HermexOverlayLab.swift").read_text(encoding="utf-8")
        self.assertGreater(
            len(pattern.findall(overlay_lab_src)), 0,
            "expected the DEBUG overlay lab to keep at least one real HermexBanner specimen",
        )

    def test_catalog_still_cites_the_real_hermex_banner_source_not_the_retired_banner_swift(self):
        catalog_source = (
            REPO_ROOT / "design-system-catalog/native/catalog/hermes/hermesSections.tsx"
        ).read_text(encoding="utf-8")
        self.assertIn("HermesMobile/Features/Shared/HermexBanner.swift", catalog_source)
        self.assertNotIn("HermesMobile/Features/Shared/Banner.swift", catalog_source)


class Round3SharedIntegrationTests(unittest.TestCase):
    """Fixture-independent contracts for the Round 3 shared integration work: the DEBUG Overlay Lab
    gains rendered-verification specimens for ListItem's press-and-hold/selected-chrome states, an
    explicit `HermexComposerToolbarDivider()` between caller-owned control groups, AccordionList's
    no-leading Card/Cardless specimens, and horizontal/vertical multi-selection Selection Sheet
    specimens — and `.hermexPopoverMenu(`/`HermexSelectionSheet(`/`HermexComposerToolbarDivider(` stay
    confined to their own foundation source plus the lab, mirroring
    `test_composer_toolbar_call_sites_are_confined_to_its_own_foundation_file_and_the_overlay_lab` and
    `test_hermex_banner_call_sites_are_confined_to_its_own_foundation_file_and_the_overlay_lab` above.
    These read the real repository directly, not the temp fixture tree."""

    @staticmethod
    def _overlay_lab_source() -> str:
        return (REPO_ROOT / "HermesMobile/Features/Shared/HermexOverlayLab.swift").read_text(encoding="utf-8")

    @staticmethod
    def _confined_call_sites(pattern: re.Pattern, allowed: set[str]) -> tuple[list[str], int]:
        offenders = []
        overlay_lab_count = 0
        for swift_path in (REPO_ROOT / "HermesMobile").rglob("*.swift"):
            rel_path = str(swift_path.relative_to(REPO_ROOT))
            count = len(pattern.findall(swift_path.read_text(encoding="utf-8")))
            if not count:
                continue
            if rel_path == "HermesMobile/Features/Shared/HermexOverlayLab.swift":
                overlay_lab_count = count
            if rel_path not in allowed:
                offenders.append(rel_path)
        return offenders, overlay_lab_count

    def test_overlay_lab_exposes_round_3_list_item_rendered_verification_specimens(self):
        src = self._overlay_lab_source()
        self.assertIn("--hermex-overlay-lab-round-3-list-item", src)
        self.assertIn("HermexOverlayLabRound3ListItemSection.scrollAnchorID", src)
        for identifier in [
            "overlay-lab-round-3-list-item-normal",
            "overlay-lab-round-3-list-item-interactive",
            "overlay-lab-round-3-list-item-selected-standard",
            "overlay-lab-round-3-list-item-selected-indicator-only",
            "overlay-lab-round-3-list-item-disabled",
            "overlay-lab-round-3-list-item-pending",
        ]:
            self.assertIn(identifier, src, f"expected a stable Round 3 identifier for {identifier}")
        self.assertIn(
            "selectionChrome: .indicatorOnly",
            src,
            "expected the indicator-only selected specimen to compose an existing Checkbox/Radio visual "
            "without a duplicate selected pill/checkmark",
        )
        self.assertTrue(
            "HermexRadio(" in src or "HermexCheckbox(" in src,
            "expected the indicator-only specimen to compose HermexRadio or HermexCheckbox",
        )

    def test_overlay_lab_composer_toolbar_specimens_use_an_explicit_divider(self):
        src = self._overlay_lab_source()
        self.assertIn(
            "HermexComposerToolbarDivider()",
            src,
            "expected the elevated fitting and transparent Card specimens to place an explicit divider "
            "between two caller-owned control groups",
        )

    def test_overlay_lab_exposes_a_no_leading_accordion_card_and_cardless_specimen(self):
        src = self._overlay_lab_source()
        for identifier in [
            "overlay-lab-round-3-accordion-no-leading-card",
            "overlay-lab-round-3-accordion-no-leading-cardless",
        ]:
            self.assertIn(identifier, src, f"expected a stable Round 3 identifier for {identifier}")
        # Preserve the existing leading-present Card specimen (Batch B follow-up) unchanged.
        self.assertIn("overlay-lab-batch-b-accordion-card", src)

    def test_overlay_lab_exposes_horizontal_and_vertical_multi_selection_sheet_specimens(self):
        src = self._overlay_lab_source()
        self.assertIn("footerAxis: .horizontal", src)
        self.assertIn("footerAxis: .vertical", src)
        self.assertIn("--hermex-overlay-lab-auto-selection-sheet-multi-vertical", src)
        for identifier in [
            "overlay-lab-selection-sheet-multi-horizontal-trigger",
            "overlay-lab-selection-sheet-multi-horizontal-committed",
            "overlay-lab-selection-sheet-multi-vertical-trigger",
            "overlay-lab-selection-sheet-multi-vertical-committed",
        ]:
            self.assertIn(identifier, src, f"expected a stable identifier for {identifier}")
        # Preserve the existing single-selection fixture unchanged.
        self.assertIn("overlay-lab-selection-sheet-single-trigger", src)

    def test_composer_toolbar_divider_call_sites_are_confined_to_its_own_foundation_file_and_the_overlay_lab(self):
        pattern = re.compile(r"HermexComposerToolbarDivider\(")
        allowed = {
            "HermesMobile/Features/Shared/HermexComposerToolbar.swift",
            "HermesMobile/Features/Shared/HermexOverlayLab.swift",
        }
        offenders, overlay_lab_count = self._confined_call_sites(pattern, allowed)
        self.assertEqual(offenders, [], f"HermexComposerToolbarDivider( must only be called from {sorted(allowed)}")
        self.assertGreater(
            overlay_lab_count, 0,
            "expected the DEBUG overlay lab to adopt HermexComposerToolbarDivider with at least one real specimen",
        )

    def test_popover_menu_modifier_call_sites_are_confined_to_its_own_foundation_file_and_the_overlay_lab(self):
        pattern = re.compile(r"\.hermexPopoverMenu\(")
        allowed = {
            "HermesMobile/Features/Shared/HermexPopoverMenu.swift",
            "HermesMobile/Features/Shared/HermexOverlayLab.swift",
        }
        offenders, overlay_lab_count = self._confined_call_sites(pattern, allowed)
        self.assertEqual(offenders, [], f".hermexPopoverMenu( must only be called from {sorted(allowed)}")
        self.assertGreater(
            overlay_lab_count, 0,
            "expected the DEBUG overlay lab to adopt .hermexPopoverMenu with at least one real specimen",
        )

    def test_selection_sheet_call_sites_are_confined_to_its_own_foundation_file_and_the_overlay_lab(self):
        pattern = re.compile(r"HermexSelectionSheet\(")
        allowed = {
            "HermesMobile/Features/Shared/HermexSelectionSheet.swift",
            "HermesMobile/Features/Shared/HermexOverlayLab.swift",
        }
        offenders, overlay_lab_count = self._confined_call_sites(pattern, allowed)
        self.assertEqual(offenders, [], f"HermexSelectionSheet( must only be called from {sorted(allowed)}")
        self.assertGreater(
            overlay_lab_count, 0,
            "expected the DEBUG overlay lab to adopt HermexSelectionSheet with at least one real specimen",
        )


class ProductionDisconnectionBoundaryTests(unittest.TestCase):
    """PR #974 issue-correction: AppTheme.swift, TranscriptLogRowView.swift, and
    CustomAttachmentPicker.swift briefly gained direct dependencies on the Issue #607 foundation and
    were disconnected again (restored to their pre-existing literals/APIs/local implementation). These
    pin that boundary so a future edit cannot silently reintroduce one of those dependencies — any
    real adoption must update this audit deliberately instead of drifting back in unnoticed."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def test_app_theme_reintroducing_hermes_product_palette_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Config/AppTheme.swift",
            "enum HeaderLogoColor {\n    static let defaultHex = HermesProductPalette.headerAccentYellow\n}",
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "AppTheme.swift" in f and "HermesProductPalette" in f and "explicit adoption update" in f
                for f in failures
            ),
            failures,
        )

    def test_app_theme_with_exact_literal_values_passes(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Config/AppTheme.swift",
            "enum HeaderLogoColor {\n    static let defaultHex = \"#FFD700\"\n}",
        )
        self.assertEqual(audit.run(self.root), [])

    def test_transcript_log_row_view_reintroducing_any_named_foundation_token_fails(self):
        for forbidden_snippet in [
            "HermesSpacing.s0",
            "HermesRadius.r8",
            "HermesIconSize.xs",
            "HermesMotion.Duration.d150",
            "AppFont.Role",
            ".appFont(.caption)",
        ]:
            with self.subTest(forbidden_snippet=forbidden_snippet):
                build_valid_fixture_tree(self.root)
                write(
                    self.root,
                    "HermesMobile/Features/Chat/TranscriptLogRowView.swift",
                    f"enum TranscriptLogRowMetrics {{}}\nlet x = {forbidden_snippet}",
                )
                failures = audit.run(self.root)
                self.assertTrue(
                    any(
                        "TranscriptLogRowView.swift" in f and "explicit adoption update" in f
                        for f in failures
                    ),
                    f"expected a failure for {forbidden_snippet}: {failures}",
                )

    def test_transcript_log_row_view_with_only_literals_passes(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Chat/TranscriptLogRowView.swift",
            "enum TranscriptLogRowMetrics {\n    static let rowSpacing: CGFloat = 8\n}",
        )
        self.assertEqual(audit.run(self.root), [])

    def test_custom_attachment_picker_reintroducing_hermex_same_window_overlay_fails(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Chat/CustomAttachmentPicker.swift",
            (
                "struct HermexKeyboardRetainingOverlay<Overlay: View>: View {\n"
                "    var body: some View {\n"
                "        HermexSameWindowOverlay(isPresented: true, bounds: .aboveKeyboard, "
                "accessibilityIdentifier: \"x\") { EmptyView() }\n"
                "    }\n"
                "}"
            ),
        )
        failures = audit.run(self.root)
        self.assertTrue(
            any(
                "CustomAttachmentPicker.swift" in f
                and "HermexSameWindowOverlay" in f
                and "explicit adoption update" in f
                for f in failures
            ),
            failures,
        )

    def test_custom_attachment_picker_with_its_own_local_overlay_passes(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Chat/CustomAttachmentPicker.swift",
            "struct HermexKeyboardRetainingOverlay<Overlay: View>: UIViewControllerRepresentable {}",
        )
        self.assertEqual(audit.run(self.root), [])

    # ─── PR #974 current Greptile correction: comments must not trip the boundary check ──────────
    # A `//` or `/* ... */` comment that merely mentions a forbidden symbol is not a dependency —
    # only a real code reference is. These two pin that the check ignores comments; the pre-existing
    # tests above (test_app_theme_reintroducing_hermes_product_palette_fails,
    # test_transcript_log_row_view_reintroducing_any_named_foundation_token_fails,
    # test_custom_attachment_picker_reintroducing_hermex_same_window_overlay_fails) pin that it still
    # catches a real code reference.

    def test_app_theme_line_comment_mentioning_hermes_product_palette_does_not_fail(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Config/AppTheme.swift",
            (
                "// Someday reconsider HermesProductPalette.headerAccentYellow here.\n"
                "enum HeaderLogoColor {\n"
                "    static let defaultHex = \"#FFD700\"\n"
                "}"
            ),
        )
        self.assertEqual(audit.run(self.root), [])

    def test_transcript_log_row_view_block_comment_mentioning_forbidden_token_does_not_fail(self):
        build_valid_fixture_tree(self.root)
        write(
            self.root,
            "HermesMobile/Features/Chat/TranscriptLogRowView.swift",
            (
                "enum TranscriptLogRowMetrics {\n"
                "    /* was HermesSpacing.s0 before the Issue #607 revert */\n"
                "    static let rowSpacing: CGFloat = 8\n"
                "}"
            ),
        )
        self.assertEqual(audit.run(self.root), [])

    def test_failure_message_phrases_as_requiring_an_update_not_a_permanent_ban(self):
        build_valid_fixture_tree(self.root)
        write(self.root, "HermesMobile/Config/AppTheme.swift", "let x = HermesProductPalette.headerAccentYellow")
        failures = audit.run(self.root)
        joined = " ".join(failures)
        self.assertIn("explicit adoption update", joined)
        self.assertNotIn("permanently prohibited", joined)
        self.assertNotIn("never allowed", joined)

    def test_absent_files_are_not_flagged(self):
        # AppTheme.swift and CustomAttachmentPicker.swift are not part of the minimal fixture tree;
        # the boundary check must skip a missing file rather than fail closed on it (that is
        # check_required_files's job for the foundation files it actually requires).
        build_valid_fixture_tree(self.root)
        self.assertEqual(audit.run(self.root), [])


class CliTests(unittest.TestCase):
    def test_cli_exits_nonzero_with_readable_failures_on_a_broken_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            build_valid_fixture_tree(root)
            (root / "HermesMobile/Features/Shared/HermexCard.swift").unlink()
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(root)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing required foundation file", result.stderr)
            self.assertIn("HermexCard.swift", result.stderr)

    def test_cli_exits_zero_on_a_valid_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            build_valid_fixture_tree(root)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(root)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("OK", result.stdout)

    def test_passes_against_the_real_repository(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
