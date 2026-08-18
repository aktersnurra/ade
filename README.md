# ADE

ADE is an experimental Agent Development Environment.

ADE runs coding agents in named Linux workbench VMs. Each workbench keeps its root across stop and start. Its `/workspace` project store survives reimage.

The project is in the design and validation stage. The `ade` command does not exist yet.

## Goals

ADE aims to provide:

- named workbench VMs such as `work` and `personal`;
- native interactive terminal sessions and guest command execution;
- persistent, classified project stores;
- explicit network and capability policy;
- guest-local development tools and containers;
- host-side gatekeepers for narrow privileged actions;
- append-only lifecycle and capability receipts.

ADE uses existing infrastructure. It does not implement a hypervisor, network stack, container runtime, secret store, or terminal multiplexer.

## Security model

A workbench VM is one hostile security principal. Agents and guest processes inside one workbench are not isolated from each other.

Use separate workbenches when agents must not share authority or data.

Full compromise of a workbench must not grant reusable authority beyond its externally enforced capability envelope.

The guest must not receive:

- the host home directory;
- host SSH credentials or agent forwarding;
- the host Docker socket or credentials;
- host cloud configuration;
- host-global Pi state;
- raw long-lived service credentials;
- a generic host command channel.

ADE manages VM lifecycle, persistent storage, external policy, and native Microsandbox terminal execution.

A user can run ADE in a plain terminal or inside any host multiplexer. ADE does not integrate with or configure terminal multiplexers.

ADE never forwards host application sockets, configuration, state, or ambient authority into a VM.

## Primary flow

```text
ade start work
  -> verify base-image provenance and external policy
  -> start or reuse the configured workbench
  -> enter the guest shell through native `msb exec --tty`
  -> use the shell and guest development tools
```

Leaving the shell does not stop the workbench.

## Current state

The repository contains:

- the ADE design;
- Microsandbox validation results for Apple silicon macOS;
- a flake-defined, Nix-built `aarch64-linux` workstation image spike;
- a validated disposable Pi sandbox plan from the earlier host-only spike;
- an approved named-workbench design with generic terminal sessions.

The Microsandbox spike validated:

- the microVM boundary;
- restricted and disabled networking;
- historical direct SSH command execution, before ADE selected native execution;
- directory-backed project-store persistence;
- stopped-only project-store checkpoints;
- disposable root state;
- guest package installation;
- guest-local Docker;
- a Nix-built OCI workstation.

The historical substrate spike also tested tmux. ADE no longer requires a terminal multiplexer.

A later disposable guest test installed Node 22.23.2 and Pi 0.84.2 without host Pi or multiplexer state.

## Repository layout

```text
docs/superpowers/specs/   Design and validation documents
docs/superpowers/plans/   Approved implementation plans
spike/nix-workstation/    Nix workstation image spike
```

Start with these documents:

- [ADE design](docs/superpowers/specs/2026-08-14-ade-design.md)
- [Microsandbox validation](docs/superpowers/specs/2026-08-14-microsandbox-validation.md)
- [Named workbench and terminal design](docs/superpowers/specs/2026-08-18-named-workbench-terminal-design.md)
- [Native execution qualification plan](docs/superpowers/plans/2026-08-18-microsandbox-native-execution-qualification.md)
- [Rejected OpenSSH stdio experiment](docs/superpowers/specs/2026-08-18-microsandbox-0.6.10-ssh-transport-experiment.md)

## Planned delivery

1. Pin Microsandbox 0.6.10, then qualify lifecycle, root and project-store persistence, networking, and native `msb exec` terminal and command behavior.
2. Add `ade list`, `ade start`, `ade exec`, `ade inspect`, `ade stop`, and `ade reimage`.
3. Add declarative project stores, classifications, explicit checkpoints, and restore controls.
4. Add the gatekeeper protocol and a model-provider capability.
5. Add narrow GitHub, signing, and restricted SSH gatekeepers.

## Status

ADE is a research project. Do not treat the current image or commands as a production security boundary.
