# SmolVM Workbench Design

**Date:** 2026-08-29  
**Status:** Approved architecture; implementation not started

## Objective

ADE is a small, single-user tool for running coding agents inside named local Linux
workbench VMs. Each workbench is a durable boundary for one identity and data domain,
such as `work`, `personal`, `offline`, `cloud`, or `quarantine`.

ADE provides:

- automatic create, start, attach, stop, restart, reimage, backup, restore, and destroy;
- reproducible workstation images and trusted configuration;
- a storage-backed, machine-owned `/workspace`;
- Docker and Herdr inside each workbench;
- per-workbench resources and network policy;
- tightly scoped credentials and capabilities;
- automatic rotation where the provider genuinely supports short-lived credentials.

ADE uses `smol-machines/smolvm` as the VM runtime. SmolVM remains authoritative for
machine existence and runtime state. ADE is policy and transaction glue, not another VM
manager.

## Scope

V1 targets one user on one Apple-silicon Mac. It manages several local named
workbenches. Many mutually trusted Herdr agents, worktrees, shells, and sessions may run
inside one workbench.

V1 is not:

- a multi-host control plane;
- a daemon or distributed scheduler;
- a hypervisor, network stack, container runtime, secret store, or terminal transport;
- an isolation boundary between agents inside one workbench;
- a general identity broker or provider abstraction framework;
- a secure-erasure system;
- a remote backup service.

The smallest implementation that satisfies the local workbench use case is preferred.

## Terminology

- **Workbench:** one named SmolVM machine and its declared authority posture.
- **Declaration:** host-owned configuration describing one workbench.
- **Materialization:** trusted configuration installed into the guest from the declaration.
- **Workspace:** machine-owned persistent data at `/workspace`.
- **Reimage:** reconstruct trusted guest state while preserving validated workspace data.
- **Destroy:** remove the instantiated machine and all machine-owned state.
- **Generation:** one installed version of a short-lived credential set.

There is no `reset` or `nuke` command.

## Runtime choice

ADE migrates from Microsandbox to `smol-machines/smolvm` for lifecycle and configuration
fit:

- persistent named machines;
- OCI images and Smolfiles;
- storage-backed `/workspace`;
- native start, stop, shell, exec, copy, pack, and restore operations;
- declarative resources, mounts, networking, and secret references.

The migration does not imply stronger isolation. Both products use the libkrun VMM
family, but have different builds, versions, guest agents, surrounding implementations,
and capability surfaces. ADE independently qualifies the complete SmolVM behavior it
relies on.

The initially audited upstream release is SmolVM `v1.13.1`, commit `62f5f04`, released
2026-08-27. The implementation plan must pin the exact approved source revision rather
than relying on `latest`.

## Implementation language

The host-side `ade` command is one Nix-built OCaml binary.

OCaml is used for the parts that benefit from explicit types and exhaustive state
handling:

- declaration validation;
- lifecycle convergence;
- process execution and error normalization;
- reimage transaction phases and recovery;
- backup manifests and validation;
- credential expiry and generation state.

The implementation remains deliberately small. V1 does not introduce Eio, a long-lived
ADE service, a plugin framework, or a second machine-state database. Sequential standard
library operations, `Cmdliner`, JSON, TOML, and digest support are sufficient.

Small guest helpers are installed by the workstation image. They perform narrowly scoped
operations such as workspace export, workspace restore, secret installation, trusted
configuration materialization, service startup, and health checks. They do not become a
second general guest agent.

A helper running in an existing mutable machine is not a trusted attestation mechanism.
In particular, an export produced by the old guest is treated as untrusted input: host
validation can establish archive integrity and extraction safety, but cannot prove that a
compromised guest included every prior workspace byte. A helper in a freshly recreated,
pinned image is trusted only for the bounded restore/materialization operation.

## Architecture

```text
Host
├── ade                         OCaml CLI
├── workbench declarations     trusted, version controlled
├── Nix/OCI image inputs       trusted, pinned
├── Herdr configuration source trusted
├── SmolVM binary              pinned and qualified
├── reimage journals           active transactions only
├── workspace backups          explicit, local by default
└── credential sources         host Keychain or declared host references
         │
         │ native SmolVM lifecycle, shell, exec and secret references
         ▼
Named workbench VM
├── trusted guest materialization
│   ├── /etc/ade/workbench.toml
│   ├── /etc/herdr/herdr.toml
│   ├── installed tools
│   └── service definitions
├── persistent untrusted data
│   └── /workspace
├── persistent mutable runtime state
│   ├── Herdr runtime state
│   ├── Docker state
│   └── caches and root changes
└── ephemeral state
    ├── /tmp
    ├── /run
    ├── /dev/shm
    └── /run/ade/secrets
```

The host repository is not mounted into a normal workbench. Repositories live on the
machine's persistent virtual storage under `/workspace`.

## Trust model

A workbench VM is one security principal. Agents, tools, containers, projects, and guest
processes inside one workbench are mutually trusted at VM level. Any process may read the
workbench filesystem and use capabilities deliberately made available to that workbench.

Use different workbenches when identities, data, or authority must not mix.

The host, host OS, ADE, SmolVM CLI, hypervisor backend, libkrun, and deliberately
forwarded capabilities are inside the trusted computing base. Guest root is untrusted.

No restored workspace data is implicitly trusted as executable configuration.

## Declaration and trusted configuration

Each workbench has one explicit host-owned declaration. V1 has no profile inheritance or
configuration language beyond the fields the implementation consumes.

A declaration identifies:

- workbench name;
- pinned image digest and Smolfile;
- CPU, memory, root overlay, and workspace storage sizes;
- network posture and positive hostname/CIDR allowlists;
- trusted dotfile and Herdr configuration sources;
- whether Docker and Herdr are enabled;
- credential and SSH-agent capabilities;
- backup location and retention policy.

The Smolfile, image digest, Nix inputs, ADE declaration, and Herdr configuration source
remain on the host or in version control. Destroying a machine does not remove them.

Trusted guest configuration is reconstructed under `/etc/ade` and `/etc/herdr`. It is
never loaded from agent-writable `/workspace`.

Durable Herdr data under `/workspace/.ade` may contain only schema-validated, non-
executable data such as workspace names or layout. It cannot specify commands, hooks,
plugins, or executable paths. Invalid data produces a safe empty state and is not run
automatically before user attachment.

## Boot and service startup

The pinned image's declared entrypoint does not intentionally launch Herdr agents or
workspace-provided hooks. A compromised persistent guest root may nevertheless alter its
own future startup; reimage is what removes that mutable root.

A normal ADE start performs:

```text
start SmolVM machine using its declared network posture
→ install the current credential generation
→ provide the populated dedicated SSH-agent socket, when enabled
→ start Docker, when enabled
→ start Herdr, when enabled
→ run focused health checks
```

Trusted configuration is built into the image or materialized immediately after creation
from the host declaration. It is not reloaded from `/workspace`.

For maintenance on an existing machine, ADE does not inject secrets, start Docker or
Herdr, or provide a populated SSH agent. SmolVM `machine update` cannot change an existing
machine's SSH-agent setting or hostname/CIDR allowlists. ADE therefore launches
maintenance with an empty dedicated SSH agent and the machine's existing network posture;
it does not claim a stronger networkless maintenance mode that the audited CLI cannot
express. The temporary host mount exposes only a fresh transaction staging directory.

## Persistent state contract

| State | Stop/start | Reimage | Destroy |
| --- | ---: | ---: | ---: |
| Host declarations and image pins | unchanged | unchanged | unchanged |
| Guest `/etc/ade`, `/etc/herdr`, binaries | preserve | reconstruct | delete |
| `/workspace` | preserve | preserve | delete |
| Non-executable durable ADE/Herdr metadata | preserve | preserve | delete |
| Herdr mutable runtime state | preserve | wipe | delete |
| Docker state and images | preserve | wipe | delete |
| package and build caches | preserve | wipe | delete |
| guest root modifications | preserve | wipe | delete |
| `/tmp`, `/run`, `/dev/shm` | wiped after restart | wipe | delete |
| `/run/ade/secrets` | reinject after restart | reinject | delete |
| interactive LLM login state | preserve | wipe | delete |

SmolVM owns `/workspace` as part of machine storage. It does not have an independently
retained lifecycle. ADE must export and restore it before deleting a machine during
reimage.

Reimage means:

```text
clean execution substrate + same potentially untrusted workspace
```

It does not certify that Git hooks, source files, build scripts, workflows, or untracked
executables in the workspace are safe. Suspected compromise requires a separate
quarantine and inspection procedure.

## Public commands

```text
ade create NAME
ade start NAME
ade attach NAME
ade exec NAME -- COMMAND [ARG...]
ade stop NAME
ade restart NAME
ade status [NAME]
ade reimage NAME
ade backup NAME
ade restore NAME BACKUP --replace-workspace
ade restore BACKUP --as NAME
ade pack NAME
ade unpack PACK --as NAME
ade destroy NAME
ade credentials status [NAME]
ade credentials rotate [NAME|--due]
ade credentials revoke NAME PROVIDER
```

`attach` starts a stopped machine, completes trusted startup, then attaches to Herdr using
SmolVM's native execution transport. ADE does not use SSH as its terminal transport.
Leaving an attachment does not stop the machine.

## Command convergence

- Creating an absent machine creates it from the declaration.
- Creating an existing machine succeeds only if it matches the declaration; otherwise it
  reports drift.
- Starting a running machine succeeds as a no-op after verifying required postconditions.
- Stopping a stopped machine succeeds as a no-op.
- Restarting a stopped machine starts it.
- Attaching to a stopped machine starts it, installs current credentials, starts Herdr,
  and attaches.
- Destroying an absent machine succeeds as a no-op only when no unfinished ADE
  transaction exists.
- A completed reimage leaves the workbench stopped regardless of its initial state.
- An interrupted reimage resumes, rolls back to a clean machine plus the preserved
  workspace, or reports that explicit recovery is required.
- Backup restores the source's original running/stopped state after export.
- Pack refuses a running source; unpack creates only an absent target name.
- Restore refuses a nonempty workspace without an explicit replacement operation.

ADE serializes lifecycle and maintenance operations with a per-workbench host lock. The
lock is not held for the duration of an interactive attachment.

## Drift

SmolVM remains authoritative for observed machine state. ADE compares that state to the
host declaration.

- A harmless already-satisfied state converges as a no-op.
- Changes SmolVM can safely apply to a stopped machine may be applied by an explicit
  lifecycle operation.
- Changes to image, trusted configuration, storage layout, or security posture require
  reimage unless the qualification suite proves a narrower safe transition.
- ADE does not silently mutate a running workbench to resolve drift.

V1 stores no shadow lifecycle database.

## Reimage transaction

Reimage is an ADE-owned crash-recoverable transaction because SmolVM deletion removes the
machine-owned workspace storage.

### Invariant

ADE never deletes the old machine until it has a complete, parseable workspace export
whose bytes and manifest have passed host validation. This protects against interrupted,
truncated, changed, or unsafe archives. It does not prove completeness against a guest
that was already malicious; that guest already controlled the source workspace.

Until the transaction commits, ADE retains:

- the verified workspace export;
- the old declaration digest;
- the old image digest;
- enough information to reconstruct a clean machine from the previous image and restore
  the exported workspace.

The previous image must remain locally available or fetchable by immutable digest until
commit.

### Sequence

1. Acquire the per-workbench maintenance lock.
2. Write a durable transaction journal.
3. Refuse active Herdr agents unless the user explicitly forces quiescence.
4. Quiesce Herdr and flush application state.
5. Stop the machine.
6. Attach a fresh transaction-specific host directory at `/mnt/ade-export` using
   `machine update`.
7. Start the old machine for bounded maintenance with no injected secrets, no Docker or
   Herdr startup, and an empty dedicated SSH agent.
8. Copy the pinned export helper into guest tmpfs and export `/workspace` into
   `/mnt/ade-export`.
9. Write and fsync the archive, manifest, staging directory, and host parent directory.
10. Stop the machine and remove the maintenance mount.
11. Validate the untrusted export on the host.
12. Persist the `export_verified` phase.
13. Delete the old machine.
14. Create the new machine from the pinned declaration without injecting credentials or
    starting Docker or Herdr.
15. Attach the staging directory read-only at `/mnt/ade-import`.
16. Start the fresh machine for bounded restore and restore `/workspace` without following
    archive links.
17. Materialize trusted configuration from the host declaration and run credential-free
    qualification checks.
18. Stop the machine and remove the maintenance mount.
19. Persist `committed` and release the lock, leaving the reimaged workbench stopped.

A later `ade start` installs current credentials, supplies the populated dedicated SSH
agent, and starts Docker and Herdr.

A maintenance mount never targets `/workspace`; doing so would hide the storage-backed
workspace being exported. SmolVM's native copy operation is not the general workspace
transfer mechanism because an individual transfer is limited below 4 GiB.

### Journal

The journal contains only active maintenance transaction state:

```text
transaction_id
machine_name
phase
old_image_digest
new_image_digest
old_declaration_digest
new_declaration_digest
staging_path
workspace_manifest_digest
started_at
```

Phases are:

```text
quiescing
exporting
export_verified
old_machine_deleted
new_machine_created
restoring
qualifying
committed
rollback_required
```

Every phase transition is persisted before the next destructive action. If a transaction
is incomplete, `status`, `start`, `attach`, and ordinary `exec` either perform the safe
recovery action or report that maintenance recovery is required. They never start an
arbitrary half-constructed machine.

The journal is not a second lifecycle database and is removed or archived after commit.

## Workspace backup and restore

`ade backup NAME` creates a consistent, validated backup of `/workspace` only. It excludes
root overlay, Docker state, caches, Herdr runtime state, materialized guest
configuration, and ADE-installed tmpfs secrets.

A normal backup uses the same maintenance export and validation rules as reimage. It
records whether the source was running, quiesces and stops it, performs the export, and
then restores that original running/stopped state. Restarting a previously running
workbench performs the normal credential and Herdr startup checks.

`ade pack NAME` explicitly creates a full SmolVM machine artifact. Because upstream pack
creation requires a stopped source, V1 refuses to pack a running workbench and tells the
user to stop it first. A pack may contain root changes, workspace data, Docker data,
caches, login state, and credentials copied to persistent storage by guest code. Packs
are rollback or debugging artifacts, not ordinary workspace backups.

ADE never automatically pushes a pack or backup. Both are local by default and are always
treated as potentially secret-bearing.

Restore operations are typed:

```text
workspace backup → replace /workspace, or create a declared machine under a new name
machine pack      → create an absent machine under a new name
```

`ade unpack PACK --as NAME` refuses when `NAME` already exists. V1 does not replace an
existing machine from a pack; the user must explicitly back up and destroy that machine
first. ADE never silently merges a backup into a nonempty workspace.

## Workspace archive validation

The backup manifest proves integrity only. It does not qualify the workspace as safe to
execute.

The format may preserve:

- directories;
- regular files;
- symlinks;
- hardlinks whose targets remain inside the archive root.

The validator rejects or normalizes:

- absolute or traversing entry names;
- hardlinks outside the archive root;
- device nodes;
- sockets;
- FIFOs;
- setuid and setgid bits;
- Linux file capabilities;
- unexpected UID or GID values.

Restoration never follows an archive-provided symlink while creating later entries.

## Destroy

Destroy removes the SmolVM machine and all machine-owned root, workspace, Docker, Herdr,
cache, login, and tmpfs state. It leaves host declarations and separately retained
backups unchanged.

Interactive destroy requires an explicit choice:

```text
1. Create a workspace backup, then destroy
2. Destroy without creating a backup
3. Abort

Type "destroy NAME" to continue:
```

Noninteractive callers must choose one:

```text
ade destroy NAME --backup-first --confirm-destroy-workspace=NAME
ade destroy NAME --no-backup --confirm-destroy-workspace=NAME
```

ADE does not infer safety from a recent backup because it cannot know whether the
workspace changed afterward. Deletion is logical deletion, not guaranteed physical
erasure from APFS, SSDs, snapshots, or host backups.

## Networking

Network policy belongs to the workbench declaration and is enforced by SmolVM, not by
agent convention.

V1 supports explicit postures that the audited SmolVM CLI can enforce:

- **sealed:** no network;
- **allowlisted:** only declared hostnames and CIDRs;
- **public:** unrestricted SmolVM network access;
- **cloud-specific:** a positive allowlist containing only endpoints required by the
  declared cloud workflow;
- **quarantine:** no network.

SmolVM does not currently expose negative CIDR rules. ADE therefore does not claim that
`public` can exclude every host or private range. Sensitive workbenches use `sealed` or a
positive allowlist instead.

Docker containers must not bypass the VM's declared egress policy. Hostname resolution,
CIDR enforcement, DNS behavior, restart behavior, localhost exposure, and container
egress are blocking qualification tests.

Allowlisting a service hostname is not operation-level authorization. V1 does not build a
service broker to narrow individual API operations.

## Credentials and capabilities

ADE owns credential policy, minting, installation, expiry handling, and revocation where
the provider supports those operations. There is no ADE daemon.

A user-level launchd timer may periodically invoke:

```text
ade credentials rotate --due
```

Each invocation performs bounded work and exits. `start`, `attach`, and `exec` also ensure
that required credentials have sufficient remaining lifetime before use.

### Installation guarantee

ADE's installer writes plaintext credentials only to guest tmpfs under:

```text
/run/ade/secrets/generation-N
```

A `current` symlink is switched atomically after validation. ADE never intentionally
writes generated credentials into guest root storage, `/workspace`, Docker storage,
arguments, logs, or shell history.

ADE cannot prevent guest code from copying a credential into persistent state. Therefore
workspace backups and full-machine packs are always potentially secret-bearing.

### Rotation sequence

```text
mint
→ validate shape, scope and expiry
→ install immutable generation
→ atomically activate current
→ retain previous generation for bounded overlap when necessary
→ revoke previous credential when supported and safe
→ record secret-free audit result
```

If minting or validation fails, ADE leaves the working generation active, reports
unhealthy status, and does not revoke it.

### Due, stopped, and failure behavior

`rotate --due` rotates credentials only for running workbenches. A stopped workbench does
not need an active generation; `start`, `attach`, or `exec` mints or installs one before
starting dependent agents.

ADE rotates before expiry using a declared safety margin rather than relying on exact
host/provider clock agreement. During a provider outage, the current generation remains
active until its real expiry. After expiry, ADE reports the capability unavailable and
does not start a dependent agent with an expired credential.

Emergency revocation removes the active guest generation, stops or marks stale dependent
agents, invokes provider revocation when supported, and records the outcome without the
credential value.

### Provider behavior

- **GitHub:** ADE mints short-lived GitHub App installation tokens scoped to declared
  repositories and permissions.
- **Kubernetes:** ADE requests short-lived service-account tokens with declared audience,
  expiry, namespace, and RBAC authority.
- **SSH:** ADE starts a dedicated host SSH agent for the running workbench, loads only the
  declared workbench identity, and forwards that socket. Every process in the workbench
  may request signatures while the capability is enabled. ADE removes the capability in
  maintenance mode and may stop the dedicated agent when the workbench stops. If an SSH
  CA exists, ADE may refresh short-lived certificates; it does not rotate a normal
  private key on a timer.
- **Datadog:** ADE may create, overlap, and delete API/application keys only when a declared
  host management credential permits it and the capability is actually needed.
- **CircleCI:** ADE installs and reports expiry for manually managed tokens. V1 does not
  claim provider-side automatic rotation where CircleCI exposes no suitable API.
- **GPG:** use a dedicated workbench identity or host signing. V1 does not periodically
  rotate GPG keys.
- **LLM tools:** the user signs in interactively inside the workbench. ADE does not mint,
  inject, proxy, or rotate LLM credentials. Login state survives stop/start in persistent
  root state and is wiped by reimage.

Tools that can use dynamic credential helpers read the current generation at each
operation. Processes that only read an environment variable at startup must finish before
expiry or be restarted by Herdr after rotation.

## Herdr

Herdr is installed and configured inside each workbench. It owns agent processes,
worktrees, shells, sessions, and logs inside the VM. ADE owns only trusted Herdr
configuration materialization, startup, health checks, and attachment.

All Herdr agents in one workbench share the same VM-level authority. ADE does not attempt
per-agent credential or filesystem isolation inside a workbench.

New agents receive the current credential generation. Existing agents follow the dynamic
helper or restart policy declared for the relevant credential type.

## SmolVM supply chain

Upstream SmolVM release archives have checksums but currently lack signatures and
provenance attestations. The upstream security policy supports only the latest published
release. ADE therefore does not use an operational `curl | bash` installer.

ADE:

- pins the complete SmolVM source revision through Nix;
- builds a reproducible host binary where practical;
- records and verifies its output digest;
- applies the macOS Hypervisor.framework entitlement;
- verifies the signature and entitlement after installation;
- updates the pin only after the full qualification suite passes.

The workstation OCI image and all Nix inputs are pinned by immutable digest or lock file.

## Host state

ADE keeps only the state it needs:

```text
host declarations             version-controlled project files
per-workbench locks            host runtime/state directory
active reimage journals        host state directory
workspace backups and packs    explicit configured directory
credential metadata            host state directory, no secret values in logs
credential roots/references    macOS Keychain or explicit protected host paths
```

ADE does not keep a parallel database of SmolVM machines. `ade status` queries SmolVM and
combines the observed state with declaration drift, transaction state, Herdr health, and
credential expiry.

## Error and audit behavior

Errors are structured by operation and preserve the underlying SmolVM or provider cause.
ADE never reports a destructive operation as complete until its postconditions have been
verified.

Secret-free audit records cover:

- destructive lifecycle operations;
- transaction phase and recovery decisions;
- backup creation and manifest digest;
- credential provider, generation identifier, expiry, and outcome;
- emergency revocation.

Logs never contain credential values or full secret-bearing command lines.

## Migration approach

The SmolVM implementation cleanly supersedes the Microsandbox-specific launcher,
installer, profiles, and tests after qualification. ADE does not carry a dual-runtime
abstraction in V1.

The qualified Microsandbox change remains historical evidence and a behavioral reference
until the SmolVM suite passes. The implementation plan must explicitly decide whether the
local Microsandbox change is retained as history or superseded before publication.

## Qualification gate

No SmolVM migration is complete until an isolated test installation passes the full suite
without modifying the user's existing SmolVM or Microsandbox state.

Blocking coverage includes:

- exact binary pin, digest, macOS signature, and hypervisor entitlement;
- create, repeated create, start, repeated start, attach, exec, stop, repeated stop,
  restart, status, and destroy convergence;
- persistent root and `/workspace` behavior across stop/start;
- tmpfs reset behavior;
- OCI image and Smolfile materialization;
- CPU, memory, overlay, and workspace storage settings;
- stopped-machine mount updates and `/workspace` mount precedence;
- normal boot plus bounded maintenance startup with no injected secrets and an empty SSH
  agent;
- network postures, DNS, positive CIDR/hostname allowlists, localhost, restart, and
  Docker-container egress;
- secret reference handling and absence from inspection, logs, and argv;
- secret generation installation, atomic activation, expiry, failure, and reinjection;
- dedicated SSH-agent authority and empty-agent behavior during maintenance;
- native interactive attachment, streams, signals, concurrency, and stop disconnect;
- Herdr startup, attachment, multi-agent use, and credential refresh/restart;
- Docker and representative nested container workload;
- workspace backup and restore above 4 GiB;
- symlink, hardlink, traversal, ownership, device, FIFO, setid, and capability validation;
- destroy with backup and explicit no-backup paths;
- full-machine pack contents and secret-bearing warnings;
- reimage with crash injection at every journal boundary;
- recovery before and after old-machine deletion;
- previous-image plus workspace rollback availability until transaction commit;
- no mutation of existing host sandboxes, runtimes, or user configuration during
  qualification.

Transactional workspace export, deletion, recreation, restoration, and crash-boundary
failure injection are mandatory blocking tests within this broader suite.

## V1 completion

V1 is complete when the user can declare a workbench and reliably:

```text
ade create work
ade attach work
run Herdr agents with the declared network and credentials
leave and later reattach
rotate supported credentials without rebuilding the VM
back up the workspace
reimage while preserving validated workspace data
restore a workspace backup
explicitly destroy the machine
```

The implementation remains one small local OCaml CLI around one pinned SmolVM runtime.
