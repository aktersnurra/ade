# ADE

ADE is an experimental Agent Development Environment.

ADE runs coding agents in disposable Linux microVMs. A persistent workspace can survive while each session starts from a controlled image.

The project is in the design and validation stage. The `ade` command does not exist yet.

## Goals

ADE aims to provide:

- isolated sessions for Pi and other coding agents.
- persistent, classified workspaces.
- explicit network and capability policy.
- guest-local development tools and containers.
- host-side gatekeepers for narrow privileged actions.
- append-only lifecycle and capability receipts.

ADE uses existing infrastructure. It does not implement a hypervisor, network stack, container runtime, or secret store.

## Security model

The microVM is the boundary around guest code. ADE treats every guest process as untrusted.

The guest must not receive:

- the host home directory.
- host SSH credentials or agent forwarding.
- the host Docker socket or credentials.
- host cloud configuration.
- host-global Pi state.
- raw long-lived service credentials.
- a generic host command channel.

Herdr stays on the trusted host. ADE must not install Herdr in a guest or expose its socket or API to a guest.

## Current state

The repository contains:

- the accepted ADE design.
- Microsandbox validation results for Apple silicon macOS.
- a flake-defined, Nix-built `aarch64-linux` workstation image spike.
- a validated disposable Pi sandbox plan for host-side Herdr integration.

The Microsandbox spike validated:

- the microVM boundary.
- restricted and disabled networking.
- SSH and guest-local tmux.
- directory-backed workspace persistence.
- stopped-only workspace checkpoints.
- disposable root state.
- guest package installation.
- guest-local Docker.
- a Nix-built OCI workstation.

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
- [Disposable Pi and Herdr design](docs/superpowers/specs/2026-08-17-pi-herdr-disposable-sandbox-design.md)

## Planned delivery

1. Add the Microsandbox lifecycle commands: `ade work`, `ade stop`, `ade reset`, and `ade inspect`.
2. Add declarative workspaces, classifications, checkpoints, and restore controls.
3. Add the gatekeeper protocol and a model-provider capability.
4. Add narrow GitHub, signing, and restricted SSH gatekeepers.

## Status

ADE is a research project. Do not treat the current image or commands as a production security boundary.
