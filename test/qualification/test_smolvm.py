"""Isolated qualification tests for the pinned SmolVM runtime.

Every test runs against a temporary ADE_SMOLVM_INSTALL_ROOT. No test may read or
write the user's real SmolVM state, Homebrew, or Microsandbox directories.
"""

import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALLER = REPO_ROOT / "scripts" / "install-smolvm.sh"

EXPECTED_VERSION = "smolvm 1.13.1"
EXPECTED_DIRNAME = "smolvm-1.13.1"


def _write_fake_result(root: Path, *, version: str, entitled: bool) -> Path:
    """Build a fake `nix build` result tree containing a stub smolvm binary."""
    result = root / "nix-result"
    (result / "bin").mkdir(parents=True, exist_ok=True)
    binary = result / "bin" / "smolvm"
    binary.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              echo "{version}"
              exit 0
            fi
            exit 0
            """
        )
    )
    binary.chmod(binary.stat().st_mode | stat.S_IEXEC)
    marker = result / "entitlements.plist"
    if entitled:
        marker.write_text("com.apple.security.hypervisor\n")
    else:
        marker.write_text("none\n")
    return result


class InstallSmolvmTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ade-install-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.install_root = self.tmp / "runtime"
        self.install_root.mkdir()

    def run_installer(self, *, fake_version=EXPECTED_VERSION, entitled=True):
        result_dir = _write_fake_result(self.tmp, version=fake_version, entitled=entitled)
        env = dict(os.environ)
        env["ADE_SMOLVM_INSTALL_ROOT"] = str(self.install_root)
        env["ADE_SMOLVM_NIX_RESULT"] = str(result_dir)
        return subprocess.run(
            ["bash", str(INSTALLER)],
            env=env,
            capture_output=True,
            text=True,
        )

    def test_rejects_wrong_version(self):
        result = self.run_installer(fake_version="smolvm 1.13.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected smolvm 1.13.1", result.stderr)

    def test_rejects_missing_entitlement(self):
        result = self.run_installer(entitled=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hypervisor entitlement", result.stderr)

    def test_installs_exact_version(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        installed = self.install_root / EXPECTED_DIRNAME / "bin" / "smolvm"
        self.assertTrue(installed.exists(), "installed binary missing")

    def test_does_not_touch_user_runtime_directories(self):
        homebrew = Path("/opt/homebrew/bin/msb")
        microsandbox = Path.home() / ".microsandbox"
        before = (homebrew.exists(), microsandbox.exists())
        self.run_installer()
        after = (homebrew.exists(), microsandbox.exists())
        self.assertEqual(before, after, "installer altered existing host runtimes")


if __name__ == "__main__":
    unittest.main()


class HostIsolationTest(unittest.TestCase):
    """Prove qualification never mutates the user's real runtime state.

    Skipped unless ADE_SMOLVM_BIN points at the installed qualified runtime, so
    the suite stays runnable before the runtime build is available.
    """

    def setUp(self):
        self.smolvm_bin = os.environ.get("ADE_SMOLVM_BIN")
        if not self.smolvm_bin or not Path(self.smolvm_bin).exists():
            self.skipTest("ADE_SMOLVM_BIN is not set to an installed runtime")

    def test_disposable_machine_leaves_default_directories_untouched(self):
        from .qualification_home import QualificationHome

        with QualificationHome(self.smolvm_bin) as home:
            machine = "ade-qual-isolation"
            home.run("machine", "delete", machine)
            home.run("machine", "list")
            home.assert_host_state_unchanged(self)

    def test_runtime_reports_pinned_version(self):
        from .qualification_home import QualificationHome

        with QualificationHome(self.smolvm_bin) as home:
            result = home.run("--version")
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertIn("1.13.1", result.stdout)
            home.assert_host_state_unchanged(self)
