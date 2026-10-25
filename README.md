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
ade net revoke work HOST # take back an allow made this session
ade net log work         # every decision, including the classifier's
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

A `proxied` workbench uses SmolVM's **virtio-net backend and mediated-egress
v2 protocol** on Linux or macOS. The runtime must support `machine create
--net-backend virtio-net` and `machine start --mediated-egress
--egress-interceptor ADDR`, with `SMOLVM_INTERCEPTOR_TOKEN`. Older runtimes
fail rather than falling back to IP-only filtering.

The IP allowlist alone is not isolation: it permits every port on that IP.
ADE also runs an authenticated, host-only flow guard that allows TCP only to
this workbench's exact proxy IP and port. Another workbench's proxy on the same
host is denied. The token never enters the guest or command-line arguments;
it is kept in ADE's private host state and passed to SmolVM's environment.
SmolVM denies other datagrams in mediated mode except its own DNS handling.
See [SmolVM's protocol and platform requirements](https://github.com/smol-machines/smolvm/blob/main/docs/mediated-egress.md).

Choose a host IPv4 address the guest can reach and the host can bind:

```toml
[network]
posture = "proxied"
proxy = "192.0.2.10:3128"    # REPLACE with your reachable host IPv4; one port per workbench
hosts = ["github.com", "*.githubusercontent.com", "registry.npmjs.org:443"]
```

The example IP is a placeholder, not a usable default. Guest `127.0.0.1`
refers to the guest, not the host, on virtio-net. Verify the chosen address
with [the real-VM smoke checks](docs/smoke-run.md).

An already-running workbench from before this guard must be explicitly
restarted. Older machines created with a different network backend need to
be recreated (preserve any wanted guest data first). Proxy recovery reuses
the running VM's binding; a new workbench start rotates it. A missing or
corrupt binding fails closed and requires a restart.

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
A revocation overrides session wildcards as well as exact session grants.
Persistent grants in the declaration or `NAME.allow` remain authoritative;
`net revoke` warns if one still permits the host.

ADE writes `HTTPS_PROXY` and friends into the guest's shell profile (and
passes them to `ade exec` and provisioning, which read no profile) and a
Claude Code managed memory (`/etc/claude-code/CLAUDE.md`) telling agents that a
403 from the proxy means asking you, not working around it. Tools that ignore
the proxy variables have no route out at all. Git over SSH is not proxied; use
HTTPS remotes, which the guest's credential helper authenticates.

The proxy does not terminate TLS: it decides on names and ports, never on what
is sent. Operation-level limits come from the credentials' own scopes.

### Classifier

With a classifier, a host no pattern allows is put to a model on OpenRouter,
which answers allow, ask or deny:

```toml
[network.classifier]
model = "typesafe/jev-1.14"
api_key_ref = "pass:ade/openrouter"
```

- **allow**: the request goes through, and that exact `host:port` stays
  allowed until the workbench next starts. Registries, source hosts,
  toolchains, mirrors and documentation sites should land here, so most new
  hosts cost you nothing.
- **ask**: refused with the "ade net allow" message. Hosts the model does not
  recognise, paste and file-sharing services, and a model that is down, slow
  (more than 10 seconds) or answers nonsense all land here.
- **deny**: refused with the model's reason, and listed in `ade net pending`
  in case it is wrong.

The request waits for the answer, once per host per run; later requests for
the same host reuse it. `ade net log` shows every automatic allow
(`auto`), and `ade net revoke work HOST` takes one back for the rest of the
session.

The host name is written by the agent, so it is the one input that can be
shaped to talk the model round. Two things limit that. Names shaped to carry
data rather than name a service (raw IP addresses, punycode, a label over 40
characters, more than six labels) go to you without the model seeing them,
because once allowed, even looking a name up delivers it to that domain's DNS
server. And an automatic allow is never a wildcard, never another port, and
never written to `work.allow`; making it permanent stays your call.

An allowed, well-known host can still carry data out (publishing a package,
creating a gist): the proxy sees names, not requests. Keep the classifier off,
and the allowlist short, for workbenches holding data that must not leave. The
classifier sends OpenRouter the requested host and the allowlist, so leave it
out where those names are confidential.

The proxy runs in the background and cannot ask for a passphrase, so a `pass:`
key needs a gpg-agent that is already unlocked; otherwise every verdict is
"ask", with the reason.

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

Run for real on Artix x86_64 with SmolVM 1.32.4: `create` with provisioning
from `provision/arch.sh`, `start`, `exec`, `attach` with a command, `stop`,
`provision` re-run, `pull` from a clone mount (jj imports the refs in a
colocated repository), and `rm`. The allowlist is enforced by IP, not only by
DNS: unlisted names and raw IPs are refused. Not yet run for real:

- `[ssh] mode = "dedicated_agent"`, `pass:` secrets and `[credentials.github]`.
  The GitHub token check assumes the response carries `repository_selection`
  and `repositories`; confirm on the first real run.
- macOS arm64.
- The egress proxy is tested on the host, not from inside a guest: whether
  the guest reaches `network.proxy` (and only it) through
  `--allow-cidr ADDRESS/32` is for the first real run.
- The proxy log (`net/log` in the workbench's state) records every
  connection and is never rotated.
