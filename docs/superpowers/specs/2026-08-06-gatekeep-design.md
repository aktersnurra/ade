# Gatekeep Design (Superseded)

**Status:** Superseded by [`2026-08-14-ade-design.md`](2026-08-14-ade-design.md)

> This document is retained as historical design context. It predates the Microsandbox validation, the OCaml decision, and the ADE naming contract.

## Goal

Gatekeep is a local, cross-platform control plane for autonomous coding agents. It opens a named workbench VM, lets multiple agents run freely inside that workbench, and enforces the host boundary for files, credentials, network egress, containers, and external effects.

Gatekeep is a separate project. `~/projects/dotagent` remains the source of complete Pi profile installation and profile updates; Gatekeep invokes its Pi-only installer for a selected guest-local profile.

## Constraints

- Support current admin-controlled macOS and Artix Linux machines from the beginning; do not require Ubuntu.
- Use one pinned Nix Linux guest specification, producing architecture-specific guest artifacts.
- Use Lima/VZ on macOS and QEMU/KVM on Artix.
- A workbench is one shared zone VM hosting multiple tmux sessions and agents.
- Work, personal, quarantine, and cloud-admin are distinct zone identities. Work and personal never share writable state, profile data, cache, workspace roots, credentials, browser state, or audit records.
- A zone may write only explicitly selected canonical host roots. Direct writes trade protection inside those roots for low friction.
- Gatekeep retains no raw long-lived external-service credential in the guest.
- The user’s normal interactive 1Password `op` session authenticates the host broker. Credentials exist only in broker memory for the selected workbench lease.
- The default workbench lease is explicit at launch, for example `--lifetime 8h`. Lock/sleep pauses brokered capabilities by default; the policy may configure another behavior.
- Normal package installs/tests may execute freely inside a development workbench. Bash, language runtimes, build tools, package hooks, project scripts, and guest-local containers are all arbitrary guest-code execution. Gatekeep protects the host and ungranted capabilities, not source data already visible in the selected zone.
- Every interface reachable from an arbitrary-code guest is assumed reachable by any agent, dependency, package hook, or project process in that workbench. A claimed agent or process identity never increases authority.
- `aws`, `kubectl`, Terraform, cloud credentials, cloud endpoints, and mutating production capabilities are absent from development workbenches. Cloud administration runs through a separate restricted cloud-admin flow.
- A pre-start host checkpoint protects every direct-write sandbox mount. Restore is allowed only after guest and container teardown.

## Product Model

### Workbench

A workbench is the unit the user enters and leaves. It has one zone, a finite lease, a VM, a guest-local tmux server, declared host workspace mounts, a guest profile, a policy digest, and an audit stream.

The host terminal reaches the guest tmux server through the guest connection. Host tmux may multiplex connections but never owns agent processes or guest session state.

### Zone

A zone is an authority boundary, not a display label.

| Zone | Files | Credentials and egress | Intended use |
| --- | --- | --- | --- |
| `work` | declared work roots | work provider and approved work capability profiles | normal work agents |
| `personal` | declared personal roots | personal provider and personal capability profiles | normal personal agents |
| `quarantine` | private snapshot/copy only by default | no work/personal credentials; narrow explicit registry/web access | unknown code, web content, package inspection |
| `cloud-admin` | selected source/plan artifact only | short-lived scoped cloud capability after approval | plan verification and apply |

### Execution posture

Execution posture is part of the verified workbench specification, not an informal runtime convention.

- `open-development` permits arbitrary guest code: Bash, language runtimes, package installation, build/test hooks, project extensions, and guest-local containers. Its capability policy must assume every guest process can invoke every reachable guest interface and read every response delivered into the guest. It cannot receive mutating production or cloud authority.
- `restricted-effect` exposes only named typed operations over verified inputs. It has no general shell, package hooks, project extension loading, or other arbitrary-code path while sensitive authority is active. Removing or renaming Bash alone does not establish this posture; the verifier must reject every equivalent execution path.

A task requiring a different posture or trust level uses a separate workbench or host-side effect flow. Gatekeep never upgrades an `open-development` workbench in place to `restricted-effect`.

### Capability

A capability is a named, typed authority: it has a zone, compatible execution posture, adapter, allowed target set, operation set, response classification and destination, request budget, lease, and policy digest. An available binary does not imply a capability. A normal guest does not receive a generic host shell, arbitrary authenticated HTTP proxy, `op`, host Docker socket, SSH agent, Keychain, or cloud configuration.

Capabilities are granted to a workbench authority boundary. Every agent and arbitrary process inside an `open-development` workbench is treated as having the same reachable capability set. Guest-supplied agent, run, or process identity is provenance only and cannot authorize or widen a request. A capability response is treated as sensitive data independently of its credential: policy decides whether it may enter guest stdout, files, logs, caches, or durable audit records.

### Blocked-action escalation

When a requested effect is denied, Gatekeep records a `BlockedAction` and delivers a host-native notification. The durable local inbox contains zone, run identity, workspace revision, requested capability, structured target, reason, and any plan artifact reference.

The user can decline, mark a handoff complete, or start a distinct higher-authority flow. The agent receives only the resulting status and never a raw credential or implicit self-approval. Gatekeep rate-limits and deduplicates blocked actions.

### Cloud-admin apply

A development workbench can prepare a plan but cannot apply cloud/cluster changes. A separate `restricted-effect` cloud-admin flow independently verifies a content-addressed artifact and an unconsumed approval binding before its fixed host-side apply adapter receives short-lived authority. The guest never receives the credential or a general command path while that authority is active.

For Terraform, the approval binds the saved plan digest, workspace/backend, source revision, lockfile digest, target, expiry, and nonce. The host adapter applies exactly that plan once. For Kubernetes, server-side dry-run is review evidence only; apply requires a digest-bound manifest bundle, target constraints, expiry/nonce, and API-server admission enforcement. Drift, conflict, expiry, or a consumed nonce requires a new plan and approval.

## Domain States

Gatekeep’s durable core uses explicit state transitions. The implementation must not model these as unconstrained strings or independent booleans.

```text
ZoneSpec -> VerifiedZoneSpec -> CheckpointedZone -> BootingWorkbench
        -> RunningWorkbench -> PausedWorkbench | ExpiredWorkbench | StoppedWorkbench

RawCapabilityRequest -> ParsedCapabilityRequest -> AuthorizedCapabilityRequest
                     -> AppliedCapabilityEffect | DeniedCapabilityRequest

RawPlanArtifact -> VerifiedPlanArtifact -> ApprovedPlanArtifact -> AppliedPlanArtifact
```

Important invariants:

- Only a `VerifiedZoneSpec` may create a checkpoint or start a VM.
- Only a `CheckpointedZone` may attach a writable direct host workspace mount.
- Only an `AuthorizedCapabilityRequest` may call an adapter.
- Only an `ApprovedPlanArtifact` with a matching policy, target, expiry, nonce, and digest may mint cloud authority.
- Arbitrary guest-code execution and mutating production/cloud authority cannot coexist within one authority boundary.
- Guest-supplied agent, run, or process identity cannot increase request authority.
- A running workbench cannot be restored over; restoration requires the stopped state.
- No durable object may contain raw service credentials or an unclassified sensitive capability response.

Expected failures use structured error values with stable code, human message, and machine context. Audit records store source facts and derived decisions separately.

## Architecture

### Host control plane

The Gatekeep host process owns:

- zone specifications and policy verification;
- lifecycle selection for the Lima/VZ or QEMU/KVM adapter;
- pre-start checkpoint and stopped-only restore coordination;
- guest disk, state, and cache allocation;
- profile update orchestration through `dotagent/install-pi --dir <guest-profile>`;
- brokered capability adapters, approval records, request budgets, and local inbox;
- append-only metadata receipts;
- capability pause/revocation at lease expiration, lock/sleep, shutdown, and emergency disable.

The host control plane exposes a narrow authenticated guest channel. It never exposes arbitrary host command execution or arbitrary file reads.

### Host adapters

Both adapters implement one backend-neutral contract: create zone storage, validate mount roots, attach the selected guest artifact, set resource limits, start/stop the VM, expose the private guest channel, and report measured status.

- **macOS:** Lima with its VZ backend. Gatekeep starts with no implicit host-home mount and validates every declared mount.
- **Artix:** QEMU/KVM. Gatekeep uses an Artix-compatible, init-neutral launcher path; a libvirt session adapter is optional only after it meets the same contract.

NAT, user-mode networking, and a guest firewall alone are not egress enforcement. The no-network baseline is a VM without general outbound network. A later capability adapter may add only a host-enforced egress path; guest root must not be able to bypass it.

### Guest

The pinned Nix source produces posture-specific guest closures. An `open-development` guest contains the non-host agent toolchain, one non-root agent user, guest-local tmux, Bash and language runtimes, declared Pi/Codex/Claude runtime adapters, a guest-local container runtime, and a bootstrap verifier. A `restricted-effect` closure contains only the fixed verifier and typed operation runner required by its flow; it excludes general shells, package hooks, project extensions, and arbitrary runtime entry points.

The verifier rejects host-looking Docker socket, Docker configuration, or credential paths. It records the guest artifact digest, zone ID, execution posture, policy digest, and selected Pi profile before starting agents or an effect runner. It also rejects a capability whose required posture is incompatible with the verified guest closure.

The guest’s mutable storage is divided into:

- durable zone state: Pi profile/session state, agent state, audit spool, and SSH host identity;
- bounded zone cache: Nix store/cache, package caches, container images/layers, and tool caches;
- per-run scratch: disposable agent/process data;
- mounted workspace roots: direct declared host roots only.

No mutable storage is shared between work and personal zones. Nix package closures and profile generations are retained only through explicit GC roots and a quota policy.

### Pi profiles and dotagent integration

Gatekeep stages the selected complete profile by invoking `~/projects/dotagent/install-pi --dir <guest-profile> [--provider <provider>]` against a pinned dotagent revision. Work zones receive the full work profile; personal zones receive the full personal profile. Gatekeep does not synthesize a reduced replacement profile or mount host-global `~/.pi`.

Profile updates are controlled guest syncs: an existing workbench continues with its current profile digest until a deliberate refresh/restart. Profile packages, extensions, skills, sessions, and mutable package state remain guest-zone-local.

Before integration, dotagent must change `install-pi` to link root `AGENTS.md`; its test now explicitly fails on an incorrect target.

### Containers

Docker/Testcontainers run inside the guest. The host Docker socket, host Docker TCP endpoint, host Docker credentials, and host Docker context are unavailable. Container image/layer/volume data belongs to the selected zone cache disk.

Rootless Docker is preferred when the target Artix init, cgroup delegation, user namespace setup, and real Testcontainers bindings pass the acceptance matrix. Rootful Docker inside the VM is an allowed fallback; it does not become host Docker authority.

## Delivery Slices

### Slice 1: Deterministic core and profile contract

Deliver the Rust control-plane core with typed zone, execution posture, lease, capability, response classification, blocked-action, plan-artifact, approval, and audit-record models. Define the backend-neutral adapter trait and profile-sync interface. Add deterministic policy parsing/verification fixtures and compatibility fixtures for complete Pi profile installation.

Success criteria:

- invalid zone/capability/approval transitions cannot reach effect adapters;
- policy construction rejects arbitrary guest-code execution combined with mutating production/cloud authority;
- guest-supplied identity cannot widen a capability request;
- every receipt includes zone, run, posture, policy, and artifact provenance;
- a guest profile is created only through the pinned dotagent `install-pi --dir` boundary;
- work and personal profile paths cannot resolve to the same durable state root.

### Slice 2: Secure no-network workbench boot on both hosts

Deliver Lima/VZ and QEMU/KVM adapters that boot the correct per-architecture Nix guest with fixed CPU/RAM/disk limits and no general outbound network. Both adapters mount one declared read-only workspace root and expose guest-local tmux through the defined connection path.

Success criteria:

- macOS and Artix select architecture-compatible artifacts from the same Nix source;
- the guest sees no host home, Docker socket, SSH agent, browser profile, or host Pi directory;
- guest tmux survives terminal disconnect and cannot be attached directly from another zone;
- resource admission refuses a new workbench before host memory pressure becomes destructive.

### Slice 3: Writable workspaces, checkpointing, profiles, and containers

Deliver canonical writable-root validation, pre-start APFS/Btrfs checkpoint adapters, stopped-only restore, controlled work/personal Pi profile sync, guest-local Docker/Testcontainers, bounded zone caches, and Nix garbage-collection policy.

Success criteria:

- a direct-write workbench creates its checkpoint before VM start;
- restore is refused while a guest or container owns the mount;
- Testcontainers reaches only the guest Docker endpoint;
- package/tool/container caches stay bounded and cannot cross work/personal zones;
- profile refresh leaves a running workbench on its prior verified digest until restart.

### Slice 4: Broker and blocked-action inbox

Deliver the private guest-to-host request protocol, policy evaluator, response-classification and destination rules, native notification adapter, durable local inbox, request budgets, and host-side 1Password-backed service adapters. Start with read-only GitHub, Datadog logs, and CircleCI read operations whose policies explicitly accept that any process in an `open-development` workbench can issue the request and consume guest-delivered results.

Success criteria:

- the guest cannot read `op` state or raw service tokens;
- shell commands, inline language runtimes, package hooks, and agent tools receive identical authority when they submit the same workbench request;
- spoofing an agent, run, or process identity cannot expand targets, operations, budgets, or response destinations;
- sensitive responses cannot enter guest files, stdout, logs, caches, or durable records unless their classification explicitly permits that destination;
- denied effects create one structured inbox request and a native notification;
- requests cannot be auto-approved, arbitrarily execute host commands, or exceed their budget;
- lock/sleep, lease expiry, and emergency disable stop credentialed adapter calls;
- work and personal service identities cannot cross capability namespaces.

### Slice 5: Controlled egress and browser work

Deliver host-enforced named egress capability profiles, registry-fetch support, and disposable browser-test/research profiles. Direct guest network remains unavailable unless a matching profile is active.

Success criteria:

- an allowlisted endpoint works only through the approved path;
- direct, redirected, private-address, metadata-address, IPv6, QUIC, and cross-zone attempts are denied;
- browser profiles have no host cookies, Keychain, extensions, downloads, or work/personal profile state;
- browser tests can reach only explicitly forwarded local/staging services.

### Slice 6: Cloud-admin approved apply

Deliver the separate restricted cloud-admin zone, immutable plan-artifact store, approval UI/inbox transition, one-time nonce enforcement, host-side short-lived credential minting and fixed apply adapters, Terraform saved-plan apply, and Kubernetes manifest/admission integration.

Success criteria:

- normal zones cannot launch cloud commands or request direct cloud credentials;
- the restricted apply boundary exposes no general shell, project hook, extension, package runner, or equivalent arbitrary-code path while authority is active;
- an altered, expired, target-mismatched, stale, or replayed artifact is rejected before credential minting;
- the host Terraform adapter applies only the approved saved plan;
- Kubernetes apply is guarded by digest/target/expiry enforcement at the API boundary;
- the final receipt correlates Gatekeep approval data with provider audit identifiers and teardown removes ephemeral authority.

## Verification Strategy

- Unit tests cover every state transition, parser, policy rule, execution-posture compatibility rule, response destination, capability budget, digest/nonce check, and structured error.
- Property tests generate invalid state/order/posture combinations and prove they never reach host effect adapters.
- Adapter contract tests run the same fixture suite against Lima/VZ and QEMU/KVM.
- Integration tests run on both target hosts: cold boot, terminal detach, forced guest kill, cache exhaustion, no-network boot, rejected egress, profile sync, work/personal separation, Docker/Testcontainers, blocked-action notification, and checkpoint/restore.
- Security regression tests assert absence of host Docker paths, host home mounts, raw credentials, cross-zone cache paths, and cloud binaries from development guest profiles.
- Adversarial broker tests submit requests through Bash, inline Python, package lifecycle hooks, direct protocol calls, and spoofed run identities; no path may exceed the workbench policy or bypass response-classification rules.
- Cloud-admin tests assert absence of arbitrary execution while authority is active and exercise changed artifact bytes, consumed nonce, wrong target, expired approval, Terraform drift, Kubernetes conflict, and broker kill-switch behavior.

## Explicit Non-goals

- Supporting future non-admin laptops now. Gatekeep must report unenforced controls honestly when that becomes a real deployment target.
- Claiming a Nix dev shell, Pi profile, tmux session, hidden `PATH` binary, or guest firewall is a host-security boundary.
- Building a Bash command blacklist or allowlist as a security boundary while another arbitrary-code execution path remains.
- Running host Docker through a mounted socket.
- Treating an arbitrary web page, project extension, npm package, or model output as trusted.
- Sending blocked-action notifications to chat/email/phone by default.
