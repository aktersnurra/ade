# ADE Design

**Status:** Approved design

**Updated:** 2026-08-18 for named workbench VMs and generic terminal sessions

**Supersedes:** [`2026-08-06-gatekeep-design.md`](2026-08-06-gatekeep-design.md)

## Product name

ADE means **Agent Development Environment**. It is a local development environment in which coding agents work.

Names have one meaning throughout the system:

- `ade` is the product and command-line interface.
- A `gatekeeper` is the host subsystem that mediates access to one external service.
- A `capability` is scoped authority granted through a gatekeeper.
- A `workbench` is a named VM and policy boundary, such as `work` or `personal`.
- A `workbench instance` is the current Microsandbox VM for a workbench.
- A `project store` is persistent, classified project data.
- A `terminal session` is native interactive PTY execution in a running workbench.

Cloudflare OS inspired the gatekeeper terminology. Cloudflare describes a Gatekeeper as service-specific software that moderates access to an external resource, not as the capability itself.

## Goal

ADE manages named Linux workbench VMs with persistent, classified project stores.

A workbench can run many concurrent agents. All agents in one workbench share its filesystem, processes, network policy, and capabilities. Agents that require isolation must use different workbenches.

The intended interaction is:

```text
ade start work
  -> verify the named configuration
  -> stage the project store and deny-by-default external policy
  -> verify base-image provenance, project-store mount, and policy
  -> start and confirm the workbench VM
  -> establish instance- and run-generation-bound native execution
  -> enter the guest shell through `msb exec --tty`
  -> use the shell and guest development tools
```

ADE manages VM lifecycle, persistent storage, policy, and generic terminal transport. Guest tools manage their own processes and state.

ADE is glue around existing infrastructure. It does not implement a hypervisor, VM network stack, container runtime, terminal multiplexer, secret store, or general-purpose identity platform.

## Scope

The first usable version supports:

- one user on an admin-controlled machine;
- one or more named workbenches, such as `work` and `personal`;
- many projects and concurrent agents in each running workbench;
- macOS first and Artix Linux validation second;
- Microsandbox as the microVM substrate;
- a flake-defined, Nix-built OCI workstation image;
- native interactive terminal sessions and guest command execution;
- one explicit persistent project store per workbench;
- declarative Git repository seeding;
- explicit stopped-only project-store checkpoints;
- guest-local package installation and containers;
- coarse workbench and project-store classification;
- a small set of service-specific gatekeepers;
- append-only capability and lifecycle receipts.

The base image is replaceable. Project-store, workbench, network, and capability policy must not depend on Nix-specific behavior.

## Security model

### Trust boundary

A named workbench VM is one hostile security principal. There is no security boundary between agents, projects, or guest processes inside it.

Compromise of one component can compromise the complete workbench. Separate workbenches isolate authority and data domains.

Full compromise of a workbench must not grant reusable authority beyond its externally enforced capability envelope.

The guest does not receive:

- the host home directory;
- host SSH credentials or agent forwarding;
- host Docker sockets, contexts, or credentials;
- host AWS configuration or Kubernetes configuration;
- host-global Pi state;
- host application control sockets, configuration, or state;
- 1Password state;
- raw long-lived service credentials;
- a generic host command channel.

### Persistent workbench and stores

A named workbench keeps its writable root disk across stop and start operations. Its project store persists independently.

Base-image provenance proves that ADE created the writable root from the declared image digest. It does not attest the current guest filesystem.

Guest changes to the writable root are hostile persistent state. ADE records the base-image digest and root generation instead of claiming current-root integrity.

An explicit reimage creates a new workbench root from the approved base image. It preserves the declared project store.

Reimage is not a security reset. The project store remains hostile after reimage.

Reimage does not clear project-store classification. A project store can contain protected source code, generated artifacts, logs, or derived information.

Snapshots and restored copies inherit the source project-store classification.

### Network zones

ADE uses coarse zones rather than attempting precise byte-level information-flow tracking.

| Zone | Public egress | Protected capabilities | Intended use |
| --- | --- | --- | --- |
| `public` | Open public network; host/private ranges denied | None | public and personal exploration |
| `work` | Allowlisted or gatekeeper-mediated | Yes | protected source and company services |
| `sealed` | No direct egress | Explicit capabilities only | sensitive or adversarial work |

Open public egress and protected capabilities cannot coexist in the same authority boundary. Once a project store observes protected information, it cannot be attached in `public` mode without creating a separate clean project store.

### Capabilities

A capability is authority bound to a named workbench, its current VM instance, and its verified policy. It has:

- a service-specific gatekeeper;
- a resource scope;
- allowed operations;
- allowed response destinations;
- a project-store classification requirement;
- an expiry;
- a request budget;
- an approval policy;
- a policy digest.

The guest receives an opaque capability handle. The handle is not an external-service credential. It is valid only for the bound workbench instance and policy.

### Gatekeepers

A gatekeeper is a host-side reference monitor for one external service. It:

1. authenticates the workbench instance and capability handle;
2. validates the resource and operation;
3. obtains or holds the real credential outside the guest;
4. constructs or mediates the service request;
5. filters and classifies the response;
6. requests approval for configured effects;
7. records observations and external effects.

Initial gatekeepers are:

- model provider;
- GitHub;
- Git signing;
- restricted SSH.

Protected destinations must not also be reachable through an unmediated path.

Generic dummy-secret substitution is not the security model. The Microsandbox spike proved that an allowed service can reflect a substituted credential back to the guest. Credential substitution may be used only inside a service-specific adapter whose destination and response behavior are understood.

### Approvals

Approvals occur at meaningful effect boundaries, not for ordinary shell commands.

Examples:

- reading an approved repository may be automatic;
- pushing an approved feature branch may be automatic;
- pushing a protected branch requires approval;
- merging a pull request requires approval;
- signing a release requires approval;
- mutating production infrastructure is outside the initial version.

The guest cannot approve its own request. Approval binds the capability, resource, operation, request digest, workbench instance, project store, expiry, and nonce.

### Observation receipts

ADE records broker-mediated observations conservatively. A receipt contains:

- workbench, VM instance, and project-store identity;
- project-store classification before and after the operation;
- capability and gatekeeper;
- resource and operation;
- response classification;
- approval decision when applicable;
- policy digest;
- timestamp and result.

ADE does not claim complete information-flow tracking when unmediated input or output exists.

## Architecture

```text
Host
  terminal or optional host multiplexer
    `- ade CLI

  ade CLI and OCaml domain core
    |- configuration parser and verifier
    |- project-store lifecycle
    |- named workbench lifecycle
    |- native terminal and command execution
    |- Microsandbox adapter
    |- gatekeeper supervisor
    `- append-only receipts

  service gatekeepers
    |- model provider
    |- GitHub
    |- signing
    `- restricted SSH

Microsandbox microVM
  Nix-built OCI workstation
    |- generic login shell
    |- Pi and development tools
    |- Nix and opam package installation
    |- guest-local container runtime
    |- persistent project-store mount
    `- capability client
```

### Microsandbox adapter

ADE wraps the `msb` command-line interface behind one narrow adapter. The adapter owns:

- local image import and lookup;
- sandbox creation, inspection, start, stop, and removal;
- resource limits;
- directory-backed named volumes;
- network policy;
- interactive `msb exec --tty` attachment;
- bounded `msb exec --no-tty` and streamed `msb exec --stream` commands;
- a short operation-start lease before native attachment is accepted;
- lifecycle error normalization;
- version-specific workarounds.

No Microsandbox command syntax appears in the domain core.

Slice 1 pins Microsandbox 0.6.10 and qualifies its lifecycle, root and project-store persistence, networking, native execution, PTY, and streaming behavior before ADE claims support.

### Nix-built workstation image

The workstation image was validated as a spike and is now maintained at [`images/nix-workstation/flake.nix`](../../../images/nix-workstation/flake.nix).

The image is built for the guest architecture, not the host architecture. On macOS, ADE may use a temporary Linux Microsandbox builder to produce the `aarch64-linux` OCI archive.

The initial production image contains Bash, Git, Jujutsu, SSH, Nix, OCaml, opam, dune, Neovim, standard build tools, and network utilities. A terminal multiplexer is not part of V1 image acceptance. The package list remains declarative and replaceable.

### Persistent storage

Each workbench declares one persistent project store with a stable guest mount path at `/workspace`.

Source repositories, worktrees, and artifacts live under `/workspace`.

The writable root preserves guest-installed tools and configuration across stop/start. V1 does not preserve guest-tool configuration across reimage and does not persist a complete guest home directory.

Directory-backed Microsandbox volumes are the initial supported storage mechanism. They passed persistence, recreation, and stopped-only copy-on-write checkpoint tests on macOS.

Disk-backed named volumes are not supported in the initial version because Microsandbox 0.6.8 showed unreliable reuse behavior during the spike.

Project-store creation may declare repositories to seed:

```ocaml
repository ~source:"git@github.com:example/project.git" ~destination:"project"
```

ADE clones each repository only when its destination is absent. It does not continuously reconcile or overwrite local changes.

### Checkpoints

ADE creates a host-native project-store checkpoint only when the user requests one:

- APFS copy-on-write copy on macOS;
- Btrfs snapshot on Artix when available;
- a clearly reported full copy fallback otherwise.

Restore is allowed only while no workbench instance or guest container owns the project store. Automatic checkpoint policy is outside the first lifecycle slice.

### Guest-local containers

Containers run inside the microVM. ADE never mounts the host Docker socket. Docker-in-Docker passed the macOS Microsandbox spike; production acceptance still requires a representative Testcontainers project.

## Domain model

The OCaml core models lifecycle states explicitly:

```text
RawConfig -> ParsedConfig -> VerifiedConfig

AbsentProjectStore -> SeededProjectStore

AbsentWorkbench -> StartingWorkbench -> RunningWorkbench
RunningWorkbench -> StoppingWorkbench -> StoppedWorkbench
StoppedWorkbench -> ReimagingWorkbench -> StoppedWorkbench

RequestedTerminal -> GenerationBoundTransport -> AttachedTerminal
RequestedExec -> GenerationBoundTransport -> CompletedExec

RequestedCapability -> AuthorizedCapability
                    -> AppliedEffect | DeniedEffect | ApprovalRequired
```

Configuration declaration is not a runtime state.

Important invariants:

- only a `VerifiedConfig` may create a workbench instance;
- `RunningWorkbench` means the current instance has verified base-image provenance, store, policy, and run-generation postconditions;
- each absent-or-stopped to running transition creates a host-managed run generation;
- entry into an already-running workbench reuses its current generation;
- stop invalidates the current generation;
- terminal entry requires a `RunningWorkbench` and generation-bound native execution;
- a short operation-start lease verifies the instance and generation until native attachment succeeds;
- attachment fails if the verified instance or generation changes before it becomes ready;
- a losing attach cannot use `msb exec` to restart a workbench that stop already won;
- ADE releases the lifecycle lock after operation-start validation, not for the terminal session;
- many terminal clients, projects, and agents may coexist in one workbench;
- all agents in one workbench share its zone, project-store classification, guest control APIs, and capabilities;
- ADE does not persist an agent registry or provide agent orchestration UI;
- `public` egress cannot coexist with protected capabilities;
- only an `AuthorizedCapability` may reach a gatekeeper adapter;
- credentials never appear in durable domain values;
- writable-root integrity is always `Not_attested`;
- project-store recreation preserves classification;
- reimage preserves the project store but does not establish its integrity;
- restore requires a stopped and unowned project store.

Expected failures use structured variants with a stable code, human-readable message, and machine-readable context. Exceptions are reserved for programming errors.

## Configuration surface

The eventual OCaml DSL should describe outcomes rather than Microsandbox flags:

```ocaml
workbench "work"
  ~zone:Work
  ~image:Images.nix_workstation
  ~project_store:
    (project_store "work"
       ~mount:"/workspace"
       ~classification:(Work "company"))
  ~repositories:[ ... ]
  ~capabilities:[]
  ~resources:{ cpus = 4; memory_gib = 8; root_disk_gib = 24 }
```

This is the V1 lifecycle configuration. Later gatekeeper slices can add protected capabilities.

The DSL compiles into a verified internal specification. It does not execute effects while parsing configuration.

## Delivery slices

### Slice 1: Microsandbox lifecycle launcher

Deliver `ade list`, `ade start <workbench>`, `ade exec <workbench> -- command`, `ade stop <workbench>`, `ade reimage <workbench>`, and `ade inspect <workbench>` around the validated Nix-built image and directory-backed stores. Pin Microsandbox 0.6.10 for this slice.

Success means:

- Microsandbox 0.6.10 passes the lifecycle, root and project-store persistence, network, and native execution regression suite;
- `start` stages the project store and deny-by-default policy before guest execution;
- `Running` certifies base-image provenance, the project-store mount, and external policy for the current instance;
- a running workbench with drift rejects entry instead of changing in place;
- `start` enters a native PTY session with `msb exec --tty` after it verifies the running instance;
- `exec` uses bounded `msb exec --no-tty` execution and selects `--stream` only for byte-streaming operations;
- concurrent terminal clients can enter one running workbench;
- native execution binds to the verified VM instance and run generation;
- lifecycle mutation and attachment are serialized by the short operation-start lease;
- stale attachment loses with a structured error, or attachment wins before mutation continues;
- a losing attachment cannot implicitly restart a stopped workbench;
- the terminal session works with a minimal image and no multiplexer;
- stop preserves the root and project store while it terminates guest processes;
- reimage replaces root state and preserves the project store without claiming to clean it;
- per-workbench lifecycle locks prevent create, start, stop, and reimage races;
- the Microsandbox adapter validates the instance and generation before native attachment succeeds;
- native PTY sessions remain attached until client exit or lifecycle stop;
- native execution rejects cross-workbench, cross-instance, and stale-generation routing;
- ambient host environment values remain absent unless ADE explicitly passes them;
- Slice 1 rejects configurations that request protected capabilities;
- all Microsandbox, policy, storage, drift, and transport failures become structured ADE errors.

### Slice 2: Declarative project stores and classifications

Deliver repository seeding, project-store metadata, coarse zones, checkpoint receipts, and restore.

Success means:

- repositories clone once into an empty project store;
- labels survive reimage, snapshot, and restore;
- a protected project store cannot enter public mode;
- restore is refused while the project store is owned.

### Slice 3: Gatekeeper protocol and model capability

Deliver the authenticated guest-to-host protocol, opaque workbench-instance-bound handles, policy evaluation, receipts, and one model-provider gatekeeper.

Success means:

- the provider credential never enters the guest;
- only the configured endpoint/model is reachable;
- requests and observations are attributed to the workbench instance and project store;
- revocation immediately blocks new calls.

### Slice 4: GitHub, signing, and restricted SSH

Add service-specific adapters and effect approvals.

Success means:

- GitHub scope is limited by repository and operation;
- signing returns signatures without exposing private keys;
- SSH is limited to configured destinations and identities;
- protected effects cannot self-approve.

## Verification

- Unit tests cover parsers, state transitions, policy joins, classification rules, and structured errors.
- Property tests prove invalid lifecycle and capability combinations never reach effect adapters.
- Adapter contract tests exercise pinned Microsandbox 0.6.10 lifecycle, `exec --tty`, `exec --no-tty`, `exec --stream`, and known version behavior.
- Integration tests verify VM isolation, pre-start deny-by-default policy, allowlists, native terminal sessions, bounded and streamed commands, concurrent clients, stop/disconnect handling, stale-generation and instance replacement rejection, project-store persistence, explicit root reimage, package installation, and guest-local containers.
- Security tests run adversarial guest probes for the host home, SSH agent, Docker socket, cloud configuration, raw credentials, forbidden destinations, and other workbench stores.
- Gatekeeper tests include credential-reflection services, redirects, private-address targets, response filtering, replay, expiry, and revocation.
- The same acceptance suite must pass on macOS and Artix before cross-platform support is claimed.

## Explicit non-goals

The initial version does not provide:

- a new VM or container runtime;
- enterprise identity or multi-user collaboration;
- complete byte-level taint tracking;
- arbitrary service integration;
- a generic authenticated HTTP proxy;
- automatic production or cloud administration;
- transparent host filesystem access;
- host Docker access;
- perfect reproducibility for mutable project-store contents;
- per-agent isolation within one workbench;
- an in-guest agent supervisor;
- an ADE agent dashboard or terminal orchestration UI;
- terminal-multiplexer installation, integration, or state preservation;
- guest-tool configuration persistence across reimage;
- automatic agent conversation restore.

## Sources

- [Cloudflare OS](https://blog.cloudflare.com/cloudflare-os/) for service-specific Gatekeepers, capabilities, approvals, and observation tracking.
- [`2026-08-14-microsandbox-validation.md`](2026-08-14-microsandbox-validation.md) for substrate evidence and known limitations.
- [`2026-08-18-named-workbench-terminal-design.md`](2026-08-18-named-workbench-terminal-design.md) for named VMs and generic terminal sessions.
