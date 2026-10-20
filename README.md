# ADE

Run coding agents inside named local Linux workbench VMs.

A workbench is one [SmolVM](https://github.com/smol-machines/smolvm) machine that
the agents of one identity share. It sees only the host directories you mount
into it and has none of your privileges. SmolVM stays authoritative for machine
existence and state; ADE is the policy around it.

## What is here

- `bin/`, `lib/` — the `ade` CLI, one small OCaml binary
- `workbenches/` — host-owned declarations, one per workbench
- `provision/arch.sh` — installs the guest's tooling after creation
- `docs/smolvm-workbenches.md` — the trust model and credential details
- `docs/smoke-run.md` — what to check on the first real run
- `docs/allowlist-workbench-sketch.md` — where this is going next

## Install

SmolVM, the upstream way:

```sh
brew install smol-machines/tap/smolvm                 # macOS
curl -sSL https://smolmachines.com/install.sh | bash  # Linux
```

On Linux the user needs access to `/dev/kvm`. ADE finds `smolvm` on `PATH`;
`ADE_SMOLVM_BIN` overrides that.

ADE itself needs OCaml 5.4 or later:

```sh
opam install . --deps-only --with-test
dune build
```

## Use

```sh
ade doctor               # check SmolVM, /dev/kvm, git are in place
ade create work          # create from the declaration, then provision it
ade start work           # ensure running
ade attach work          # start if needed, then attach (Herdr, if enabled)
ade exec work -- CMD
ade status work
ade stop work
ade pull work [REPO]     # bring the agents' branches back from clone mounts
ade provision work       # re-run the provision script (machine must be stopped)
ade rm work --yes        # delete the machine, its guest disk and ADE's state
```

Every command states an intended end state and is safe to repeat. Creating an
existing machine converges rather than recreating it.

## The guest

Workbenches run `docker.io/menci/archlinuxarm:base-devel`. It is a third-party
image, but the only one that is multi-arch (amd64 and arm64) and rebuilt daily
from Arch Linux ARM: the official `archlinux` image is amd64 only, and Artix has
no arm64 image. Because the guest runs `pacman -Syu`, pinning the image by digest
would not pin what the agents run, so the digest is optional; if you write one
(`name@sha256:...`) it is checked.

```toml
image = "docker.io/menci/archlinuxarm:base-devel"
provision = "../provision/arch.sh"   # relative to the declaration file
```

`provision` is optional. ADE runs the script once, right after creating the
machine, as root with `bash -s`, checks its exit status, and stops the machine.
The guest is booted without the SSH identity and without credentials for that
window, since it is installing software from the network. A failed script leaves
the machine created and stopped; fix it and run `ade provision NAME`. A `sealed`
workbench cannot declare `provision`, because installing packages needs a network.

`provision/arch.sh` installs git, jujutsu, base-devel, openssh, ripgrep, fd,
nodejs, npm and python, then Herdr (`herdr.dev/install.sh`) and Claude Code (its
native installer). Agents run as root in the guest and may `pacman -S` more, so
the shipped allowlists include the Arch mirror hosts. SmolVM's allowlist is
DNS-level and the Arch mirrors redirect between hosts, so expect to add one when
a mirror changes.

## Mounts

Nothing on the host is visible in a workbench unless its declaration mounts it:

```toml
[[mount]]
host = "~/code/project-a"
guest = "/src/project-a"        # read-only unless mode = "rw"

[[mount]]
host = "~/scratch/data"
guest = "/work/data"
mode = "rw"
```

Each host path is resolved, symlinks included, on the host that creates the
machine. ADE refuses the home directory and its ancestors; credential and
configuration stores (`~/.ssh`, `~/.gnupg`, `~/.config`, `~/.local/share`,
`~/Library` and similar); and its own state and declarations. It also refuses
a writable mount containing `.git` or `.jj`, because hooks, VCS config and
the jj operation log all act on the host the next time you run git or jj
there. Guest paths may not overlap each other or `/workspace`, `/run` and
the other system paths.

### Clone mode for repositories

A writable mount of a repository is a way out of the VM: git hooks, `.git/config`
(`core.fsmonitor`, filters, aliases) and jj's operation log all run on the host
the next time you use that tree. So repositories use `mode = "clone"`:

```toml
[[mount]]
host = "~/code/project-a"
mode = "clone"                  # guest defaults to /src/project-a, read-only
```

The agent clones into its own disk (`git clone /src/project-a /workspace/project-a`)
and commits, branches and rebases freely. `ade pull work` then has the guest
write `git bundle create /outbox/project-a.bundle --branches`, checks on the host
that the file is a regular file and a valid bundle, and fetches it into your
repository as `refs/remotes/agents/*` with object checking on. Your branches,
working tree and config are never touched; review and merge agent branches like a
colleague's. In a colocated jj repository, jj imports the refs on its next
command. Only the bundle crosses: fetching straight from the guest's clone would
run `upload-pack` inside a repository the guest controls.

A clone mount must be a git repository, and the repository's name (the last part
of the host path) may use only letters, digits, `.`, `_` and `-`. `/outbox` is
backed by ADE's own state directory for the workbench and is reserved. `git`
must be on the host's `PATH`.

Mounts and `--ssh-agent` are applied when the machine is created. Adding either
to an existing workbench takes effect after `ade rm` and `ade create`.

## What start does

`ade start`, and `attach` and `exec` when the workbench is stopped, bring it up
in this order. If a step fails, the steps before it are undone, so a failed
start leaves nothing running:

1. With `[ssh] mode = "dedicated_agent"`, start a host `ssh-agent` holding only
   the key named by `key_ref`. The VM gets this agent's socket, never yours,
   and never the key. The key must have no passphrase.
2. Boot the VM.
3. With `[credentials.github]`, mint an installation token scoped to the
   declared repositories and permissions, verify GitHub granted no more, and
   install it into guest tmpfs.

`ade stop` stops the VM, then its agent. Tokens are minted at start, so a
restart refreshes them.

Secret references (`key_ref`, `private_key_path`) take `keychain:ITEM` (macOS
Keychain), `pass:ENTRY` (password-store, the whole entry) or `file:PATH`.

## Trust model

A workbench VM is one security principal. Agents and tools inside one workbench
are mutually trusted at VM level: any process may read the workbench filesystem
and use the capabilities that workbench holds. Use different workbenches when
identities, data or authority must not mix.

Guest root is untrusted. The host, ADE, SmolVM and the hypervisor are inside
the trusted computing base. Credentials are written only to guest tmpfs under
`/run/ade/secrets`, but ADE cannot stop guest code copying one into persistent
state, so treat the guest disk as potentially secret-bearing.

## Testing

```sh
dune runtest                               # unit suites
python3 -m unittest discover -s test -t .  # CLI end-to-end against a fake SmolVM
```

## Status

Nothing has run against a real SmolVM, ssh-agent, `pass` or GitHub yet; the
tests use a fake runtime. Known gaps:

- The GitHub token check assumes the response carries `repository_selection`
  and `repositories`; confirm on the first real run.
- `ade pull` is tested against real git with a simulated guest, not a real VM.
- `provision/arch.sh` and the allowlist hosts for the Herdr and Claude Code
  installers are untested against the real services.
