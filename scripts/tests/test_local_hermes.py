"""Run with: python3 -m unittest discover -s scripts/tests -v"""

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import signal
import subprocess
import unittest
from unittest.mock import Mock, call, patch


SCRIPT = Path(__file__).resolve().parents[1] / "local-hermes"
loader = importlib.machinery.SourceFileLoader("local_hermes", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
local = importlib.util.module_from_spec(spec)
loader.exec_module(local)

TOOLS = [{"type": "function", "function": {"name": "terminal", "parameters": {}}}]


def tool_result(**fields):
    """A terminal tool result as Hermes returns it to the model: a JSON string."""
    return json.dumps(dict(dict(output="", exit_code=0, error=None), **fields))


class StubModelTests(unittest.TestCase):
    def answer(self, body):
        status, reply = local.stub_reply(body)
        self.assertEqual(status, 200)
        return reply["choices"][0]

    def test_a_call_without_tools_gets_plain_text(self):
        choice = self.answer({"messages": [{"role": "user", "content": "Title this conversation"}]})
        self.assertEqual(choice["finish_reason"], "stop")
        self.assertNotIn("tool_calls", choice["message"])

    def test_a_user_message_gets_one_terminal_call(self):
        choice = self.answer({"tools": TOOLS, "messages": [
            {"role": "system", "content": "You are Hermes."}, {"role": "user", "content": "hi"}]})
        self.assertEqual(choice["finish_reason"], "tool_calls")
        self.assertEqual(choice["message"]["content"], "Let me run a quick check.")
        calls = choice["message"]["tool_calls"]
        self.assertEqual([c["function"]["name"] for c in calls], ["terminal"])
        self.assertEqual(json.loads(calls[0]["function"]["arguments"]), {"command": 'python3 -c "print(1)"'})

    def test_a_tool_result_gets_the_closing_text_with_its_first_line(self):
        choice = self.answer({"tools": TOOLS, "messages": [
            {"role": "user", "content": "hi"},
            {"role": "tool", "tool_call_id": "call_1", "content": tool_result(output="1\nsecond line\n")}]})
        self.assertEqual(choice["finish_reason"], "stop")
        self.assertEqual(choice["message"]["content"], "The command returned: 1.")
        self.assertNotIn("tool_calls", choice["message"])

    def test_a_denied_command_reports_the_error(self):
        choice = self.answer({"tools": TOOLS, "messages": [
            {"role": "user", "content": "hi"},
            {"role": "tool", "tool_call_id": "call_1",
             "content": tool_result(exit_code=-1, error="BLOCKED: the user denied it.\nDo not retry.", status="blocked")}]})
        self.assertEqual(choice["message"]["content"], "The command returned: BLOCKED: the user denied it.")

    def test_a_streaming_request_is_refused(self):
        status, reply = local.stub_reply({"stream": True, "tools": TOOLS, "messages": [{"role": "user", "content": "hi"}]})
        self.assertEqual(status, 400)
        self.assertIn("model.streaming: false", reply["error"]["message"])


class HomeTests(unittest.TestCase):
    def make_home(self):
        home = local.make_home(stub_port=5123)
        self.addCleanup(shutil.rmtree, home)
        return home

    def test_the_config_points_the_model_at_the_loopback_stub_with_manual_approvals(self):
        config = json.loads((self.make_home() / "config.yaml").read_text())
        self.assertEqual(config["model"]["provider"], "custom")
        self.assertEqual(config["model"]["base_url"], "http://127.0.0.1:5123/v1")
        self.assertIs(config["model"]["streaming"], False)
        self.assertEqual(config["approvals"]["mode"], "manual")

    def test_every_home_carries_the_same_install_id(self):
        first, second = self.make_home(), self.make_home()
        self.assertNotEqual(first, second)
        identity = (first / "install_id").read_text().strip()
        self.assertRegex(identity, r"^[0-9a-f]{32}$")
        self.assertEqual((second / "install_id").read_text().strip(), identity)

    def test_the_server_environment_is_confined_to_the_home(self):
        home = self.make_home()
        env = local.server_env(home, {"PATH": "/usr/bin", "HERMES_DESKTOP": "1", "HERMES_HOME": "/Users/someone/.hermes"})
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertNotIn("HERMES_DESKTOP", env)
        self.assertEqual(env["HERMES_HOME"], str(home))
        self.assertEqual(env["HERMES_GATEWAY_LOCK_DIR"], str(home / "locks"))
        self.assertEqual(env["HERMES_DASHBOARD_BASIC_AUTH_USERNAME"], "hermex")
        self.assertEqual(env["HERMES_DASHBOARD_BASIC_AUTH_PASSWORD"], "hermex-local")
        self.assertEqual(env["HERMES_DASHBOARD_PUBLIC_URL"], "http://hermex-local.invalid")


class StopTests(unittest.TestCase):
    def test_stop_signals_only_the_recorded_process_group(self):
        process = Mock(pid=4242)
        process.wait.side_effect = [subprocess.TimeoutExpired("hermes", 10), 0]
        with patch.object(local.os, "killpg") as killpg:
            local.stop(process)
        self.assertEqual(killpg.call_args_list, [call(4242, signal.SIGTERM), call(4242, signal.SIGKILL)])
        self.assertEqual(process.wait.call_args_list, [call(timeout=10), call()])

    def test_stop_tolerates_a_group_that_is_already_gone(self):
        process = Mock(pid=4242)
        with patch.object(local.os, "killpg", side_effect=ProcessLookupError) as killpg:
            local.stop(process)
        self.assertEqual(killpg.call_args_list, [call(4242, signal.SIGTERM), call(4242, signal.SIGKILL)])


if __name__ == "__main__":
    unittest.main()
