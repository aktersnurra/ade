# Microsandbox workbenches

This is the operational contract for the runnable profiles in this repository. It intentionally exposes Microsandbox rather than replacing it.

## Profile model

A profile is an executable Bash file loaded by `bin/ade`. Checked-in examples live in `profiles/`; user replacements live in `~/.config/ade/profiles/`.

```bash
PROFILE_HOME="$HOME/.local/share/ade/workbenches/example"
SANDBOX_NAME=ade-example
IMAGE='ade-nix-workstation:0.1.0'
EXPECTED_IMAGE_DIGEST='sha256:...'
CPUS=4
MEMORY=8G
ROOT_DISK=24G
WORKDIR=/workspace
PULL_POLICY=never
EXEC_TIMEOUT=30m
REIMAGE_STATE=running

PERSIST_DIRS=("$PROFILE_HOME/workspace")
MOUNTS=("$PROFILE_HOME/workspace:/workspace")
NETWORK_ARGS=(--net public)
SECRET_SPECS=()
REQUIRED_SECRETS=()
ENV_ARGS=()
EXTRA_CREATE_ARGS=()
DEFAULT_SHELL=(/bin/bash -l)
```

Every array maps directly to native `msb create` arguments. `EXTRA_CREATE_ARGS` is the escape hatch for any supported option not given a dedicated profile variable. When `EXPECTED_IMAGE_DIGEST` is set, creation fails before launching a VM unless the locally resolved image has that digest.

## Images

A profile may use:

- a mutable image tag during development;
- an immutable image digest;
- the Nix image in this repository;
- a work-specific, personal, project-specific, or third-party image.

Edit `images/nix-workstation/packages.nix` to change packages. Put files under `images/nix-workstation/root/` to bake them into the image. Baked content may include dotfiles, agent configuration, certificates, scripts, application configuration, or credentials when that is the chosen distribution model.

Build, normalize, load, and inspect:

```sh
./bin/ade build-image
./bin/ade load-image
msb image inspect --format json ade-nix-workstation:0.1.0
```

Both Darwin and Linux builds write canonical compressed and uncompressed
archives under `artifacts/`; set `ADE_ARTIFACT_DIR` to use another location. A
Darwin host uses the disposable Microsandbox Linux builder. A Linux host builds
the same flake directly and normalizes its Nix output before loading.

`msb image load` registers the local tag `ade-nix-workstation:0.1.0`, which the
checked-in profiles use.

The checked-in profiles require the qualified image digest
`sha256:5c0bffada804326ae73d3bf3778a77358aa236974e27d9f80a7ec88e826a1997`
before creating a VM. A custom `ADE_WORK_IMAGE`, `ADE_PERSONAL_IMAGE`, or
`ADE_WORK_OFFLINE_IMAGE` disables that default expectation; set the matching
`*_IMAGE_DIGEST` variable to verify a rebuilt or third-party image.

A digest check prevents accidental local tag drift. It does not defend against
a compromised dependency deliberately included in a newly built image; mounts,
credentials, and network policy remain separate authority controls.

## Mounts and persistence

`MOUNTS` accepts any Microsandbox directory mount:

```bash
MOUNTS=(
  "$PROFILE_HOME/workspace:/workspace"
  "$HOME/.config/nvim:/root/.config/nvim"
  "$HOME/.gitconfig:/root/.gitconfig"
  "$HOME/company-ca:/etc/company-ca"
  "$HOME/.cache/ade-work:/root/.cache"
)
```

Use profile-specific directories for separation or mount shared host paths when sharing is desired. Mounted bytes persist independently of VM removal. Writable root persists across stop/start and is replaced by `ade reimage`; host mounts are preserved.

Microsandbox supports additional mount controls through native flags. Put them in `EXTRA_CREATE_ARGS` or invoke `ade modify PROFILE -- ...`.

## Agents and dotfiles

Install agent harnesses inside the VM so their installers and updates receive
only that VM's mounts and network authority. The base image deliberately does
not claim to ship Pi, Copilot, Claude Code, or browser binaries; choose versions
and installation policy in a derived image or inside the writable guest root.

The checked-in profiles do not forward ambient host API keys or PATs. Authenticate
inside the selected VM. Login state written under `/root/.config` persists in
that profile's dedicated config mount, keeping work and personal sessions
separate. Optional SSH and GPG directories are mounted only when their
profile-specific host directories exist.

Split dotfiles by how often they change:

| Where | Survives reimage | Use for |
| --- | --- | --- |
| `images/nix-workstation/root/` | yes, needs rebuild | stable, non-secret configuration |
| `$PROFILE_HOME/config` → `/root/.config` | yes, no rebuild | VM-local login and application state |
| explicit host path in `MOUNTS` | yes, no rebuild | deliberately shared dotfiles or repositories |

Mount specific subdirectories rather than the whole host `~/.config`, which may
contain unrelated tokens and cloud CLI authority. Reimage replaces guest root
only; mounted state must be inspected separately after a compromise.

## Personal and application configuration

Configuration can be supplied by any combination of:

1. files baked under `images/nix-workstation/root/`;
2. persistent profile mounts such as `/root/.config` and `/root/.local/state`;
3. direct host configuration mounts;
4. guest-local installation in the persistent writable root;
5. environment values in `ENV_ARGS`;
6. initialization commands or scripts baked or mounted into the guest.

Stop/start preserves guest-local configuration. Reimage removes it unless it is baked or mounted.

## Credentials

The profiles support every deliberate credential placement model.

### VM-local login (checked-in default)

The checked-in profiles inject no host API key or PAT. Authenticate each agent
or CLI inside the VM whose authority it should use. State written under
`/root/.config` persists in that profile's mounted config directory and is not
shared with other profiles.

For Git over SSH or commit signing, create profile-specific identity directories.
The work and personal profiles mount them only when present:

```sh
mkdir -p ~/.config/ade/identity/work/{ssh,gnupg}
ssh-keygen -t ed25519 -f ~/.config/ade/identity/work/ssh/id_ed25519 -C ade-work
gpg --homedir ~/.config/ade/identity/work/gnupg \
  --quick-gen-key 'ADE Work Agent <you+ade@example.com>' ed25519 sign 1y
```

Use identities scoped to the repositories and operations required by that VM.
Do not put credentials in a workspace shared with less-authorized profiles.

### Microsandbox host-side substitution (optional)

A custom profile may use `add_secret_if_set NAME HOSTS`, which adds a native
`--secret NAME@HOST[,HOST...]` reference. Microsandbox reads the corresponding
exported host environment value and substitutes it only for matching outbound
hosts.

This is an explicit policy choice, not a checked-in default. The credential is
available to the `msb` process environment, and an allowed upstream can receive
and reflect it. Recreate the VM after changing a substitution binding; restart
does not rebuild the sandbox configuration.

A user profile may instead load Keychain, 1Password, `pass`, SOPS, mounted
credential files, or another mechanism. Keep profile-scoped names and storage
when work and personal authority must remain separate.

### Other supported choices

Credentials may instead be:

- baked into an image;
- mounted as files or directories;
- passed with native environment options;
- installed inside the persistent guest root;
- fetched by guest applications;
- stored through Microsandbox-specific registry credential support.

These choices differ in persistence, portability, and exposure. The launcher does not prohibit them.

### Substitution limitation

A matching upstream service receives the real substituted credential and can return it in a response. Destination-scoped substitution therefore relies on the allowed endpoint not reflecting the credential. Use narrower credentials or a service-specific broker when that property is insufficient.

## Networking

All network configuration is native Microsandbox policy.

### No network

```bash
NETWORK_ARGS=(--no-net)
```

### Allowlist

```bash
NETWORK_ARGS=(
  --no-net
  --net-rule 'allow:egress@dns'
  --net-rule 'allow@api.example.com:tcp:443'
  --net-rule 'allow@*.example.org:tcp:443'
)
```

### Public network profile

```bash
NETWORK_ARGS=(--net public)
```

Microsandbox also supports private and host profiles, explicit ingress/egress defaults, CIDR and protocol rules, TLS controls, DNS controls, port forwarding, rate limits, and vsock mappings. Add their native flags to the profile.

Inspect the effective policy rather than assuming the command succeeded:

```sh
./bin/ade inspect work | jq '.active_config.network // .config.network'
```

## Lifecycle

```sh
./bin/ade create work      # create with the complete profile
./bin/ade up work          # create or explicitly start; do not attach
./bin/ade start work       # create/start, then native --tty attach
./bin/ade exec work -- CMD # bounded native --no-tty command
./bin/ade stream work -- CMD
./bin/ade stop work
./bin/ade restart work     # stop then start; keeps existing secret bindings
./bin/ade reimage work     # remove/recreate; preserve host mounts
./bin/ade inspect work
./bin/ade modify work -- MSB_MODIFY_ARGS...
./bin/ade remove work
```

The launcher does not use SSH. It does not keep a hidden state database. Microsandbox inspection is authoritative.

## Capability profiles

Use a separate named profile for each authority boundary. The supplied `work-offline` profile has no DNS exception, network destination, credential file, or secret source:

```sh
./bin/ade start work-offline
```

For cloud access, copy the deny-by-default template and configure only the identity mount and exact provider endpoints required by that VM:

```sh
mkdir -p ~/.config/ade/profiles
cp profiles/work-cloud.sh.example ~/.config/ade/profiles/work-cloud.sh
$EDITOR ~/.config/ade/profiles/work-cloud.sh
./bin/ade create work-cloud
```

Keep cloud credentials outside `/workspace` and other directories mounted into less-authorized VMs. AWS SigV4 and similar signed protocols generally require a dedicated credential directory, environment injection, SSO, or a credential helper rather than HTTP placeholder substitution.

## Custom profiles

Copy either checked-in profile and change any field:

```sh
mkdir -p ~/.config/ade/profiles
cp profiles/work.sh ~/.config/ade/profiles/client-a.sh
$EDITOR ~/.config/ade/profiles/client-a.sh
./bin/ade create client-a
```

For completely custom behavior, a profile may define `load_credentials` and populate any argument arrays dynamically.

## Version and isolation

Install the qualified runtime without replacing a system installation:

```sh
./scripts/install-msb.sh
```

The checksum-verified runtime is installed at `${XDG_DATA_HOME:-$HOME/.local/share}/ade/runtime/msb-0.6.10/bin/msb`, which the launcher discovers automatically. `MSB_BIN` can select another binary explicitly:

```sh
MSB_BIN=/path/to/msb-0.6.10 ./bin/ade start work
```

The launcher requires exactly `msb 0.6.10`. Use `MSB_HOME` normally or point it at an isolated root; the installer and launcher do not rewrite it or touch `~/.microsandbox` themselves.
