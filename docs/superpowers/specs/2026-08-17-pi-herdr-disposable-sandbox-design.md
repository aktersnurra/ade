# Disposable Pi Sandbox for Host-Side Herdr

**Status:** Approved for implementation planning

## Objective

Create one disposable Microsandbox VM that can run Pi while Herdr remains entirely on the trusted host.

The interactive launch command is:

```sh
HERDR_AGENT=pi msb ssh ade-pi-herdr-test -- pi
```

This spike validates the host/guest integration boundary. It does not define the production ADE workstation image.

## Existing foundation

Use the existing local image:

```text
gatekeep-nix-workstation:spike-v3
sha256:ea551ebb9355
```

The image already contains Nix and the validated ADE development toolchain. It does not contain Node or Pi.

## Sandbox definition

Create a new sandbox named `ade-pi-herdr-test` with:

- 2 virtual CPUs;
- 4 GiB of memory;
- an 8 GiB writable disposable root disk;
- the image's `/workspace` working directory;
- public-network egress for Nix and npm downloads;
- gateway DNS access limited to TCP/UDP port 53;
- no other access to private or host network ranges;
- no host directory, file, socket, or named-volume mounts;
- no copied host files;
- no forwarded ports;
- no injected secrets;
- no forwarded host environment variables.

Do not replace or modify an existing sandbox if the requested name is already present.

## Guest installation

Install Node 22 through guest-local Nix. Node must satisfy Pi's declared minimum version of 22.19.0.

Install this exact Pi package into guest-local writable storage:

```text
@earendil-works/pi-coding-agent@0.84.2
```

Place the npm installation under `/root/.local`. Configure the sandbox's guest `PATH` so both the Nix-installed Node executable and `/root/.local/bin/pi` resolve during later `msb ssh` commands.

Do not install Herdr in the guest. Do not copy or mount host Pi state, provider credentials, shell configuration, or authentication files.

## Host-side Herdr boundary

Herdr remains installed and running only on the trusted host.

Set `HERDR_AGENT=pi` only on the host-visible `msb` wrapper process:

```sh
HERDR_AGENT=pi msb ssh ade-pi-herdr-test -- pi
```

Never:

- run a Herdr server or integration in the guest;
- use `herdr --remote`;
- forward or mount the Herdr socket;
- forward any `HERDR_*` variable into the guest;
- give the guest access to the Herdr API;
- duplicate Herdr panes, sessions, persistence, workspaces, worktrees, agent detection, or orchestration UI.

Launch the interactive command directly from Ghostty. Do not nest Herdr inside tmux because both use `Ctrl-A`.

## Authentication

The installation and launch checks must not use provider credentials.

If Pi later requires provider authentication, authenticate independently inside the guest. Do not mount, copy, or forward host credentials or host-global Pi state. Guest authentication persistence is outside this disposable integration spike.

## Provisioning verification

Before declaring the sandbox ready:

1. Confirm the selected image digest still matches `sha256:ea551ebb9355`.
2. Confirm no sandbox named `ade-pi-herdr-test` already exists.
3. Create the sandbox with the approved resources and boundary controls.
4. Confirm the only host-group egress rule is gateway DNS on TCP/UDP port 53, public egress is allowed, and all other egress and all ingress default to deny.
5. Confirm Node is at least version 22.19.0.
6. Confirm `pi` resolves from the guest `PATH`.
7. Confirm `pi --version` reports 0.84.2.
8. Query only environment-variable names and confirm no name begins with `HERDR_`.
9. Confirm no Herdr socket or host directory was mounted.
10. Stop the sandbox after provisioning.
11. Confirm the sandbox remains available in the stopped state for the interactive Ghostty test.

Do not launch Pi from automation. The user performs the interactive launch from Ghostty after provisioning succeeds.

## Failure handling

If creation or installation fails:

- capture only targeted, non-secret diagnostics;
- do not print the complete guest environment;
- stop the new sandbox if it is running;
- leave existing sandboxes unchanged;
- report whether the disposable sandbox was created and whether cleanup is required;
- do not weaken network or isolation controls to make installation succeed.

## Acceptance criteria

The design is accepted when:

- `ade-pi-herdr-test` exists in a stopped state;
- Node and Pi are installed entirely inside its disposable guest root;
- `msb ssh ade-pi-herdr-test -- pi --version` succeeds;
- no `HERDR_*` variable is visible in the guest;
- no host files, credentials, sockets, or Herdr components are present in the guest;
- the exact Ghostty launch command is ready for the user;
- no existing sandbox, Herdr configuration, or VM image was modified.
