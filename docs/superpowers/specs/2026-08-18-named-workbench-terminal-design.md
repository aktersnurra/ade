# Named Workbench VMs and Generic Terminal Sessions

**Status:** Approved design

## Objective

ADE manages named workbench VMs such as `work` and `personal`.

Each workbench is one data, network, and capability boundary. Many agents and projects can run inside one workbench.

The primary flow is:

```text
ade start work
  -> resolve the named ADE configuration
  -> establish base-image provenance and external policy
  -> create, start, or reuse the workbench VM
  -> confirm that the workbench is Running
  -> enter the guest shell through native `msb exec --tty`
  -> use the shell and guest development tools
```

ADE manages the workbench. V1 does not install, configure, or integrate with a terminal multiplexer.

## Core boundary

ADE owns lifecycle, policy, the project store, and terminal transport.

```text
terminal or optional host multiplexer
          |
          v
ade start work
          |
          |- resolve and verify configuration
          |- stage the project store and deny-by-default external policy
          |- verify base-image provenance, store, and policy
          |- start and confirm the VM is Running
          |- prepare native Microsandbox terminal execution
          |- release the lifecycle lock after operation-start validation
          `- attach with `msb exec --tty`
                    |
================ VM boundary ================
                    |
              guest login shell
                    |
           guest tools and processes
```

Native PTY and guest command execution are the complete V1 terminal boundary.

## Trust model

A workbench VM is one hostile security principal.

There is no security boundary between agents, projects, tools, or other guest processes in one workbench. Compromise of one component can compromise the complete workbench.

Agents in one workbench share:

- the guest filesystem and project store;
- guest processes;
- guest-local control sockets and APIs;
- the workbench network policy;
- the workbench capabilities.

This behavior is not an ADE security violation. Use separate workbenches when agents must not share data or authority.

Full compromise of a workbench must not grant reusable authority beyond its externally enforced capability envelope.

The VM boundary protects the host and separates workbench data. The capability boundary protects external services from a hostile workbench.

The main [ADE design](2026-08-14-ade-design.md) defines zones, capabilities, gatekeepers, approvals, and observation receipts.

## Responsibilities

### ADE

ADE owns:

- named workbench configuration and lifecycle;
- base-image selection and writable-root provenance;
- resource and external network policy;
- the declared project store;
- project-store checkpoints when requested;
- native Microsandbox terminal and command execution;
- lifecycle locks;
- effective-authority inspection;
- structured errors and receipts.

ADE does not own guest process layout, agent orchestration, worktrees, or agent state.

### Terminal transport

The terminal adapter provides:

- interactive PTY execution with `msb exec --tty`;
- bounded non-interactive execution with `msb exec --no-tty`;
- byte-streamed execution with `msb exec --stream` when required;
- terminal resize and signal behavior;
- concurrent clients;
- one validated route to the selected running workbench.

The adapter does not forward ambient host authority. Standard SSH compatibility is not a V1 requirement.

### Host terminal

ADE works in a plain terminal. A host multiplexer may run ADE as an ordinary command, but ADE does not inspect or configure it.

### Guest tools

The approved guest image contains the development tools required by the image manifest. ADE does not inspect or configure guest application state.

## Configuration

A workbench name maps to one verified ADE configuration.

```ocaml
workbench "work"
  ~zone:Work
  ~image:Images.nix_workstation
  ~project_store:(project_store "work" ~mount:"/workspace")
  ~repositories:[ ... ]
  ~capabilities:[]
  ~resources:{ cpus = 4; memory_gib = 8; root_disk_gib = 24 }
```

The V1 lifecycle configuration has no protected capabilities. Later gatekeeper slices can add them.

The image owns guest-tool installation and defaults. Guest configuration is mutable root state, persists across stop/start, and is replaced by reimage.

The project store declaration supplies its stable `/workspace` mount path. V1 persists only this project store across reimage.

## Commands

The initial command surface is:

```sh
ade list
ade start work
ade exec work -- command
ade inspect work
ade stop work
ade stop --force work
ade reimage work
```

`ade start <workbench>` is idempotent. It starts a stopped workbench and enters it. If the workbench is already running, it enters it.

Leaving the terminal session does not stop the workbench.

A future design can define destructive cleanup for roots, stores, and checkpoints. `reimage` is not a complete erasure operation.

## Start flow

`ade start <workbench>`:

1. resolves and verifies the named configuration;
2. acquires the per-workbench lifecycle lock;
3. inspects the VM, recorded base image, writable-root generation, project-store mount, and policy;
4. creates an absent VM with its project store and deny-by-default external policy;
5. reconciles a stopped VM before guest execution;
6. verifies base-image provenance, the project-store mount, and the effective policy digest;
7. starts the VM and confirms the `Running` postconditions;
8. prepares native execution against the recorded Microsandbox instance and run generation;
9. starts `msb exec --tty` under a short operation-start lease;
10. releases the lifecycle lock after attachment succeeds, then supervises the terminal client.

`Running` means that ADE verified base-image provenance, the project-store mount, external policy, and the run generation for the current VM instance.

Base-image provenance proves that ADE created the writable root from the declared image digest. It does not prove that the current writable root still matches that image.

Guest changes to the writable root are hostile persistent state. ADE does not hash or attest the current guest filesystem. Reimage creates a new root from the approved base image.

Each transition from absent or stopped to running creates a new host-managed run generation. Entry into an already-running workbench reuses its current generation.

Stop invalidates the generation, even when the next start reuses the same VM root.

ADE does not mutate a running workbench. If a running workbench has drift, `ade start` reports a structured drift error.

Multiple clients can enter one running workbench. A terminal client never owns the lifecycle lock.

Native execution binds to the recorded Microsandbox instance identity and run generation. A short operation-start lease covers the interval between the final `Running` check and confirmed attachment.

Lifecycle mutation waits for this lease to attach the terminal or fail. The lease ends after attachment and never lasts for the terminal session. ADE must not use `msb exec` as an implicit start operation.

If stop, restart, or reimage changes the tuple before attachment, ADE terminates the client and reports `run_generation_changed` or `instance_changed`. ADE integration tests must prove that a losing attach cannot restart a workbench that stop already won; the substrate-only qualification records implicit-start behavior but cannot prove ADE's lease implementation.

## Workbench lifecycle

Configuration declaration is separate from runtime state.

```text
Absent -> Starting -> Running -> Stopping -> Stopped
             |           |          |          |
             `-----------+----------+----------+-> Failed

Stopped -> Reimaging -> Stopped
               |
               `-> Failed
```

The writable VM root persists across stop and start.

The host stores the current run generation outside the guest. Guest code cannot choose or reuse a generation.

`ade stop <workbench>` terminates guest processes. It preserves the VM root and project store.

`ade reimage <workbench>`:

1. stops the VM when necessary;
2. removes the writable VM root;
3. creates a new root from the approved image;
4. reattaches the project store;
5. leaves the workbench stopped.

ADE serializes create, start, stop, reimage, and future purge operations per workbench.

## Persistent storage

Each workbench has one persistent project store mounted at `/workspace`.

Source repositories, worktrees, and artifacts live under `/workspace`.

Guest-tool configuration remains in the writable root. It survives stop/start and is replaced by reimage. ADE does not promise that agent-local session data or guest configuration survives reimage, and it does not persist a complete guest home directory.

The project-store mount path appears in `ade inspect`. Project-store contents remain hostile after reimage. Reimage creates a new root from the approved base image and does not prove that the workbench is uncompromised.

ADE creates project-store checkpoints only when the user requests one. Automatic checkpoint policy is outside the first lifecycle slice.

## Native terminal execution

ADE V1 does not require standard SSH for workbench access. It first resolves the named workbench, explicitly ensures it is `Running`, and then uses native Microsandbox operations:

```sh
msb exec --tty work
msb exec --no-tty work -- command
msb exec --stream work -- command
```

Interactive entry uses `--tty`. Bounded `ade exec` operations use `--no-tty`; operations that require bidirectional byte streaming can use `--stream`. ADE does not rely on `msb exec` to start a stopped workbench implicitly.

The Microsandbox adapter validates the selected physical instance and run generation under a short operation-start lease. If lifecycle mutation wins before attachment, the adapter terminates the native client and reports a structured stale-generation or instance error. If attachment wins, the lease ends and a later stop terminates the active session.

The adapter must:

- invoke native execution only for the selected `RunningWorkbench`;
- avoid ambient shell configuration and host environment forwarding;
- use explicit operation timeouts for bounded commands;
- reject cross-workbench, cross-instance, and stale-generation routing;
- preserve PTY, resize, signal, disconnect, and concurrent-client behavior;
- leave the workbench running when a terminal client exits.

V1 exposes no arbitrary host-path copy operation and no standard SSH workbench access.

## Security requirements

- Treat the complete workbench as hostile.
- Enforce network and capability policy outside the guest.
- Never mount the host home directory into a workbench.
- Never forward host SSH credentials or an SSH agent.
- Never expose a host Docker socket or cloud configuration.
- Never forward or mount host application control sockets, configuration, or state.
- Never send raw long-lived service credentials to a workbench.
- Install guest tools through the approved image.
- Refuse stores or capabilities whose classification is incompatible with the workbench.
- Report errors without complete environments, secrets, or credential-bearing command lines.

The first lifecycle slice supports only workbenches without protected capabilities. ADE must not claim protected capability support before gatekeeper and network enforcement tests pass.

## Inspection

`ade inspect <workbench>` reports:

- lifecycle state and current run generation;
- declared and recorded base-image digest;
- writable-root generation and `root_integrity = Not_attested`, because ADE does not attest the current guest filesystem;
- actual and declared policy digest;
- effective network zone;
- active capabilities, scopes, and expiry;
- the mounted project store;
- detected drift;
- the most recent lifecycle error.

Inspection must answer: "What can this workbench reach and authorize now?"

## Failure behavior

If VM start fails, ADE leaves the project store unchanged and reports the failed lifecycle operation.

If policy verification fails, ADE does not open the terminal session.

If native execution setup fails, ADE closes temporary resources and leaves the VM state visible through `ade inspect`.

If a terminal disconnects, its login shell and foreground children can terminate. Independently detached guest processes can continue while the VM remains running.

If normal stop times out, ADE reports the timeout. The user can request `ade stop --force`.

If a persistent store is full or unavailable, ADE reports the affected store and operation. It does not reimage or delete data automatically.

## ADE acceptance criteria

The ADE model is accepted when:

- `ade start work` starts or enters the `work` VM;
- `ade start personal` starts or enters a separate `personal` VM;
- both workbenches can run at the same time;
- interactive shells work with the minimal approved image and no multiplexer;
- Microsandbox 0.6.10 passes the lifecycle, root and project-store persistence, network, and native execution regression suite;
- `msb exec --tty` enters an interactive guest shell only after ADE confirms `Running`;
- `ade exec` uses bounded native non-interactive execution;
- `msb exec --stream` preserves bidirectional byte-stream behavior when selected;
- concurrent terminal sessions work in one VM;
- terminal resize, signals, disconnect, and stop behavior work;
- a new `ade start` session works after a previous terminal disconnects;
- stop and start preserve the root while `ade inspect` continues to report `root_integrity = Not_attested`;
- stop terminates guest processes but preserves the root and project store;
- reimage replaces the root and preserves the project store;
- reimage does not claim to clean persistent data;
- the host home, credentials, SSH agent, application state, and ambient environment are absent from each VM;
- guest root cannot disable externally enforced egress policy;
- unapproved destinations and other workbench stores remain unreachable;
- V1 rejects workbench configurations that request protected capabilities;
- `ade inspect` reports no active protected capabilities in V1;
- native execution routes only to the selected workbench instance and run generation;
- lifecycle mutation that wins before attachment causes a generation or instance error and cannot implicitly restart the stopped workbench;
- an operation-start lease that wins confirms attachment before lifecycle mutation continues;
- all lifecycle, drift, policy, storage, and transport failures use structured ADE errors.

## Default image integration criteria

The default guest image is accepted when:

- the login shell starts through the generic terminal session;
- required development tools resolve from the declared image;
- `/workspace` is the default project location;
- package installation and guest-local containers work;
- no terminal multiplexer or guest-tool state format is required by ADE.

## Non-goals

The first version does not provide:

- per-agent isolation inside one VM;
- an ADE agent dashboard;
- ADE-managed tabs, panes, agents, or worktrees;
- terminal-multiplexer installation, integration, or state persistence;
- standard SSH workbench access;
- automatic agent conversation restore;
- automatic checkpoints on start or reimage;
- complete persistent-data cleanup through reimage;
- cloud-hosted workbenches;
- multi-user collaboration.

## Sources

- [Microsandbox: Sandbox commands](https://docs.microsandbox.dev/cli/sandbox-commands) for native `exec` behavior.
- [Microsandbox: CLI overview](https://docs.microsandbox.dev/cli/overview) for terminal auto-detection.
- [Microsandbox 0.6.10](https://github.com/superradcompany/microsandbox/releases/tag/v0.6.10) for the pinned qualification release.
- [OpenSSH stdio transport experiment](2026-08-18-microsandbox-0.6.10-ssh-transport-experiment.md) for the rejected historical path and shutdown failure.
