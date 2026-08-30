# SmolVM workbenches

ADE runs coding agents inside named local SmolVM machines. Each workbench is a
durable boundary for one identity and data domain.

## Trust model

A workbench VM is one security principal. Agents, tools, containers and guest
processes inside one workbench are mutually trusted at VM level: any process may
read the workbench filesystem and use the capabilities that workbench has.

Use different workbenches when identities, data or authority must not mix.

Guest root is untrusted. The host, ADE, the pinned SmolVM CLI and the hypervisor
are inside the trusted computing base.

## Declarations

Each workbench has one host-owned declaration in `workbenches/`:

| File | Network posture |
| --- | --- |
| `work.toml` | positive hostname allowlist |
| `personal.toml` | unrestricted (`public`) |
| `work-offline.toml` | sealed, no network, no credentials |
| `work-cloud.toml.example` | template for a cloud workflow |

The image must be pinned by digest. A moving tag is refused, because it would
silently change the trusted execution substrate between reimages.

`public` cannot exclude private ranges: SmolVM exposes no negative CIDR rules.
Sensitive workbenches use `sealed` or a positive allowlist.

Allowlisting a hostname is not operation-level authorization. It only permits
the workbench to reach that endpoint.

## Commands

```sh
ade create NAME     # create from the declaration; converges if it exists
ade start NAME      # ensure running
ade attach NAME     # start if needed, then attach
ade exec NAME -- CMD
ade stop NAME
ade restart NAME
ade status [NAME]
```

Every command states an intended end state and is safe to repeat. Creating an
existing machine never recreates it, because that would destroy the workspace.

Attach brings the machine up under the per-workbench lock and then releases it:
an interactive session must not block every other operation on the workbench.

## State

| State | Stop/start | Reimage | Destroy |
| --- | --- | --- | --- |
| `/workspace` | preserved | preserved | deleted |
| guest root, Docker, caches | preserved | wiped | deleted |
| `/run/ade/secrets` | reinjected | reinjected | deleted |

Reimage means a clean execution substrate plus the same, still untrusted,
workspace. It does not certify that hooks, build scripts or untracked
executables in the workspace are safe.

## Reimage safety

ADE never deletes the old machine until it holds a complete, validated workspace
export. The transaction journal is written before each destructive step, so an
interrupted reimage either resumes or reports that explicit recovery is
required; it never starts a half-constructed machine.

This protects against interrupted or unsafe archives. It cannot prove
completeness against a guest that was already compromised: such a guest already
controlled the source workspace.

## Credentials

Plaintext credentials are written only to guest tmpfs under
`/run/ade/secrets/generation-N`, with `current` swapped atomically after
validation.

ADE cannot prevent guest code from copying a credential into persistent state,
so workspace backups and full-machine packs are always treated as potentially
secret-bearing.

Rotation happens before expiry using a safety margin, because host and provider
clocks do not agree exactly. If minting or validation fails, the working
generation stays active and is not revoked.

## Runtime

The SmolVM CLI is pinned, built from source and installed under a managed
runtime root:

```sh
./scripts/install-smolvm.sh
```

ADE does not use the upstream release tarballs: they carry no signatures or
provenance attestations. The installer verifies the exact version, the binary
digest and the macOS hypervisor entitlement before installing, and never touches
Homebrew, the upstream SmolVM directories or Microsandbox.

## Testing

```sh
nix develop -c dune runtest                 # unit and adapter suites
python3 -m unittest discover -s test        # installer and CLI end-to-end
```

Property tests need a native arm64 opam switch; see `docs/hegel-testing.md`.
