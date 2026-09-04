# SmolVM 1.13.1 qualification evidence

**Date:** 2026-08-30
**Status:** Partial. Host-side qualification passes; guest boot is blocked on the
agent rootfs.

## Runtime provenance

| Item | Value |
| --- | --- |
| Source | `github:smol-machines/smolvm` |
| Revision | `62f5f04bcb4fc097cca55cffa5772a32093f4636` |
| Source SRI | `sha256-jLcJpAoF+as+y15oaL8u9Z+YFIBjyFgMC2K3sNQh4VM=` |
| Version reported | `smolvm 1.13.1` |
| Installed binary SHA-256 | `fee53a4d6e6bbfa35d9653b28f6939de8f68718856de31189c8159cfec2921b5` |
| libkrun | `98163265197caa24a789699f16a68b98e917b65b` (1.17.3) |
| libkrunfw | `516ceece6aed60ccc84ac8faa459885062e39400` (5.4.0) |

The plan's source SRI hash was independently verified against the upstream
tarball before use. Upstream's own `nix/smolvm.nix` was **not** reused: at this
revision it downloads prebuilt 1.8.1 release tarballs, which are both the wrong
version and unsigned.

## Passing

- Source builds reproducibly through Nix from the pinned revision.
- The binary links against the pinned libkrun and runs.
- `com.apple.security.hypervisor` is present on the signed Mach-O.
- The installer refuses a wrong version, a missing entitlement, and a digest
  mismatch, and installs only under `ADE_SMOLVM_INSTALL_ROOT`.
- `machine create`, `machine status --json`, `machine ls` and `machine delete`
  behave as ADE's adapter assumes; `--json` carries the documented `state`
  field.
- Running with a temporary `HOME` and XDG directories confines all runtime state
  to that directory: the user's `~/.smolvm`, `~/Library/Application
  Support/smolvm`, `~/.microsandbox` and Homebrew paths were unchanged.

### Sealed network posture confirmed

Creating a machine without `--net` is genuinely networkless. SmolVM refuses the
create when the image would have to be pulled:

```
image '...' must be pulled from a registry, but this machine has no network,
so the pull can never succeed.
```

This confirms ADE's mapping: `sealed` omits `--net` entirely rather than
attempting to filter a public network.

## Blocked: guest boot

`machine start` fails:

```
verify rootfs: agent rootfs not found: .../Library/Application Support/smolvm/agent-rootfs
```

The guest agent rootfs is a separate artifact. Upstream builds it with
`scripts/build-agent-rootfs.sh`, which assembles an Alpine root containing
`crane`, `crun`, the utilities SmolVM shells out to, and the `smolvm-agent`
daemon cross-compiled to Linux musl for the guest architecture.

Nothing in the ADE host controller depends on this being absent, but every
blocking test that needs a booted VM is gated on it:

- persistent root and `/workspace` behavior across stop/start;
- tmpfs reset behavior;
- network postures, DNS, allowlists and container egress;
- secret installation, activation and reinjection;
- native interactive attachment;
- Herdr and Docker startup;
- workspace backup and restore above 4 GiB;
- reimage with crash injection at every journal boundary.

## Boot progress (2026-08-31)

The agent rootfs is now a pinned derivation and the runtime is self-contained.
Boot advanced through four distinct defects, each fixed:

1. **agent rootfs missing** — packaged as `nix/agent-rootfs.nix` from fixed-hash
   inputs, with `SMOLVM_AGENT_ROOTFS` set in the wrapper.
2. **`mkfs.ext4` missing** — e2fsprogs added to the runtime PATH.
3. **libkrunfw not loadable** — upstream's expression passes `OS=Linux` on
   macOS so the guest kernel cross-builds, but `OS` also selects the *host*
   library format, yielding an ELF `.so` the loader rejects with "slice is not
   valid mach-o file". A Darwin relink step now emits `libkrunfw.5.dylib`.
4. **`krun_add_vsock with TSI failed`** — smolvm 1.13.1 assumes a libkrun where
   the implicit vsock is gone ("the old krun_disable_implicit_vsock is gone"),
   but the pinned revision still defaults `VsockConfig` to `Implicit` and
   returns `-EEXIST`. Patched to call `krun_disable_implicit_vsock` first, in
   **both** launchers: `launcher.rs` drives the boot path, and
   `launcher_dynamic.rs` carries the same sequence.

Disks now format, config is written, and the boot subprocess spawns.

## Pins corrected (2026-08-31)

Upstream's `flake.nix` and its git submodules disagreed, and the submodules are
authoritative: `scripts/check-libkrun-provenance.sh` asserts the shipped library
matches `HEAD:libkrun` precisely to prevent shipping a stale libkrun. The flake
inputs are not covered by that check and had drifted by three months.

At the approved SmolVM revision `62f5f04` the submodules record:

| Component | Submodule (used now) | Upstream flake (stale) |
| --- | --- | --- |
| libkrun | `2dfbd6fb` (2.0.0-dev) | `98163265` (1.17.3) |
| libkrunfw | `8f130764` (5.5.0) | `516ceece` (5.4.0) |

This resolved the vsock defect at its source: libkrun `2dfbd6fb` removes
`krun_disable_implicit_vsock` and defaults `VsockConfig` to `Disabled`, exactly
as smolvm 1.13.1 assumes. The local vsock patch was dropped.

Knock-on changes handled: kernel 6.12.95, and a libkrun ABI bump from 1 to 2.
The smolvm library reference is now read from the binary rather than
hardcoding `libkrun.1.dylib`, so a future ABI change fails at build time
instead of at boot.

## Blocked: vCPU threads panic inside libkrun

Correcting the pins did **not** resolve the boot failure, so the earlier
hypothesis that smolvm and libkrun were merely out of step was incomplete.

`krun_start_enter` still returns `EINVAL`, but that is a downstream symptom.
`agent-startup-error.log` shows the real failure:

```
thread 'fc_vcpu 0' panicked at src/vmm/src/macos/vstate.rs:696:14:
failed to send Exited status: "SendError(..)"

thread 'fc_vcpu 1' panicked at src/vmm/src/macos/vstate.rs:525:79:
called `Result::unwrap()` on an `Err` value: RecvError
```

vCPU 1 blocks on `boot_receiver.recv()` — the PSCI `CpuOn` handshake — and gets
`RecvError` because vCPU 0 has already exited. So vCPU 0 dies first and the
rest is cascade. `agent-console.log` is empty: the guest never executed a
single instruction.

Ruled out:

- **Entitlements.** The installed binary carries
  `com.apple.security.hypervisor`, `allow-jit` and
  `disable-library-validation`, and `codesign -v` passes.
- **Stale disks.** Reproduced on freshly created machines.
- **Missing APIs.** Every symbol smolvm loads, required and optional, is
  exported by libkrun 2.0.0.
- **Pin drift.** Now aligned with the submodules upstream treats as
  authoritative.

### VMs do boot on this host (correction)

An earlier revision of this document concluded that "SmolVM 1.13.1 does not boot
a VM on this host". **That was wrong, and it was caused by the test harness.**

Every qualification run used a temporary `HOME` under `$TMPDIR` for isolation.
On macOS that path is ~63 characters, which pushes the agent's Unix socket to
118 bytes:

```
/var/folders/jp/.../T/tmp.6sRJYM2Bwy/Library/Caches/smolvm/vms/<id>/agent.sock
```

`sun_path` on macOS is capped at 104 bytes. The socket could never bind, the
vCPUs panicked, and libkrun reported `krun_start_enter -22`. Upstream's release
"failed identically" only because it was run under the same long `HOME`.

With the real `HOME`, or any short isolated one, upstream's release boots:

```
$ HOME=/tmp/adeq/h.OgoX ./smolvm machine run --net --image alpine -- echo hello
hello
```

**Qualification must use a short HOME.** `$TMPDIR` is unusable for this, and the
failure mode is silent and misleading.

### ADE's binary and rootfs are good

With upstream's library pair, ADE's own binary and agent rootfs boot, start the
guest agent, and pull an image:

| binary | libs | rootfs | result |
| --- | --- | --- | --- |
| ADE | upstream | upstream | boots, runs command |
| ADE | upstream | **ADE** | boots, agent runs, fails at `crun` |
| upstream | upstream | **ADE** | boots, agent runs, fails at `crun` |
| ADE | **ADE** | ADE | boot process exits (code 0) |

So the source-built binary, the `install_name_tool` ABI fix, and the pinned
agent rootfs are all correct. Two defects remain, both ADE's own.

### Fixed: the guest rootfs now runs containers

`crun` and the guest utilities are back, taken as Alpine packages rather than
nixpkgs' `pkgsStatic`: Alpine's builds already target the exact musl this
minirootfs ships, so no cross toolchain is rebuilt. An `.apk` is a gzipped tar,
unpacked over the rootfs in dependency order.

Added `crun` (at `/usr/bin/crun`, where the agent spawns it), `libseccomp`,
`yajl`, `libcap2`, `jq`, `e2fsprogs`, `e2fsprogs-extra` and `util-linux-misc`.
`libseccomp` was not obvious: without it `crun` is found and executed but fails
relocation on `seccomp_syscall_resolve_name`. A build assertion now fails if
`crun` is absent, since otherwise it only surfaces at container start.

Verified with upstream's libraries: a VM boots on ADE's rootfs, pulls an image
and runs a container reporting `Linux aarch64`, Alpine 3.24.1, pid 1 = `init`.

### Root cause: the guest kernel is built with the wrong GCC

The kernel's own version banner names the compiler, and the two builds differ:

```
upstream: Linux version 6.12.95 ... (gcc (Debian 12.2.0-14+deb12u1) 12.2.0, ...
ADE:      Linux version 6.12.95 ... (aarch64-unknown-linux-gnu-gcc (GCC) 15.3.0, ...
```

Upstream compiles the guest kernel with **Debian GCC 12.2.0**; nixpkgs' aarch64
cross compiler is **GCC 15.3.0**, three major versions newer. That accounts for
the 1.5 MB payload difference and a kernel that boots but never reaches init.
GCC 12 has been removed from nixpkgs as unmaintained.

The kernel *configuration* was ruled out: resolving `config-libkrunfw_aarch64`
with `make olddefconfig` adds only 19 entries, all compiler-identification
symbols or ordinary dependency closures. `CONFIG_LSM` lists `lockdown` and
`ipe`, but neither is compiled in — the string is an ordering hint.

### libkrun and libkrunfw are version-coupled

Pairing a locally built libkrun with upstream's libkrunfw, or the reverse,
aborts at VM start (SIGABRT, exit 134) even at nominally matching versions.
They must come from the same build.

### Resolution: upstream's libraries, pinned by hash

`nix/smolvm-libs-upstream.nix` extracts the whole `lib/` directory from
upstream's published release, pinned by SHA-256 against their
`checksums.sha256`. The whole directory matters: upstream's libkrun links
`libvirglrenderer`, which pulls `libepoxy` and `libMoltenVK`, and a missing one
surfaces only as a dyld failure at first run. An install assertion now checks
for each required library and for the embedded kernel version.

The tradeoff, stated plainly: the SmolVM CLI, the guest agent and the agent
rootfs are still built from pinned source, and the library pair is immutable
and hash-verified — but it carries no signature or provenance attestation,
which is the property the design objects to. `libkrunfw-source` and
`libkrun-source` are retained so a source build can be re-tested with a
suitable compiler.

## Working end to end (2026-09-01)

The installed runtime, with no environment overrides, boots a VM and runs a
container:

```
$ smolvm machine run --net --image alpine -- sh -c 'uname -sm; cat /etc/alpine-release; echo pid1=$(cat /proc/1/comm)'
Linux aarch64
3.24.1
pid1=init
```

ADE's own CLI drives that runtime:

```
$ ade status work-offline
work-offline	absent
```

Installed binary SHA-256: `220ef903e2c72a4b805a83c3d30e3953e3b3e59d517ef07f5cee3267159174f8`.

### Defects fixed to get here

1. Missing agent rootfs — packaged as a pinned derivation.
2. Missing `mkfs.ext4` — e2fsprogs on the runtime PATH.
3. libkrunfw built as a Linux ELF instead of a Mach-O dylib.
4. The implicit-vsock mismatch — resolved by correcting the libkrun pin to
   smolvm's submodule commit rather than its stale flake input.
5. A 118-byte agent socket path against macOS's 104-byte `sun_path` limit,
   caused by the qualification harness using `$TMPDIR` for isolation.
6. `crun` and the guest utilities missing from the rootfs.
7. The guest kernel compiler mismatch.

### Qualification constraints learned

- **Use a short HOME.** `$TMPDIR` paths exceed the Unix socket limit and the
  failure is silent and misleading.
- **Never mix library builds.** libkrun and libkrunfw must come from one build.
- **Validate the harness against a known-good baseline** before trusting a
  negative result. An earlier revision of this document concluded the runtime
  was broken on this host; the harness was.

## Runtime qualification (2026-09-01)

`test/qualification/test_runtime.py` runs against a live runtime, 10 tests
passing. Each asserts a property the design depends on rather than restating
what the runtime does.

| Area | Verified |
| --- | --- |
| Lifecycle | create → start → stop with the expected state at each step; repeated stop is a no-op; an unknown machine reports "not found" |
| Persistence | `/workspace` survives stop/start; `/run` is wiped by a restart |
| Network | a sealed machine cannot reach the network; a networked machine resolves DNS and reaches a server |
| Isolation | machine data stays under the test HOME; the user's `~/.smolvm`, `~/.microsandbox` and Homebrew paths are unchanged |

Two harness constraints are encoded in `test/qualification/runtime.py`, both
learned from failures that misdirected earlier work:

- **HOME must be short.** The agent socket lives under it and macOS caps
  `sun_path` at 104 bytes; a `$TMPDIR` path reaches 118 and the VM fails to
  boot with a vCPU panic that looks like a runtime defect.
- **`mkfs.ext4` must be on PATH**, since smolvm shells out to it to format
  disks. The harness finds it in the Nix store when absent.

Two network assertions had to be corrected, and both are worth recording
because the naive version would have produced a false negative:

- An `https` probe fails at certificate verification: the bare Alpine rootfs
  ships no CA bundle. That is not an egress failure.
- An HTTP **403** still proves egress works — DNS resolved, TCP connected, a
  server replied. Only a timeout or resolution failure means blocked.

### Allowlist enforcement verified (2026-09-04)

A positive hostname allowlist is enforced by the runtime, not by agent
convention. On a machine created with `--net --allow-host example.com`:

```
wget http://example.com   -> '/dev/null' saved
wget http://neverssl.com  -> wget: bad address 'neverssl.com'
```

The allowlisted host resolves and transfers; a host not on the list fails at
resolution. This is the claim the `allowlisted` posture rests on.

### Not yet covered

The design lists these as blocking, and they remain untested:

- Docker and a nested container workload;
- Herdr startup, attachment and multi-agent use;
- native interactive attachment, streams, signals and stop disconnect;
- workspace backup and restore above 4 GiB;
- CIDR allowlist entries, and egress from a Docker container inside a
  workbench.

Secret installation and reimage crash injection, previously listed here, are
now covered by `test_credential_installer.ml` and `test_reimage_crash.ml`. The
SSH agent is tested against a fake host rather than a real `ssh-agent`, so its
process interaction is also still unqualified.

### Still open elsewhere

- Credential providers (Task 11): GitHub, Kubernetes and the dedicated SSH
  agent, plus the tmpfs installer and `credentials status|rotate|revoke`.
- Microsandbox removal (Task 14), gated on the qualification suite.
- The libkrun/libkrunfw provenance gap recorded above.
