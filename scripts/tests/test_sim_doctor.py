"""Run with: python3 -m unittest discover -s scripts/tests -v"""

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "sim-doctor"
loader = importlib.machinery.SourceFileLoader("sim_doctor", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)

UDID = "SIM-A"


def facts(**changes):
    healthy = dict(swap_used_mb=1024, ram_mb=16384, stalled=0, service_answers=True,
                   state="Booted", spawn_answers=True, zombie_pid=None)
    return doctor.Facts(**{**healthy, **changes})


class DiagnoseTests(unittest.TestCase):
    def verdict(self, **changes):
        return doctor.diagnose(facts(**changes), UDID)

    def test_healthy_simulator_needs_nothing(self):
        self.assertEqual(self.verdict(), ("OK", "CoreSimulator answers and the simulator answers.", None))

    def test_silent_service_needs_the_owner_to_restart_it(self):
        verdict, _, fix = self.verdict(service_answers=False)
        self.assertEqual(verdict, "SERVICE")
        self.assertIn("killall -9 com.apple.CoreSimulator.CoreSimulatorService", fix)

    def test_silent_device_with_free_memory_is_restarted_by_udid(self):
        self.assertEqual(self.verdict(spawn_answers=False), (
            "DEVICE", "This simulator (Booted) does not answer but CoreSimulator does.",
            "The session that owns it may run: xcrun simctl shutdown SIM-A && xcrun simctl boot SIM-A"))

    def test_silent_device_while_paging_blames_memory(self):
        for paging in (dict(swap_used_mb=12000), dict(stalled=19)):
            with self.subTest(**paging):
                self.assertEqual(self.verdict(spawn_answers=False, **paging)[0], "MEMORY")


    def test_paging_alone_only_warns(self):
        verdict, explanation, fix = self.verdict(swap_used_mb=12000)
        self.assertEqual((verdict, fix), ("OK", None))
        self.assertIn("11.7 GB swap used", explanation)

    def test_shut_down_simulator_has_nothing_stuck(self):
        self.assertEqual(self.verdict(state="Shutdown")[::2], ("NOT_BOOTED", None))


class GatherTests(unittest.TestCase):
    """Runs gather() and diagnose() against canned command output; None is a
    command that hung or failed."""

    def doctor_says(self, state, jobs, host_state=""):
        listing = json.dumps({"devices": {"iOS-27-0": [dict(udid=UDID, state=state)]}})

        def fake_probe(command, timeout=doctor.PROBE_TIMEOUT):
            if command[:2] == ["sysctl", "-n"]:
                return "17179869184" if command[2] == "hw.memsize" else "used = 1024.00M"
            if command[:4] == ["xcrun", "simctl", "list", "devices"]:
                return listing
            if command[-2:] == ["launchctl", "list"]:
                return jobs
            if command[:2] == ["ps", "-o"]:
                return host_state
            return ""

        with patch.object(doctor, "probe", fake_probe):
            return doctor.diagnose(doctor.gather(UDID), UDID)

    def test_zombie_app_is_cleared_by_restarting_the_simulator(self):
        jobs = "PID\tStatus\tLabel\n46848\t0\tUIKitApplication:com.uzairansar.hermesmobile[e626][rb-legacy]\n"
        verdict, explanation, fix = self.doctor_says("Booted", jobs, host_state="Z\n")
        self.assertEqual(verdict, "ZOMBIE_APP")
        self.assertIn("PID 46848", explanation)
        self.assertIn("xcrun simctl shutdown SIM-A", fix)

    def test_running_app_is_healthy(self):
        jobs = "46848\t0\tUIKitApplication:com.uzairansar.hermesmobile[e626]\n"
        self.assertEqual(self.doctor_says("Booted", jobs, host_state="Ss\n")[0], "OK")

    def test_failed_app_listing_is_not_reported_healthy(self):
        self.assertEqual(self.doctor_says("Booted", None)[0], "DEVICE")

    def test_simulator_stuck_booting_is_not_reported_harmless(self):
        self.assertEqual(self.doctor_says("Booting", None)[:2], (
            "DEVICE", "This simulator (Booting) does not answer but CoreSimulator does."))


class ProbeTests(unittest.TestCase):
    def test_hung_command_returns_none_and_stops_its_children(self):
        started = time.monotonic()
        self.assertIsNone(doctor.probe(["sh", "-c", "sleep 30 & sleep 30; wait"], timeout=0.5))
        self.assertLess(time.monotonic() - started, 5)

    def test_gives_up_on_a_child_that_outlives_the_kill(self):
        # The grandchild leaves the process group but keeps the pipe open, like
        # a child stuck in an uninterruptible wait.
        started = time.monotonic()
        escaped = "import os, time; os.setsid(); time.sleep(8)"
        self.assertIsNone(doctor.probe(["sh", "-c", 'python3 -c "{}" & sleep 30'.format(escaped)],
                                       timeout=0.5))
        self.assertLess(time.monotonic() - started, 5)

    def test_answering_command_returns_its_output(self):
        self.assertEqual(doctor.probe(["echo", "ok"]), "ok\n")


if __name__ == "__main__":
    unittest.main()
