# SmolVM workbenches

ADE runs coding agents inside named local SmolVM machines. Each workbench is a
durable boundary for one identity and data domain.

## Trust model

A workbench VM is one security principal. Agents, tools, containers and guest
processes inside one workbench are mutually trusted at VM level: any process may
read the workbench filesystem and use the capabilities that workbench has.

Use different workbenches when identities, data or authority must not mix.

Guest root is untrusted. The host, ADE, the SmolVM CLI and the hypervisor
are inside the trusted computing base.

## Declarations

Each workbench has one host-owned declaration in `~/.config/ade/workbenches/`;
this repository's `workbenches/` holds the examples:

| File | Network posture |
| --- | --- |
| `work.toml` | positive hostname allowlist |
| `personal.toml` | unrestricted (`public`) |
| `work-offline.toml` | sealed, no network, no credentials |
| `work-cloud.toml.example` | template for a cloud workflow |

The image digest is optional: the guest runs `pacman -Syu`, so pinning the base
image would not pin what the agents run. A digest, when written, is checked.

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
ade refresh NAME    # mint the next GitHub token into a running machine
ade provision NAME  # re-run the provision script on a stopped machine
ade rm NAME --yes   # delete the machine and ADE's state for it
```

Every command states an intended end state and is safe to repeat. Creating an
existing machine never recreates it.

Attach brings the machine up under the per-workbench lock and then releases it:
an interactive session must not block every other operation on the workbench.
Pull instead retains the lock across export, private host staging, verification
and import. Lock files live outside the deletable workbench state directory.

Creation manifests contain versioned, resolved inputs, not just declaration text.
Missing or unsupported records are unknown, not matching; `create` and `pull`
refuse to infer creation facts. Pull targets the recorded repositories. Runtime
states such as booting, stopping and failed are preserved and refused by lifecycle
transitions until the runtime reports a settled state.

## Credentials

Plaintext credentials are written only to guest tmpfs under
`/run/ade/secrets/generation-N`, with `current` swapped atomically after
validation.

ADE cannot prevent guest code from copying a credential into persistent state,
so the guest disk is always treated as potentially secret-bearing.

Tokens are minted at start, and `ade refresh` mints the next generation into
a running machine. Configuration is parsed and scoped before effects. The
response must provide complete repository identities, permissions and a
readable expiry before an installer can receive the token. If minting or
validation fails, an existing working generation stays active.

Boot failures trigger cleanup of the VM, dedicated agent and proxy. Cleanup
failures are reported alongside the original failure; agent records are
retained for retry when release fails.
