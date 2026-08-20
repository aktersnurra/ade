# Microsandbox 0.6.10 Native Execution Qualification for ADE

**Status:** qualification passed

## Scope

Apple silicon macOS qualification of the official Microsandbox 0.6.10 release with a digest-pinned Alpine arm64 fixture. The run used an isolated `MSB_HOME`, two fixed no-network sandboxes, and separate qualification-owned project-store directories.

Standard SSH, `msb ssh`, guest `sshd`, arbitrary host-path copy, ADE product code, and existing Microsandbox state were outside the run.

## Observed values

- Host: `Darwin arm64`
- Installed Homebrew command: `msb 0.6.8` (observed only)
- Qualified command: `msb 0.6.10`
- Release archive SHA-256: `a1742728676bbdfa3850e59df4b85b9df7dabcfd7e1c270876725aecdd3e992c`
- Fixture: `alpine@sha256:e7a1a92a5bfeee40966aea60f0796b0e7917cc35591542701834f03a68fa3d18`
- Fixture architecture metadata: `arm64`
- Guest `uname -m`: `aarch64`
- Network policy: deny ingress and egress with no exception rules
- Explicit command timeout: 2 seconds; command returned nonzero without its normal-completion marker
- Stop-to-PTY-client exit: `0.116` seconds
- PTY client status after stop: `255`
- Concurrent PTY clients: 4

## Acceptance results

| Check | Status | Evidence |
| --- | --- | --- |
| `release_archive` | pass | official msb 0.6.10 archive checksum and version verified |
| `native_feature_probe` | pass | tty, no-tty, stream, and timeout operations exposed |
| `fixture_image` | pass | digest-pinned Alpine arm64 fixture verified |
| `sandbox_create` | pass | two isolated running fixtures use separate stores and deny-all networking |
| `no_tty_exec` | pass | captured command output, options, and exit status preserved |
| `stream_and_timeout` | pass | stream round-trip and explicit command timeout passed with timeout evidence |
| `isolation_and_persistence` | pass | network, authority, root, and separate project stores persisted across stop-start |
| `root_replacement` | pass | replacement removed writable-root marker and preserved the project store |
| `pty_behavior` | pass | interactive attach, resize, signals, reconnect, concurrency, and stop disconnect passed |
| `explicit_restart` | pass | workbench remained stopped until explicit start and then accepted execution |
| `stopped_lifecycle_ownership` | pass | native exec temporarily started a stopped fixture and returned it to stopped |
| `cleanup` | pass | both exact fixtures removed from isolated home |

## Lifecycle observations

- Writable-root markers survived stop/start in both fixtures.
- Separate project-store markers survived stop/start.
- Replacing the `personal` sandbox removed its writable-root marker while preserving its project-store marker.
- `msb exec` against a stopped sandbox temporarily started it, completed the command, and returned it to `stopped`.
- ADE must therefore establish `Running` explicitly and prevent a losing attachment from implicitly restarting a workbench after stop wins.

## Terminal observations

- Captured non-TTY execution preserved output, workdir, explicit environment, and guest exit status 23.
- Bidirectional stream execution round-tripped input and output.
- Explicit timeout ended the client operation in 2 seconds, reported timeout evidence, and suppressed the normal-completion marker. The run did not independently probe whether the guest process remained after timeout.
- PTY attach, resize to 37 by 113, interrupt delivery, reconnect, and four concurrent clients passed.
- Stopping the sandbox closed the attached native PTY client in `0.116` seconds; the guest command did not reach normal completion.

## Authority observations

- Public and tested private-network requests failed under deny-all networking.
- Host `SSH_AUTH_SOCK` and a host environment canary were absent from both guests.
- The two project stores remained separate.
- The isolated home contained only the two qualification fixtures, which were removed before this report was generated.

## Limitations

- The fixture was Alpine, not the production Nix workstation image.
- The run covered Apple silicon macOS only, not Artix/KVM.
- It did not implement or exercise any OCaml ADE code.
- It did not implement or prove ADE lifecycle locks, physical-instance binding, run generations, operation-start leases, losing-attach cancellation, or structured ADE errors.
- It did not qualify protected capabilities, gatekeepers, package installation, or guest-local containers.
- The normal `Backend local` diagnostic emitted by `msb exec` was allowed on stderr; unexpected additional stderr remained a failure.

## Decision

Microsandbox 0.6.10 passed the native lifecycle, persistence, network, command, stream, and PTY substrate qualification required before implementing the minimal ADE V1 layer.
