# ADE

ADE is an experimental Agent Development Environment.

ADE runs coding agents in named Linux workbench VMs. Each workbench keeps its root across stop and start. Declared stores survive reimage.

The project is in the design and validation stage. The `ade` command does not exist yet.

## Goals

ADE aims to provide:

- named workbench VMs such as `work` and `personal`;
- generic interactive terminal sessions and remote commands;
- Herdr as the preferred guest multiplexer, not an ADE dependency;
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

ADE manages VM lifecycle, persistent storage, external policy, and bounded OpenSSH transport.

A user can run ADE in a plain terminal or inside a host multiplexer. The approved guest image can include Herdr for projects, tabs, panes, and agents.

ADE never forwards the host Herdr socket, API, configuration, state, or host `HERDR_*` values into a VM. The guest image can define guest-local Herdr paths.

## Primary flow

```text
ade start work
  -> verify base-image provenance and external policy
  -> start or reuse the configured workbench
  -> enter a generic remote shell
  -> run Herdr or another guest tool
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
- direct SSH command execution;
- directory-backed project-store persistence;
- stopped-only project-store checkpoints;
- disposable root state;
- guest package installation;
- guest-local Docker;
- a Nix-built OCI workstation.

The historical substrate spike also tested tmux. ADE no longer requires a terminal multiplexer.

A later disposable guest test installed Node 22.23.2 and Pi 0.84.2 without host Pi state.

The test also confirmed that Herdr remained absent from the guest.

## Repository layout

```text
docs/superpowers/specs/   Design and validation documents
docs/superpowers/plans/   Approved implementation plans
spike/nix-workstation/    Nix workstation image spike
```

Start with these documents:

- [ADE design](docs/superpowers/specs/2026-08-14-ade-design.md)
- [Microsandbox validation](docs/superpowers/specs/2026-08-14-microsandbox-validation.md)
- [Disposable Pi and Herdr spike](docs/superpowers/specs/2026-08-17-pi-herdr-disposable-sandbox-design.md)
- [Named workbench and terminal design](docs/superpowers/specs/2026-08-18-named-workbench-terminal-design.md)

## Planned delivery

1. Upgrade to and pin Microsandbox 0.6.10, then rerun the lifecycle, network, and SSH suite, including `msb ssh serve --stdio --no-inactivity-timeout`.
2. Add `ade list`, `ade start`, `ade exec`, `ade inspect`, `ade stop`, and `ade reimage`.
3. Add declarative project stores, classifications, explicit checkpoints, and restore controls.
4. Add the gatekeeper protocol and a model-provider capability.
5. Add narrow GitHub, signing, and restricted SSH gatekeepers.

## Status

ADE is a research project. Do not treat the current image or commands as a production security boundary.
