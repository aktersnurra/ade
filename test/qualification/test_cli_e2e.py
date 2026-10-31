"""End-to-end tests: the real ade binary against a fake SmolVM CLI.

These prove ADE's convergence behavior and the exact argv it produces, without
needing a hypervisor. Every test uses a temporary state root and a temporary
fake-runtime state file, so nothing touches real user or machine state.
"""

import json
import os
import shutil
import socket
import struct
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

    def ade(self, *args, cwd=None, declarations_env=True, smolvm=None):
        env = dict(os.environ)
        # Without a session bus the proxy's desktop notifications fail
        # silently instead of popping up while the suite runs.
        for key in ("DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR", "DISPLAY", "WAYLAND_DISPLAY"):
            env.pop(key, None)
        env["ADE_SMOLVM_BIN"] = str(smolvm or self.fake_runtime())
        env["ADE_STATE_ROOT"] = str(self.tmp / "state")
        env.pop("ADE_WORKBENCHES_DIR", None)
        if declarations_env:
            env["ADE_WORKBENCHES_DIR"] = str(self.declarations)
        else:
            env["XDG_CONFIG_HOME"] = str(self.tmp / "config")
        return subprocess.run(
            [str(ADE), *args], env=env, capture_output=True, text=True, timeout=60,
            cwd=cwd,
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

    def test_rm_deletes_the_machine(self):
        self.ade("create", "work")
        removed = self.ade("rm", "work", "--yes")
        self.assertEqual(removed.returncode, 0, msg=removed.stderr)
        self.assertNotIn("work", self.machines())

    def test_attach_with_a_command_runs_it(self):
        self.ade("create", "work")
        attached = self.ade("attach", "work", "echo", "attached")
        self.assertEqual(attached.returncode, 0, msg=attached.stderr)

    def test_unknown_workbench_is_reported(self):
        result = self.ade("status", "does-not-exist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("declaration", result.stderr)

    def test_declarations_come_from_the_config_dir_not_the_cwd(self):
        # A checkout with its own workbenches/ must not supply the policy.
        result = self.ade("status", "work", cwd=self.tmp, declarations_env=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.tmp / "config" / "ade" / "workbenches"), result.stderr)

        config = self.tmp / "config" / "ade"
        config.mkdir(parents=True)
        shutil.copytree(self.declarations, config / "workbenches")
        shutil.copytree(self.tmp / "provision", config / "provision")
        result = self.ade("status", "work", cwd=self.tmp, declarations_env=False)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("absent", result.stdout)

    def test_refresh_of_a_stopped_workbench_is_a_no_op(self):
        self.ade("create", "work")
        result = self.ade("refresh", "work")
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("already satisfied", result.stdout)
        self.assertEqual(self.machines().get("work"), "stopped")

    def proxied_declaration(self):
        # A free port, and no classifier: these tests must not reach OpenRouter.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        text = (REPO_ROOT / "workbenches" / "work-proxied.toml.example").read_text()
        text = text.replace('proxy = "192.0.2.10:3128"', f'proxy = "127.0.0.1:{port}"')
        text = text.split("[network.classifier]")[0] + "[services]\nherdr = true\n"
        (self.declarations / "work-proxied.toml").write_text(text)
        return port

    def request(self, port, head):
        with socket.create_connection(("127.0.0.1", port), timeout=5) as conn:
            conn.sendall(head.encode())
            return conn.recv(4096).decode()

    def test_proxied_start_runs_the_proxy_and_stop_ends_it(self):
        port = self.proxied_declaration()
        started = self.ade("start", "work-proxied")
        self.assertEqual(started.returncode, 0, msg=started.stderr)
        self.addCleanup(self.ade, "stop", "work-proxied")

        refused = self.request(port, "CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        self.assertTrue(refused.startswith("HTTP/1.1 403"), refused)
        self.assertIn("ade net allow work-proxied example.com", refused)

        pending = self.ade("net", "pending", "work-proxied")
        self.assertEqual(pending.returncode, 0, msg=pending.stderr)
        self.assertIn("example.com:443", pending.stdout)

        allowed = self.ade("net", "allow", "work-proxied", "example.com")
        self.assertEqual(allowed.returncode, 0, msg=allowed.stderr)
        self.assertIn("no blocked requests", self.ade("net", "pending", "work-proxied").stdout)

        # The guest was told where its proxy is.
        self.assertTrue(
            any(line.startswith("machine exec") for line in self.calls()),
            "guest proxy configuration was not written",
        )

        # A proxy that dies under a running machine comes back on the next
        # command, keeping what was allowed this session.
        pid_file = self.tmp / "state" / "workbenches" / "work-proxied" / "net" / "proxy.pid"
        os.kill(int(pid_file.read_text().strip()), 9)
        again = self.ade("start", "work-proxied")
        self.assertEqual(again.returncode, 0, msg=again.stderr)
        self.assertIn("no blocked requests", self.ade("net", "pending", "work-proxied").stdout)
        refused = self.request(port, "CONNECT other.example:443 HTTP/1.1\r\n\r\n")
        self.assertTrue(refused.startswith("HTTP/1.1 403"), refused)

        guard_file = pid_file.parent / "guard.json"
        self.assertTrue(guard_file.exists())
        stopped = self.ade("stop", "work-proxied")
        self.assertEqual(stopped.returncode, 0, msg=stopped.stderr)
        with self.assertRaises(OSError):
            self.request(port, "CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        # The guard file holds the interceptor token; it must not outlive the run.
        self.assertFalse(guard_file.exists())

    def test_proxied_start_requires_an_authenticated_endpoint_guard(self):
        port = self.proxied_declaration()
        self.addCleanup(self.ade, "stop", "work-proxied")
        started = self.ade("start", "work-proxied")
        self.assertEqual(started.returncode, 0, msg=started.stderr)
        starts = [line for line in self.calls() if line.startswith("machine start")]
        self.assertTrue(starts)
        self.assertTrue(all("--mediated-egress" in line for line in starts))
        self.assertTrue(all("--egress-interceptor " in line for line in starts))
        creates = [line for line in self.calls() if line.startswith("machine create")]
        self.assertIn("--net-backend virtio-net", creates[0])

        net = self.tmp / "state" / "workbenches" / "work-proxied" / "net"
        binding_file = net / "guard.json"
        binding = json.loads(binding_file.read_text())
        self.assertEqual(binding_file.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(binding["token"], "\n".join(self.calls()))
        self.assertNotIn(binding["token"], started.stdout + started.stderr)
        address, guard_port = binding["address"].rsplit(":", 1)
        self.assertEqual(address, "127.0.0.1")

        def decide(ip, destination_port, token=None, payload=b"", magic=b"SMOLMEG2",
                   identity=b"m" * 16, payload_length=None):
            ip_bytes = socket.inet_pton(socket.AF_INET6 if ":" in ip else socket.AF_INET, ip)
            prelude = (magic + bytes.fromhex(token or binding["token"])
                       + identity + bytes(16)
                       + struct.pack("!BH", 6 if ":" in ip else 4, destination_port)
                       + ip_bytes + struct.pack("!H", len(payload) if payload_length is None else payload_length)
                       + payload)
            with socket.create_connection((address, int(guard_port)), timeout=5) as conn:
                conn.sendall(prelude)
                conn.shutdown(socket.SHUT_WR)
                try:
                    return conn.recv(1)
                except ConnectionResetError:
                    return b""

        self.assertEqual(decide("127.0.0.1", port, payload=b"CONNECT example.com:443\r\n\r\n"), b"\x00")
        self.assertEqual(decide("127.0.0.1", port, payload=b"x" * 8192), b"\x00")
        for ip, other_port in [("127.0.0.1", port % 65535 + 1), ("127.0.0.1", int(guard_port)),
                               ("127.0.0.2", port), ("1.1.1.1", 443), ("::1", port)]:
            self.assertNotEqual(decide(ip, other_port), b"\x00", (ip, other_port))
        for kwargs in [{"token": "00" * 32}, {"magic": b"SMOLMEG1"},
                       {"identity": bytes(16)}, {"payload_length": 8193},
                       {"payload_length": 1}]:
            self.assertNotEqual(decide("127.0.0.1", port, **kwargs), b"\x00", kwargs)

        # Recovery must reuse the runtime's binding; silently rotating it would
        # strand the running VM. A new VM start, in contrast, rotates it.
        os.kill(int((net / "proxy.pid").read_text().strip()), 9)
        again = self.ade("start", "work-proxied")
        self.assertEqual(again.returncode, 0, msg=again.stderr)
        self.assertEqual(json.loads(binding_file.read_text()), binding)
        self.assertEqual(decide("127.0.0.1", port), b"\x00")
        restarted = self.ade("restart", "work-proxied")
        self.assertEqual(restarted.returncode, 0, msg=restarted.stderr)
        self.assertNotEqual(json.loads(binding_file.read_text())["token"], binding["token"])
        # Losing the binding must not mint a replacement for a running VM.
        binding_file.write_text("broken")
        os.kill(int((net / "proxy.pid").read_text().strip()), 9)
        failed = self.ade("start", "work-proxied")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("restart", failed.stderr)
        self.assertEqual(binding_file.read_text(), "broken")

    def test_unsupported_mediation_fails_without_an_unfiltered_boot(self):
        port = self.proxied_declaration()
        runtime = self.fake_runtime()
        old_runtime = self.tmp / "old-smolvm"
        old_runtime.write_text(
            '#!/bin/sh\ncase " $* " in *" --mediated-egress "*) '
            'echo "unsupported --mediated-egress" >&2; exit 2;; esac\n'
            f'exec "{runtime}" "$@"\n'
        )
        old_runtime.chmod(0o755)
        self.addCleanup(self.ade, "stop", "work-proxied")
        failed = self.ade("start", "work-proxied", smolvm=old_runtime)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("unsupported --mediated-egress", failed.stderr)
        # The refused start never reached the runtime; ADE's rollback stop did.
        self.assertFalse([line for line in self.calls() if line.startswith("machine start")])
        self.assertNotEqual(self.machines().get("work-proxied"), "running")
        net = self.tmp / "state" / "workbenches" / "work-proxied" / "net"
        self.assertFalse((net / "mediated").exists())
        # The guard listens in the proxy process, so a closed proxy port means
        # both are gone; the rollback also removed the guard's token.
        with self.assertRaises(OSError):
            self.request(port, "CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        self.assertFalse((net / "guard.json").exists())

    def test_running_proxied_machine_without_guard_is_not_adopted(self):
        self.proxied_declaration()
        self.state_file.write_text(json.dumps({"work-proxied": "running"}))
        self.addCleanup(self.ade, "stop", "work-proxied")
        result = self.ade("start", "work-proxied")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restart", result.stderr)
        self.assertFalse(any(line.startswith("machine exec") for line in self.calls()))

    def test_revocation_overrides_session_wildcards_but_not_persistent_grants(self):
        port = self.proxied_declaration()
        self.addCleanup(self.ade, "stop", "work-proxied")
        started = self.ade("start", "work-proxied")
        self.assertEqual(started.returncode, 0, msg=started.stderr)
        request = "CONNECT foo.localhost:443 HTTP/1.1\r\n\r\n"
        self.assertEqual(self.ade("net", "allow", "work-proxied", "*.localhost").returncode, 0)
        # A local address is never dialled, but a 502 (rather than 403) proves
        # the host policy allowed the request through to the resolver.
        self.assertTrue(self.request(port, request).startswith("HTTP/1.1 502"))
        revoked = self.ade("net", "revoke", "work-proxied", "foo.localhost")
        self.assertEqual(revoked.returncode, 0, msg=revoked.stderr)
        self.assertTrue(self.request(port, request).startswith("HTTP/1.1 403"))
        self.assertIn("foo.localhost:443", self.ade("net", "pending", "work-proxied").stdout)
        self.assertTrue(self.request(port, request.replace("foo.", "bar.")).startswith("HTTP/1.1 502"))

        self.assertEqual(self.ade("net", "allow", "work-proxied", "foo.localhost").returncode, 0)
        self.assertTrue(self.request(port, request).startswith("HTTP/1.1 502"))
        self.ade("net", "revoke", "work-proxied", "foo.localhost")
        # Host-owned persistent policy remains authoritative, with an accurate
        # warning even when that policy is a wildcard, not an exact name.
        self.ade("net", "allow", "work-proxied", "*.localhost", "--always")
        revoked = self.ade("net", "revoke", "work-proxied", "foo.localhost")
        self.assertIn("stays allowed", revoked.stdout)
        self.assertTrue(self.request(port, request).startswith("HTTP/1.1 502"))
        (self.declarations / "work-proxied.allow").write_text("")
        self.assertTrue(self.request(port, request).startswith("HTTP/1.1 403"))

    def test_net_commands_refuse_an_unproxied_workbench(self):
        result = self.ade("net", "pending", "work")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a proxied workbench", result.stderr)


if __name__ == "__main__":
    unittest.main()
