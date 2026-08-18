# Microsandbox Validation for ADE

**Status:** macOS spike complete; Artix validation pending

**Microsandbox version:** 0.6.8

**Host:** Apple silicon macOS with Hypervisor.framework support

## Decision

Proceed with Microsandbox as ADE's initial microVM substrate.

The spike demonstrated the required isolation, networking, historical SSH/tmux access, persistent directory-backed workspaces, stopped-only workspace checkpointing, disposable root state, a Nix-built OCI workstation, guest package installation, and guest-local Docker. SSH was a spike mechanism; the approved V1 design now uses native `msb exec` terminal and command execution.

ADE must isolate Microsandbox behind an adapter because version 0.6.8 also showed lifecycle and storage quirks. Disk-backed named volumes and generic secret substitution are not accepted as production mechanisms.

## Acceptance results

| Requirement | Result | Evidence |
| --- | --- | --- |
| Apple silicon support | Pass | `msb doctor` passed; Linux 6.12.98/aarch64 guests booted |
| VM boundary | Pass | Host home, SSH credentials, SSH agent, AWS configuration, and Docker socket were absent |
| No-network mode | Pass | DNS and HTTPS requests failed under `--no-net` |
| Allowlisted HTTPS | Pass | Approved endpoint worked and an unapproved endpoint was blocked |
| Secret substitution | Partial | Real secret stayed out of the guest request but an echo endpoint returned it in the response |
| SSH command execution | Pass | `msb ssh` executed guest commands |
| Guest-local tmux | Pass | A detached tmux session remained available across SSH commands |
| Directory-backed workspace persistence | Pass | Data survived stop/start and attachment to a replacement VM |
| Disk-backed named volume reuse | Fail | Marker data disappeared during reuse and lifecycle behavior was inconsistent |
| Stopped workspace checkpoint | Pass | An APFS copy-on-write copy restored the earlier marker into a new volume |
| Disposable root state | Pass | Root marker disappeared after VM destruction and recreation |
| Nested Docker | Pass | Guest `dockerd` started and `docker run --rm hello-world` succeeded |
| Host Docker isolation | Pass | No host Docker socket was present in the Docker guest |
| Nix-built OCI image | Pass | Flake-built aarch64-linux archive imported and booted |
| Guest package installation | Pass | `nix shell nixpkgs#hello -c hello` printed `Hello, world!` |
| Guest toolchain | Pass | Git, Jujutsu, tmux, OCaml, opam, dune, Neovim, SSH, and Nix ran |
| Artix/KVM support | Pending | Must run the same acceptance suite on the Artix host |
| Representative Testcontainers project | Pending | Docker-in-Docker passed, but a real language binding remains to test |
| Pi installation | Pass | A later disposable guest installed Node 22.23.2 and Pi 0.84.2 without host Pi or Herdr state |
| Pi authentication | Pending | Must validate provider access through a gatekeeper without a guest API key |

## Nix-built workstation

The reproducible spike definition is in:

```text
spike/nix-workstation/flake.nix
spike/nix-workstation/flake.lock
```

The final local image, built before the ADE naming decision, was:

```text
gatekeep-nix-workstation:spike-v3
sha256:ea551ebb9355
```

The retained flake now emits `ade-nix-workstation.tar.gz` for future builds.

The compressed Docker archive was approximately 485 MiB. Microsandbox reported approximately 1.4 GiB after import.

Verified versions included:

```text
Nix    2.34.8
OCaml  5.4.1
opam   2.5.2
dune   3.23.1
jj     0.44.0
tmux   3.7b
Git    2.55.0
Neovim 0.12.4
```

The image contains `/workspace` as its default working directory and includes a minimal single-user Nix configuration. The package set is declarative, but the base-image contract remains replaceable.

## Workspace findings

### Directory-backed volumes

Directory-backed named volumes behaved correctly:

- persisted across stop and start;
- persisted after one VM was destroyed;
- attached successfully to a replacement VM;
- supported host-native stopped-only checkpoints;
- restored correctly into a fresh named volume.

ADE should use them for its first implementation.

### Disk-backed volumes

Disk-backed named volumes require explicit `kind=disk,size=...`. In version 0.6.8, reuse was unreliable: marker data disappeared and deletion/name reuse showed inconsistent behavior.

ADE must not use disk-backed named volumes until a focused regression test passes against a newer Microsandbox release.

### Root versus workspace state

The final recreation test wrote separate markers to the root disk and workspace. After destroying the VM and creating another from the same image and workspace:

```text
workspace_persisted_after_vm_recreation=true
root_state_discarded=true
```

This validates that Microsandbox can separate disposable root state from persistent workspace state.

The spike used disposable sessions. The current ADE design keeps the root across stop and start, then replaces it only during explicit reimage.

## Network and secret findings

No-network mode provided the expected baseline. Allowlisted HTTPS also blocked an unapproved destination.

Microsandbox secret substitution correctly replaced a guest placeholder only for an approved destination. However, an approved echo endpoint returned the real substituted secret in its response. Any arbitrary process in the guest could then read it.

Therefore:

- secret substitution is not itself a capability boundary;
- protected destinations require service-specific gatekeepers;
- gatekeepers must construct authenticated requests and control responses;
- protected capabilities cannot coexist with unrestricted public egress;
- credential-reflection tests belong in the permanent security suite.

## Container findings

The documented `docker:dind` image worked inside a microVM with a guest-local disk mounted at `/var/lib/docker`.

The first background script did not start because `msb create` did not execute the configured image entrypoint as expected. Starting `dockerd` explicitly with a detached guest command succeeded:

```text
guest_docker_ready=true
nested_container_ran=true
host_docker_socket_absent=true
```

ADE must own daemon startup rather than assume container entrypoint behavior during background creation.

## Image import finding

`msb load --input <gzip-archive>` returned success but did not add the image. Streaming the uncompressed Docker archive worked:

```sh
gzip -dc workstation.tar.gz | msb load --tag ade-workstation:local
```

ADE's Microsandbox adapter should use the verified stream form and then confirm the expected reference with `msb image list`. A zero exit status alone is insufficient evidence of import.

## Lifecycle findings

A failed create could leave a stopped sandbox record whose name blocked a later create. Some remove/name-reuse behavior was inconsistent during the disk-volume tests.

The adapter must:

1. inspect before create;
2. distinguish absent, stopped, running, and failed records;
3. verify state after every lifecycle command;
4. use replacement only when policy explicitly allows it;
5. normalize tombstone/name-collision failures into structured ADE errors.

## Remaining validation

Before declaring the substrate fully accepted:

1. Run the same suite on Artix Linux with KVM.
2. Run a representative OCaml or other real Testcontainers project.
3. Validate Pi provider access through the first gatekeeper rather than a guest API key.
4. Re-test disk-backed volumes on a future Microsandbox release before enabling them.
5. Measure cold image build, import, boot, and reimage times.

## Conclusion

Microsandbox is suitable for ADE if ADE treats it as a replaceable adapter and avoids the failed mechanisms. No requirement currently justifies writing custom VM infrastructure.
