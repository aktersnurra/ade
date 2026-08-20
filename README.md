# ADE Microsandbox Workbenches

ADE is a runnable, configurable Microsandbox 0.6.10 workstation setup. Microsandbox remains the runtime; this repository supplies reproducible OCI images and editable capability profiles for images, resources, mounts, networking, credentials, persistence, and native execution.

There is no SSH transport, custom VM runtime, or parallel lifecycle state machine.

## What is included

- `bin/ade` — a transparent profile launcher around native `msb` commands;
- `profiles/work.sh` — deny-by-default work allowlist with optional repository and identity mounts;
- `profiles/work-offline.sh` — isolated workbench with no network or credential source;
- `profiles/work-cloud.sh.example` — safe starting point for provider-specific cloud authority;
- `profiles/personal.sh` — public-network personal profile with separate persistent state;
- `images/nix-workstation/` — configurable `aarch64-linux` OCI image built with Nix;
- `docs/microsandbox-workbenches.md` — complete configuration and operation reference;
- pinned Microsandbox 0.6.10 validation and qualification documents.

Profiles are executable Bash configuration. They can select any image, mount arbitrary configured host paths, choose any Microsandbox network policy, load credentials from any host mechanism, bake or mount configuration, and append native create options.

## Install the qualified runtime

```sh
./scripts/install-msb.sh
```

This installs the checksum-verified Microsandbox 0.6.10 runtime under `~/.local/share/ade/runtime/` without replacing Homebrew or writing `~/.microsandbox`. `bin/ade` discovers it automatically. `MSB_BIN` and `MSB_HOME` remain explicit overrides.

## Build and load the workstation image

```sh
./bin/ade build-image
./bin/ade load-image
```

On macOS, the image targets `aarch64-linux` and therefore requires a Linux Nix builder. See the workbench guide for the disposable Microsandbox builder workflow.

## Agents run inside the VM

Install and authenticate agent harnesses inside the selected VM. The checked-in
profiles do not forward ambient host API keys or PATs. VM-local login state is
kept in each profile's persistent `/root/.config` mount, which separates work
and personal authority.

Mount a repository tree explicitly when an agent needs it:

```sh
export ADE_WORK_REPOS="$HOME/work/repos"
./bin/ade start work
```

`ade reimage` replaces only the guest root. Mounted repositories and
configuration survive, so inspect mounted data and rotate exposed credentials
after a compromise.

## Run workbenches

```sh
./bin/ade create work
./bin/ade start work
./bin/ade start work-offline

./bin/ade exec work -- uname -a
./bin/ade stream work -- sh -lc 'cat'
./bin/ade inspect work
./bin/ade stop work
./bin/ade reimage work

./bin/ade start personal
```

`start` explicitly establishes a running sandbox and then enters its native Microsandbox PTY. Leaving the shell does not stop the sandbox. `reimage` removes and recreates the VM while preserving every host-backed mount.

## Customize

Edit the checked-in profiles or place replacements at:

```text
~/.config/ade/profiles/work.sh
~/.config/ade/profiles/work-offline.sh
~/.config/ade/profiles/work-cloud.sh
~/.config/ade/profiles/personal.sh
```

The image package set is `images/nix-workstation/packages.nix`. Files under `images/nix-workstation/root/` are baked verbatim into the image.

Credential environment files default to:

```text
~/.config/ade/credentials/work.env
~/.config/ade/credentials/personal.env
```

They are optional. Profiles may instead load credentials from macOS Keychain, 1Password, `pass`, SOPS, mounted files, baked image files, or any other desired source.

## Documentation

- [Microsandbox workbench guide](docs/microsandbox-workbenches.md)
- [Microsandbox 0.6.10 native execution validation](docs/superpowers/specs/2026-08-18-microsandbox-0.6.10-native-execution-validation.md)
- [Native execution qualification](docs/superpowers/plans/2026-08-18-microsandbox-native-execution-qualification.md)

Earlier ADE architecture documents remain as historical design records and are not the current implementation contract.
