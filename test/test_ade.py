#!/usr/bin/env python3
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
ADE = REPO / "bin" / "ade"
INSTALLER = REPO / "scripts" / "install-msb.sh"
EXPECTED_WORKSTATION_DIGEST = "sha256:5c0bffada804326ae73d3bf3778a77358aa236974e27d9f80a7ec88e826a1997"

FAKE_MSB = """#!/usr/bin/python3
import json, os, pathlib, sys
args = sys.argv[1:]
log = os.environ.get("FAKE_MSB_LOG")
if log:
    with open(log, "a") as stream:
        stream.write(json.dumps(args) + "\\n")
if args == ["--version"]:
    print("msb 0.6.10")
elif args[:2] == ["list", "--quiet"]:
    if os.environ.get("FAKE_SANDBOX_EXISTS"):
        print(os.environ.get("FAKE_SANDBOX_NAME", "ade-integrity"))
elif args[:3] == ["image", "inspect", "--format"]:
    print(json.dumps({"digest": os.environ.get("FAKE_IMAGE_DIGEST", "sha256:wrong")}))
elif args and args[0] in {"create", "list", "stop", "remove", "start"}:
    pass
else:
    print("unexpected fake msb arguments: " + repr(args), file=sys.stderr)
    sys.exit(64)
"""


class AdeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.root / "home"),
                "XDG_CONFIG_HOME": str(self.root / "config"),
                "XDG_DATA_HOME": str(self.root / "data"),
                "PATH": "/usr/bin:/bin",
                "FAKE_MSB_LOG": str(self.root / "msb.log"),
            }
        )

    def tearDown(self):
        self.temp.cleanup()

    def fake_msb(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(FAKE_MSB)
        path.chmod(0o755)
        return path

    def run_ade(self, *args, **env):
        process_env = self.env.copy()
        process_env.update(env)
        return subprocess.run(
            [ADE, *args],
            cwd=REPO,
            env=process_env,
            text=True,
            capture_output=True,
        )

    def logged_commands(self):
        path = Path(self.env["FAKE_MSB_LOG"])
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def write_profile(self, expected_digest):
        directory = self.root / "profiles"
        directory.mkdir()
        profile_home = self.root / "profile-home"
        (directory / "integrity.sh").write_text(
            f'''PROFILE_HOME="{profile_home}"
SANDBOX_NAME="ade-integrity"
IMAGE="ade-nix-workstation:0.1.0"
EXPECTED_IMAGE_DIGEST="{expected_digest}"
PERSIST_DIRS=("$PROFILE_HOME/workspace")
MOUNTS=("$PROFILE_HOME/workspace:/workspace")
NETWORK_ARGS=(--no-net)
'''
        )
        return directory

    def test_uses_managed_microsandbox_when_msb_bin_is_unset(self):
        managed = self.root / "data/ade/runtime/msb-0.6.10/bin/msb"
        self.fake_msb(managed)

        result = self.run_ade("list")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["list"], self.logged_commands())

    def test_rejects_mismatched_local_workstation_digest_before_create(self):
        fake = self.fake_msb(self.root / "fake-msb")
        profiles = self.write_profile(EXPECTED_WORKSTATION_DIGEST)

        result = self.run_ade(
            "create",
            "integrity",
            MSB_BIN=str(fake),
            ADE_PROFILE_DIR=str(profiles),
            FAKE_IMAGE_DIGEST="sha256:unexpected",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image digest mismatch", result.stderr)
        self.assertFalse(any(command and command[0] == "create" for command in self.logged_commands()))

    def test_accepts_qualified_local_workstation_digest(self):
        fake = self.fake_msb(self.root / "fake-msb")
        profiles = self.write_profile(EXPECTED_WORKSTATION_DIGEST)

        result = self.run_ade(
            "create",
            "integrity",
            MSB_BIN=str(fake),
            ADE_PROFILE_DIR=str(profiles),
            FAKE_IMAGE_DIGEST=EXPECTED_WORKSTATION_DIGEST,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(command and command[0] == "create" for command in self.logged_commands()))

    def test_installer_can_install_verified_local_archive(self):
        payload = self.root / "payload"
        fake = self.fake_msb(payload / "msb")
        archive = self.root / "microsandbox.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.add(fake, arcname="msb")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        install_root = self.root / "installed-runtime"

        result = subprocess.run(
            [INSTALLER],
            cwd=REPO,
            env={
                **self.env,
                "ADE_MSB_ARCHIVE": str(archive),
                "ADE_MSB_ARCHIVE_SHA256": digest,
                "ADE_MSB_INSTALL_ROOT": str(install_root),
            },
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        installed = install_root / "bin/msb"
        self.assertTrue(installed.is_file())
        self.assertEqual(subprocess.check_output([installed, "--version"], text=True).strip(), "msb 0.6.10")

    def test_secret_reference_is_passed_without_secret_value_in_argv(self):
        fake = self.fake_msb(self.root / "fake-msb")
        profiles = self.write_profile(EXPECTED_WORKSTATION_DIGEST)
        with (profiles / "integrity.sh").open("a") as profile:
            profile.write('''\nconfigure_credentials() {
  add_secret_if_set CLOUD_TOKEN "api.cloud.example"
}
''')

        result = self.run_ade(
            "create",
            "integrity",
            MSB_BIN=str(fake),
            ADE_PROFILE_DIR=str(profiles),
            FAKE_IMAGE_DIGEST=EXPECTED_WORKSTATION_DIGEST,
            CLOUD_TOKEN="secret-value-must-not-enter-argv",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(command for command in self.logged_commands() if command and command[0] == "create")
        self.assertIn("CLOUD_TOKEN@api.cloud.example", create)
        self.assertNotIn("secret-value-must-not-enter-argv", json.dumps(create))

    def test_reimage_preflights_digest_before_removing_existing_sandbox(self):
        fake = self.fake_msb(self.root / "fake-msb")
        profiles = self.write_profile(EXPECTED_WORKSTATION_DIGEST)

        result = self.run_ade(
            "reimage",
            "integrity",
            MSB_BIN=str(fake),
            ADE_PROFILE_DIR=str(profiles),
            FAKE_IMAGE_DIGEST="sha256:unexpected",
            FAKE_SANDBOX_EXISTS="1",
            FAKE_SANDBOX_NAME="ade-integrity",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image digest mismatch", result.stderr)
        commands = self.logged_commands()
        self.assertFalse(any(command and command[0] == "stop" for command in commands))
        self.assertFalse(any(command and command[0] == "remove" for command in commands))

    def test_reimage_existing_running_profile_returns_success(self):
        fake = self.fake_msb(self.root / "fake-msb")
        profiles = self.write_profile(EXPECTED_WORKSTATION_DIGEST)

        result = self.run_ade(
            "reimage",
            "integrity",
            MSB_BIN=str(fake),
            ADE_PROFILE_DIR=str(profiles),
            FAKE_IMAGE_DIGEST=EXPECTED_WORKSTATION_DIGEST,
            FAKE_SANDBOX_EXISTS="1",
            FAKE_SANDBOX_NAME="ade-integrity",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.logged_commands()
        self.assertTrue(any(command and command[0] == "remove" for command in commands))
        self.assertTrue(any(command and command[0] == "create" for command in commands))

    def test_builder_image_is_pinned_by_digest(self):
        script = (REPO / "scripts/build-linux-image.sh").read_text()
        self.assertNotIn("nixos/nix:latest", script)
        self.assertIn("nixos/nix@sha256:a326ac1ed46069ead5cdcba3a3a1e7255ebf72300c8319bf2c12cacfe9ab2787", script)

    def test_linux_build_writes_canonical_loadable_artifacts(self):
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        uname = fake_bin / "uname"
        uname.write_text("#!/bin/sh\necho Linux\n")
        uname.chmod(0o755)
        nix = fake_bin / "nix"
        nix.write_text(
            "#!/usr/bin/python3\n"
            "import gzip, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "output = pathlib.Path(args[args.index('--out-link') + 1])\n"
            "output.parent.mkdir(parents=True, exist_ok=True)\n"
            "output.write_bytes(gzip.compress(b'oci-archive'))\n"
        )
        nix.chmod(0o755)
        artifacts = self.root / "artifacts"

        result = self.run_ade(
            "build-image",
            PATH=f"{fake_bin}:/usr/bin:/bin",
            ADE_ARTIFACT_DIR=str(artifacts),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(gzip.decompress((artifacts / "ade-nix-workstation-0.1.0.tar.gz").read_bytes()), b"oci-archive")
        self.assertEqual((artifacts / "ade-nix-workstation-0.1.0.tar").read_bytes(), b"oci-archive")

    def test_rejects_profile_name_that_escapes_the_profile_directories(self):
        fake = self.fake_msb(self.root / "fake-msb")
        profiles = self.write_profile(EXPECTED_WORKSTATION_DIGEST)
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "evil.sh").write_text(
            'PERSIST_DIRS=(); MOUNTS=(); NETWORK_ARGS=()\n'
            'EXPECTED_IMAGE_DIGEST=""\n'
            'echo TRAVERSAL-EXECUTED >&2\n'
        )

        result = self.run_ade(
            "profile",
            "../outside/evil",
            MSB_BIN=str(fake),
            ADE_PROFILE_DIR=str(profiles),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid profile name", result.stderr)
        self.assertNotIn("TRAVERSAL-EXECUTED", result.stderr)

    def test_failing_sandbox_listing_aborts_instead_of_creating(self):
        failing = self.root / "failing-msb"
        failing.write_text(
            "#!/usr/bin/python3\n"
            "import json, os, sys\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['FAKE_MSB_LOG'], 'a') as stream:\n"
            "    stream.write(json.dumps(args) + '\\n')\n"
            "if args == ['--version']:\n"
            "    print('msb 0.6.10')\n"
            "elif args[:2] == ['list', '--quiet']:\n"
            "    sys.exit(1)\n"
        )
        failing.chmod(0o755)
        profiles = self.write_profile("")

        result = self.run_ade(
            "create",
            "integrity",
            MSB_BIN=str(failing),
            ADE_PROFILE_DIR=str(profiles),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot list sandboxes", result.stderr)
        self.assertFalse(any(command and command[0] == "create" for command in self.logged_commands()))

    def test_credential_file_values_do_not_enter_the_msb_environment(self):
        reporter = self.root / "env-msb"
        reporter.write_text(
            "#!/usr/bin/python3\n"
            "import os, sys\n"
            "args = sys.argv[1:]\n"
            "if args == ['--version']:\n"
            "    print('msb 0.6.10')\n"
            "    sys.exit(0)\n"
            "if args[:2] == ['list', '--quiet']:\n"
            "    sys.exit(0)\n"
            "sys.stderr.write('LEAKY=%r\\n' % os.environ.get('LEAKY_TOKEN'))\n"
        )
        reporter.chmod(0o755)
        profiles = self.write_profile("")
        env_file = self.root / "creds.env"
        env_file.write_text("LEAKY_TOKEN=super-secret-value\n")
        with (profiles / "integrity.sh").open("a") as profile:
            profile.write(f'\nCREDENTIAL_ENV_FILE="{env_file}"\n')

        result = self.run_ade(
            "create",
            "integrity",
            MSB_BIN=str(reporter),
            ADE_PROFILE_DIR=str(profiles),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LEAKY=None", result.stderr)
        self.assertNotIn("super-secret-value", result.stderr)

    def test_work_profile_does_not_inject_ambient_agent_credentials(self):
        fake = self.fake_msb(self.root / "fake-msb")

        result = self.run_ade(
            "profile",
            "work",
            MSB_BIN=str(fake),
            GITHUB_TOKEN="generic",
            ADE_WORK_GITHUB_TOKEN="scoped",
            ANTHROPIC_API_KEY="personal-anthropic",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("/root/.ade-secrets", result.stdout)
        self.assertNotIn("secret=GITHUB_TOKEN", result.stdout)
        self.assertNotIn("secret=ANTHROPIC_API_KEY", result.stdout)
        self.assertFalse((Path(self.env["XDG_DATA_HOME"]) / "ade/workbenches/work/secrets").exists())

    def test_personal_profile_does_not_inject_ambient_agent_credentials(self):
        fake = self.fake_msb(self.root / "fake-msb")

        result = self.run_ade(
            "profile",
            "personal",
            MSB_BIN=str(fake),
            GITHUB_TOKEN="generic",
            ADE_PERSONAL_GITHUB_TOKEN="scoped",
            ANTHROPIC_API_KEY="ambient-anthropic",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("/root/.ade-secrets", result.stdout)
        self.assertNotIn("secret=GITHUB_TOKEN", result.stdout)
        self.assertNotIn("secret=ANTHROPIC_API_KEY", result.stdout)
        self.assertFalse((Path(self.env["XDG_DATA_HOME"]) / "ade/workbenches/personal/secrets").exists())

    def test_personal_profile_uses_public_network_by_default(self):
        fake = self.fake_msb(self.root / "fake-msb")

        result = self.run_ade("profile", "personal", MSB_BIN=str(fake))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("network_arg=--net", result.stdout)
        self.assertIn("network_arg=public", result.stdout)
        self.assertNotIn("network_arg=--no-net", result.stdout)

    def test_checked_in_work_profile_rejects_unqualified_default_image(self):
        fake = self.fake_msb(self.root / "fake-msb")

        result = self.run_ade(
            "create",
            "work",
            MSB_BIN=str(fake),
            FAKE_IMAGE_DIGEST="sha256:unexpected",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image digest mismatch", result.stderr)
        self.assertFalse(any(command and command[0] == "create" for command in self.logged_commands()))

    def test_offline_profile_is_ready_and_has_no_credentials(self):
        fake = self.fake_msb(self.root / "fake-msb")

        result = self.run_ade("profile", "work-offline", MSB_BIN=str(fake))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sandbox=ade-work-offline", result.stdout)
        self.assertIn("network_arg=--no-net", result.stdout)
        self.assertNotIn("secret=ANTHROPIC_API_KEY", result.stdout)
        self.assertNotIn("secret=OPENAI_API_KEY", result.stdout)
        self.assertNotIn("secret=GITHUB_TOKEN", result.stdout)


if __name__ == "__main__":
    unittest.main()
