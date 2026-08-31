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

## Blocked: krun_start_enter returns EINVAL

```
start vm: krun_start_enter returned: -22 (EINVAL — libkrun rejected the VM
configuration)
```

The subprocess dies inside `krun_start_enter` about 140 ms after spawning, on a
freshly created machine as well as a reused one, so it is not stale disk state.

All 13 symbols smolvm loads unconditionally are exported by the pinned libkrun,
as are every optional symbol it probes (`krun_add_virtiofs3`,
`krun_create_disk_overlay`, `krun_set_snapshot`, and the rest). So this is a
semantic mismatch in the VM configuration, not a missing API.

That is consistent with the vsock defect: smolvm 1.13.1 appears to target a
newer libkrun than the revision its own flake pins. The vsock case was
recoverable because the older API still existed under a name smolvm no longer
called; an `EINVAL` from `krun_start_enter` gives no such handle without
identifying which specific configuration call libkrun rejects.

### Options

1. Instrument the boot subprocess to log each `krun_*` call and its return
   value, isolating the rejected configuration. Most precise; needs another
   full rebuild per iteration (~2 h each).
2. Move libkrun to the revision smolvm 1.13.1 actually expects. Likely resolves
   both this and the vsock defect at the source, but changes the qualified
   runtime's provenance and requires re-auditing the pin.
3. Pin an older smolvm that matches the current libkrun revision. Preserves the
   audited libkrun but abandons the approved SmolVM version.

Option 2 is the most likely to be correct, since the evidence points to smolvm
and libkrun being out of step rather than to a defect in either alone. It is a
change to the approved pin and therefore a decision for the user.
