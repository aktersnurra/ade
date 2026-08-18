# Microsandbox 0.6.10 OpenSSH Stdio Transport Experiment

**Status:** rejected experiment

## Purpose

This historical experiment evaluated standard OpenSSH over `msb ssh serve --stdio` before ADE selected native Microsandbox execution for V1 terminal access.

The result does not block ADE's native terminal design. Standard SSH is not a V1 requirement.

## Environment

- Host: Apple silicon macOS
- Installed Homebrew command: `msb 0.6.8` (observed only)
- Isolated qualified command: `msb 0.6.10`
- Release archive SHA-256: `a1742728676bbdfa3850e59df4b85b9df7dabcfd7e1c270876725aecdd3e992c`
- Fixture: `alpine@sha256:e7a1a92a5bfeee40966aea60f0796b0e7917cc35591542701834f03a68fa3d18`
- Guest architecture: `aarch64`
- Isolated sandbox names: `ade-msb-0610-work` and `ade-msb-0610-personal`

## Results

| Check | Result | Observation |
| --- | --- | --- |
| Release provenance | Pass | Official 0.6.10 archive checksum and version matched |
| SSH feature probe | Pass | `--stdio`, `--inactivity-timeout`, and `--no-inactivity-timeout` were present |
| Isolated runtime | Pass | Qualification began with an empty isolated `MSB_HOME` |
| Fixture provenance | Pass | Digest and arm64 architecture matched |
| Sandbox creation | Pass | Two fixed no-network sandboxes were created without replacement |
| External network policy | Pass | Both policies denied ingress and egress with no exception rules |
| Strict OpenSSH configuration | Pass | Temporary keys and host keys were isolated; effective `SendEnv` was empty |
| Guest command execution | Pass | Both aarch64 guests executed commands through the stdio proxy |
| Network denial | Pass | Guest `wget` could not reach tested public or private destinations |
| Store separation | Pass | Work and personal stores remained separate |
| Stop/start persistence | Pass | Both project-store markers survived stop and start |
| Ambient authority | Pass | No host SSH agent or host `HERDR_*` value reached either guest |
| TCP listener absence | Pass | The stdio proxy created no qualification-owned TCP listener |
| Concurrent clients | Pass | Four clients completed with unique outputs |
| Long idle session | Pass | A real 660-second silent session remained usable with `--no-inactivity-timeout` |
| PTY resize and signal | Pass | Resize was observed before interrupt delivery |
| Generic disconnect | Pass | The foreground guest process terminated with its client |
| Stop disconnect | **Fail** | The VM stopped, but the ready OpenSSH client remained blocked until the 120-second harness timeout |
| Same-name replacement rejection | Not run | Execution stopped at the mandatory disconnect failure |

## Blocking observation

`msb stop ade-msb-0610-personal` reached the stopped state and the guest command did not produce its normal-completion marker. The host OpenSSH process nevertheless remained blocked until the harness killed its process group at 120 seconds.

A separate negative control using `--inactivity-timeout 2s` suppressed delayed guest output but also left OpenSSH blocked instead of closing the client cleanly.

No stop-disconnect pass was recorded.

## Follow-up native probe

After rejecting the SSH path, a focused native probe attached with:

```sh
msb exec --tty ade-msb-0610-personal
```

The PTY accepted an interactive command. After `msb stop`, the native client exited in approximately 0.22 seconds with a non-zero status. This probe motivated the dedicated native-execution qualification plan; it is not a substitute for that complete qualification.

## Decision

ADE V1 does not use standard OpenSSH, `ProxyCommand`, `msb ssh serve`, SSH host-key routing, or SSH inactivity controls for workbench entry.

ADE explicitly establishes the named workbench as `Running`, then uses native `msb exec --tty` for interactive entry and native non-interactive or streamed execution for commands. ADE V1 exposes no arbitrary host-path copy operation.

## Limitations

- The experiment used a pinned Alpine fixture, not the production Nix workstation image.
- It did not implement ADE lifecycle locks, generation binding, operation-start leases, or structured errors.
- It did not qualify protected capabilities, gatekeepers, or Artix/KVM.
- Runtime evidence was intentionally removed after this result was recorded.
