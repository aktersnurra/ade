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
or token is involved, and add a throwaway repository:

```toml
[[repo]]
host = "~/scratch/smoke-repo"     # a real git repo with one commit
```

Keep the allowlist and `provision = "../provision/arch.sh"` if you want to test
provisioning, or drop both for a faster first pass.

```sh
ade create smoke      # does the image pull? does provisioning finish?
ade start smoke
ade status smoke      # running
ade exec smoke -- uname -m
```

## 2. The inbox and the outbox

```sh
ade exec smoke -- ls -l /inbox                # smoke-repo.bundle, read-only?
ade exec smoke -- touch /inbox/x              # must fail: read-only
ade exec smoke -- git -C /workspace/smoke-repo log --oneline   # cloned at start
ade exec smoke -- sh -c 'cd /workspace/smoke-repo && git switch -c agent && echo hi > f && git add f && git -c user.name=a -c user.email=a@a commit -m agent'
ade pull smoke
git -C ~/scratch/smoke-repo branch -r        # agents/agent present
jj log -r 'remote_bookmarks()' -R ~/scratch/smoke-repo   # if colocated
ls -ln ~/.local/state/ade/*/outbox 2>/dev/null           # which uid owns the bundle
```

Questions this answers: does `:ro` hold on the inbox, which uid the outbox files get on the
host, whether the guest can write `/outbox`, whether jj imports the ref.

## 3. Network

```sh
ade exec smoke -- curl -sS -m 5 https://github.com     # allowed host
ade exec smoke -- curl -sS -m 5 https://example.com    # must fail
ade exec smoke -- curl -sS -m 5 https://1.1.1.1        # raw IP: blocked or not?
```

If a raw IP gets through, the SmolVM allowlist is a speed bump, not a
boundary, and the proxied posture is the one to use.

### The proxy

Requires Linux/macOS and a SmolVM build with virtio-net and mediated-egress
v2. Verify `smolvm machine start --help` lists `--mediated-egress` and
`--egress-interceptor`; unsupported runtimes must fail, not boot with only
the CIDR rule.

Copy `workbenches/work-proxied.toml.example` to `smoke-proxy.toml` (rename
`name`, drop the classifier for now). Replace the documentation-only
`192.0.2.10` with an actual host IPv4 that the guest can reach and the host
can bind. Do not use guest loopback. Then:

```sh
ade create smoke-proxy && ade start smoke-proxy
ade exec smoke-proxy -- ip route                                  # what is the host from here?
ade exec smoke-proxy -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://github.com
ade exec smoke-proxy -- curl -sS -m 5 https://example.com         # 403 from ade
ade exec smoke-proxy -- curl -sS -m 5 --noproxy '*' https://github.com   # must fail: no direct route
ade net pending smoke-proxy                                       # example.com listed
```

Both guest reachability and host-side isolation must be checked. The tests
against the fake runtime exercise the real guard's protocol, not SmolVM's
enforcement. In particular:

1. Start a second proxied workbench on the **same host IP, another port**, with
   `example.com` allowed only there. From `smoke-proxy`, explicitly select that
   other proxy with `curl --proxy http://HOST:OTHER_PORT --noproxy '' -m 5
   https://example.com`. It must fail before reaching the other proxy. Using
   `smoke-proxy`'s own proxy must still work for `github.com`.
2. A direct TCP connection to another listening host port must also fail.
   Repeat with proxy variables unset; environment settings are not enforcement.
3. Kill the proxy daemon (PID in ADE's `workbenches/smoke-proxy/net/proxy.pid`).
   Networking must fail closed. `ade start smoke-proxy` must restore access
   without changing `net/guard.json` or rebooting the VM. Do not print that
   file: it contains the host authentication token.
4. `ade restart smoke-proxy` must rotate the binding. Stop must close both
   the proxy and guard listeners and remove `net/guard.json`.

If the selected address is unreachable, choose another host-assigned address
and recreate the machine, noting which one worked. If another proxy or host
port is reachable, stop the workbench: the host isolation check has failed.

## 4. Identity and credentials (optional, needs setup)

Restore `[ssh]` with a passphrase-less key in `pass`, and `[credentials.github]`
with your GitHub App. Then `ade start`, and inside: `ssh-add -l` shows the key
and `git ls-remote` of a declared repository works; an undeclared one fails.
Confirm the token response carries `repository_selection` and `repositories`.

## Cleanup

```sh
ade rm smoke --yes
```
