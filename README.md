# ADE

Run coding agents inside named local Linux workbench VMs.

Each workbench is a durable boundary for one identity and data domain — `work`,
`personal`, `offline`, `quarantine`. ADE is policy and transaction glue around a
pinned [SmolVM](https://github.com/smol-machines/smolvm) runtime, which stays
authoritative for machine existence and state.

## What is here

- `bin/`, `lib/` — the `ade` CLI, one small OCaml binary
- `workbenches/` — host-owned declarations, one per workbench
- `nix/` — the pinned runtime, guest agent rootfs and library set
- `images/nix-workstation/` — the workbench OCI image
- `smolfiles/` — the machine definition
- `scripts/install-smolvm.sh` — install the qualified runtime
- `scripts/build-workstation-image.sh` — build the image inside a workbench
- `docs/smolvm-workbenches.md` — operational guide

## Install

```sh
./scripts/install-smolvm.sh
```

Builds SmolVM 1.13.1 from the pinned source, verifies its version, digest and
macOS hypervisor entitlement, then installs it under
`~/.local/share/ade/runtime/`. It never touches Homebrew or the upstream SmolVM
directories.

`mkfs.ext4` must be on `PATH`; the runtime shells out to it to format machine
disks.

## Use

```sh
ade create work          # create from the declaration
ade start work           # ensure running
ade attach work          # start if needed, then attach
ade exec work -- CMD
ade status work
ade stop work
```

Maintenance:

```sh
ade backup work DEST
ade restore work ARCHIVE --replace-workspace
ade reimage work
ade pack work OUTPUT
ade destroy work --no-backup --confirm-destroy-workspace=work
ade credentials status work
```

Every command states an intended end state and is safe to repeat. Creating an
existing machine converges rather than recreating it, which would destroy the
workspace.

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

Mounts are applied when the machine is created. Adding one to an existing
workbench takes effect after it is recreated.

## Trust model

A workbench VM is one security principal. Agents, tools and containers inside
one workbench are mutually trusted at VM level: any process may read the
workbench filesystem and use the capabilities that workbench holds. Use
different workbenches when identities, data or authority must not mix.

Guest root is untrusted. The host, ADE, the pinned runtime and the hypervisor
are inside the trusted computing base.

Credentials are written only to guest tmpfs under `/run/ade/secrets`, and a
`Secret.t` can be neither printed nor written into a declaration. ADE cannot
stop guest code copying a credential into persistent state, so workspace
backups and machine packs are always treated as potentially secret-bearing.

## Testing

```sh
nix develop -c dune runtest                # unit and adapter suites
python3 -m unittest discover -s test -t .  # installer and runtime qualification
```

Property tests need a native arm64 opam switch; see `docs/hegel-testing.md`.

Runtime qualification needs an installed runtime and a **short** `HOME`: the
guest agent socket lives under it, and macOS caps `sun_path` at 104 bytes,
which a `$TMPDIR` path exceeds.

## Status

The command surface is complete. The runtime boots, runs containers, and
enforces network postures — a positive hostname allowlist is verified to block
hosts not on the list.

Parts of the design's qualification gate remain unverified: Docker and nested
containers, Herdr startup, interactive attachment, and backups above 4 GiB. The
libkrun/libkrunfw pair is consumed from upstream's release, pinned by hash but
without signature or provenance attestation, because the guest kernel needs a
compiler nixpkgs no longer carries. Both gaps are recorded in
`docs/superpowers/specs/2026-08-30-smolvm-qualification-evidence.md`.
