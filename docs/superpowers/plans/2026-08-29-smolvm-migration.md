# SmolVM Workbench Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the runnable Microsandbox workbench kit with one small OCaml CLI that manages the user's local SmolVM workbenches, persistent `/workspace`, Herdr, and tightly scoped credentials.

**Architecture:** ADE treats the pinned SmolVM CLI as the machine authority. A typed OCaml core validates host declarations, converges lifecycle operations, and journals only active workspace maintenance transactions. The workstation image supplies narrowly scoped guest helpers; normal repositories live on SmolVM's machine-owned storage rather than host mounts.

**Tech Stack:** OCaml 5.4.1, Dune 3.21.1, Cmdliner 2.1.1, Otoml 1.0.5, Yojson 3.0.0, Digestif 1.3.0, Alcotest 1.9.1, Hegel 0.9.2, Nix, Python `unittest` for host/runtime qualification, SmolVM `v1.13.1`.

## Global Constraints

- Implement in `/Users/aktersnurra/projects/vibe/gatekeep.workspaces/transport-qualification` on a new jj child of `wrzwzvow`; retain that change as the historical Microsandbox baseline.
- Use jj for every version-control operation. Do not use Git mutation commands.
- Target one user on one Apple-silicon Mac. Do not introduce a daemon, control plane, plugin framework, dual-runtime abstraction, or lifecycle database.
- Pin SmolVM commit `62f5f04bcb4fc097cca55cffa5772a32093f4636` with source SRI hash `sha256-jLcJpAoF+as+y15oaL8u9Z+YFIBjyFgMC2K3sNQh4VM=`.
- Pin Herdr `0.8.2` Linux aarch64 with SHA-256 `f55610658e1c2e0d2aaef730b4b2ab885f7f8ba00285ab372bfb14f2e3d5b40d`.
- Pin Hegel `0.9.2` at commit `56eec3788594afd39e8ffff05635d84a88643c1e` for tests.
- Keep SmolVM authoritative for machine state. ADE persists only declarations, locks, backups, secret-free credential metadata, and active transaction journals.
- No host repository mount in normal operation. The only host mount added by ADE is a fresh transaction staging directory at `/mnt/ade-export` or `/mnt/ade-import`.
- Never expose `reset` or `nuke`.
- `reimage` always leaves the workbench stopped.
- ADE-installed secrets exist only in guest tmpfs. Tests and logs must never contain credential values.
- LLM login occurs interactively inside the workbench, survives stop/start, and is wiped by reimage.
- Use result-returning ADTs for expected failures. Do not use exceptions as control flow or polymorphic comparison on structured values.
- Write every `.mli` before its `.ml`; run its failing test before implementation.
- Use Hegel only for real properties: parser robustness, journal round trips, transition-model agreement, and archive-path safety. Keep exact CLI/error assertions as Alcotest or Python unit tests.
- Do not modify `/opt/homebrew/bin/msb`, `$HOME/.microsandbox`, the user's ordinary SmolVM state, or existing host sandboxes during qualification.

## File map

### Host controller

- `dune-project` — Dune language/package declaration.
- `ade.opam` — exact OCaml dependencies and Hegel pin.
- `flake.nix` / `flake.lock` — reproducible host CLI, test shell, and checks.
- `bin/dune` / `bin/main.ml` — Cmdliner command tree only.
- `lib/ade_error.{mli,ml}` — structured user-facing failures.
- `lib/workbench_name.{mli,ml}` — validated SmolVM-safe workbench names.
- `lib/declaration.{mli,ml}` — parse-don't-validate TOML declaration.
- `lib/process_runner.{mli,ml}` — safe argv/env/stdin execution and inherited TTY.
- `lib/smolvm.{mli,ml}` — the only module containing SmolVM command syntax.
- `lib/lifecycle.{mli,ml}` — idempotent create/start/attach/exec/stop/restart/status.
- `lib/state_paths.{mli,ml}` — host locks, journals, backups, and runtime paths.
- `lib/workbench_lock.{mli,ml}` — per-workbench advisory lock.
- `lib/workspace_bundle.{mli,ml}` — manifest, path validation, hashing, and restore policy.
- `lib/reimage.{mli,ml}` — typed transaction journal, recovery, backup, restore, reimage.
- `lib/destroy.{mli,ml}` — backup decision, confirmation, pack/unpack, destroy.
- `lib/credential.{mli,ml}` — generation state and tmpfs installation.
- `lib/github_credential.{mli,ml}` — GitHub App installation tokens.
- `lib/kubernetes_credential.{mli,ml}` — TokenRequest-backed credentials.
- `lib/ssh_agent.{mli,ml}` — one dedicated host agent per running workbench.
- `lib/credential_schedule.{mli,ml}` — bounded `rotate --due` and launchd plist.

### Declarations and image

- `workbenches/work.toml` — allowlisted work workbench.
- `workbenches/personal.toml` — explicit public-network personal workbench.
- `workbenches/work-offline.toml` — sealed workbench.
- `workbenches/work-cloud.toml.example` — positive cloud endpoint allowlist.
- `smolfiles/workstation.Smolfile` — pinned resources/image and no workspace hooks.
- `images/nix-workstation/flake.nix` — retain and adapt OCI build.
- `images/nix-workstation/packages.nix` — add pinned Herdr and runtime prerequisites.
- `images/nix-workstation/root/usr/local/libexec/ade/` — guest helpers.
- `images/nix-workstation/root/etc/herdr/herdr.toml` — trusted default Herdr config.

### Runtime and operations

- `nix/smolvm.nix` — pinned source build and macOS runtime layout.
- `nix/herdr.nix` — checksum-verified Linux aarch64 Herdr package.
- `scripts/install-smolvm.sh` — install the qualified Nix result under ADE's managed runtime root.
- `scripts/build-linux-image.sh` — replace the Microsandbox builder path with the qualified SmolVM builder path.
- `scripts/qualify-smolvm.sh` — isolated qualification entrypoint.
- `docs/smolvm-workbenches.md` — operational guide.

### Tests

- `test/dune` — Alcotest/Hegel suites.
- `test/test_workbench_name.ml`
- `test/test_declaration.ml`
- `test/test_process_runner.ml`
- `test/test_smolvm.ml`
- `test/test_lifecycle.ml`
- `test/test_workspace_bundle.ml`
- `test/test_reimage.ml`
- `test/test_destroy.ml`
- `test/test_credential.ml`
- `test/qualification/test_smolvm.py`
- `test/qualification/fake_smolvm.py`

### Removed after replacement passes

- `bin/ade`
- `profiles/work.sh`
- `profiles/personal.sh`
- `profiles/work-offline.sh`
- `profiles/work-cloud.sh.example`
- `scripts/install-msb.sh`
- `docs/microsandbox-workbenches.md`
- `test/test_ade.py`

Historical Microsandbox validation documents remain under `docs/superpowers/`.

---

### Task 1: Establish the OCaml/Nix build and preserve the baseline

**Files:**

- Create: `dune-project`
- Create: `ade.opam`
- Create: `flake.nix`
- Create: `lib/dune`
- Create: `bin/dune`
- Create: `bin/main.ml`
- Create: `test/dune`
- Modify: `.gitignore`

**Interfaces:**

- Produces: `ade` executable built by Dune and `nix build .#ade`.
- Produces: `nix develop -c dune runtest` as the common test command.

- [ ] **Step 1: Start the migration change**

```bash
cd /Users/aktersnurra/projects/vibe/gatekeep.workspaces/transport-qualification
jj status
jj new -m "feat: migrate ADE workbenches to SmolVM"
```

Expected: the new empty working-copy change has parent `wrzwzvow`.

- [ ] **Step 2: Write the failing CLI smoke test**

Create `test/test_cli.ml`:

```ocaml
let cli_reports_version () =
  let command = Bos.Cmd.(v "dune" % "exec" % "ade" % "--" % "--version") in
  match Bos.OS.Cmd.run_out command |> Bos.OS.Cmd.out_string with
  | Ok (output, _) -> Alcotest.(check string) "version" "ade 0.1.0\n" output
  | Error (`Msg message) -> Alcotest.fail message

let () =
  Alcotest.run "ade" [ "cli", [ Alcotest.test_case "version" `Quick cli_reports_version ] ]
```

Register an executable in `test/dune` and run:

```bash
dune runtest
```

Expected: FAIL because no Dune project or `ade` executable exists.

- [ ] **Step 3: Add the minimal project and dependency declarations**

`dune-project` must declare Dune `3.21`, package `ade`, version `0.1.0`, and OCaml `>= 5.4`. `ade.opam` must include `cmdliner`, `otoml`, `yojson`, `digestif`, `bos`, `rresult`, `alcotest` with-test, and the exact Hegel `pin-depends` entry:

```opam
pin-depends: [
  [ "hegel.0.9.2"
    "git+https://github.com/hegeldev/hegel-ocaml.git#56eec3788594afd39e8ffff05635d84a88643c1e" ]
]
```

`bin/main.ml` initially contains only:

```ocaml
let version = "0.1.0"

let command =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "ade" ~version ~doc:"Manage local agent workbench VMs")
    Cmdliner.Term.(const (`Help (`Pager, None)))

let () = exit (Cmdliner.Cmd.eval command)
```

- [ ] **Step 4: Add the Nix development/build shell**

Pin nixpkgs in `flake.lock`. `flake.nix` must expose `packages.aarch64-darwin.ade`, `devShells.aarch64-darwin.default`, and `checks.aarch64-darwin.unit`. Include OCaml 5.4.1, Dune, Cmdliner, Otoml, Yojson, Digestif, Bos, Rresult, Alcotest, and the Hegel test dependency. Add `.hegel/`, `_build/`, and `result` to `.gitignore`.

- [ ] **Step 5: Verify the scaffold**

```bash
nix develop -c dune runtest
nix build .#ade
./result/bin/ade --version
```

Expected: tests pass and the final command prints `ade 0.1.0`.

- [ ] **Step 6: Commit**

```bash
jj describe -m "build: add OCaml ADE scaffold"
jj new
```

---

### Task 2: Build, install, and isolate the pinned SmolVM runtime

**Files:**

- Create: `nix/smolvm.nix`
- Create: `scripts/install-smolvm.sh`
- Create: `test/qualification/test_smolvm.py`

**Interfaces:**

- Produces: managed runtime layout `~/.local/share/ade/runtime/smolvm-1.13.1/`.
- Produces: `ADE_SMOLVM_BIN` override for all tests and operations.
- Produces: isolated qualification environment helper `QualificationHome`.

- [ ] **Step 1: Write installer failure tests**

In `test/qualification/test_smolvm.py`, add tests proving that installation refuses a source result with the wrong version, a missing hypervisor entitlement, or a binary digest mismatch. Every test uses a temporary `ADE_SMOLVM_INSTALL_ROOT`; none writes the real managed runtime.

```python
class InstallSmolvmTest(unittest.TestCase):
    def test_rejects_wrong_version(self):
        result = self.run_installer(fake_version="smolvm 1.13.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected smolvm 1.13.1", result.stderr)
```

Run:

```bash
python3 -m unittest test.qualification.test_smolvm.InstallSmolvmTest -v
```

Expected: FAIL because `scripts/install-smolvm.sh` does not exist.

- [ ] **Step 2: Package the exact SmolVM source**

`nix/smolvm.nix` must fetch owner `smol-machines`, repo `smolvm`, rev `62f5f04bcb4fc097cca55cffa5772a32093f4636`, and hash `sha256-jLcJpAoF+as+y15oaL8u9Z+YFIBjyFgMC2K3sNQh4VM=`. Use the checked-in `Cargo.lock` through `rustPlatform.importCargoLock`, build the host CLI and Linux aarch64 agent rootfs, install required libkrun libraries, and ad-hoc codesign the final macOS executable with `com.apple.security.hypervisor=true`.

The derivation's install check must run:

```bash
$out/bin/smolvm --version
codesign -d --entitlements :- "$out/bin/smolvm" 2>&1 | grep -q com.apple.security.hypervisor
```

- [ ] **Step 3: Implement the narrow installer**

`scripts/install-smolvm.sh` builds `.#smolvm`, copies the immutable result into a temporary sibling directory, verifies exact version/digest/entitlement, and atomically renames it to `smolvm-1.13.1`. It must honor only:

```text
ADE_SMOLVM_INSTALL_ROOT
ADE_SMOLVM_NIX_RESULT
```

It must never alter Homebrew, the upstream SmolVM default directories, or Microsandbox.

- [ ] **Step 4: Prove host-state isolation before lifecycle qualification**

`QualificationHome` snapshots the existence and metadata of the user's default SmolVM directories, then launches every runtime command with temporary `HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`, and `XDG_CONFIG_HOME`. Add a test that creates a disposable machine and proves the default directories were unchanged.

- [ ] **Step 5: Run the focused checks**

```bash
nix build .#smolvm
python3 -m unittest test.qualification.test_smolvm.InstallSmolvmTest -v
codesign -d --entitlements :- ./result/bin/smolvm 2>&1
```

Expected: exact version and entitlement pass; all installer/isolation tests pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "build: pin and install SmolVM 1.13.1"
jj new
```

---

### Task 3: Parse workbench declarations into validated types

**Files:**

- Create: `lib/ade_error.{mli,ml}`
- Create: `lib/workbench_name.{mli,ml}`
- Create: `lib/declaration.{mli,ml}`
- Create: `test/test_workbench_name.ml`
- Create: `test/test_declaration.ml`
- Create: `workbenches/work.toml`
- Create: `workbenches/personal.toml`
- Create: `workbenches/work-offline.toml`
- Create: `workbenches/work-cloud.toml.example`

**Interfaces:**

```ocaml
module Workbench_name : sig
  type t
  type error = Empty | Invalid_character of char | Too_long of int
  val of_string : string -> (t, error) result
  val to_string : t -> string
end

module Declaration : sig
  type network = Sealed | Public | Allowlisted of { hosts : string list; cidrs : string list }
  type ssh = Disabled | Dedicated_agent of { key_ref : string }
  type t
  val load : string -> (t, Ade_error.t) result
  val name : t -> Workbench_name.t
  val network : t -> network
  val digest_hex : t -> string
end
```

- [ ] **Step 1: Write failing parser and name tests**

Cover empty names, whitespace, path separators, overlong names, valid `work-cloud`, unknown TOML keys, missing image digest, contradictory sealed/allowlist configuration, and malformed CIDRs. Add a Hegel property to `test_workbench_name.ml`: arbitrary text never raises and every successful `of_string` round-trips through `to_string`.

- [ ] **Step 2: Run the tests and confirm failure**

```bash
nix develop -c dune runtest test/test_workbench_name.exe test/test_declaration.exe
```

Expected: FAIL because modules are absent.

- [ ] **Step 3: Write `.mli` contracts and minimal implementations**

Parse TOML once at the boundary. Reject unknown keys rather than silently ignoring drift. Normalize only ordering-insensitive declaration fields before calculating the SHA-256 digest; do not normalize workbench names or executable paths.

- [ ] **Step 4: Add the four concrete declarations**

`work.toml` uses a positive hostname/CIDR allowlist and dedicated SSH agent. `personal.toml` explicitly opts into unrestricted public networking. `work-offline.toml` is sealed and declares no credentials. The cloud file is an example with no usable account identifiers or secrets.

- [ ] **Step 5: Verify properties and examples**

```bash
nix develop -c dune runtest
nix develop -c dune exec ade -- status work
```

Expected: unit/properties pass; CLI may still report runtime command unavailable, but declaration loading succeeds.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: add typed workbench declarations"
jj new
```

---

### Task 4: Add safe process execution and the SmolVM adapter

**Files:**

- Create: `lib/process_runner.{mli,ml}`
- Create: `lib/smolvm.{mli,ml}`
- Create: `test/test_process_runner.ml`
- Create: `test/test_smolvm.ml`
- Create: `test/qualification/fake_smolvm.py`

**Interfaces:**

```ocaml
module Process_runner : sig
  type stdio = Capture | Inherit
  type request = {
    executable : string;
    argv : string list;
    env : (string * string) list;
    stdin : string option;
    stdio : stdio;
  }
  type output = { status : int; stdout : string; stderr : string }
  val run : request -> (output, Ade_error.t) result
  val replace_process : request -> (unit, Ade_error.t) result
end

module Smolvm : sig
  type state = Absent | Created | Stopped | Running
  type t
  val make : executable:string -> runner:(Process_runner.request -> (Process_runner.output, Ade_error.t) result) -> t
  val state : t -> Workbench_name.t -> (state, Ade_error.t) result
  val create : t -> Declaration.t -> (unit, Ade_error.t) result
  val start : ?ssh_auth_sock:string -> t -> Workbench_name.t -> (unit, Ade_error.t) result
  val stop : t -> Workbench_name.t -> (unit, Ade_error.t) result
  val exec : t -> Workbench_name.t -> string list -> (Process_runner.output, Ade_error.t) result
  val attach : t -> Workbench_name.t -> command:string list -> (unit, Ade_error.t) result
end
```

- [ ] **Step 1: Write failing argv, environment, TTY, and state tests**

Tests must prove arguments containing spaces remain one argument, secret environment values never appear in rendered diagnostics, inherited stdio is used only for attachment, JSON state maps to the four ADT variants, and malformed runtime JSON returns `Runtime_output_invalid`.

- [ ] **Step 2: Run the focused tests**

```bash
nix develop -c dune runtest test/test_process_runner.exe test/test_smolvm.exe
```

Expected: FAIL because interfaces are absent.

- [ ] **Step 3: Implement the process boundary**

Use `Unix.create_process_env` for captured commands and `Unix.execve` for final attachment. Never construct a shell command string. Redact values for keys represented by the `Secret` variant in structured diagnostics.

- [ ] **Step 4: Implement only audited SmolVM syntax**

All SmolVM argument construction lives in `lib/smolvm.ml`. Parse `machine ls --json`/status output strictly. Keep fake runtime fixtures faithful to `v1.13.1` output captured during Task 2 qualification.

- [ ] **Step 5: Run tests and static checks**

```bash
nix develop -c dune runtest
nix develop -c dune build @all
```

Expected: PASS with warnings treated as errors for project source.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: add SmolVM process adapter"
jj new
```

---

### Task 5: Implement convergent lifecycle commands

**Files:**

- Create: `lib/state_paths.{mli,ml}`
- Create: `lib/workbench_lock.{mli,ml}`
- Create: `lib/lifecycle.{mli,ml}`
- Create: `test/test_lifecycle.ml`
- Modify: `bin/main.ml`

**Interfaces:**

```ocaml
module Lifecycle : sig
  type dependencies = { runtime : Smolvm.t; declaration_dir : string; state_root : string }
  val create : dependencies -> Workbench_name.t -> (unit, Ade_error.t) result
  val start : dependencies -> Workbench_name.t -> (unit, Ade_error.t) result
  val stop : dependencies -> Workbench_name.t -> (unit, Ade_error.t) result
  val restart : dependencies -> Workbench_name.t -> (unit, Ade_error.t) result
  val status : dependencies -> Workbench_name.t option -> (string, Ade_error.t) result
  val exec : dependencies -> Workbench_name.t -> string list -> (int, Ade_error.t) result
  val attach : dependencies -> Workbench_name.t -> (unit, Ade_error.t) result
end
```

- [ ] **Step 1: Write the lifecycle model tests**

Use a fake `Smolvm.t` command log. Cover every convergence rule from the specification. Add a Hegel stateful property that generates create/start/stop/restart sequences, compares `Lifecycle` to a four-state reference model, and asserts no command is issued for an already-satisfied transition.

- [ ] **Step 2: Verify failure**

```bash
nix develop -c dune runtest test/test_lifecycle.exe
```

Expected: FAIL because `Lifecycle` is absent.

- [ ] **Step 3: Implement locks and convergence**

Use one advisory lock path per validated workbench name. Query SmolVM under the lock immediately before mutation. Do not hold the lock after `attach` replaces the ADE process.

`attach` performs `start`, credential freshness, Herdr health/start, then replaces itself with native SmolVM execution of the trusted Herdr attach command. `exec` starts a stopped workbench normally before running the requested command.

- [ ] **Step 4: Add Cmdliner subcommands**

Expose only `create`, `start`, `attach`, `exec`, `stop`, `restart`, and `status` in this task. `ADE_SMOLVM_BIN`, `ADE_WORKBENCH_DIR`, and `ADE_STATE_ROOT` are explicit test/operator overrides; normal defaults are deterministic.

- [ ] **Step 5: Run unit and fake-runtime E2E tests**

```bash
nix develop -c dune runtest
ADE_SMOLVM_BIN="$PWD/test/qualification/fake_smolvm.py" nix develop -c dune exec ade -- start work-offline
```

Expected: all tests pass and the fake command log contains one create and one start.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: add convergent workbench lifecycle"
jj new
```

---

### Task 6: Build the workstation image with trusted Herdr/bootstrap helpers

**Files:**

- Create: `nix/herdr.nix`
- Create: `smolfiles/workstation.Smolfile`
- Create: `images/nix-workstation/root/usr/local/libexec/ade/export-workspace`
- Create: `images/nix-workstation/root/usr/local/libexec/ade/restore-workspace`
- Create: `images/nix-workstation/root/usr/local/libexec/ade/install-secrets`
- Create: `images/nix-workstation/root/usr/local/libexec/ade/start-services`
- Create: `images/nix-workstation/root/usr/local/libexec/ade/health-check`
- Create: `images/nix-workstation/root/etc/herdr/herdr.toml`
- Modify: `images/nix-workstation/flake.nix`
- Modify: `images/nix-workstation/packages.nix`
- Modify: `scripts/build-linux-image.sh`
- Test: `test/qualification/test_smolvm.py`

**Interfaces:**

- Produces: OCI image with pinned digest recorded by the build.
- Produces guest commands under `/usr/local/libexec/ade/` with no implicit workspace hooks.
- Produces: `herdr 0.8.2` in guest PATH.

- [ ] **Step 1: Write image-content and inert-start tests**

Add qualification tests that fail unless the image reports the expected architecture, OCaml version, Herdr version, helper hashes, Docker availability, and absence of automatic Herdr agents after raw `machine start`.

- [ ] **Step 2: Verify the tests fail against the current image**

```bash
python3 -m unittest test.qualification.test_smolvm.WorkstationImageTest -v
```

Expected: FAIL because Herdr/helpers/Smolfile are absent.

- [ ] **Step 3: Package Herdr and guest helpers**

Fetch `https://github.com/herdrdev/herdr/releases/download/v0.8.2/herdr-linux-aarch64` with the pinned checksum. Guest helper scripts use fixed absolute tool paths, `set -eu`, restrictive umasks, and no workspace-derived executable paths.

The export helper copies `/workspace` into the transaction mount without following symlinks. The restore helper accepts only a read-only validated bundle and never runs restored content. `install-secrets` refuses destinations outside `/run/ade/secrets`.

- [ ] **Step 4: Adapt the image builder**

Use the isolated, qualified SmolVM runtime for the Linux Nix builder rather than downloading Microsandbox. Preserve canonical artifact names and emit the OCI digest manifest consumed by declarations.

- [ ] **Step 5: Run image qualification**

```bash
scripts/build-linux-image.sh
python3 -m unittest test.qualification.test_smolvm.WorkstationImageTest -v
```

Expected: all content, Docker, Herdr, architecture, and inert-start checks pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: build SmolVM workstation image with Herdr"
jj new
```

---

### Task 7: Validate workspace bundles safely

**Files:**

- Create: `lib/workspace_bundle.{mli,ml}`
- Create: `test/test_workspace_bundle.ml`

**Interfaces:**

```ocaml
module Workspace_bundle : sig
  type entry_kind = Directory | Regular | Symlink of string | Hardlink of string
  type manifest
  val validate_staging_tree : root:string -> (manifest, Ade_error.t) result
  val write_manifest : path:string -> manifest -> (unit, Ade_error.t) result
  val load_verified : root:string -> manifest_path:string -> (manifest, Ade_error.t) result
  val digest_hex : manifest -> string
end
```

- [ ] **Step 1: Write malicious-tree tests first**

Create fixtures for absolute/traversing names, escaping hardlinks, symlinks followed by later writes, device nodes where supported, FIFO, socket, setuid/setgid, unexpected UID/GID, changed file after manifest, and ordinary Git symlinks/hardlinks. Tests must operate on temporary directories and never require root.

Add Hegel properties: arbitrary relative path components either normalize inside the root or are rejected; writing/loading an unchanged manifest round-trips; changing any regular-file byte changes verification outcome.

- [ ] **Step 2: Run and confirm failure**

```bash
nix develop -c dune runtest test/test_workspace_bundle.exe
```

Expected: FAIL because `Workspace_bundle` is absent.

- [ ] **Step 3: Implement `lstat`-based traversal and hashing**

Never follow symlinks during traversal. Track `(st_dev, st_ino)` for hardlinks. Hash regular-file bytes and entry metadata in deterministic path order. Reject unsupported node types and privilege-bearing metadata. Treat the result as integrity evidence, not workspace trust.

- [ ] **Step 4: Re-run tests**

```bash
nix develop -c dune runtest test/test_workspace_bundle.exe
```

Expected: all unit and Hegel properties pass.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: validate workspace backup bundles"
jj new
```

---

### Task 8: Journal and recover reimage transactions

**Files:**

- Create: `lib/reimage.{mli,ml}`
- Create: `test/test_reimage.ml`

**Interfaces:**

```ocaml
module Reimage : sig
  type phase =
    | Quiescing | Exporting | Export_verified | Old_machine_deleted
    | New_machine_created | Restoring | Qualifying | Committed | Rollback_required
  type journal
  type dependencies = {
    runtime : Smolvm.t;
    state_root : string;
    staging_root : string;
    now : unit -> float;
  }
  val load_journal : path:string -> (journal option, Ade_error.t) result
  val reimage : dependencies -> Declaration.t -> (unit, Ade_error.t) result
  val recover : dependencies -> Declaration.t -> journal -> (unit, Ade_error.t) result
end
```

- [ ] **Step 1: Write journal round-trip and crash-boundary tests**

For every phase, simulate process death after the journal fsync but before the next operation. Assert that recovery never deletes the old machine before `Export_verified`, never starts normal services before commit, retains the staging tree until commit, and finishes with the machine stopped.

Use Hegel to generate valid phase/action sequences and compare recovery decisions to a pure reference model.

- [ ] **Step 2: Run and confirm failure**

```bash
nix develop -c dune runtest test/test_reimage.exe
```

Expected: FAIL because `Reimage` is absent.

- [ ] **Step 3: Implement atomic journals**

Write JSON to a same-directory temporary file, fsync it, rename it, and fsync the parent directory. The journal stores exactly the fields in the approved specification. Expected failures return a phase-specific `Ade_error.t`.

- [ ] **Step 4: Implement the transaction against the fake runtime**

Use the audited stopped-machine `update --volume` and `--remove-volume` operations. Maintenance starts use no secret references, no service startup, and an empty dedicated SSH agent. Validate the old guest's export on the host. Create the new machine from the pinned declaration, mount import read-only, restore with the fresh image helper, qualify without credentials, stop, remove the mount, and commit.

- [ ] **Step 5: Add CLI recovery guards**

Before `start`, `attach`, ordinary `exec`, or destroy, detect an unfinished journal. Resume only deterministic safe phases; otherwise report `maintenance_recovery_required` with the recovery command.

- [ ] **Step 6: Run all crash tests**

```bash
nix develop -c dune runtest test/test_reimage.exe
```

Expected: every phase and Hegel model property passes.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat: add crash-recoverable reimage transaction"
jj new
```

---

### Task 9: Expose backup, restore, reimage, pack, unpack, and destroy

**Files:**

- Create: `lib/destroy.{mli,ml}`
- Create: `test/test_destroy.ml`
- Modify: `lib/reimage.{mli,ml}`
- Modify: `bin/main.ml`

**Interfaces:**

```ocaml
type backup_decision = Backup_first | No_backup

val backup : Reimage.dependencies -> Declaration.t -> (string, Ade_error.t) result
val restore_workspace : Reimage.dependencies -> Declaration.t -> backup:string -> replace:bool -> (unit, Ade_error.t) result
val pack : runtime:Smolvm.t -> Declaration.t -> output:string -> (unit, Ade_error.t) result
val unpack : runtime:Smolvm.t -> pack:string -> as_name:Workbench_name.t -> (unit, Ade_error.t) result
val destroy : runtime:Smolvm.t -> Declaration.t -> backup_decision -> confirmation:string -> (unit, Ade_error.t) result
```

- [ ] **Step 1: Write destructive-command tests**

Cover interactive backup/no-backup/abort, exact typed confirmation, noninteractive missing decision, backup failure preventing deletion, absent-machine no-op with and without a journal, pack refusing running sources, unpack refusing existing names, workspace restore refusing nonempty targets without `--replace-workspace`, and source state restoration after backup.

- [ ] **Step 2: Verify failure**

```bash
nix develop -c dune runtest test/test_destroy.exe
```

Expected: FAIL because commands are absent.

- [ ] **Step 3: Implement the smallest explicit command contracts**

Do not infer safety from backup age. Never automatically push artifacts. Treat every backup and pack as potentially secret-bearing. `unpack` creates only an absent machine; replacing a machine requires separate backup/destroy/unpack commands.

- [ ] **Step 4: Wire Cmdliner commands**

Add `reimage`, `backup`, `restore`, `pack`, `unpack`, and `destroy`. Boolean flags are replaced by explicit variants where possible; noninteractive destroy requires exactly one of `--backup-first` or `--no-backup` and exact `--confirm-destroy-workspace=NAME`.

- [ ] **Step 5: Run tests**

```bash
nix develop -c dune runtest
```

Expected: all lifecycle, transaction, and destructive-command tests pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: add workspace backup and destructive lifecycle"
jj new
```

---

### Task 10: Install credential generations and dedicated SSH authority

**Files:**

- Create: `lib/credential.{mli,ml}`
- Create: `lib/ssh_agent.{mli,ml}`
- Create: `test/test_credential.ml`
- Modify: `lib/lifecycle.ml`

**Interfaces:**

```ocaml
module Credential : sig
  type provider = Github | Kubernetes | Datadog | Circleci | Gpg
  type availability = Available of { expires_at : float option } | Unavailable of string
  type generation
  val ensure_fresh : now:float -> runtime:Smolvm.t -> Declaration.t -> (generation, Ade_error.t) result
  val install : runtime:Smolvm.t -> Workbench_name.t -> generation -> (unit, Ade_error.t) result
  val revoke : runtime:Smolvm.t -> Workbench_name.t -> provider -> (unit, Ade_error.t) result
end

module Ssh_agent : sig
  type t
  val start : Workbench_name.t -> key_ref:string -> (t, Ade_error.t) result
  val start_empty : Workbench_name.t -> (t, Ade_error.t) result
  val socket : t -> string
  val stop : t -> unit
end
```

- [ ] **Step 1: Write generation and leakage tests**

Test mint failure preserves the current generation, activation is atomic, expired credentials are never installed, stopped workbenches are skipped by `rotate --due`, start installs before Herdr, emergency revoke removes guest tmpfs generation before reporting success, and secret sentinel values never occur in argv, diagnostics, journal, or audit output.

- [ ] **Step 2: Verify failure**

```bash
nix develop -c dune runtest test/test_credential.exe
```

Expected: FAIL because credential modules are absent.

- [ ] **Step 3: Implement generation installation**

Send plaintext through SmolVM's secret environment/file reference mechanism into the fixed guest installer. Store only provider, generation ID, scope digest, expiry, and outcome on the host. Keep current/previous generation overlap bounded and never revoke a working generation after failed mint/validation.

- [ ] **Step 4: Implement one dedicated SSH agent per running workbench**

Normal start creates an agent, loads only the declaration's key reference, and passes its socket through `SSH_AUTH_SOCK`. Maintenance uses a separate empty agent. Stop tears down ADE's agent process. Tests inspect `ssh-add -L` and prove no unrelated host identity is present.

- [ ] **Step 5: Run tests**

```bash
nix develop -c dune runtest test/test_credential.exe test/test_lifecycle.exe
```

Expected: credential ordering, redaction, and SSH authority tests pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: install scoped workbench credentials"
jj new
```

---

### Task 11: Add only the provider behaviors the user needs

**Files:**

- Create: `lib/github_credential.{mli,ml}`
- Create: `lib/kubernetes_credential.{mli,ml}`
- Create: `test/test_provider_credentials.ml`
- Modify: `lib/credential.{mli,ml}`
- Modify: `lib/declaration.{mli,ml}`

**Interfaces:**

```ocaml
val Github_credential.mint : now:float -> app_id:string -> installation_id:int64 -> private_key_ref:string -> permissions:(string * string) list -> repositories:string list -> (Credential.generation, Ade_error.t) result
val Kubernetes_credential.mint : context:string -> namespace:string -> service_account:string -> audience:string -> duration_seconds:int -> (Credential.generation, Ade_error.t) result
```

- [ ] **Step 1: Write provider contract tests**

Use local fake HTTP and fake `kubectl` processes. Assert GitHub JWT lifetime, installation/repository/permission request scope, token expiry parsing, Kubernetes context/namespace/service-account/audience/duration arguments, provider outage behavior, clock-skew safety margin, and complete redaction.

- [ ] **Step 2: Verify failure**

```bash
nix develop -c dune runtest test/test_provider_credentials.exe
```

Expected: FAIL because provider modules are absent.

- [ ] **Step 3: Implement GitHub App minting**

Read the private key from the declared protected host reference, sign the JWT without placing it in argv, request `POST /app/installations/INSTALLATION_ID/access_tokens`, validate repository/permission scope and expiry, then discard the JWT.

- [ ] **Step 4: Implement Kubernetes TokenRequest minting**

Use the declared `kubectl` context and `kubectl create token`/TokenRequest flow. Parse the returned token expiry where available and enforce the safety margin before installation.

- [ ] **Step 5: Encode honest non-rotating behavior**

Datadog rotation is enabled only for an explicitly declared management credential and verified create/delete API. CircleCI is manual replacement with expiry reporting. GPG is a dedicated identity or host signer and is never timer-rotated. LLM providers have no ADE credential declaration at all.

- [ ] **Step 6: Run tests and commit**

```bash
nix develop -c dune runtest test/test_provider_credentials.exe test/test_credential.exe
jj describe -m "feat: rotate supported provider credentials"
jj new
```

---

### Task 12: Add bounded launchd scheduling without an ADE daemon

**Files:**

- Create: `lib/credential_schedule.{mli,ml}`
- Create: `test/test_credential_schedule.ml`
- Modify: `bin/main.ml`

**Interfaces:**

```ocaml
val rotate_due : now:float -> declarations:Declaration.t list -> (unit, Ade_error.t) result
val install_launchd : ade_binary:string -> interval_seconds:int -> (string, Ade_error.t) result
val uninstall_launchd : unit -> (unit, Ade_error.t) result
```

- [ ] **Step 1: Write scheduling tests**

Assert generated plist uses an absolute ADE binary path, contains no credentials, invokes only `credentials rotate --due`, has restrictive file mode, and repeated install/uninstall converges. Verify one invocation rotates due credentials for running machines, skips stopped machines, and exits.

- [ ] **Step 2: Verify failure**

```bash
nix develop -c dune runtest test/test_credential_schedule.exe
```

Expected: FAIL because scheduling is absent.

- [ ] **Step 3: Implement one-shot scheduling**

Expose:

```text
ade credentials status [NAME]
ade credentials rotate [NAME|--due]
ade credentials revoke NAME PROVIDER
ade credentials schedule install
ade credentials schedule uninstall
```

Do not create a long-running process, socket, background server, retry queue, or database.

- [ ] **Step 4: Run tests and commit**

```bash
nix develop -c dune runtest test/test_credential_schedule.exe
jj describe -m "feat: schedule bounded credential rotation"
jj new
```

---

### Task 13: Run the complete isolated SmolVM qualification suite

**Files:**

- Create: `scripts/qualify-smolvm.sh`
- Expand: `test/qualification/test_smolvm.py`
- Create: `docs/superpowers/specs/2026-08-29-smolvm-1.13.1-qualification.md`

**Interfaces:**

- Produces: one evidence directory with command log, JSON results, artifact digests, and cleanup result.
- Produces: a blocking pass/fail report mapped to every qualification item in the design.

- [ ] **Step 1: Add failing qualification cases before each runtime claim**

Cover exact pin/signature/entitlement, lifecycle convergence, root/workspace/tmpfs persistence, image materialization, resources, mount update and `/workspace` precedence, maintenance behavior, sealed/allowlisted/public network, DNS/CIDR/localhost/container egress, secret references, SSH agent, TTY/streams/signals/concurrency/stop disconnect, Docker, Herdr multi-agent use, backups above 4 GiB, archive attacks, destroy choices, packs, and crash injection at every journal phase.

- [ ] **Step 2: Isolate every test**

`scripts/qualify-smolvm.sh` creates a random temporary HOME and XDG tree, disposable machine prefix, dedicated SSH agent, and local fake providers. It records pre/post checks proving the user's normal SmolVM and Microsandbox paths were unchanged. Cleanup is mandatory even after test failure.

- [ ] **Step 3: Run qualification**

```bash
scripts/qualify-smolvm.sh
```

Expected: one final `PASS` row per blocking requirement and `cleanup=PASS`. Any failure blocks migration and remains documented; do not weaken a test to obtain green output.

- [ ] **Step 4: Record exact evidence**

Write the runtime version, source commit, source hash, binary digest, codesign entitlement, OCI digest, Herdr digest, host details, commands, results, known limitations, and cleanup proof into the qualification document.

- [ ] **Step 5: Commit**

```bash
jj describe -m "test: qualify SmolVM workbench runtime"
jj new
```

---

### Task 14: Replace the Microsandbox surface and publish the SmolVM workbench guide

**Files:**

- Replace: `README.md`
- Create: `docs/smolvm-workbenches.md`
- Modify: `.gitignore`
- Delete: `bin/ade`
- Delete: `profiles/work.sh`
- Delete: `profiles/personal.sh`
- Delete: `profiles/work-offline.sh`
- Delete: `profiles/work-cloud.sh.example`
- Delete: `scripts/install-msb.sh`
- Delete: `docs/microsandbox-workbenches.md`
- Delete: `test/test_ade.py`

**Interfaces:**

- Produces: the OCaml `ade` as the only supported launcher.
- Produces: one SmolVM operational guide matching actual qualified behavior.

- [ ] **Step 1: Write documentation assertions**

Add a test that rejects active documentation links or operational examples referring to `MSB_BIN`, `msb create`, host repository mounts, `reset`, `nuke`, ADE-managed LLM credentials, or reimage ending running. Permit Microsandbox references only inside explicitly historical validation documents.

- [ ] **Step 2: Verify the assertions fail**

```bash
python3 -m unittest test.qualification.test_smolvm.DocumentationTest -v
```

Expected: FAIL against the current Microsandbox README/guide.

- [ ] **Step 3: Replace the operational documentation and old files**

Document installation, declarations, create/attach/stop, Herdr, interactive LLM login, credential rotation, backup, reimage recovery, destroy, packs, network limitations, and troubleshooting. Keep the historical validation documents but label them superseded evidence.

Delete the Bash launcher and executable Bash profiles only after all OCaml and qualification tests pass.

- [ ] **Step 4: Run the final verification gate**

```bash
nix flake check
nix develop -c dune runtest
python3 -m unittest discover -s test/qualification -v
shellcheck scripts/*.sh images/nix-workstation/root/usr/local/libexec/ade/*
scripts/qualify-smolvm.sh
jj diff --check
```

Expected: every command passes, the qualification report says `cleanup=PASS`, and no secret sentinel appears anywhere under the repository or evidence directory.

- [ ] **Step 5: Independent review**

Request review against `docs/superpowers/specs/2026-08-29-smolvm-workbench-design.md`. Resolve every blocker/high finding and rerun the complete verification gate.

- [ ] **Step 6: Commit the migration**

```bash
jj describe -m "feat: migrate ADE workbenches to SmolVM"
```

Do not squash away the historical `wrzwzvow` baseline until the user explicitly chooses final history shape.

## Final acceptance

The migration is complete only when:

- `ade create work`, `ade attach work`, `ade stop work`, and repeated invocations converge;
- repositories live inside machine-owned `/workspace`;
- Herdr runs multiple mutually trusted agents inside the VM;
- supported short-lived credentials rotate through ADE without a daemon;
- interactive LLM login survives stop/start and is wiped by reimage;
- backup preserves the source's running/stopped state;
- reimage survives every injected crash boundary and leaves the machine stopped;
- destroy requires an explicit backup decision and typed confirmation;
- the pinned source-built SmolVM runtime and Nix OCI image pass isolated qualification;
- the user's existing SmolVM, Microsandbox, and host configuration remain unchanged by tests.
