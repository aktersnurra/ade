"""Shared harness for runtime qualification against a live SmolVM.

Two constraints learned the hard way:

  - HOME must be short. The agent's Unix socket lives under it, and macOS caps
    sun_path at 104 bytes. A $TMPDIR path pushes it to 118 and the VM fails to
    boot with a misleading vCPU panic.
  - mkfs.ext4 must be on PATH; smolvm shells out to it to format disks.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

RUNTIME = Path(
    os.environ.get(
        "ADE_SMOLVM_BIN",
        Path.home() / ".local/share/ade/runtime/smolvm-1.13.1/bin/smolvm",
    )
)

# Kept short deliberately; see the module docstring.
SHORT_ROOT = Path("/tmp/ade-qual")

TEST_IMAGE = "docker.io/library/alpine:latest"


def runtime_available():
    return RUNTIME.exists()


def _mkfs_on_path():
    if shutil.which("mkfs.ext4"):
        return None
    for candidate in Path("/nix/store").glob("*-e2fsprogs-*-bin/bin"):
        if (candidate / "mkfs.ext4").exists():
            return str(candidate)
    return None


class RuntimeTestCase(unittest.TestCase):
    """A test case with its own isolated, short-pathed SmolVM state."""

    @classmethod
    def setUpClass(cls):
        if not runtime_available():
            raise unittest.SkipTest(f"no runtime at {RUNTIME}")
        SHORT_ROOT.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="h.", dir=SHORT_ROOT))
        self.addCleanup(self._cleanup)
        self.machines = []

    def _cleanup(self):
        for name in self.machines:
            self.smolvm("machine", "delete", "--name", name, stdin="y\n", timeout=120)
        shutil.rmtree(self.home, ignore_errors=True)

    @property
    def env(self):
        env = dict(os.environ)
        env["HOME"] = str(self.home)
        env["XDG_DATA_HOME"] = str(self.home / "data")
        env["XDG_CACHE_HOME"] = str(self.home / "cache")
        env["XDG_CONFIG_HOME"] = str(self.home / "config")
        extra = _mkfs_on_path()
        if extra:
            env["PATH"] = extra + os.pathsep + env.get("PATH", "")
        return env

    def smolvm(self, *args, stdin=None, timeout=500):
        return subprocess.run(
            [str(RUNTIME), *args],
            env=self.env,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def machine(self, name, *extra):
        """Create a named machine and register it for cleanup."""
        self.machines.append(name)
        result = self.smolvm(
            "machine", "create", "--name", name,
            "--image", TEST_IMAGE, "--cpus", "2", "--mem", "1024", *extra,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr[-500:])
        return result

    def guest(self, name, script, timeout=500):
        """Run a shell snippet inside the machine and return its stdout."""
        result = self.smolvm(
            "machine", "exec", "--name", name, "--", "sh", "-c", script,
            timeout=timeout,
        )
        return result
