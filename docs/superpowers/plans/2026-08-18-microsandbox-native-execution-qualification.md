# Microsandbox 0.6.10 Native Execution Qualification Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to execute this plan task by task. Stop on the first mandatory failure.

**Goal:** Qualify Microsandbox 0.6.10 lifecycle, root and project-store persistence, native terminal execution, command execution, and streaming on Apple silicon macOS without changing Homebrew Microsandbox, existing sandboxes, or ADE product code.

**Architecture:** Download and verify the official 0.6.10 release into an isolated temporary root. Use an isolated `MSB_HOME`, one digest-pinned Alpine fixture, two fixed sandbox names, and separate project-store directories. Exercise guest access only through native `msb exec`. Generate the validation document from a structured result ledger.

**Tech Stack:** Microsandbox 0.6.10, Apple silicon macOS, Python 3 standard library, POSIX shell tools, Alpine arm64 fixture, Jujutsu.

## Locked decisions

- ADE V1 does not require standard SSH compatibility.
- Interactive entry uses `msb exec --tty <sandbox>` only after ADE explicitly establishes `Running`.
- Bounded commands use `msb exec --no-tty <sandbox> -- <command>`.
- Bidirectional byte-stream operations use `msb exec --stream <sandbox> -- <command>` only when needed.
- ADE V1 exposes no arbitrary host-path copy operation.
- ADE must not rely on `msb exec` to start a stopped workbench implicitly.
- The rejected `msb ssh serve --stdio` experiment is historical evidence, not a qualification requirement.

## Global constraints

- Run only on `Darwin` and `arm64`.
- Download only `https://github.com/superradcompany/microsandbox/releases/download/v0.6.10/microsandbox-darwin-aarch64.tar.gz`.
- Require archive SHA-256 `a1742728676bbdfa3850e59df4b85b9df7dabcfd7e1c270876725aecdd3e992c`.
- Set `MSB_HOME` and `DYLD_LIBRARY_PATH` explicitly for every qualified command.
- Do not modify `/opt/homebrew/bin/msb` or `$HOME/.microsandbox`.
- Do not inspect or modify existing sandboxes beyond reading `/opt/homebrew/bin/msb --version`.
- Pull only `alpine@sha256:e7a1a92a5bfeee40966aea60f0796b0e7917cc35591542701834f03a68fa3d18`.
- Create only `ade-msb-0610-work` and `ade-msb-0610-personal` in the isolated home.
- Never pass `--replace`.
- Mount only qualification-owned directories at Alpine's existing `/mnt` mount point.
- Apply `--no-net` before guest execution.
- Do not mount the repository, home directory, credentials, sockets, Pi state, or host application state.
- Do not run `msb ssh`, OpenSSH, an SSH listener, or guest `sshd`.
- Do not forward ambient host environment values. Guest probes must confirm that `SSH_AUTH_SOCK` and a qualification canary are absent.
- Kill exact test process groups on timeout or failure.
- Always remove the two exact sandboxes and temporary root.
- Use `jj` for repository operations.

## Scope

This plan proves:

- official 0.6.10 archive provenance;
- isolated named-sandbox lifecycle behavior;
- deny-by-default networking;
- separate persistent project stores;
- writable-root and project-store stop/start persistence;
- root replacement with project-store preservation;
- native captured, streamed, and PTY execution;
- PTY resize, signal, disconnect, stop, and concurrent-client behavior;
- observed stopped-sandbox lifecycle ownership behavior;
- absence of ambient host authority.

This plan does not prove:

- the production Nix workstation image;
- ADE lifecycle locks, operation-start leases, or structured errors;
- protected capabilities or gatekeepers;
- Artix/KVM support;
- standard SSH interoperability.

## Output

- Create: `docs/superpowers/specs/2026-08-18-microsandbox-0.6.10-native-execution-validation.md`
- Runtime only: `$QUAL_ROOT/**`

---

### Task 1: Establish the isolated runtime

- [ ] **Create the temporary root and cleanup functions**

```sh
set -euo pipefail
cd "$(jj root)"

export QUAL_ROOT
QUAL_ROOT="$(cd "$(mktemp -d "/private/tmp/ade-msb-0610-native.XXXXXX")" && pwd -P)"
export MSB_HOME="$QUAL_ROOT/msb-home"
export MSB_BIN="$QUAL_ROOT/bin/msb"
export MSB_DYLD_DIR="$QUAL_ROOT/bin"
export RESULT_TSV="$QUAL_ROOT/evidence/results.tsv"
export QUAL_LOG="$QUAL_ROOT/evidence/qualification.log"

mkdir -p "$QUAL_ROOT"/{bin,download,evidence,stores/work,stores/personal}
: >"$RESULT_TSV"
: >"$QUAL_LOG"

record_pass() { printf '%s\tpass\t%s\n' "$1" "$2" >>"$RESULT_TSV"; }

cleanup_sandboxes() {
  if [ -x "$MSB_BIN" ]; then
    for name in ade-msb-0610-work ade-msb-0610-personal; do
      env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" \
        "$MSB_BIN" stop "$name" >/dev/null 2>&1 || true
      env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" \
        "$MSB_BIN" remove "$name" >/dev/null 2>&1 || true
    done
  fi
}

cleanup_root() {
  cleanup_sandboxes
  case "$QUAL_ROOT" in
    /private/tmp/ade-msb-0610-native.*|/tmp/ade-msb-0610-native.*|/private/var/folders/*/ade-msb-0610-native.*|/var/folders/*/ade-msb-0610-native.*)
      rm -rf "$QUAL_ROOT" ;;
    *) printf 'refusing unsafe cleanup: %s\n' "$QUAL_ROOT" >&2; return 1 ;;
  esac
}

trap cleanup_root EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
```

- [ ] **Verify host preconditions and install the isolated release**

```sh
test "$(uname -s)" = Darwin
test "$(uname -m)" = arm64
printf 'source_msb=%s\n' "$(/opt/homebrew/bin/msb --version)" | tee -a "$QUAL_LOG"

curl --fail --location --proto '=https' --tlsv1.2 \
  -o "$QUAL_ROOT/download/microsandbox-darwin-aarch64.tar.gz" \
  https://github.com/superradcompany/microsandbox/releases/download/v0.6.10/microsandbox-darwin-aarch64.tar.gz
printf '%s  %s\n' \
  a1742728676bbdfa3850e59df4b85b9df7dabcfd7e1c270876725aecdd3e992c \
  "$QUAL_ROOT/download/microsandbox-darwin-aarch64.tar.gz" | shasum -a 256 -c -
tar -xzf "$QUAL_ROOT/download/microsandbox-darwin-aarch64.tar.gz" -C "$QUAL_ROOT/bin"
chmod 0755 "$MSB_BIN"
test "$(env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" "$MSB_BIN" --version)" = 'msb 0.6.10'
test -z "$(env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" "$MSB_BIN" list | tail -n +2 | sed '/^[[:space:]]*$/d')"
record_pass release_archive 'official msb 0.6.10 archive checksum and version verified'
```

- [ ] **Feature-probe native operations**

```sh
env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" "$MSB_BIN" exec --help \
  | tee "$QUAL_ROOT/evidence/exec-help.txt"
for flag in --tty --no-tty --stream --timeout; do
  grep -F -- "$flag" "$QUAL_ROOT/evidence/exec-help.txt"
done
record_pass native_feature_probe 'tty, no-tty, stream, and timeout operations exposed'
```

### Task 2: Create isolated workbench fixtures

- [ ] **Pull and inspect the digest-pinned fixture**

```sh
export FIXTURE_IMAGE='alpine@sha256:e7a1a92a5bfeee40966aea60f0796b0e7917cc35591542701834f03a68fa3d18'
env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" "$MSB_BIN" image pull "$FIXTURE_IMAGE"
env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" \
  "$MSB_BIN" image inspect --format json "$FIXTURE_IMAGE" >"$QUAL_ROOT/evidence/image.json"
python3 - "$QUAL_ROOT/evidence/image.json" <<'PY'
import json, sys
image = json.load(open(sys.argv[1], encoding="utf-8"))
assert image["digest"] == "sha256:e7a1a92a5bfeee40966aea60f0796b0e7917cc35591542701834f03a68fa3d18"
assert image["architecture"] == "arm64"
PY
record_pass fixture_image 'digest-pinned Alpine arm64 fixture verified'
```

- [ ] **Create exactly two running no-network sandboxes**

```sh
for name in work personal; do
  env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" \
    "$MSB_BIN" create --name "ade-msb-0610-$name" \
      --cpus 2 --memory 2G --root-disk 4G \
      --mount-dir "$QUAL_ROOT/stores/$name:/mnt" \
      --workdir /mnt --no-net --pull never "$FIXTURE_IMAGE"
done

python3 - "$MSB_BIN" "$MSB_HOME" "$MSB_DYLD_DIR" <<'PY'
import json, os, subprocess, sys
msb, home, dylib = sys.argv[1:]
env = os.environ | {"MSB_HOME": home, "DYLD_LIBRARY_PATH": dylib}
for name in ("ade-msb-0610-work", "ade-msb-0610-personal"):
    doc = json.loads(subprocess.check_output([msb, "inspect", "--format", "json", name], env=env))
    policy = doc["config"]["network"]["policy"]
    assert policy["default_ingress"] == "deny"
    assert policy["default_egress"] == "deny"
    assert policy["rules"] == []
PY
record_pass sandbox_create 'two isolated running fixtures use separate stores and deny-all networking'
```

### Task 3: Qualify non-interactive and streamed execution

- [ ] **Verify captured commands, exit status, workdir, and environment**

```sh
msbq() { env MSB_HOME="$MSB_HOME" DYLD_LIBRARY_PATH="$MSB_DYLD_DIR" "$MSB_BIN" "$@"; }

test "$(msbq exec --no-tty ade-msb-0610-work -- uname -m)" = aarch64
test "$(msbq exec --no-tty -w /mnt ade-msb-0610-work -- pwd)" = /mnt
test "$(msbq exec --no-tty -e ADE_TEST=value ade-msb-0610-work -- sh -lc 'printf %s "$ADE_TEST"')" = value
if msbq exec --no-tty ade-msb-0610-work -- sh -c 'exit 23'; then
  echo 'non-zero guest command unexpectedly passed' >&2; exit 1
else
  test "$?" -eq 23
fi
record_pass no_tty_exec 'captured command output, options, and exit status preserved'
```

- [ ] **Verify bidirectional stream behavior and bounded timeout**

```sh
test "$(printf 'stream-input\n' | msbq exec --stream ade-msb-0610-work -- sh -lc 'IFS= read -r line; printf "stream:%s" "$line"')" = 'stream:stream-input'

start=$(date +%s)
set +e
msbq exec --no-tty --timeout 2s ade-msb-0610-work -- sh -lc \
  'sleep 30; printf timeout_normal_completion' \
  >"$QUAL_ROOT/evidence/timeout.out" \
  2>"$QUAL_ROOT/evidence/timeout.err"
timeout_rc=$?
set -e
test "$timeout_rc" -ne 0
test "$(( $(date +%s) - start ))" -lt 10
! grep -F timeout_normal_completion "$QUAL_ROOT/evidence/timeout.out"
grep -Eqi 'timeout|timed out|deadline' "$QUAL_ROOT/evidence/timeout.err"
record_pass stream_and_timeout 'stream round-trip and explicit command timeout passed with timeout evidence'
```

- [ ] **Verify network denial, store separation, persistence, and ambient-authority absence**

```sh
export SSH_AUTH_SOCK="$QUAL_ROOT/host-ssh-agent-canary"
export ADE_QUAL_HOST_ENV_CANARY=host-environment-canary
test -n "$SSH_AUTH_SOCK"
test -n "$ADE_QUAL_HOST_ENV_CANARY"
for name in work personal; do
  msbq exec --no-tty "ade-msb-0610-$name" -- sh -lc \
    'command -v wget >/dev/null; ! wget -T 3 -qO- https://example.com >/dev/null 2>&1; ! wget -T 3 -qO- http://192.168.1.1 >/dev/null 2>&1'
  test "$(msbq exec --no-tty "ade-msb-0610-$name" -- sh -lc 'printf "%s|%s" "${SSH_AUTH_SOCK-unset}" "${ADE_QUAL_HOST_ENV_CANARY-unset}"')" = 'unset|unset'
done
unset SSH_AUTH_SOCK ADE_QUAL_HOST_ENV_CANARY
printf work-marker >"$QUAL_ROOT/stores/work/marker"
printf personal-marker >"$QUAL_ROOT/stores/personal/marker"
msbq exec --no-tty ade-msb-0610-work -- sh -lc \
  'printf work-root-marker >/root/ade-root-marker'
msbq exec --no-tty ade-msb-0610-personal -- sh -lc \
  'printf personal-root-marker >/root/ade-root-marker'
test "$(msbq exec --no-tty ade-msb-0610-work -- cat /mnt/marker)" = work-marker
test "$(msbq exec --no-tty ade-msb-0610-personal -- cat /mnt/marker)" = personal-marker

for name in work personal; do
  msbq stop "ade-msb-0610-$name"
  msbq start "ade-msb-0610-$name"
done

test "$(msbq exec --no-tty ade-msb-0610-work -- cat /root/ade-root-marker)" = work-root-marker
test "$(msbq exec --no-tty ade-msb-0610-personal -- cat /root/ade-root-marker)" = personal-root-marker
test "$(msbq exec --no-tty ade-msb-0610-work -- cat /mnt/marker)" = work-marker
test "$(msbq exec --no-tty ade-msb-0610-personal -- cat /mnt/marker)" = personal-marker
record_pass isolation_and_persistence 'network, authority, root, and separate project stores persisted across stop-start'
```

- [ ] **Verify root replacement preserves only the project store**

```sh
msbq stop ade-msb-0610-personal
msbq remove ade-msb-0610-personal
msbq create --name ade-msb-0610-personal \
  --cpus 2 --memory 2G --root-disk 4G \
  --mount-dir "$QUAL_ROOT/stores/personal:/mnt" \
  --workdir /mnt --no-net --pull never "$FIXTURE_IMAGE"

set +e
msbq exec --no-tty ade-msb-0610-personal -- test -e /root/ade-root-marker \
  >"$QUAL_ROOT/evidence/replaced-root-check.out" \
  2>"$QUAL_ROOT/evidence/replaced-root-check.err"
root_check_rc=$?
set -e
test "$root_check_rc" -eq 1
test -z "$(awk '!/^[[:space:]]*• Backend[[:space:]]+local[[:space:]]*$/' "$QUAL_ROOT/evidence/replaced-root-check.err")"
test "$(msbq exec --no-tty ade-msb-0610-personal -- cat /mnt/marker)" = personal-marker
record_pass root_replacement 'replacement removed writable-root marker and preserved the project store'
```

### Task 4: Qualify interactive PTY behavior

- [ ] **Run the PTY, resize, signal, concurrency, and stop harness**

Create `$QUAL_ROOT/pty_harness.py`. It must:

1. spawn `msb exec --tty ade-msb-0610-work` with `pty.fork()`;
2. send `echo ADE_TTY_READY` and require the marker within 10 seconds;
3. apply `TIOCSWINSZ` with rows 37 and columns 113, then require `stty size` to return `37 113`;
4. run `sleep 30`, send `Ctrl-C`, and require the shell to accept `echo ADE_SIGNAL_OK` afterward;
5. close one client process group and verify a new PTY client can attach;
6. run four concurrent PTY clients and require four unique completion markers;
7. attach one final client, call `msb stop ade-msb-0610-work`, and require the client to exit within 15 seconds without a normal-completion marker;
8. terminate the exact process group on every failure path.

The harness must use only Python's standard library and the isolated environment variables. Record elapsed stop-to-client-exit time.

```sh
python3 "$QUAL_ROOT/pty_harness.py" "$MSB_BIN" "$MSB_HOME" "$MSB_DYLD_DIR" \
  | tee "$QUAL_ROOT/evidence/pty-harness.txt"
grep -F 'pty_qualification_ok' "$QUAL_ROOT/evidence/pty-harness.txt"
record_pass pty_behavior 'interactive attach, resize, signals, reconnect, concurrency, and stop disconnect passed'
```

- [ ] **Verify explicit restart after the stop test**

```sh
msbq start ade-msb-0610-work
test "$(msbq exec --no-tty ade-msb-0610-work -- printf restarted)" = restarted
record_pass explicit_restart 'workbench remained stopped until explicit start and then accepted execution'
```

### Task 5: Qualify stopped-sandbox execution ownership

- [ ] **Observe and bound implicit stopped-sandbox behavior**

```sh
msbq stop ade-msb-0610-personal
msbq exec --no-tty ade-msb-0610-personal -- printf temporary-start \
  >"$QUAL_ROOT/evidence/stopped-exec.txt"
test "$(cat "$QUAL_ROOT/evidence/stopped-exec.txt")" = temporary-start
msbq status ade-msb-0610-personal >"$QUAL_ROOT/evidence/stopped-after-exec.txt"
grep -qi stopped "$QUAL_ROOT/evidence/stopped-after-exec.txt"
record_pass stopped_lifecycle_ownership 'native exec temporarily started a stopped fixture and returned it to stopped'
```

This observation does **not** authorize ADE to use implicit start. ADE must explicitly establish `Running` before attachment and must prevent a stop/attach race from restarting a stopped workbench.

### Task 6: Clean up and generate the validation result

- [ ] **Remove only qualification-owned sandboxes**

```sh
cleanup_sandboxes
test -z "$(msbq list | tail -n +2 | sed '/^[[:space:]]*$/d')"
record_pass cleanup 'both exact fixtures removed from isolated home'
test -x /opt/homebrew/bin/msb
```

- [ ] **Generate the validation document from the ledger**

Required keys:

```text
release_archive
native_feature_probe
fixture_image
sandbox_create
no_tty_exec
stream_and_timeout
isolation_and_persistence
root_replacement
pty_behavior
explicit_restart
stopped_lifecycle_ownership
cleanup
```

The generator must reject duplicate, missing, or non-pass rows. The validation document must include:

- exact release and fixture digests;
- host and guest architectures;
- the acceptance table;
- measured stop-to-client-exit time;
- stop/start root and project-store persistence;
- root replacement with project-store preservation;
- the observed implicit-start behavior and ADE's prohibition on relying on it;
- the Alpine-fixture, macOS-only, no-OCaml, and no-gatekeeper limitations;
- an explicit statement that standard SSH was not exercised or required.

Expected heading and status:

```markdown
# Microsandbox 0.6.10 Native Execution Qualification for ADE

**Status:** qualification passed
```

- [ ] **Verify document scope and clean the runtime root**

```sh
grep -F '**Status:** qualification passed' \
  docs/superpowers/specs/2026-08-18-microsandbox-0.6.10-native-execution-validation.md
! grep -E 'ProxyCommand|msb ssh serve|OpenSSH transport|SSH inactivity' \
  docs/superpowers/specs/2026-08-18-microsandbox-0.6.10-native-execution-validation.md
jj status
jj diff --git
cleanup_root
trap - EXIT INT TERM
```

## Verification checklist

- [ ] Official release checksum and version matched.
- [ ] Isolated home contained only the two fixed fixtures.
- [ ] Both fixtures used separate `/mnt` stores and deny-all networking.
- [ ] No SSH command, key, listener, config, or guest daemon was used.
- [ ] `--no-tty`, `--stream`, timeout, exit status, environment, and workdir behavior passed.
- [ ] PTY attachment, resize, signals, reconnect, concurrency, and stop disconnect passed.
- [ ] Host authority remained absent.
- [ ] Writable roots and separate project stores persisted across stop/start.
- [ ] Root replacement removed root state and preserved the project store.
- [ ] Stopped-sandbox implicit lifecycle behavior was recorded but not adopted by ADE.
- [ ] Exact cleanup passed.
- [ ] Generated status came only from the complete result ledger.

## Deferred ADE implementation

A later OCaml implementation plan must add:

- `RunningWorkbench` validation before native execution;
- physical instance and run-generation binding;
- the operation-start lease and losing-attach cancellation;
- lifecycle locks and structured adapter errors;
- the production Nix workstation image and project store;
- `ade list`, `ade start`, `ade exec`, `ade inspect`, `ade stop`, and `ade reimage`.
