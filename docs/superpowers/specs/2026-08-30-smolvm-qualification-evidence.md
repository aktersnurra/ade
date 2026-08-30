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

## Next step

Package the agent rootfs as a pinned Nix derivation and set
`SMOLVM_AGENT_ROOTFS` in the wrapper, so the runtime is self-contained rather
than depending on a rootfs built imperatively on the host.
