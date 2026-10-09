import plistlib
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "HermesMobile.xcodeproj/project.pbxproj"


def load_project():
    return plistlib.loads(subprocess.run(["plutil", "-convert", "xml1", "-o", "-", str(PROJECT)], check=True, capture_output=True).stdout)


class WatchSharedLinkageTests(unittest.TestCase):
    def test_one_local_package_and_exact_five_target_links(self):
        project = load_project()
        objects = project["objects"]
        root = objects[project["rootObject"]]
        refs = [ref for ref in root.get("packageReferences", []) if objects[ref].get("relativePath") == "Packages/WatchShared"]
        self.assertEqual(len(refs), 1)
        package_ref = refs[0]
        products = [key for key, value in objects.items() if value.get("isa") == "XCSwiftPackageProductDependency" and value.get("productName") == "WatchShared"]
        self.assertEqual(len(products), 1)
        self.assertEqual(objects[products[0]].get("package"), package_ref)
        linked = []
        for target_id in root["targets"]:
            target = objects[target_id]
            if products[0] in target.get("packageProductDependencies", []):
                linked.append(target["name"])
                framework_phases = [objects[p] for p in target["buildPhases"] if objects[p]["isa"] == "PBXFrameworksBuildPhase"]
                self.assertEqual(len(framework_phases), 1)
                refs_in_phase = [objects[b].get("productRef") for b in framework_phases[0].get("files", [])]
                self.assertEqual(refs_in_phase.count(products[0]), 1)
        self.assertEqual(set(linked), {"HermesMobile", "HermesMobileTests", "HermexWatchApp", "HermexWatchWidget", "HermexWatchAppTests"})
        self.assertNotIn("HermesShareExtension", linked)
        self.assertNotIn("HermesLiveActivityWidget", linked)
        self.assertNotIn("HermexWatchAppUITests", linked)


if __name__ == "__main__":
    unittest.main()
