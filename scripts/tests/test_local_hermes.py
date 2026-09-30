"""Run with: python3 -m unittest discover -s scripts/tests -v"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
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

    def test_the_server_reaches_the_stub_past_a_proxy(self):
        env = local.server_env(self.make_home(), {"http_proxy": "http://proxy.example:3128", "no_proxy": "corp.example"})
        self.assertEqual(env["no_proxy"], "corp.example,127.0.0.1")
        self.assertEqual(env["NO_PROXY"], "corp.example,127.0.0.1")


class StatusHandler(BaseHTTPRequestHandler):
    """A gated /api/status carrying the script's install_id."""

    def do_GET(self):
        data = json.dumps({"auth_required": True, "auth_providers": ["basic"], "install_id": local.INSTALL_ID}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


class ReadinessTests(unittest.TestCase):
    def test_readiness_skips_a_configured_proxy(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), StatusHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        # Port 9 on loopback refuses connections, so a proxied request never answers.
        with patch.dict(local.os.environ, {"http_proxy": "http://127.0.0.1:9"}), patch.object(local, "READY_TIMEOUT", 1):
            status = local.wait_until_ready(Mock(**{"poll.return_value": None}), server.server_address[1])
        self.assertEqual(status["install_id"], local.INSTALL_ID)


class PortTests(unittest.TestCase):
    def listener(self):
        """A listening socket bound the way `hermes serve` (uvicorn) binds, with SO_REUSEADDR."""
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        return listener

    def test_a_port_the_last_run_left_in_time_wait_is_free(self):
        listener = self.listener()
        port = listener.getsockname()[1]
        client = socket.create_connection(("127.0.0.1", port))
        accepted, _ = listener.accept()
        accepted.close()  # The server side closes first, so its end enters TIME_WAIT.
        self.assertEqual(client.recv(1), b"")
        client.close()
        listener.close()
        local.require_free(port)

    def test_a_listening_port_is_in_use(self):
        listener = self.listener()
        self.addCleanup(listener.close)
        with self.assertRaises(SystemExit):
            local.require_free(listener.getsockname()[1])


class InstallTests(unittest.TestCase):
    SHA = "0" * 40

    def setUp(self):
        self.cache = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.cache)
        self.root = self.cache / self.SHA
        (self.root / "src").mkdir(parents=True)
        (self.root / "src" / "pyproject.toml").write_text("")

    def test_an_interrupted_install_is_redone_and_a_finished_one_reused(self):
        root = self.root
        # An install stopped after uv wrote the entry point.
        (root / ".venv" / "bin").mkdir(parents=True)
        (root / ".venv" / "bin" / "hermes").write_text("")
        with patch.object(local, "CACHE", self.cache), patch.object(local, "run") as run, \
                patch.object(local.shutil, "which", return_value="/usr/bin/tool"):
            self.assertEqual(local.ensure_install(self.SHA), root / ".venv" / "bin" / "hermes")
            self.assertEqual([made.args[0][:3] for made in run.call_args_list],
                             [["uv", "venv", "--quiet"], ["uv", "pip", "install"]])
            run.reset_mock()
            local.ensure_install(self.SHA)
            self.assertEqual(run.call_args_list, [])

    def test_a_run_that_waited_for_another_install_reuses_it(self):
        def other_run_finishes(lock, operation):
            self.assertEqual(operation, local.fcntl.LOCK_EX)
            (self.root / "installed").touch()
        with patch.object(local, "CACHE", self.cache), patch.object(local, "run") as run, \
                patch.object(local.fcntl, "flock", side_effect=other_run_finishes) as flock:
            self.assertEqual(local.ensure_install(self.SHA), self.root / ".venv" / "bin" / "hermes")
        self.assertEqual(flock.call_count, 1)
        self.assertEqual(run.call_args_list, [])


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
