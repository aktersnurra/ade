"""Host-state isolation for SmolVM runtime qualification.

Qualification must never read or write the user's real SmolVM, Microsandbox, or
Homebrew state. `QualificationHome` gives every runtime command a temporary HOME
and XDG base directories, and snapshots the user's default directories so a test
can prove they were untouched.
"""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

# Directories that must never change during qualification.
PROTECTED_PATHS = [
    Path.home() / ".smolvm",
    Path.home() / ".microsandbox",
    Path.home() / ".local" / "share" / "smolvm",
    Path.home() / ".config" / "smolvm",
    Path("/opt/homebrew/bin/msb"),
]


def _snapshot(path: Path):
    """Record existence and mtime/size without following into the tree."""
    try:
        st = path.lstat()
    except FileNotFoundError:
        return None
    return (st.st_mode, st.st_size, st.st_mtime_ns)


class QualificationHome:
    """A disposable HOME plus XDG base directories for runtime commands."""

    def __init__(self, smolvm_bin=None):
        self.smolvm_bin = smolvm_bin or os.environ.get("ADE_SMOLVM_BIN", "smolvm")
        self._tmp = None
        self.root = None
        self.baseline = {}

    def __enter__(self):
        self._tmp = tempfile.mkdtemp(prefix="ade-qual-home-")
        self.root = Path(self._tmp)
        for name in ("cache", "data", "config", "state"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        self.baseline = {p: _snapshot(p) for p in PROTECTED_PATHS}
        return self

    def __exit__(self, *exc):
        shutil.rmtree(self._tmp, ignore_errors=True)
        return False

    @property
    def env(self):
        """Environment that confines runtime state to this temporary home."""
        env = dict(os.environ)
        env["HOME"] = str(self.root)
        env["XDG_CACHE_HOME"] = str(self.root / "cache")
        env["XDG_DATA_HOME"] = str(self.root / "data")
        env["XDG_CONFIG_HOME"] = str(self.root / "config")
        env["XDG_STATE_HOME"] = str(self.root / "state")
        return env

    def run(self, *argv, check=False, timeout=300):
        """Run the pinned smolvm binary inside the isolated home."""
        return subprocess.run(
            [self.smolvm_bin, *argv],
            env=self.env,
            capture_output=True,
            text=True,
            check=check,
            timeout=timeout,
        )

    def assert_host_state_unchanged(self, test_case):
        """Fail the given test if any protected host path changed."""
        for path, before in self.baseline.items():
            after = _snapshot(path)
            test_case.assertEqual(
                before, after, f"qualification modified protected host path: {path}"
            )
