import hashlib
import json
import os
import plistlib
import subprocess
import unittest
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[2]
PROJECT_PATH = ROOT / "HermesMobile.xcodeproj/project.pbxproj"
SCHEME_PATH = ROOT / "HermesMobile.xcodeproj/xcshareddata/xcschemes/HermexWatchApp.xcscheme"
IOS_SCHEME_PATH = ROOT / "HermesMobile.xcodeproj/xcshareddata/xcschemes/HermesMobile.xcscheme"
FIXTURE_PATH = Path(__file__).parent / "fixtures/pre-watch-project.json"
WATCH_SHARED_PATH = "Packages/WatchShared"
WATCH_SHARED_TARGETS = {
    "HermesMobile",
    "HermesMobileTests",
    "HermexWatchApp",
    "HermexWatchWidget",
    "HermexWatchAppTests",
}
AUTHORIZED_IOS_WATCH_COMPANION_SOURCES = {
    "WatchInstallationIdentity.swift",
    "APIClientWatchPhoneBackend.swift",
    "HermesWatchPhoneBackend.swift",
    "WatchVoiceNoteTranscription.swift",
    "PhoneWatchConnectivityHost.swift",
}


def load_project():
    converted = subprocess.run(
        ["plutil", "-convert", "xml1", "-o", "-", str(PROJECT_PATH)],
        check=True,
        capture_output=True,
    ).stdout
    return plistlib.loads(converted)


class WatchProjectStructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = load_project()
        cls.objects = cls.project["objects"]
        cls.root = cls.objects[cls.project["rootObject"]]
        cls.targets = {
            cls.objects[target_id]["name"]: (target_id, cls.objects[target_id])
            for target_id in cls.root["targets"]
        }
        cls.fixture = json.loads(FIXTURE_PATH.read_text())

    def configurations(self, target):
        config_list = self.objects[target["buildConfigurationList"]]
        return {
            self.objects[config_id]["name"]: self.objects[config_id]
            for config_id in config_list["buildConfigurations"]
        }

    def phase(self, target, isa, name=None):
        matches = []
        for phase_id in target["buildPhases"]:
            phase = self.objects[phase_id]
            if phase["isa"] == isa and (name is None or phase.get("name") == name):
                matches.append(phase)
        self.assertEqual(len(matches), 1, (isa, name, matches))
        return matches[0]

    def dependency_target_names(self, target):
        return [self.objects[self.objects[dep]["target"]]["name"] for dep in target.get("dependencies", [])]

    def built_product_paths(self, phase):
        paths = []
        for build_file_id in phase.get("files", []):
            file_ref = self.objects[build_file_id]["fileRef"]
            paths.append(self.objects[file_ref]["path"])
        return paths

    def watch_shared_product_id(self):
        package_refs = [
            ref
            for ref in self.root.get("packageReferences", [])
            if self.objects[ref].get("relativePath") == WATCH_SHARED_PATH
        ]
        self.assertEqual(len(package_refs), 1)
        products = [
            object_id
            for object_id, value in self.objects.items()
            if value.get("isa") == "XCSwiftPackageProductDependency"
            and value.get("productName") == "WatchShared"
            and value.get("package") == package_refs[0]
        ]
        self.assertEqual(len(products), 1)
        return products[0]

    def assert_preserved_dependencies_with_authorized_watch_shared_addition(
        self, target_name, actual_dependencies, expected_dependencies, watch_shared_product
    ):
        expected = list(expected_dependencies)
        if target_name in WATCH_SHARED_TARGETS:
            expected.append(watch_shared_product)
        self.assertEqual(actual_dependencies, expected)

    def assert_preserved_phase_files_with_authorized_watch_shared_addition(
        self, target_name, actual_phase, expected_phase, watch_shared_product
    ):
        actual_files = actual_phase.get("files", [])
        if (
            expected_phase["isa"] == "PBXSourcesBuildPhase"
            and target_name == "HermesMobile"
        ):
            extras = [item for item in actual_files if item not in expected_phase["files"]]
            for build_file_id in extras:
                file_ref = self.objects[build_file_id]["fileRef"]
                path = self.objects[file_ref].get("path", "")
                self.assertIn(path, AUTHORIZED_IOS_WATCH_COMPANION_SOURCES)
            self.assertEqual(
                [item for item in actual_files if item in set(expected_phase["files"])],
                expected_phase["files"],
            )
            return
        if expected_phase["isa"] != "PBXFrameworksBuildPhase" or target_name not in WATCH_SHARED_TARGETS:
            self.assertEqual(actual_files, expected_phase["files"])
            return

        watch_shared_build_files = [
            build_file_id
            for build_file_id in actual_files
            if self.objects[build_file_id].get("productRef") == watch_shared_product
        ]
        self.assertEqual(len(watch_shared_build_files), 1)
        self.assertEqual(
            [item for item in actual_files if item not in watch_shared_build_files],
            expected_phase["files"],
        )

    def test_existing_target_configuration_and_memberships_are_preserved(self):
        watch_shared_product = self.watch_shared_product_id()
        for expected in self.fixture["targets"]:
            target_id, actual = self.targets[expected["name"]]
            self.assertEqual(target_id, expected["id"])
            self.assertEqual(actual["productType"], expected["productType"])
            self.assertEqual(actual["productReference"], expected["productReference"])
            self.assert_preserved_dependencies_with_authorized_watch_shared_addition(
                expected["name"],
                actual.get("packageProductDependencies", []),
                expected["packageProductDependencies"],
                watch_shared_product,
            )
            actual_configs = self.configurations(actual)
            for config in expected["configurations"]:
                self.assertEqual(actual_configs[config["name"]].get("baseConfigurationReference"), config["baseConfigurationReference"])
                self.assertEqual(actual_configs[config["name"]]["buildSettings"], config["buildSettings"])
            old_phases = expected["phases"]
            for phase in old_phases:
                actual_phase = self.objects[phase["id"]]
                self.assertEqual(actual_phase["isa"], phase["isa"])
                self.assert_preserved_phase_files_with_authorized_watch_shared_addition(
                    expected["name"], actual_phase, phase, watch_shared_product
                )
                self.assertEqual(actual_phase.get("dstPath"), phase["dstPath"])
                self.assertEqual(actual_phase.get("dstSubfolderSpec"), phase["dstSubfolderSpec"])
                self.assertEqual(actual_phase.get("name"), phase["name"])
            if expected["name"] == "HermesMobile":
                self.assertEqual(actual["buildPhases"][: len(old_phases)], [p["id"] for p in old_phases])
                self.assertEqual(actual["dependencies"][: len(expected["dependencies"])], expected["dependencies"])
            else:
                self.assertEqual(actual["buildPhases"], [p["id"] for p in old_phases])
                self.assertEqual(actual.get("dependencies", []), expected["dependencies"])
        self.assertEqual(
            self.root.get("packageReferences", [])[: len(self.fixture["package_references"])],
            self.fixture["package_references"],
        )
        added_packages = self.root.get("packageReferences", [])[len(self.fixture["package_references"]):]
        self.assertEqual(
            [self.objects[package_id]["relativePath"] for package_id in added_packages],
            ["Packages/HermexWatchRoot", WATCH_SHARED_PATH],
        )
        old_main_children = set(self.fixture["main_group_children"])
        self.assertEqual(
            [item for item in self.objects[self.root["mainGroup"]]["children"] if item in old_main_children],
            self.fixture["main_group_children"],
        )
        old_products = set(self.fixture["product_group_children"])
        self.assertEqual(
            [item for item in self.objects[self.root["productRefGroup"]]["children"] if item in old_products],
            self.fixture["product_group_children"],
        )
        self.assertEqual(hashlib.sha256(IOS_SCHEME_PATH.read_bytes()).hexdigest(), self.fixture["scheme_sha256"])

    def test_legacy_dependency_preservation_rejects_unrelated_dependency_drift(self):
        watch_shared_product = "WATCH_SHARED"
        original = ["EXISTING_A", "EXISTING_B"]

        self.assert_preserved_dependencies_with_authorized_watch_shared_addition(
            "HermesMobile", original + [watch_shared_product], original, watch_shared_product
        )
        with self.assertRaises(AssertionError):
            self.assert_preserved_dependencies_with_authorized_watch_shared_addition(
                "HermesMobile",
                original + ["UNRELATED", watch_shared_product],
                original,
                watch_shared_product,
            )
        with self.assertRaises(AssertionError):
            self.assert_preserved_dependencies_with_authorized_watch_shared_addition(
                "HermesShareExtension",
                original + [watch_shared_product],
                original,
                watch_shared_product,
            )

    def test_modern_watch_target_graph_and_settings(self):
        self.assertEqual(len(self.targets), 8)
        app_id, app = self.targets["HermexWatchApp"]
        _, widget = self.targets["HermexWatchWidget"]
        _, unit_tests = self.targets["HermexWatchAppTests"]
        _, ui_tests = self.targets["HermexWatchAppUITests"]
        self.assertEqual(app["productType"], "com.apple.product-type.application")
        self.assertEqual(widget["productType"], "com.apple.product-type.app-extension")
        self.assertEqual(unit_tests["productType"], "com.apple.product-type.bundle.unit-test")
        self.assertEqual(ui_tests["productType"], "com.apple.product-type.bundle.ui-testing")
        for target_name in ("HermexWatchApp", "HermexWatchWidget", "HermexWatchAppTests", "HermexWatchAppUITests"):
            self.assertNotIn(self.targets[target_name][1]["productType"], {
                "com.apple.product-type.application.watchapp2",
                "com.apple.product-type.watchkit2-extension",
            })
        for phase_type in ("PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"):
            self.phase(app, phase_type)
        self.assertEqual(self.dependency_target_names(app), ["HermexWatchWidget"])
        self.assertEqual(self.dependency_target_names(unit_tests), ["HermexWatchApp"])
        self.assertEqual(self.dependency_target_names(ui_tests), ["HermexWatchApp"])
        expected_ids = {
            "HermexWatchApp": "$(APP_BUNDLE_IDENTIFIER).watchkitapp",
            "HermexWatchWidget": "$(APP_BUNDLE_IDENTIFIER).watchkitapp.widgets",
            "HermexWatchAppTests": "$(APP_BUNDLE_IDENTIFIER).watchkitapp.tests",
            "HermexWatchAppUITests": "$(APP_BUNDLE_IDENTIFIER).watchkitapp.uitests",
        }
        for name, bundle_id in expected_ids.items():
            for config in self.configurations(self.targets[name][1]).values():
                settings = config["buildSettings"]
                self.assertEqual(settings["SDKROOT"], "watchos")
                self.assertEqual(settings["SUPPORTED_PLATFORMS"], "watchos watchsimulator")
                self.assertEqual(settings["WATCHOS_DEPLOYMENT_TARGET"], "11.0")
                self.assertEqual(str(settings["TARGETED_DEVICE_FAMILY"]), "4")
                self.assertEqual(settings["SWIFT_VERSION"], "5.0")
                self.assertEqual(settings["SWIFT_STRICT_CONCURRENCY"], "targeted")
                self.assertEqual(settings["CODE_SIGN_STYLE"], "Automatic")
                self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], bundle_id)
        for config in self.configurations(app).values():
            settings = config["buildSettings"]
            self.assertEqual(settings["INFOPLIST_KEY_WKApplication"], "YES")
            self.assertEqual(settings["INFOPLIST_KEY_WKCompanionAppBundleIdentifier"], "$(APP_BUNDLE_IDENTIFIER)")
            self.assertEqual(settings["INFOPLIST_KEY_HermexWatchAppGroupIdentifier"], "$(APP_GROUP_IDENTIFIER).watch")
            self.assertEqual(settings["SKIP_INSTALL"], "YES")
            self.assertNotIn("INFOPLIST_KEY_WKWatchOnly", settings)
        for config in self.configurations(widget).values():
            self.assertEqual(config["buildSettings"]["INFOPLIST_KEY_HermexWatchAppGroupIdentifier"], "$(APP_GROUP_IDENTIFIER).watch")

    def test_embed_relationships_are_exact(self):
        _, ios = self.targets["HermesMobile"]
        _, app = self.targets["HermexWatchApp"]
        self.assertEqual(self.dependency_target_names(ios).count("HermexWatchApp"), 1)
        watch_embed = self.phase(ios, "PBXCopyFilesBuildPhase", "Embed Watch Content")
        self.assertEqual(str(watch_embed["dstSubfolderSpec"]), "16")
        self.assertEqual(watch_embed["dstPath"], "$(CONTENTS_FOLDER_PATH)/Watch")
        self.assertEqual(self.built_product_paths(watch_embed), ["HermexWatchApp.app"])
        widget_embed = self.phase(app, "PBXCopyFilesBuildPhase", "Embed App Extensions")
        self.assertEqual(str(widget_embed["dstSubfolderSpec"]), "13")
        self.assertEqual(self.built_product_paths(widget_embed), ["HermexWatchWidget.appex"])
        for phase_id in ios["buildPhases"]:
            phase = self.objects[phase_id]
            if phase["isa"] == "PBXCopyFilesBuildPhase":
                self.assertNotIn("HermexWatchWidget.appex", self.built_product_paths(phase))

    def test_watch_scheme_launches_app_and_contains_tests(self):
        tree = ElementTree.parse(SCHEME_PATH)
        refs = tree.findall(".//BuildableReference")
        names = [ref.attrib["BlueprintName"] for ref in refs]
        self.assertIn("HermexWatchApp", names)
        test_names = [
            ref.attrib["BlueprintName"]
            for ref in tree.findall(".//TestAction/Testables/TestableReference/BuildableReference")
        ]
        self.assertEqual(test_names, ["HermexWatchAppTests", "HermexWatchAppUITests"])
        launch = tree.find(".//LaunchAction/BuildableProductRunnable/BuildableReference")
        self.assertIsNotNone(launch)
        assert launch is not None
        self.assertEqual(launch.attrib["BlueprintName"], "HermexWatchApp")

    def test_entitlements_and_widget_plist_are_minimal(self):
        expected_groups = ["$(APP_GROUP_IDENTIFIER).watch"]
        for path in (
            ROOT / "HermexWatch/Resources/HermexWatch.entitlements",
            ROOT / "HermexWatchWidget/Resources/HermexWatchWidget.entitlements",
        ):
            payload = plistlib.loads(path.read_bytes())
            self.assertEqual(payload, {"com.apple.security.application-groups": expected_groups})
        info = plistlib.loads((ROOT / "HermexWatchWidget/Resources/Info.plist").read_bytes())
        self.assertEqual(info["NSExtension"]["NSExtensionPointIdentifier"], "com.apple.widgetkit-extension")
        self.assertEqual(info["HermexWatchAppGroupIdentifier"], "$(APP_GROUP_IDENTIFIER).watch")

    def test_watch_app_uses_explicit_info_plist_contract(self):
        _, app = self.targets["HermexWatchApp"]
        info_path = ROOT / "HermexWatch/Resources/Info.plist"
        info = plistlib.loads(info_path.read_bytes())

        self.assertEqual(info["HermexWatchAppGroupIdentifier"], "$(APP_GROUP_IDENTIFIER).watch")
        self.assertTrue(info["WKApplication"])
        self.assertEqual(info["WKCompanionAppBundleIdentifier"], "$(APP_BUNDLE_IDENTIFIER)")
        for config in self.configurations(app).values():
            settings = config["buildSettings"]
            self.assertEqual(settings["GENERATE_INFOPLIST_FILE"], "NO")
            self.assertEqual(settings["INFOPLIST_FILE"], "HermexWatch/Resources/Info.plist")

    def test_built_watch_app_plists_preserve_required_contract(self):
        derived_data = os.environ.get("HERMEX_WATCH_DERIVED_DATA")
        if derived_data is None:
            self.skipTest("set HERMEX_WATCH_DERIVED_DATA to verify processed products")

        products = Path(derived_data) / "Build/Products"
        paths = (
            products / "Debug-watchsimulator/HermexWatchApp.app/Info.plist",
            products / "Debug-iphonesimulator/HermesMobile.app/Watch/HermexWatchApp.app/Info.plist",
        )
        for path in paths:
            with self.subTest(path=path):
                info = plistlib.loads(path.read_bytes())
                self.assertEqual(
                    info["HermexWatchAppGroupIdentifier"],
                    "group.com.uzairansar.hermesmobile.watch",
                )
                self.assertTrue(info["WKApplication"])
                self.assertEqual(
                    info["WKCompanionAppBundleIdentifier"],
                    "com.uzairansar.hermesmobile",
                )


if __name__ == "__main__":
    unittest.main()
