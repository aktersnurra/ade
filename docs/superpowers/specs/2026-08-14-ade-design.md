# ADE Design

**Status:** Approved design

**Supersedes:** [`2026-08-06-gatekeep-design.md`](2026-08-06-gatekeep-design.md)

## Product name

ADE means **Agent Development Environment**. It is a local, disposable development environment in which coding agents work.

Names have one meaning throughout the system:

- `ade` is the product and command-line interface.
- A `gatekeeper` is the host subsystem that mediates access to one external service.
- A `capability` is scoped authority granted through a gatekeeper.
- A `workspace` is persistent project state.
- A `session` is disposable compute attached to one workspace.

Cloudflare OS inspired the gatekeeper terminology. Cloudflare describes a Gatekeeper as service-specific software that moderates access to an external resource, not as the capability itself.

## Goal

ADE launches disposable Linux development sessions with persistent, classified workspaces. A session provides SSH, tmux, Pi, development tools, package installation, and guest-local containers without exposing ambient host authority.

The intended interaction is:

```text
ade work
  -> checkpoint the workspace
  -> start a disposable Microsandbox microVM
  -> attach the persistent workspace
  -> apply network and capability policy
  -> enter guest tmux over SSH
```

ADE is glue around existing infrastructure. It does not implement a hypervisor, VM network stack, container runtime, secret store, or general-purpose identity platform.

## Scope

The first usable version supports:

- one user on an admin-controlled machine;
- macOS first and Artix Linux validation second;
- Microsandbox as the microVM substrate;
- a flake-defined, Nix-built OCI workstation image;
- directory-backed persistent workspaces;
- declarative Git repository seeding;
- stopped-only workspace checkpoints;
- SSH into guest-local tmux;
- guest-local package installation and containers;
- coarse workspace classification;
- a small set of service-specific gatekeepers;
- append-only capability and lifecycle receipts.

The base image is replaceable. Workspace, session, network, and capability policy must not depend on Nix-specific behavior.

## Security model

### Trust boundary

The microVM is the boundary around arbitrary guest code. Every process in a session is treated as equally untrusted and equally able to invoke any interface reachable from that session.

The guest does not receive:

- the host home directory;
- host SSH credentials or agent forwarding;
- host Docker sockets, contexts, or credentials;
- host AWS configuration or Kubernetes configuration;
- host-global Pi state;
- 1Password state;
- raw long-lived service credentials;
- a generic host command channel.

### Disposable session, persistent workspace

A session root disk is disposable. The attached workspace persists independently.

Destroying a session must discard root-disk changes while preserving the workspace. Resetting a session does not clear the workspace's security classification because the workspace may contain protected source code, generated artifacts, logs, or derived information.

Snapshots and restored copies inherit the source workspace classification.

### Network zones

ADE uses coarse zones rather than attempting precise byte-level information-flow tracking.

| Zone | Public egress | Protected capabilities | Intended use |
| --- | --- | --- | --- |
| `public` | Open public network; host/private ranges denied | None | public and personal exploration |
| `work` | Allowlisted or gatekeeper-mediated | Yes | protected source and company services |
| `sealed` | No direct egress | Explicit capabilities only | sensitive or adversarial work |

Open public egress and protected capabilities cannot coexist in the same authority boundary. Once a workspace observes protected information, it cannot be reopened in `public` mode without creating a separate clean workspace.

### Capabilities

A capability is session-bound authority with:

- a service-specific gatekeeper;
- a resource scope;
- allowed operations;
- allowed response destinations;
- a workspace classification requirement;
- an expiry;
- a request budget;
- an approval policy;
- a policy digest.

The guest receives an opaque capability handle. The handle is not an external-service credential and is valid only for the bound session and policy.

### Gatekeepers

A gatekeeper is a host-side reference monitor for one external service. It:

1. authenticates the session and capability handle;
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

The guest cannot approve its own request. Approval binds the capability, resource, operation, request digest, session, workspace, expiry, and nonce.

### Observation receipts

ADE records broker-mediated observations conservatively. A receipt contains:

- session and workspace identity;
- workspace classification before and after the operation;
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
  ade CLI and OCaml domain core
    |- configuration parser and verifier
    |- workspace lifecycle
    |- session lifecycle
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
    |- Pi and development tools
    |- Nix and opam package installation
    |- guest-local tmux
    |- guest-local container runtime
    |- persistent /workspace mount
    `- capability client
```

### Microsandbox adapter

ADE wraps the `msb` command-line interface behind one narrow adapter. The adapter owns:

- local image import and lookup;
- sandbox creation, inspection, start, stop, and removal;
- resource limits;
- directory-backed named volumes;
- network policy;
- SSH and command execution;
- lifecycle error normalization;
- version-specific workarounds.

No Microsandbox command syntax appears in the domain core.

### Nix-built workstation image

The workstation image is defined by [`spike/nix-workstation/flake.nix`](../../../spike/nix-workstation/flake.nix) during validation and will move to a production image module after the design is accepted.

The image is built for the guest architecture, not the host architecture. On macOS, ADE may use a temporary Linux Microsandbox builder to produce the `aarch64-linux` OCI archive.

The initial image contains Bash, Git, Jujutsu, tmux, SSH, Nix, OCaml, opam, dune, Neovim, standard build tools, and network utilities. The package list remains declarative and replaceable.

### Workspace storage

Directory-backed Microsandbox volumes are the initial supported storage mechanism. They passed persistence, recreation, and stopped-only copy-on-write checkpoint tests on macOS.

Disk-backed named volumes are not supported in the initial version because Microsandbox 0.6.8 showed unreliable reuse behavior during the spike.

Workspace creation may declare repositories to seed:

```ocaml
repository ~source:"git@github.com:example/project.git" ~destination:"project"
```

ADE clones each repository only when its destination is absent. It does not continuously reconcile or overwrite local changes.

### Checkpoints

Before a session starts, ADE stops all owners of the workspace and creates a host-native checkpoint:

- APFS copy-on-write copy on macOS;
- Btrfs snapshot on Artix when available;
- a clearly reported full copy fallback otherwise.

Restore is allowed only while no session or guest container owns the workspace.

### Guest-local containers

Containers run inside the microVM. ADE never mounts the host Docker socket. Docker-in-Docker passed the macOS Microsandbox spike; production acceptance still requires a representative Testcontainers project.

## Domain model

The OCaml core models lifecycle states explicitly:

```text
RawConfig -> ParsedConfig -> VerifiedConfig

AbsentWorkspace -> SeededWorkspace -> CheckpointedWorkspace

DeclaredSession -> StartingSession -> RunningSession
                -> StoppedSession -> RemovedSession

RequestedCapability -> AuthorizedCapability
                    -> AppliedEffect | DeniedEffect | ApprovalRequired
```

Important invariants:

- only a `VerifiedConfig` may create a session;
- only a `CheckpointedWorkspace` may attach read-write;
- a session has exactly one zone and workspace classification;
- `public` egress cannot coexist with protected capabilities;
- only an `AuthorizedCapability` may reach a gatekeeper adapter;
- credentials never appear in durable domain values;
- workspace recreation preserves classification;
- restore requires a stopped and unowned workspace.

Expected failures use structured variants with a stable code, human-readable message, and machine-readable context. Exceptions are reserved for programming errors.

## Configuration surface

The eventual OCaml DSL should describe outcomes rather than Microsandbox flags:

```ocaml
workbench "work"
  ~zone:Work
  ~image:Images.nix_workstation
  ~workspace:(workspace "work" ~classification:(Work "company"))
  ~repositories:[ ... ]
  ~capabilities:[ Github.work; Model.approved; Signing.agent ]
  ~resources:{ cpus = 4; memory_gib = 8; root_disk_gib = 24 }
```

The DSL compiles into a verified internal specification. It does not execute effects while parsing configuration.

## Delivery slices

### Slice 1: Microsandbox lifecycle launcher

Deliver `ade work`, `ade stop`, `ade reset`, and `ade inspect` around the validated Nix-built image and directory-backed workspace.

Success means:

- `ade work` checkpoints, boots, mounts, and enters tmux;
- reset discards root state and preserves workspace state;
- host credentials and sockets remain absent;
- all Microsandbox failures become structured ADE errors.

### Slice 2: Declarative workspaces and classifications

Deliver repository seeding, workspace metadata, coarse zones, checkpoint receipts, and restore.

Success means:

- repositories clone once into an empty workspace;
- labels survive reset, snapshot, and restore;
- a protected workspace cannot enter public mode;
- restore is refused while the workspace is owned.

### Slice 3: Gatekeeper protocol and model capability

Deliver the authenticated guest-to-host protocol, opaque session-bound handles, policy evaluation, receipts, and one model-provider gatekeeper.

Success means:

- the provider credential never enters the guest;
- only the configured endpoint/model is reachable;
- requests and observations are attributed to the session and workspace;
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
- Adapter contract tests exercise Microsandbox lifecycle behavior and known version quirks.
- Integration tests verify VM isolation, no-network mode, allowlists, SSH/tmux, workspace persistence, root disposal, package installation, and nested containers.
- Security tests verify absence of host home, SSH agent, Docker socket, cloud configuration, and raw credentials.
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
- perfect reproducibility for mutable workspace contents.

## Sources

- [Cloudflare OS](https://blog.cloudflare.com/cloudflare-os/) for service-specific Gatekeepers, capabilities, approvals, and observation tracking.
- [`2026-08-14-microsandbox-validation.md`](2026-08-14-microsandbox-validation.md) for substrate evidence and known limitations.
