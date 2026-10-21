"""End-to-end tests: the real ade binary against a fake SmolVM CLI.

These prove ADE's convergence behavior and the exact argv it produces, without
needing a hypervisor. Every test uses a temporary state root and a temporary
fake-runtime state file, so nothing touches real user or machine state.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FAKE = REPO_ROOT / "test" / "qualification" / "fake_smolvm.py"
ADE = REPO_ROOT / "_build" / "default" / "bin" / "main.exe"


@unittest.skipUnless(ADE.exists(), "ade binary not built; run dune build first")
class CliEndToEndTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ade-e2e-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.state_file = self.tmp / "machines.json"
        self.log_file = self.tmp / "calls.log"
        self.declarations = self.tmp / "workbenches"
        shutil.copytree(REPO_ROOT / "workbenches", self.declarations)
        # Declarations name their provision script relative to themselves.
        shutil.copytree(REPO_ROOT / "provision", self.tmp / "provision")
        # The shipped declaration with its SSH identity disabled: these tests
        # are about lifecycle convergence, and starting a dedicated agent needs
        # a real ssh-agent and key. test_boot covers the agent sequence.
        work = (self.declarations / "work.toml").read_text()
        disabled = work.replace(
            'mode = "dedicated_agent"\nkey_ref = "keychain:ade-work-ssh"',
            'mode = "disabled"',
        )
        assert disabled != work, "work.toml [ssh] table changed; update this test"
        (self.declarations / "work.toml").write_text(disabled)

    def fake_runtime(self):
        """A wrapper that bakes the fake's settings into the script itself.

        ADE deliberately passes only PATH to a child process, so the fake cannot
        be configured through the environment: that isolation is the behavior
        test_process_runner asserts. The wrapper carries the paths instead.
        """
        wrapper = self.tmp / "smolvm"
        wrapper.write_text(
            "#!/bin/sh\n"
            f'FAKE_SMOLVM_STATE="{self.state_file}" '
            f'FAKE_SMOLVM_LOG="{self.log_file}" '
            f'exec {sys.executable} "{FAKE}" "$@"\n'
        )
        wrapper.chmod(0o755)
        return wrapper

    def ade(self, *args):
        env = dict(os.environ)
        env["ADE_SMOLVM_BIN"] = str(self.fake_runtime())
        env["ADE_STATE_ROOT"] = str(self.tmp / "state")
        env["ADE_WORKBENCHES_DIR"] = str(self.declarations)
        return subprocess.run(
            [str(ADE), *args], env=env, capture_output=True, text=True, timeout=60
        )

    def machines(self):
        try:
            return json.loads(self.state_file.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def calls(self):
        try:
            return self.log_file.read_text().splitlines()
        except FileNotFoundError:
            return []

    def test_create_then_start_converges(self):
        created = self.ade("create", "work")
        self.assertEqual(created.returncode, 0, msg=created.stderr)
        # work.toml provisions on create, which boots the machine and stops it.
        self.assertEqual(self.machines().get("work"), "stopped")
        execs = [line for line in self.calls() if line.startswith("machine exec")]
        self.assertEqual(len(execs), 1, "provision script did not run exactly once")

        started = self.ade("start", "work")
        self.assertEqual(started.returncode, 0, msg=started.stderr)
        self.assertEqual(self.machines().get("work"), "running")

    def test_repeated_create_does_not_recreate(self):
        self.ade("create", "work")
        again = self.ade("create", "work")
        self.assertEqual(again.returncode, 0, msg=again.stderr)
        self.assertIn("already satisfied", again.stdout)
        creates = [line for line in self.calls() if line.startswith("machine create")]
        self.assertEqual(len(creates), 1, "machine was created more than once")

    def test_repeated_stop_is_a_no_op(self):
        self.ade("create", "work")
        self.ade("start", "work")
        first = self.ade("stop", "work")
        second = self.ade("stop", "work")
        self.assertEqual(first.returncode, 0, msg=first.stderr)
        self.assertEqual(second.returncode, 0, msg=second.stderr)
        self.assertIn("already satisfied", second.stdout)
        self.assertEqual(self.machines().get("work"), "stopped")

    def test_status_reports_observed_state(self):
        self.ade("create", "work")
        self.ade("start", "work")
        status = self.ade("status", "work")
        self.assertEqual(status.returncode, 0, msg=status.stderr)
        self.assertIn("running", status.stdout)

    def test_exec_starts_a_stopped_machine_first(self):
        self.ade("create", "work")
        result = self.ade("exec", "work", "echo", "hello")
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("hello", result.stdout)
        self.assertEqual(self.machines().get("work"), "running")

    def test_exec_exits_with_the_guest_status(self):
        self.ade("create", "work")
        result = self.ade("exec", "work", "exit", "3")
        self.assertEqual(result.returncode, 3, msg=result.stderr)

    def test_create_uses_declared_resources_and_allowlist(self):
        self.ade("create", "work")
        create_calls = [line for line in self.calls() if line.startswith("machine create")]
        self.assertTrue(create_calls, "no create call recorded")
        argv = create_calls[0]
        # Resources and network posture come only from the declaration.
        self.assertIn("--cpus 6", argv)
        self.assertIn("--mem 12288", argv)
        self.assertIn("--allow-host github.com", argv)
        self.assertIn("--net", argv)

    def test_sealed_workbench_is_created_without_network(self):
        self.ade("create", "work-offline")
        create_calls = [line for line in self.calls() if line.startswith("machine create")]
        self.assertTrue(create_calls, "no create call recorded")
        argv = create_calls[0]
        self.assertNotIn("--net", argv)
        self.assertNotIn("--allow-host", argv)

    def test_editing_a_creation_setting_is_reported_as_drift(self):
        self.ade("create", "work")
        work = self.declarations / "work.toml"
        edited = work.read_text().replace("cpus = 6", "cpus = 2")
        assert edited != work.read_text(), "work.toml cpus changed; update this test"
        work.write_text(edited)

        status = self.ade("status", "work")
        self.assertEqual(status.returncode, 0, msg=status.stderr)
        self.assertIn("drift\tresources changed", status.stdout)

        started = self.ade("start", "work")
        self.assertEqual(started.returncode, 0, msg=started.stderr)
        self.assertIn("warning: work: resources changed", started.stderr)

        again = self.ade("create", "work")
        self.assertNotEqual(again.returncode, 0)

    def test_unknown_workbench_is_reported(self):
        result = self.ade("status", "does-not-exist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("declaration", result.stderr)


if __name__ == "__main__":
    unittest.main()
