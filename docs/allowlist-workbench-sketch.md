# Allow-list workbenches: a sketch

Not implemented. This proposes what ADE becomes if its first job is the one it
was started for: **run a group of agents in one VM that can see only the
directories I choose, reach only the hosts I choose, and act under an identity
that is not mine.**

It borrows from how Jane Street sandboxes agents (Signals and Threads, episode
31, "The Changing Craft of Programming"), adapted to a single macOS user:

- Allow-list, never deny-list. Their first sandbox let through anything it had
  no rule for; they replaced it.
- Friction is the real threat. Rules could not be added fast enough, so people
  turned the sandbox off. A denied action should become a question, not a
  dead end.
- Observe first, then write rules. They traced which files a process touched to
  build the allow-list instead of guessing it.
- The agent is its own principal. "The LLMs just inherit all the permissions of
  the human. And that's super wrong." Agents call as `AI <user>`, which also
  attributes their work.
- Treat the agent as an adversary even when it is not malicious. Models disabled
  warnings-as-errors and read reference solutions to pass.

Jane Street does this with bubblewrap, pasta and seccomp on Linux dev boxes.
ADE has to work on both macOS workstations and Linux machines (Artix), and
macOS has none of those. So the VM stays the boundary on both: SmolVM uses
Hypervisor.framework on macOS and KVM on Linux. What changes is what crosses it.

## The boundary, in one picture

```
host (trusted)                          workbench VM "agents" (untrusted)
─────────────────────────────           ──────────────────────────────────
~/code/project-a  ──── ro ────────────▶ /src/project-a
                                        /workspace/project-a   (agent's clone,
~/notes           ──── ro ────────────▶ /ref/notes              VM disk)
~/scratch/data    ──── rw ────────────▶ /work/data
state/agents/outbox ◀─ rw ───────────── /outbox                 (bundles out)

egress proxy (ade) ◀── only allowed ─── HTTPS_PROXY for every agent
  allow-list + ask                       no other route out
GitHub App token (scoped)  ── tmpfs ──▶ /run/ade/secrets
dedicated ssh-agent        ── socket ─▶ SSH_AUTH_SOCK
```

Nothing else from the host is visible: not `$HOME`, not `~/.ssh`, not the
Keychain, not your shell's environment, not your own ssh-agent.

## Declaration

```toml
name = "agents"
image = "file:artifacts/ade-workstation.tar@sha256:..."

[resources]
cpus = 6
memory_mib = 12288

# Every host path the VM can see. Nothing is mounted by default.
[[mount]]
host = "~/code/project-a"
mode = "clone"          # default for git repositories; see below

[[mount]]
host = "~/notes"
guest = "/ref/notes"
mode = "ro"

[[mount]]
host = "~/scratch/data"
guest = "/work/data"
mode = "rw"

[network]
posture = "proxied"     # all egress goes through ADE's proxy
allow = ["api.anthropic.com", "github.com", "api.github.com",
         "codeload.github.com", "registry.npmjs.org"]
on_deny = "ask"         # ask | fail

[identity.github]       # the agents' identity, not yours
app_id = "..."
installation_id = "..."
private_key = "keychain:ade-agents-app-key"
repositories = ["you/project-a"]
permissions = { contents = "write", pull_requests = "write" }

[identity.ssh]
key = "keychain:ade-agents-ssh"   # a key made for this workbench only

[services]
herdr = true
```

A workbench is a *group*: every agent in it shares its mounts, network and
identity. Put agents in the same workbench only when they may share all three.
That is the resource saving and the trust boundary in one decision.

## Mounts

### Path rules, checked on the host before anything starts

- The host path is resolved with `realpath`, so a symlink cannot widen it.
- These are refused outright, along with their ancestors: `/`, `$HOME`,
  `~/.ssh`, `~/.gnupg`, `~/.config`, `~/.aws`, `~/.kube`, `~/Library`,
  `~/.local/state/ade` and the declarations directory. Mounting `~/code` is
  allowed; mounting `~` is not.
- `ro` is the default. `rw` must be written out.
- Two mounts may not overlap unless the inner one is the more restrictive.

### Why git repositories default to `clone`

A writable mount of a repository is a way out of the VM. The agent never needs
to escape. It only has to write something that the host runs later without you
deciding to:

- `.git/hooks/*` runs on your next commit, checkout or merge.
- `.git/config` can set `core.fsmonitor`, `core.pager`, aliases, or
  `filter.*.smudge` and `clean`. Each is a command git runs on the host.
- `.jj/` holds jj's operation log, the repository store and, depending on
  the jj version, repository config (aliases, `fix.tools`, editors, signing
  programs). The guest could rewrite history or the commands jj runs.
- Editor auto-run config, such as `.vscode/tasks.json` or an exrc `.nvim.lua`.
  direnv is safe by default, because a changed `.envrc` needs `direnv allow`.

So there are three modes:

| mode | guest sees | how changes get back | host risk |
|---|---|---|---|
| `ro` | the tree, read-only | they don't | none from the mount |
| `clone` | `/src/<name>` read-only, and the agent clones it into `/workspace/<name>` on the VM disk | `ade pull`, which brings changes back as a git bundle | none: a bundle is data |
| `rw` | the tree, writable, with `.git` mounted read-only on top | you review and commit on the host | everything you later *run* from that tree |

`clone` is the mode to reach for. Inside the VM, the agent commits, branches and
rebases freely. `ade pull agents project-a` then runs:

```
guest: git -C /workspace/project-a bundle create /outbox/project-a.bundle --branches
host:  validate the bundle (git bundle verify, run with an empty config)
host:  git -C ~/code/project-a fetch <bundle> 'refs/heads/*:refs/remotes/agents/*'
```

With jj (colocated with git), the host side is `jj git fetch` from the same
bundle, or a `git fetch` followed by `jj git import`. The agent can use jj or
git inside the VM; only the bundle crosses.

Fetching from a bundle never reads the agent's config or runs its hooks. The
same is not true of fetching straight from the agent's clone over a local path,
because `upload-pack` runs inside that repository. Agent branches arrive as
`agents/*` remote-tracking refs, which you can review and merge like a
colleague's. This is the "untrusted export, validated on the host" pattern ADE
already uses for workspace backup, applied to code.

`rw` is for data directories, and for repositories where you want the agent's
edits to appear live in your editor. In that mode ADE refuses a tree containing
`.git` unless it can lay a read-only `.git` mount over the writable one. So the
agent can edit files but cannot commit, and cannot touch hooks or config.

## Network: an egress proxy that asks

SmolVM's `--allow-host` is a static list fixed when the machine is created.
Changing it means recreating the machine, which is exactly the friction that
gets sandboxes turned off. So instead:

1. The machine's only allowed destination is the host gateway, through a single
   `--allow-cidr`.
2. `ade` runs a small HTTP CONNECT proxy on that address, one per workbench.
   The guest image sets `HTTPS_PROXY` and `HTTP_PROXY` system-wide. Tools that
   ignore the proxy have no other route, so they fail closed.
3. The proxy matches the CONNECT host (and the TLS SNI, when it differs) against
   `network.allow`.
4. A host not on the list is held, not refused, when `on_deny = "ask"`:
   - a macOS notification and `ade net pending` show
     `agents wants registry.yarnpkg.com:443`;
   - `ade net allow agents registry.yarnpkg.com` lets it through once, or
     `--always` appends it to the declaration;
   - with no answer within a timeout, the request is refused and logged.
5. Every decision is logged: `ade net log agents`.

Learn mode is the same proxy with `on_deny = "allow-and-record"`. Run a task
once with it, then `ade net suggest agents` prints the hosts that were used, as
TOML to paste in. That is the network equivalent of Jane Street's seccomp
tracing.

An LLM classifier at the "ask" step is possible later. It belongs after the
human path works, not before.

The proxy sees host names, not request contents. It does not terminate TLS, so
it cannot tell `POST /repos/x/merges` from `GET /repos/x`. Operation-level limits
come from the identity's own scopes, as below, which is Jane Street's conclusion
too: file and network rules have a limit.

## Identity: the agents are not you

- **GitHub.** A GitHub App installation token, scoped to the declared
  repositories and permissions *in the token request*. ADE's current code
  validates the scopes but never sends them; that is fixed first. Commits and
  PRs show up as the App, so agent work is attributed for free. The token lasts
  an hour and lives only in guest tmpfs. ADE rotates it while the workbench
  runs.
- **SSH.** A key made for this workbench, loaded into a dedicated host
  ssh-agent whose socket is forwarded. Never your own agent, and never a key
  file inside the guest.
- **Model API.** A per-workbench API key, or a login done inside the VM. Your
  host login state is never copied in.
- **No host environment.** The guest gets nothing from the shell that ran `ade`.
  ADE's process runner already behaves this way.

What the agents cannot do, then: read anything you did not mount, reach
anything you did not allow, push anywhere the App is not installed, or sign
anything with your keys.

## Commands

```
ade up agents                  create if absent, start, start proxy + herdr, install identity
ade attach agents              herdr session (start first if needed)
ade down agents                stop VM, proxy and ssh-agent
ade pull agents [REPO]         bring agent branches back as agents/*
ade mount add agents PATH [--rw|--clone]   edit declaration, restart
ade net pending|allow|log|suggest agents
ade status agents              VM state, mounts, proxy, token expiry
```

`ade mount add` keeps the declaration as the only source of truth. It edits the
file and restarts the VM; it does not hot-plug.

## What happens to the rest of ADE

| keep | park (not delete) |
|---|---|
| declaration parsing and validation | reimage with journal |
| lifecycle and lock (fix stale lock) | backup / restore / pack |
| process runner | credential schedule and launchd |
| GitHub App minting (fix scoping) | multi-provider credential surface |
| ssh agent (finally wired in) | workspace bundle validator, until `pull` needs it |

With `clone` mode, the state worth keeping lives in your host repositories,
not on the VM disk. A broken workbench is `ade down` plus a delete and `ade up`,
which is why reimage and backup can wait.

## Build order

1. **Mounts.** `[[mount]]` in `Declaration`, the path rules, and `--volume` in
   `Smolvm.create_argv`. Qualify `ro`, `rw` and a read-only mount nested inside
   a writable one on the pinned SmolVM, including what uid guest-created files
   get on the host.
2. **`ade up` / `attach` actually starting things.** Herdr, the identity
   install, and the ssh-agent, all on the start path.
3. **GitHub scoping fix**, with a test that asserts the request body.
4. **`clone` mode and `ade pull`** via bundles.
5. **Egress proxy**, first with `fail`, then `ask`, then `allow-and-record`.

Steps 1 and 2 alone give you a usable "agents in a box with my chosen folders".
Steps 3 to 5 make the box tight without making it annoying.

## Open questions

- **Nested mounts.** Does SmolVM honor a read-only mount nested inside a
  writable one? If not, `rw` on a repository has to be refused, and `clone` is
  the only way to work on git trees.
- **Mount performance.** How fast is virtiofs on large trees like
  `node_modules` or `_build`? `clone` mode avoids the question, since the
  working copy is on the VM disk.
- **Proxy behind proxy.** Can tools that pin certificates or speak raw TCP
  (`git://`, some package managers) use the CONNECT proxy? Over plain HTTPS
  they can; other protocols get no fallback route.
- **One proxy per workbench, or one shared?** Per workbench keeps the logs and
  allow-lists separate. Shared is less to run.
