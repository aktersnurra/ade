# ADE

Run coding agents inside named local Linux workbench VMs.

A workbench is one [SmolVM](https://github.com/smol-machines/smolvm) machine that
the agents of one identity share. It sees only the host directories you mount
into it and has none of your privileges. SmolVM stays authoritative for machine
existence and state; ADE is the policy around it.

## What is here

- `bin/`, `lib/` — the `ade` CLI, one small OCaml binary
- `workbenches/` — example declarations, one per workbench
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

Declarations are read from `~/.config/ade/workbenches/NAME.toml`
(`$XDG_CONFIG_HOME/ade/workbenches` when that is set; `ADE_WORKBENCHES_DIR`
overrides both), never from the current directory: a declaration is policy, and
running `ade` inside a checkout that ships its own `workbenches/` must not let
that checkout choose it. Start from the examples here:

```sh
mkdir -p ~/.config/ade
cp -r workbenches provision ~/.config/ade/
```

Copy `provision/` too: declarations name their script relative to themselves.

## Use

```sh
ade doctor               # check SmolVM, /dev/kvm, git are in place
ade doctor work          # ...and that work's declaration loads and its secrets are readable
ade create work          # create from the declaration, then provision it
ade start work           # ensure running
ade attach work          # start if needed, then attach (Herdr, if enabled)
ade exec work -- CMD
ade status work
ade stop work
ade pull work [REPO]     # bring the agents' branches back from clone mounts
ade refresh work         # mint a fresh GitHub token into the running workbench
ade net pending work     # requests a proxied workbench's proxy refused
ade net allow work HOST  # let HOST through, until the next start or --always
ade net log work
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

Mounts, resources, the network and whether an SSH agent is forwarded are fixed
when the machine is created; changing them takes effect after `ade rm` and
`ade create`. ADE records what each machine was created with, so after such an
edit `ade status` reports the drift, `start`, `attach`, `exec` and `pull` warn,
and `create` refuses instead of claiming the machine matches. The SSH key,
credentials and Herdr apply at every start and are not drift.

## What start does

`ade start`, and `attach` and `exec` when the workbench is stopped, bring it up
in this order. If a step fails, the steps before it are undone, so a failed
start leaves nothing running:

1. With `[ssh] mode = "dedicated_agent"`, start a host `ssh-agent` holding only
   the key named by `key_ref`. The VM gets this agent's socket, never yours,
   and never the key. The key must have no passphrase.
2. With `posture = "proxied"`, start the workbench's egress proxy on the host.
3. Boot the VM, and tell a proxied guest where its proxy is.
4. With `[credentials.github]`, mint an installation token scoped to the
   declared repositories and permissions, verify GitHub granted no more, and
   install it into guest tmpfs.

5. With `[credentials.anthropic]`, install the API key into guest tmpfs.

`ade stop` stops the VM, then its agent and proxy.

GitHub tokens last an hour and are minted at start. `ade refresh NAME` mints
the next one into a running workbench without disturbing the agents, and is a
no-op for a stopped one, so it is safe to run from cron or a launchd agent
every half hour:

```
*/30 * * * * PATH=/usr/local/bin:/usr/bin:/bin ade refresh work
```

`smolvm` and, for `pass:` references, `pass` must be on that `PATH`;
a `pass` entry needs a gpg-agent that is already unlocked.

In the guest, `provision/arch.sh` points git at the token for
`https://github.com` (a credential helper reading
`/run/ade/secrets/current/github`) and exports `ANTHROPIC_API_KEY` from
`/run/ade/secrets/anthropic` in login and interactive shells:

```toml
[credentials.anthropic]
api_key_ref = "pass:ade/work-anthropic"   # a reference, never the key
```

Without it, log in to Claude Code inside the guest instead; that login is
stored on the guest disk.

Secret references (`key_ref`, `private_key_path`, `api_key_ref`) take `keychain:ITEM` (macOS
Keychain), `pass:ENTRY` (password-store, the whole entry) or `file:PATH`.

## Egress proxy

SmolVM's allowlist is fixed when the machine is created and works at the DNS
level. A `proxied` workbench instead may reach exactly one address, its proxy,
which ADE runs on the host:

```toml
[network]
posture = "proxied"
proxy = "127.0.0.1:3128"     # what the guest connects to; one port per workbench
hosts = ["github.com", "*.githubusercontent.com", "registry.npmjs.org:443"]
```

The proxy handles `CONNECT` and plain `http://` requests, one destination per
connection, and resolves names itself, refusing any that resolve to loopback
or link-local addresses. A host on the list goes through. Anything else gets a
403 that says how to allow it, and nothing in the guest can allow anything:

```sh
ade net pending work                         # what was refused, and why
ade net allow work registry.yarnpkg.com      # until the workbench next starts
ade net allow work registry.yarnpkg.com --always   # appended to work.allow
```

`work.allow` sits next to `work.toml`, one pattern a line, so ADE never rewrites
a file you wrote. The hosts, `work.allow` and the session approvals are read for
every request, so all three apply to a running workbench; only `proxy` is fixed
when the machine is created. A pattern is `HOST` (ports 443 and 80),
`HOST:PORT`, or `*.SUFFIX` (names below the suffix, not the suffix itself).

ADE writes `HTTPS_PROXY` and friends into the guest's shell profile (and
passes them to `ade exec` and provisioning, which read no profile) and a
Claude Code managed memory (`/etc/claude-code/CLAUDE.md`) telling agents that a
403 from the proxy means asking you, not working around it. Tools that ignore
the proxy variables have no route out at all. Git over SSH is not proxied; use
HTTPS remotes, which the guest's credential helper authenticates.

The proxy does not terminate TLS: it decides on names and ports, never on what
is sent. Operation-level limits come from the credentials' own scopes.

### Classifier

Optionally, a model on OpenRouter annotates each refused host in `ade net
pending` as routine or suspicious, with a reason:

```toml
[network.classifier]
model = "typesafe/jev-1.14"
api_key_ref = "pass:ade/openrouter"
```

The proxy runs in the background and cannot ask for a passphrase, so a `pass:`
key needs a gpg-agent that is already unlocked; otherwise the verdict reads
"unavailable" with the reason. It advises, never decides: a refused request
stays refused until you allow it.
It sees only the host, port and allowlist, which the agent can shape to
persuade it, so its answer is sanitized before it is stored or shown and is
never acted on. The call happens on the host after the refusal, so it adds no
delay. Those host names leave for OpenRouter; leave the classifier out where
they are confidential.

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
- The egress proxy is tested on the host, not from inside a guest: whether
  the guest reaches `network.proxy` (and only it) through
  `--allow-cidr ADDRESS/32` is for the first real run.
- The proxy log (`net/log` in the workbench's state) records every
  connection and is never rotated.
