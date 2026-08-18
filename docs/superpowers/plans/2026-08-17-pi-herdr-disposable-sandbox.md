# Disposable Pi Sandbox for Host-Side Herdr Implementation Plan

**Status:** Historical completed spike

**Superseded by:** [`2026-08-18-named-workbench-terminal-design.md`](../specs/2026-08-18-named-workbench-terminal-design.md)

> **Historical record:** Do not execute this plan as current ADE work. It records the completed disposable host-side Herdr spike.

**Goal:** Create and provision one disposable Microsandbox VM that runs Pi while Herdr remains entirely on the trusted host.

**Architecture:** Build no new image and modify no existing sandbox. Create `ade-pi-herdr-test` from the validated local Nix workstation image, install Node and Pi only in its writable guest root, verify the host/guest boundary, then stop it for an interactive Ghostty launch.

**Tech Stack:** Microsandbox 0.6.8 (`msb`), Nix, Node.js 22, npm, Pi 0.84.2, Python 3 for targeted JSON assertions, Jujutsu.

## Global Constraints

- Use local image `gatekeep-nix-workstation:spike-v3` with manifest digest prefix `sha256:ea551ebb9355`.
- Name the new sandbox `ade-pi-herdr-test`.
- Allocate 2 virtual CPUs, 4 GiB RAM, and an 8 GiB writable disposable root disk.
- Allow public egress and Microsandbox gateway DNS on TCP/UDP port 53 only; deny all ingress and all other host/private access.
- Do not mount or copy host files, directories, named volumes, credentials, sockets, or host Pi state.
- Do not forward ports, secrets, host environment variables, SSH agents, or `HERDR_*` variables.
- Install `@earendil-works/pi-coding-agent@0.84.2` under `/root/.local` with Node >=22.19.0.
- Never install Herdr in the guest, run `herdr --remote`, expose the Herdr API, or mount the Herdr socket.
- Do not read host shell startup files or broad home-directory configuration.
- Do not replace or modify an existing sandbox.
- Do not launch the interactive Pi TUI from automation.

## File Structure

No product source or image definition changes are required. Implementation changes only Microsandbox runtime state by creating `ade-pi-herdr-test`.

- Reference: `docs/superpowers/specs/2026-08-17-pi-herdr-disposable-sandbox-design.md`
- Create at runtime: Microsandbox VM `ade-pi-herdr-test`
- Modify inside the new VM only: Nix root profile and `/root/.local`

---

### Task 1: Preflight and Create the Isolated Sandbox

**Files:**

- Modify: none
- Create at runtime: Microsandbox VM `ade-pi-herdr-test`

**Interfaces:**

- Consumes: local image `gatekeep-nix-workstation:spike-v3`
- Produces: a running, empty Pi test VM with the approved resource and network policy

- [ ] **Step 1: Verify the image and sandbox name without changing state**

Run:

```sh
python3 - <<'PY'
import subprocess

image = "gatekeep-nix-workstation:spike-v3"
digest_prefix = "sha256:ea551ebb9355"
name = "ade-pi-herdr-test"

images = subprocess.run(
    ["msb", "image", "list"],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()
matching = [line.split() for line in images[1:] if line.split() and line.split()[0] == image]
assert len(matching) == 1, f"expected one local image {image}, found {len(matching)}"
assert matching[0][1].startswith(digest_prefix), matching[0][1]

sandboxes = subprocess.run(
    ["msb", "list"],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()
names = {line.split()[0] for line in sandboxes[1:] if line.split()}
assert name not in names, f"sandbox already exists: {name}"
print("preflight_ok")
PY
```

Expected output:

```text
preflight_ok
```

If the name already exists, stop. Do not use `--replace` and do not modify the existing sandbox.

- [ ] **Step 2: Create the sandbox with explicit resource and network controls**

Run:

```sh
msb create \
  --name ade-pi-herdr-test \
  --cpus 2 \
  --memory 4G \
  --root-disk 8G \
  --workdir /workspace \
  --env 'PATH=/root/.local/bin:/nix/var/nix/profiles/per-user/root/profile/bin:/bin' \
  --net-rule 'allow:egress@host:tcp:53' \
  --net-rule 'allow:egress@host:udp:53' \
  --net-rule 'allow:egress@public' \
  --net-default deny \
  --pull never \
  gatekeep-nix-workstation:spike-v3
```

Expected: `msb create` exits successfully and creates `ade-pi-herdr-test`. The command contains no mount, copy, port, secret, or host-derived environment option.

- [ ] **Step 3: Assert the resulting runtime configuration**

Run:

```sh
python3 - <<'PY'
import json
import subprocess

expected_digest = "sha256:ea551ebb9355"
raw = subprocess.run(
    ["msb", "inspect", "--format", "json", "ade-pi-herdr-test"],
    check=True,
    capture_output=True,
    text=True,
).stdout
state = json.loads(raw)
config = state["config"]
network = config["network"]
policy = network["policy"]
rules = policy["rules"]

assert config["image"]["Oci"]["reference"] == "gatekeep-nix-workstation:spike-v3"
assert config["manifest_digest"].startswith(expected_digest)
assert config["image"]["Oci"]["root_disk"] == {"kind": "managed", "size_mib": 8192}
assert config["resources"]["cpus"] == 2
assert config["resources"]["memory_mib"] == 4096
assert config["runtime"]["workdir"] == "/workspace"
assert policy["default_egress"] == "deny"
assert policy["default_ingress"] == "deny"
assert network["ports"] == []
assert network["secrets"]["secrets"] == []
assert all(mount["type"] == "Tmpfs" for mount in config["mounts"]), config["mounts"]

env_names = {item["key"] for item in config["env"]}
assert not any(name.startswith("HERDR_") for name in env_names), env_names

public_rules = [
    rule for rule in rules
    if rule["action"] == "allow"
    and rule["direction"] == "egress"
    and rule["destination"] == {"group": "public"}
    and rule["ports"] == []
]
assert len(public_rules) == 1, rules

host_rules = [rule for rule in rules if rule["destination"] == {"group": "host"}]
assert len(host_rules) == 2, host_rules
assert {tuple(rule["protocols"]) for rule in host_rules} == {("tcp",), ("udp",)}
for dns in host_rules:
    assert dns["action"] == "allow"
    assert dns["direction"] == "egress"
    assert dns["ports"] == [{"start": 53, "end": 53}]

allowed_rules = public_rules + host_rules
assert len(rules) == len(allowed_rules), rules
print("sandbox_policy_ok")
PY
```

Expected output:

```text
sandbox_policy_ok
```

If an assertion fails, run `msb stop ade-pi-herdr-test`, report the failed assertion, and do not install packages.

---

### Task 2: Install Node and Pi in the Guest Root

**Files:**

- Modify inside guest: `/nix/var/nix/profiles/per-user/root/profile`
- Create inside guest: `/root/.local`
- Modify on host: none

**Interfaces:**

- Consumes: running sandbox `ade-pi-herdr-test`
- Produces: guest commands `node`, `npm`, and `pi` on the sandbox-configured `PATH`

- [ ] **Step 1: Confirm Pi is absent before installation**

Run:

```sh
python3 - <<'PY'
import subprocess

probe = subprocess.run(
    ["msb", "ssh", "ade-pi-herdr-test", "--", "command", "-v", "pi"],
    capture_output=True,
    text=True,
)
assert probe.returncode != 0, f"unexpected Pi before install: {probe.stdout.strip()}"
print("pi_absent_before_install")
PY
```

Expected output:

```text
pi_absent_before_install
```

- [ ] **Step 2: Install Node 22 and Pi entirely inside the guest**

Run:

```sh
python3 - <<'PY'
import subprocess

name = "ade-pi-herdr-test"
script = r'''
set -eu
profile=/nix/var/nix/profiles/per-user/root/profile
nix --option build-users-group '' profile install --profile "$profile" nixpkgs#nodejs_22
export PATH="/root/.local/bin:$profile/bin:/bin"
test -x /bin/env
mkdir -p /usr/bin
test -e /usr/bin/env || ln -s /bin/env /usr/bin/env
npm install --global --prefix /root/.local @earendil-works/pi-coding-agent@0.84.2
'''
try:
    subprocess.run(["msb", "ssh", name, "--", "sh", "-lc", script], check=True)
except subprocess.CalledProcessError:
    subprocess.run(["msb", "stop", name], check=False)
    raise
print("guest_install_ok")
PY
```

Expected: Nix and npm finish successfully. No provider authentication is requested or supplied.

- [ ] **Step 3: Verify Node and Pi versions without launching the Pi TUI**

Run:

```sh
python3 - <<'PY'
import subprocess

script = r'''
set -eu
node -e '
  const [major, minor] = process.versions.node.split(".").map(Number);
  if (major < 22 || (major === 22 && minor < 19)) process.exit(1);
  console.log(`node_version_ok=${process.versions.node}`);
'
version="$(pi --version)"
printf "%s\n" "$version" | grep -Eq "(^|[^0-9])0[.]84[.]2([^0-9]|$)"
printf "pi_version_ok=%s\n" "$version"
'''
subprocess.run(
    ["msb", "ssh", "ade-pi-herdr-test", "--", "sh", "-lc", script],
    check=True,
)
PY
```

Expected output contains:

```text
node_version_ok=
pi_version_ok=
```

and the Pi version line contains `0.84.2`.

---

### Task 3: Verify Isolation, Stop the VM, and Hand Off the Ghostty Command

**Files:**

- Modify: none

**Interfaces:**

- Consumes: provisioned sandbox `ade-pi-herdr-test`
- Produces: a stopped Pi-ready sandbox and the exact host-side interactive launch command

- [ ] **Step 1: Verify guest-visible names and executables without printing environment values**

Run:

```sh
python3 - <<'PY'
import subprocess

script = r'''
set -eu
command -v pi >/dev/null
if command -v herdr >/dev/null 2>&1; then
  echo "herdr_present_in_guest" >&2
  exit 1
fi
names="$(env | cut -d= -f1 | grep "^HERDR_" || true)"
if [ -n "$names" ]; then
  printf "guest_herdr_env_names=%s\n" "$(printf "%s" "$names" | paste -sd, -)" >&2
  exit 1
fi
if find /run /var/run /tmp -type s -iname "*herdr*" -print -quit 2>/dev/null | grep -q .; then
  echo "herdr_socket_present_in_guest" >&2
  exit 1
fi
echo "guest_boundary_ok"
'''
subprocess.run(
    ["msb", "ssh", "ade-pi-herdr-test", "--", "sh", "-lc", script],
    check=True,
)
PY
```

Expected output:

```text
guest_boundary_ok
```

- [ ] **Step 2: Stop the sandbox and verify its final state**

Run:

```sh
msb stop ade-pi-herdr-test
python3 - <<'PY'
import subprocess

lines = subprocess.run(
    ["msb", "list"],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()
rows = [line.split() for line in lines[1:] if line.split() and line.split()[0] == "ade-pi-herdr-test"]
assert len(rows) == 1, rows
assert rows[0][2] == "stopped", rows[0]
print("sandbox_ready_and_stopped")
PY
```

Expected output:

```text
sandbox_ready_and_stopped
```

- [ ] **Step 3: Report the exact interactive Ghostty launch command**

Do not run this command from automation. Give it to the user to run directly in Ghostty:

```sh
HERDR_AGENT=pi msb ssh ade-pi-herdr-test -- pi
```

State explicitly that `HERDR_AGENT=pi` is set only on the trusted host's `msb` process. If Pi asks for provider authentication, the user must authenticate independently inside the guest; no host credential or host Pi state may be copied, mounted, or forwarded.
