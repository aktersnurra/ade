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

### Isolated: upstream's own release fails identically

The upstream-published release was run as a control: `smolvm-1.13.1-darwin-arm64
.tar.gz`, checksum `da877a29...` verified against upstream's `checksums.sha256`.
It bundles upstream's binary, their `lib/` (libkrun + libkrunfw), and their
`agent-rootfs`. Nothing from ADE is involved.

It fails with a byte-identical signature:

```
thread 'fc_vcpu 0' panicked at src/vmm/src/macos/vstate.rs:696:14
thread 'fc_vcpu 1' panicked at src/vmm/src/macos/vstate.rs:525:79
krun_start_enter returned: -22
```

`agent-console.log` is empty in both cases: no guest instruction ever executes.

Upstream's `smolvm-bin` carries `com.apple.security.hypervisor`, `allow-jit` and
`disable-library-validation`, and `codesign -v` passes.

**Conclusion: SmolVM 1.13.1 does not boot a VM on this host.** The failure is in
the runtime on this macOS/hardware combination, not in ADE's packaging. Every
component ADE builds — the source-built binary, the pinned libkrun/libkrunfw,
the agent rootfs — reproduces exactly what upstream's own artifact does.

Host: macOS 26.5.2, Apple M1.

This also retroactively validates the four defects fixed earlier. They were real
and had to be fixed to reach this point, but none of them was the cause: ADE's
build now behaves indistinguishably from upstream's.

### What this means for the migration

The ADE host controller does not depend on this. It is complete and tested
against a fake runtime: 127 tests covering declarations, the process boundary,
the SmolVM adapter, lifecycle convergence, archive validation, the reimage
journal, destroy authorization, and credential handling.

What is blocked is anything requiring a booted VM: the runtime qualification
suite, the workstation image build, and therefore Task 14's removal of the
Microsandbox surface.

Options, none of which ADE can decide on its own:

1. **Report upstream.** The reproducer is minimal and uses only their published
   artifact: create a machine, start it, observe the vCPU panic. This is the
   cheapest path and the most likely to produce a real fix.
2. **Try another SmolVM version.** 1.13.1 is the approved pin, but the defect is
   in the runtime, so a different release may simply work. Changes the approved
   pin.
3. **Try another host.** A different macOS version or an Apple Silicon
   generation other than M1 would establish how narrow the failure is.

Until a VM boots somewhere, the Microsandbox baseline must stay: the plan's
gate says the SmolVM suite has to pass before that surface is removed, and it
cannot pass.
