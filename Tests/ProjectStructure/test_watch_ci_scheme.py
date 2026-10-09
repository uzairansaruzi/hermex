"""CI test scheme preserves the normal scheme except test debugger."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

SCHEMES = Path(__file__).resolve().parents[2] / 'HermesMobile.xcodeproj/xcshareddata/xcschemes'

class WatchCISchemeTests(unittest.TestCase):
    def test_ci_scheme_preserves_build_launch_and_test_membership(self):
        normal = ET.parse(SCHEMES / 'HermesMobile.xcscheme').getroot()
        candidate = SCHEMES / 'HermesMobileCI.xcscheme'
        self.assertTrue(candidate.is_file(), 'Reproducible debugger-free CI scheme required')
        ci = ET.parse(candidate).getroot()
        action = ci.find('TestAction')
        baseline_action = normal.find('TestAction')
        assert action is not None and baseline_action is not None
        self.assertEqual(action.get('selectedDebuggerIdentifier'), '')
        self.assertEqual(action.get('selectedLauncherIdentifier'), 'Xcode.IDEFoundation.Launcher.PosixSpawn')
        for key in ('selectedDebuggerIdentifier', 'selectedLauncherIdentifier'):
            value = baseline_action.get(key)
            assert value is not None
            action.set(key, value)
        self.assertEqual(ET.tostring(ci), ET.tostring(normal), 'CI scheme must not change tests, app launch, dependencies or production behavior')

if __name__ == '__main__': unittest.main()
