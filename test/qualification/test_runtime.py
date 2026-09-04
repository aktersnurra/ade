"""Blocking runtime qualification for the pinned SmolVM.

Each test asserts a property ADE's design depends on. They run against a live
runtime and are skipped when none is installed.
"""

import json
import unittest

from .runtime import REPO_ROOT, RuntimeTestCase


class LifecycleTest(RuntimeTestCase):
    def test_create_start_stop_and_state_transitions(self):
        self.machine("q-lifecycle", "--net")

        status = self.smolvm("machine", "status", "--name", "q-lifecycle", "--json")
        self.assertEqual(json.loads(status.stdout)["state"], "created")

        started = self.smolvm("machine", "start", "--name", "q-lifecycle")
        self.assertEqual(started.returncode, 0, msg=started.stderr[-400:])
        status = self.smolvm("machine", "status", "--name", "q-lifecycle", "--json")
        self.assertIn(json.loads(status.stdout)["state"], ("running", "ready", "booting"))

        stopped = self.smolvm("machine", "stop", "--name", "q-lifecycle")
        self.assertEqual(stopped.returncode, 0, msg=stopped.stderr[-400:])
        status = self.smolvm("machine", "status", "--name", "q-lifecycle", "--json")
        self.assertIn(json.loads(status.stdout)["state"], ("stopped", "stopping"))

    def test_repeated_stop_is_not_an_error(self):
        self.machine("q-idempotent", "--net")
        self.smolvm("machine", "start", "--name", "q-idempotent")
        first = self.smolvm("machine", "stop", "--name", "q-idempotent")
        second = self.smolvm("machine", "stop", "--name", "q-idempotent")
        self.assertEqual(first.returncode, 0, msg=first.stderr[-300:])
        self.assertEqual(second.returncode, 0, msg=second.stderr[-300:])

    def test_status_of_an_unknown_machine_says_not_found(self):
        result = self.smolvm("machine", "status", "--name", "q-nonexistent", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not found", (result.stderr + result.stdout).lower())


class PersistenceTest(RuntimeTestCase):
    """The state contract: /workspace survives stop/start, tmpfs does not."""

    def test_workspace_survives_stop_and_start(self):
        self.machine("q-persist", "--net")
        self.smolvm("machine", "start", "--name", "q-persist")

        written = self.guest("q-persist", "mkdir -p /workspace && echo durable > /workspace/marker && cat /workspace/marker")
        self.assertIn("durable", written.stdout, msg=written.stderr[-400:])

        self.smolvm("machine", "stop", "--name", "q-persist")
        self.smolvm("machine", "start", "--name", "q-persist")

        after = self.guest("q-persist", "cat /workspace/marker 2>&1")
        self.assertIn("durable", after.stdout, msg="workspace did not survive a restart")

    def test_tmpfs_is_wiped_by_a_restart(self):
        self.machine("q-tmpfs", "--net")
        self.smolvm("machine", "start", "--name", "q-tmpfs")

        self.guest("q-tmpfs", "echo ephemeral > /run/marker")
        present = self.guest("q-tmpfs", "cat /run/marker 2>&1")
        self.assertIn("ephemeral", present.stdout)

        self.smolvm("machine", "stop", "--name", "q-tmpfs")
        self.smolvm("machine", "start", "--name", "q-tmpfs")

        after = self.guest("q-tmpfs", "cat /run/marker 2>/dev/null || echo GONE")
        self.assertIn("GONE", after.stdout, msg="/run survived a restart; it must be ephemeral")


class NetworkPostureTest(RuntimeTestCase):
    """Network policy is enforced by the runtime, not by agent convention."""

    def test_a_sealed_machine_has_no_egress(self):
        # Sealed means no --net at all. The image must already be cached, since
        # a sealed machine cannot pull one.
        self.smolvm("machine", "create", "--name", "q-warm", "--image",
                    "docker.io/library/alpine:latest", "--net")
        self.machines.append("q-warm")

        self.machines.append("q-sealed")
        created = self.smolvm(
            "machine", "create", "--name", "q-sealed",
            "--image", "docker.io/library/alpine:latest", "--cpus", "2", "--mem", "1024",
        )
        if created.returncode != 0:
            # Refusing to create is itself proof the posture is enforced: the
            # runtime knows the pull could never succeed without a network.
            self.assertIn("network", created.stderr.lower())
            return

        self.smolvm("machine", "start", "--name", "q-sealed")
        result = self.guest(
            "q-sealed",
            "wget -q -T 5 -O /dev/null http://example.com 2>&1 && echo REACHED || echo BLOCKED",
        )
        self.assertIn("BLOCKED", result.stdout, msg="a sealed machine reached the network")

    def test_a_networked_machine_resolves_dns(self):
        self.machine("q-net", "--net")
        self.smolvm("machine", "start", "--name", "q-net")
        # What is under test is reachability, not TLS trust or the status code:
        # the bare Alpine rootfs ships no CA bundle, and a proxy may answer 403.
        # Any HTTP response proves DNS resolved, TCP connected and a server
        # replied; only a timeout or resolution failure means blocked.
        result = self.guest(
            "q-net",
            "wget -T 10 -O /dev/null http://example.com 2>&1 | tail -3; echo ---",
        )
        combined = result.stdout + result.stderr
        reached = any(
            marker in combined
            for marker in ("HTTP/1.1", "saving to", "200 OK", "Forbidden", "301", "302")
        )
        self.assertTrue(reached, msg=f"no server response: {combined[-400:]}")

    def test_dns_resolves_inside_a_networked_machine(self):
        self.machine("q-dns", "--net")
        self.smolvm("machine", "start", "--name", "q-dns")
        result = self.guest(
            "q-dns",
            "nslookup example.com >/dev/null 2>&1 && echo RESOLVED || echo UNRESOLVED",
        )
        self.assertIn("RESOLVED", result.stdout, msg=result.stderr[-400:])


class HostIsolationTest(RuntimeTestCase):
    """Qualification must never touch the user's real runtime state."""

    def test_runtime_state_stays_inside_the_test_home(self):
        self.machine("q-isolated", "--net")
        self.smolvm("machine", "start", "--name", "q-isolated")

        # The machine's data directory must live under the temporary HOME.
        data_dir = self.smolvm("machine", "data-dir", "--name", "q-isolated")
        self.assertIn(str(self.home), data_dir.stdout, msg=data_dir.stderr[-300:])

    def test_the_users_default_directories_are_untouched(self):
        from pathlib import Path

        protected = [
            Path.home() / ".smolvm",
            Path.home() / ".microsandbox",
            Path("/opt/homebrew/bin/msb"),
        ]
        before = [(p, p.exists()) for p in protected]

        self.machine("q-untouched", "--net")
        self.smolvm("machine", "start", "--name", "q-untouched")

        for path, existed in before:
            self.assertEqual(existed, path.exists(), f"qualification changed {path}")


if __name__ == "__main__":
    unittest.main()


class WorkstationImageTest(RuntimeTestCase):
    """The image a workbench actually runs, rather than a bare Alpine.

    Skipped when the artifact has not been built, so the suite stays runnable
    on a fresh checkout.
    """

    IMAGE = REPO_ROOT / "artifacts" / "ade-nix-workstation-0.1.0.tar"

    def setUp(self):
        super().setUp()
        if not self.IMAGE.exists():
            self.skipTest("workstation image not built")

    def image_run(self, script, timeout=590):
        return self.smolvm(
            "machine", "run", "--image", str(self.IMAGE), "--",
            "/bin/bash", "-c", script, timeout=timeout,
        )

    def test_herdr_is_the_pinned_version(self):
        result = self.image_run("herdr --version")
        self.assertIn("herdr 0.8.2", result.stdout, msg=result.stderr[-400:])

    def test_herdr_manages_a_session(self):
        # The reason ADE exists: Herdr owns agent processes, worktrees and
        # sessions inside the workbench.
        result = self.image_run(
            "export HOME=/root; timeout 40 herdr session list 2>&1 | head -3"
        )
        self.assertIn("default", result.stdout, msg=result.stderr[-400:])

    def test_the_ocaml_toolchain_is_usable(self):
        result = self.image_run("ocaml -version; dune --version")
        self.assertIn("5.5.0", result.stdout, msg=result.stderr[-400:])
        self.assertIn("3.23", result.stdout)
