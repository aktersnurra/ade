# First real run

Nothing in ADE has run against a real SmolVM yet. This is the shortest path to
find out what the fake runtime hid. Stop at the first failure and note what
SmolVM printed; most of these are one-line fixes.

```sh
ade doctor          # every line ok or warn; fix any FAIL first
```

## 1. A bare workbench

Copy `workbenches/work-offline.toml` (or any declaration) to
`~/.config/ade/workbenches/smoke.toml`, with `provision/` next to that
directory if you keep the provision line. Run `ade doctor smoke` once it is in
place. Remove `[ssh]` and `[credentials.github]`, so no key
or token is involved, and add a clone mount of a throwaway repository:

```toml
[[mount]]
host = "~/scratch/smoke-repo"     # a real git repo with one commit
mode = "clone"
```

Keep the allowlist and `provision = "../provision/arch.sh"` if you want to test
provisioning, or drop both for a faster first pass.

```sh
ade create smoke      # does the image pull? does provisioning finish?
ade start smoke
ade status smoke      # running
ade exec smoke -- uname -m
```

## 2. Mounts and the outbox

```sh
ade exec smoke -- ls -l /src/smoke-repo      # visible, read-only?
ade exec smoke -- touch /src/smoke-repo/x    # must fail: read-only
ade exec smoke -- git clone /src/smoke-repo /workspace/smoke-repo
ade exec smoke -- sh -c 'cd /workspace/smoke-repo && git switch -c agent && echo hi > f && git add f && git -c user.name=a -c user.email=a@a commit -m agent'
ade pull smoke
git -C ~/scratch/smoke-repo branch -r        # agents/agent present
jj log -r 'remote_bookmarks()' -R ~/scratch/smoke-repo   # if colocated
ls -ln ~/.local/state/ade/*/outbox 2>/dev/null           # which uid owns the bundle
```

Questions this answers: does `:ro` hold, which uid the outbox files get on the
host, whether the guest can write `/outbox`, whether jj imports the ref.

## 3. Network

```sh
ade exec smoke -- curl -sS -m 5 https://github.com     # allowed host
ade exec smoke -- curl -sS -m 5 https://example.com    # must fail
ade exec smoke -- curl -sS -m 5 https://1.1.1.1        # raw IP: blocked or not?
```

The last one decides the egress proxy design. If a raw IP gets through, the
SmolVM allowlist is a speed bump, not a boundary, and the proxy has to be
the only route out.

## 4. Identity and credentials (optional, needs setup)

Restore `[ssh]` with a passphrase-less key in `pass`, and `[credentials.github]`
with your GitHub App. Then `ade start`, and inside: `ssh-add -l` shows the key
and `git ls-remote` of a declared repository works; an undeclared one fails.
Confirm the token response carries `repository_selection` and `repositories`.

## Cleanup

```sh
ade rm smoke --yes
```
