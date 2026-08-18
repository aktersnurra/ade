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
  -> open a generic SSH/PTTY session
  -> enter the guest login shell
  -> run Herdr or another guest tool
```

ADE manages the workbench. It does not manage a terminal multiplexer.

Herdr remains the preferred guest multiplexer. ADE must also work when Herdr is absent.

## Core boundary

ADE owns lifecycle, policy, persistent stores, and terminal transport.

```text
optional outer host Herdr
          |
          v
ade start work
          |
          |- resolve and verify configuration
          |- stage stores and deny-by-default external policy
          |- verify base-image provenance, stores, and policy
          |- start and confirm the VM is Running
          |- prepare bounded OpenSSH transport
          |- release the lifecycle lock
          `- exec a generic interactive session
                    |
================ VM boundary ================
                    |
              guest login shell
                    |
             user runs `herdr`
                    |
       guest Herdr owns projects and agents
```

Removing Herdr from a guest image reduces convenience. It does not change ADE lifecycle or security behavior.

ADE does not provide a multiplexer plug-in system. A generic PTY and remote command interface are sufficient.

## Trust model

A workbench VM is one hostile security principal.

There is no security boundary between agents, projects, guest Herdr, or other guest processes in one workbench. Compromise of one component can compromise the complete workbench.

Agents in one workbench share:

- the guest filesystem and persistent stores;
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
- declared persistent stores;
- project-store checkpoints when requested;
- bounded generic SSH transport;
- lifecycle locks;
- effective-authority inspection;
- structured errors and receipts.

ADE does not own terminal tabs, panes, agents, worktrees, or agent process state.

### Terminal transport

The transport provides:

- an interactive SSH/PTTY session;
- remote command execution;
- terminal resize and signal behavior;
- concurrent clients;
- one authenticated route to the selected workbench.

The transport does not forward ambient host authority.

### Host terminal and multiplexer

ADE does not require a host multiplexer.

The user can run ADE in a plain terminal or inside an outer host Herdr. When the host uses Herdr, it can act as the workbench cockpit.

The recommended host Herdr prefix is `Ctrl-A`.

### Guest tools

The approved guest image can include Herdr and other development tools.

Guest Herdr owns guest-local workspaces, tabs, panes, agents, processes, worktrees, and its socket. The recommended guest Herdr prefix is `Ctrl-B`.

ADE does not parse guest Herdr configuration. ADE does not use the Herdr remote protocol. Host and guest Herdr versions do not need to match.

## Configuration

A workbench name maps to one verified ADE configuration.

```ocaml
workbench "work"
  ~zone:Work
  ~image:Images.nix_workstation
  ~stores:
    [ project_store "work" ~mount:"/workspace"
    ; tool_state "herdr" ~mount:"/var/lib/ade-state/herdr"
    ]
  ~repositories:[ ... ]
  ~capabilities:[]
  ~resources:{ cpus = 4; memory_gib = 8; root_disk_gib = 24 }
```

The V1 lifecycle configuration has no protected capabilities. Later gatekeeper slices can add them.

The guest image owns guest-tool configuration. On first creation, the default image initializes Herdr with:

```toml
[keys]
prefix = "ctrl+b"

[experimental]
pane_history = false

[session]
resume_agents_on_restore = false

[worktrees]
directory = "/workspace/.herdr/worktrees"
```

These settings are guest defaults, not security controls. A hostile guest can change its own configuration.

ADE treats tool-state stores as opaque data. It does not parse or enforce the Herdr state format.

Each store declaration includes its stable guest mount path. The image manifest must use that path and keep runtime sockets outside it.

The default image sets guest-local `HERDR_CONFIG_PATH` to a config file under `/var/lib/ade-state/herdr`. The image integration keeps Herdr's durable config and session data in that state area.

It sets `HERDR_SOCKET_PATH` to a runtime path under `/run`.

These guest-local variables configure the guest application. ADE must not derive them from host `HERDR_*` values.

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
3. inspects the VM, recorded base image, writable-root generation, stores, and policy;
4. creates an absent VM with its stores and deny-by-default external policy;
5. reconciles a stopped VM before guest execution;
6. verifies base-image provenance, store mounts, and the effective policy digest;
7. starts the VM and confirms the `Running` postconditions;
8. prepares an SSH configuration bound to the instance and run generation;
9. releases the lifecycle lock;
10. replaces itself with an interactive OpenSSH client.

`Running` means that ADE verified base-image provenance, store mounts, external policy, and the run generation for the current VM instance.

Base-image provenance proves that ADE created the writable root from the declared image digest. It does not prove that the current writable root still matches that image.

Guest changes to the writable root are hostile persistent state. ADE does not hash or attest the current guest filesystem. Reimage creates a new root from the approved base image.

Each transition from absent or stopped to running creates a new host-managed run generation. Entry into an already-running workbench reuses its current generation.

Stop invalidates the generation, even when the next start reuses the same VM root.

ADE does not mutate a running workbench. If a running workbench has drift, `ade start` reports a structured drift error.

Multiple clients can enter one running workbench. A terminal client never owns the lifecycle lock.

The transport binds to the verified instance identity and run generation. A short connection lease verifies this tuple while the Microsandbox stdio stream opens.

Lifecycle mutation waits for this connection lease to open the stream or fail. The lease ends after the stream opens and never lasts for the terminal session.

If stop, restart, or reimage changes the tuple before connection, the transport fails with `run_generation_changed` or `instance_changed`.

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

`ade stop <workbench>` terminates guest processes. It preserves the VM root and declared persistent stores.

`ade reimage <workbench>`:

1. stops the VM when necessary;
2. removes the writable VM root;
3. creates a new root from the approved image;
4. reattaches the declared persistent stores;
5. leaves the workbench stopped.

ADE serializes create, start, stop, reimage, and future purge operations per workbench.

## Persistent storage

Each workbench has explicit persistent stores.

The initial default configuration declares:

1. a project store mounted at `/workspace`;
2. a narrow guest Herdr state store mounted at the declared `/var/lib/ade-state/herdr` path.

Source repositories, worktrees, and artifacts live under `/workspace`.

The Herdr state store can contain workspace layout, tabs, pane metadata, and guest configuration. The default image disables pane history and automatic agent restore.

These defaults do not establish a guest security boundary. Persisted guest configuration remains hostile and can override them.

ADE does not promise that agent-local session data survives reimage. ADE does not persist a complete guest home directory.

Runtime sockets and process identifiers remain on disposable runtime storage. Store mount paths are stable configuration values and appear in `ade inspect`.

All declared stores remain hostile after reimage. Reimage creates a new root from the approved base image. It does not prove that the workbench is uncompromised.

ADE creates project-store checkpoints only when the user requests one. Automatic checkpoint policy is outside the first lifecycle slice.

## Remote transport

ADE uses standard OpenSSH through an internal ADE transport helper:

```sshconfig
Host ade-work
  User root
  ProxyCommand ade transport --workbench work --instance INSTANCE --generation GENERATION
```

The helper validates the expected instance and run generation under a short connection lease. It then opens the stream with:

```sh
msb ssh serve work --stdio --no-inactivity-timeout
```

`ade transport` is an internal adapter command, not a public workbench operation. ADE generates this dedicated configuration for the selected workbench.

This path does not require a listening TCP port or a guest `sshd`.

Interactive `ade start` sessions disable the Microsandbox inactivity timeout. `ade exec` uses a separate explicit operation timeout.

The validated Microsandbox 0.6.8 binary supports `--stdio` but not `--no-inactivity-timeout`. Slice 1 pins Microsandbox 0.6.10, where the timeout flag was added, and reruns the lifecycle, network, and SSH acceptance suite before ADE claims support.

The generated configuration must:

- disable SSH agent forwarding;
- disable environment forwarding;
- disable unintended local, remote, and dynamic forwarding;
- avoid ambient host aliases and proxy commands;
- authenticate the selected workbench and verified VM instance;
- pin the expected instance identity, host key, and run generation;
- use a short connection lease while it opens the stdio stream;
- reject cross-workbench, cross-instance, and stale-generation routing;
- preserve PTY, resize, and signal behavior.

ADE validates workbench identifiers before it constructs a proxy command. The transport fails instead of following a reused workbench name to a replacement instance.

ADE never forwards host `HERDR_*` variables. Guest Herdr runs as a normal guest-local multiplexer.

## Security requirements

- Treat the complete workbench as hostile.
- Enforce network and capability policy outside the guest.
- Never mount the host home directory into a workbench.
- Never forward host SSH credentials or an SSH agent.
- Never expose a host Docker socket or cloud configuration.
- Never forward or mount a host Herdr socket, API, configuration, or state.
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
- mounted persistent stores;
- transport state;
- detected drift;
- the most recent lifecycle error.

Inspection must answer: "What can this workbench reach and authorize now?"

## Failure behavior

If VM start fails, ADE leaves persistent stores unchanged and reports the failed lifecycle operation.

If policy verification fails, ADE does not open the terminal session.

If SSH setup fails, ADE closes temporary resources and leaves the VM state visible through `ade inspect`.

If a terminal disconnects, its login shell and foreground children can terminate. Independently detached or multiplexed processes can continue while the VM remains running.

If normal stop times out, ADE reports the timeout. The user can request `ade stop --force`.

If a persistent store is full or unavailable, ADE reports the affected store and operation. It does not reimage or delete data automatically.

## ADE acceptance criteria

The ADE model is accepted when:

- `ade start work` starts or enters the `work` VM;
- `ade start personal` starts or enters a separate `personal` VM;
- both workbenches can run at the same time;
- interactive shells work when Herdr is absent;
- Microsandbox 0.6.10 passes the lifecycle, network, and SSH regression suite;
- `msb ssh serve --help` exposes `--stdio` and `--no-inactivity-timeout`;
- `ade exec` runs a bounded remote command;
- concurrent terminal sessions work in one VM;
- terminal resize and signals work;
- an idle interactive session does not hit the Microsandbox inactivity timeout;
- a new `ade start` session works after a previous terminal disconnects;
- stop and start preserve the root while `ade inspect` continues to report `root_integrity = Not_attested`;
- stop terminates guest processes but preserves the root and declared stores;
- reimage replaces the root and preserves declared stores;
- reimage does not claim to clean persistent data;
- the host home, credentials, SSH agent, and host Herdr state are absent from each VM;
- no host `HERDR_*` variables reach a VM;
- guest root cannot disable externally enforced egress policy;
- unapproved destinations and other workbench stores remain unreachable;
- V1 rejects workbench configurations that request protected capabilities;
- `ade inspect` reports no active protected capabilities in V1;
- transport routes only to the selected workbench instance and run generation;
- lifecycle mutation that wins before transport validation causes a generation or instance error;
- a connection lease that wins opens the stream before lifecycle mutation continues;
- all lifecycle, drift, policy, storage, and transport failures use structured ADE errors.

## Default image integration criteria

The default guest image is accepted when:

- guest Herdr starts from the generic terminal session;
- Herdr is absent from the ADE transport and lifecycle path;
- host and guest Herdr versions can differ;
- optional outer Herdr `Ctrl-A` and guest Herdr `Ctrl-B` routing works;
- guest Herdr layout state survives reimage;
- `HERDR_CONFIG_PATH` points to a config file under `/var/lib/ade-state/herdr`;
- durable Herdr config and session data remain in that state area;
- `HERDR_SOCKET_PATH` resolves the runtime socket under `/run`;
- guest-local `HERDR_*` values do not come from the host;
- the initial guest configuration disables pane history and automatic agent restore.

## Herdr UX tradeoff

The SSH-first workflow runs Herdr entirely inside the guest. It cannot use local-client desktop bridges such as Herdr image clipboard paste.

ADE will not add Herdr protocol knowledge to restore this feature. A future need should use a generic file-transfer mechanism.

## Non-goals

The first version does not provide:

- per-agent isolation inside one VM;
- an ADE agent dashboard;
- ADE-managed tabs, panes, agents, or worktrees;
- a multiplexer plug-in system;
- Herdr remote attach as an ADE protocol;
- automatic agent conversation restore;
- automatic checkpoints on start or reimage;
- complete persistent-data cleanup through reimage;
- cloud-hosted workbenches;
- multi-user collaboration.

## Sources

- [Herdr: How to work](https://herdr.dev/docs/how-to-work/) for the SSH-first guest workflow.
- [Herdr: Configuration](https://herdr.dev/docs/configuration/) for guest config and socket path overrides.
- [Herdr: Config reference](https://herdr.dev/docs/config-reference/) for worktree, pane-history, and agent-restore settings.
- [Microsandbox: SSH](https://docs.microsandbox.dev/sandboxes/ssh) for stdio `ProxyCommand` transport.
- [Microsandbox: SSH commands](https://docs.microsandbox.dev/cli/ssh-commands) for inactivity-timeout behavior.
- [Microsandbox 0.6.10](https://github.com/superradcompany/microsandbox/releases/tag/v0.6.10) for the first pinned timeout-capable release.
