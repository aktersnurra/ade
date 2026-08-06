# Gatekeep project overview (superseded)

> This historical overview predates the Microsandbox validation and ADE naming decision. See [`2026-08-14-ade-design.md`](../specs/2026-08-14-ade-design.md) for the current design.

## Summary

Gatekeep is a proposed **local, cross-platform control plane for autonomous coding agents**. It launches an isolated virtual-machine workbench where multiple coding agents can work, while the host controls access to files, credentials, network egress, containers, and external actions.

Its central purpose is not to constrain what agents can do inside already-authorized source trees. Instead, it makes access to the host and external systems explicit, scoped, auditable, time-bounded, and separated by trust zone.

This repository currently contains a design draft rather than an implementation.

## The problem it solves

Coding agents commonly need a capable environment: a workspace, package tools, a terminal, containers, browser access, and occasionally credentials for services or cloud infrastructure. Giving an agent unrestricted access to the host machine makes those capabilities inseparable from sensitive user state such as the home directory, browser profile, SSH agent, 1Password session, Docker socket, cloud credentials, and unrelated project files.

Gatekeep proposes a different boundary:

```text
Host control plane
  ├─ validates policy and zone configuration
  ├─ starts/stops isolated VM workbenches
  ├─ checkpoints explicitly writable host roots
  ├─ brokers narrowly scoped external capabilities
  └─ records approvals, denials, and receipts

Guest workbench VM
  ├─ runs agents and guest-local tmux
  ├─ contains guest-local tools and containers
  ├─ mounts only declared host workspace roots
  └─ requests external effects through a private channel
```

The guest must not get a generic host shell, host Docker access, arbitrary authenticated HTTP proxying, `op`, SSH agent forwarding, Keychain access, or host-global Pi state.

## Workbenches and zones

A **workbench** is one finite-lived VM environment. It includes a zone identity, lease, VM, guest-local tmux server, declared workspace mounts, selected Pi profile, policy digest, and audit stream.

A **zone** is an authority boundary, rather than merely a label:

| Zone | Intended contents and authority |
| --- | --- |
| `work` | Declared work roots and approved work-provider capabilities |
| `personal` | Declared personal roots and separate personal capabilities |
| `quarantine` | A private copy/snapshot for untrusted code or web content; no work/personal credentials by default |
| `cloud-admin` | A separate, higher-trust path for verified cloud plan application |

The design requires work and personal zones never to share writable state, profiles, caches, roots, credentials, browser data, or audit records.

## Capabilities, rather than ambient access

Gatekeep models authority as a typed **capability**, with a zone, adapter, target allowlist, allowed operations, request budget, lease, and policy digest. The presence of a command-line binary is deliberately not authority to use it.

For example, ordinary workbenches do not contain cloud tooling or credentials. A read-only GitHub, Datadog, or CircleCI action would be performed through a brokered, named capability. A denied action creates a structured `BlockedAction`, records it in a local inbox, and sends a host-native notification. The user may decline it or start a distinct higher-authority flow; the agent receives only that decision, never a raw credential or self-approval path.

## Security and lifecycle model

The proposal uses explicit domain state transitions:

```text
ZoneSpec -> VerifiedZoneSpec -> CheckpointedZone -> BootingWorkbench
        -> RunningWorkbench -> PausedWorkbench | ExpiredWorkbench | StoppedWorkbench

RawCapabilityRequest -> ParsedCapabilityRequest -> AuthorizedCapabilityRequest
                     -> AppliedCapabilityEffect | DeniedCapabilityRequest

RawPlanArtifact -> VerifiedPlanArtifact -> ApprovedPlanArtifact -> AppliedPlanArtifact
```

These transitions encode key safeguards:

- only verified zone specifications may start a VM;
- writable host mounts require a pre-start checkpoint;
- only authorized requests reach capability adapters;
- cloud authority can be minted only for an approved, matching, unexpired, one-time plan artifact;
- restoration is allowed only after the workbench and containers stop;
- durable state must never store raw external-service credentials.

Workbench leases are explicit (for example, eight hours). Lock, sleep, expiry, shutdown, or an emergency disable revokes brokered capabilities by default.

## Platform and runtime plan

The architecture targets admin-controlled macOS and Artix Linux systems from the outset:

- **macOS:** Lima with the VZ backend.
- **Artix Linux:** QEMU/KVM through an init-neutral launcher; a libvirt session adapter is optional.
- **Guest:** a pinned Nix Linux specification, producing architecture-specific guest artifacts.

The guest contains a non-root agent user, agent toolchains, guest-local tmux, a guest-local container runtime, and a startup verifier. Docker/Testcontainers run *inside* the guest. Host Docker sockets, credentials, and contexts remain unavailable.

A no-network workbench means no general outbound network, not merely a guest firewall or NAT configuration. Future networking is intended to be host-enforced and allowlist-based, so guest root cannot bypass it.

## Pi and profile integration

Gatekeep does not take over profile installation. It delegates the complete guest-local Pi profile setup to a pinned revision of the separate `dotagent` project:

```text
~/projects/dotagent/install-pi --dir <guest-profile> [--provider <provider>]
```

Each zone receives its own complete work or personal profile. Gatekeep must not mount host-global `~/.pi`, synthesize a reduced replacement profile, or share mutable profile state. Profile changes are deliberate guest syncs: a running workbench keeps its current verified profile digest until a refresh/restart.

## Cloud administration

Cloud administration is intentionally separate from everyday coding work. A normal workbench can prepare a plan, but cannot directly apply Terraform or Kubernetes changes. A cloud-admin workbench independently verifies a content-addressed artifact and an unconsumed approval binding before it receives short-lived, scoped authority.

For Terraform, approval binds the saved-plan digest, workspace/backend, source revision, lockfile digest, target, expiry, and nonce; Gatekeep applies that exact plan once. For Kubernetes, server-side dry-run is review evidence only; apply requires a digest-bound manifest bundle plus target, expiry, nonce, and API-server admission enforcement.

## Delivery roadmap

The design describes six incremental slices:

1. **Deterministic core and profile contract:** Rust types for zones, leases, capabilities, approvals, plan artifacts, and audits; backend-neutral adapter and profile-sync interfaces.
2. **Secure no-network boot:** Lima/VZ and QEMU/KVM boot the right Nix guest with constrained resources and no general egress.
3. **Writable workspaces and containers:** canonical writable-root validation, APFS/Btrfs checkpoints, stopped-only restore, isolated profiles, guest Docker/Testcontainers, cache quotas.
4. **Broker and inbox:** guest-to-host request protocol, policy evaluation, notifications, budgets, inbox, and 1Password-backed read-only service adapters.
5. **Controlled egress and browser work:** host-enforced named egress profiles and disposable browser profiles without host cookies, Keychain, extensions, or downloads.
6. **Approved cloud apply:** cloud-admin workbench, immutable plan store, one-time approvals, short-lived credentials, Terraform and Kubernetes enforcement.

## Verification philosophy

The project emphasizes proving that invalid or unsafe paths cannot reach effect adapters:

- unit tests for transitions, policies, budgets, digests/nonces, and structured errors;
- property tests that generate invalid ordering combinations;
- shared adapter contract tests for macOS and Artix backends;
- host integration tests for isolation, no-network boot, termination, cache exhaustion, profile separation, checkpointing, and broker behavior;
- security regression tests for absence of host mounts, credentials, Docker paths, cross-zone caches, and cloud binaries;
- cloud-admin tests for artifact changes, expiry, replay, target mismatch, drift, conflicts, and kill-switch behavior.

## Explicit boundaries and non-goals

Gatekeep does not claim a dev shell, Pi profile, tmux session, hidden `PATH` command, or guest firewall is a host-security boundary. It does not support unrestricted host Docker, automatically trust untrusted code/web content/model output, or send approval notifications to chat/email/phone by default. Support for non-admin laptops is deferred and must report controls honestly if added later.

## Source

This overview is based solely on the current design draft: [`docs/superpowers/specs/2026-08-06-gatekeep-design.md`](../specs/2026-08-06-gatekeep-design.md).
