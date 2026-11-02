# Repositories as bundles

Status: implemented in #17, 2026-11-01.

## Problem

A clone mount is one virtiofs device per repository. SmolVM 1.32.4 on x86_64
boots at most 8 mounts (9 fails with libkrun's "no more IRQs are available"),
and clone mounts also take the outbox, so a workbench holds at most 7
repositories. The `vibe` workbench needs 12.

A clone mount also shows the guest more than the repository's history: the
working tree, untracked files and anything else under that path, read-only.

## Decision

Repositories stop being mounts. The host hands each one to the guest as a git
bundle and gets the agents' work back as a bundle, as `ade pull` already does.
Every workbench gets two fixed mounts, whatever the number of repositories:

| guest path | host path                               | writer | contents                     |
|------------|-----------------------------------------|--------|------------------------------|
| `/inbox`   | `STATE/workbenches/NAME/inbox`, `:ro`   | host   | `REPO.bundle` per repository |
| `/outbox`  | `STATE/workbenches/NAME/outbox`         | guest  | `REPO.bundle` from `ade pull`|

The inbox is a separate read-only mount, not a subdirectory of the outbox, so
the host never writes into a directory the guest controls: a planted symlink
there would otherwise redirect a host write.

## Declaration

```toml
[[repo]]
host = "~/projects/vibe/kcal"

[[repo]]
host = "~/projects/vibe/ade"
```

- `host` is the only key. The repository's name is the last path component,
  held to the alphabet clone names use today, and must be unique.
- The host path passes the same policy as a mount (no home directory, no
  `~/.ssh`, `~/.password-store` and the rest, no ADE state), because handing
  its history to the guest is exposure even without a mount. It must contain
  `.git`, so a non-colocated jj repository is refused as today.
- `mode = "clone"` is no longer accepted. The error says that clone mounts
  became `[[repo]]` entries.
- Declarations may have at most 6 `[[mount]]` entries: 8, minus the inbox and
  outbox. The parser says so, rather than the VM failing to boot. The limit is
  `max_mounts` in `Declaration`, measured on 1.32.4/x86_64; macOS is
  unmeasured.

Repositories are not creation-time: the mounts that carry them are fixed, so
adding or removing a `[[repo]]` applies at the next start, like credentials,
and is not drift.

## Flow

At every Work start (`ade start`, and each command that ensures a running
workbench), after the machine boots and before credentials are installed:

1. **Host, per repository:** `git bundle create TMP HEAD --branches` with the
   same sanitized git environment `Pull` uses, written to a temporary file in
   the inbox and renamed to `REPO.bundle`. A fingerprint of
   `git show-ref --head` is kept beside it; when it matches, the bundle is
   reused, so an unchanged repository costs one `show-ref`.
2. **Guest, per repository:**
   - first time: `git clone /inbox/REPO.bundle /workspace/REPO`, then rename the
     remote to `host`;
   - after that: `git -C /workspace/REPO fetch --prune --no-tags
     /inbox/REPO.bundle '+refs/heads/*:refs/remotes/host/*'`, so `host/*`
     mirrors the host's branches.
   The agents' own branches and working tree are never touched; they rebase
   onto `host/*` when they want your new commits.
3. **Record:** the set that was synced, name to resolved host path, is written
   to `STATE/workbenches/NAME/repos`. `ade pull` reads that record, so it
   fetches only into repositories that were handed out, even if the
   declaration or a symlink has changed since.

`ade refresh` runs steps 1 to 3 on a running workbench as well, so new host
commits reach the agents without a restart.

In a colocated jj repository HEAD is `@-`, and bookmarks are branches. The
agents see what is committed and bookmarked, never the working-copy commit.

### Failures

- Bundling fails on the host (the path is gone, git fails): the start fails
  and rolls back like a failed credential install. It is the user's to fix.
- An empty repository (nothing for `HEAD` or `--branches`) is skipped with a
  warning.
- A fetch fails in the guest: a warning naming the repository, and the start
  goes on. That clone is the agents' own state, and failing the start would
  lock the user out of the workbench, since `exec` and `attach` start it too.

### Removed repositories

Dropping a `[[repo]]` stops syncing it and removes its bundle. The clone in
`/workspace` stays: it may hold agent work that was never pulled.

## Remote for pushing

Unchanged here: the clone's only remote is `host`, and agents add a GitHub
remote themselves, as in the smoke runs. Setting `origin` from the host
repository's remote (rewriting `git@github.com:` to HTTPS for the token) would
save that step, but it copies host configuration into the guest. It is a
separate change.

## Code

- `Declaration`: `[[repo]]` parsing, the `clone` mode removed, the mount limit,
  `/inbox` reserved, the `/src/NAME` default removed.
- `Host_mount`: the repository policy check (shared with mounts), and the inbox
  and outbox mounts on every workbench.
- `Repo_sync` (new): bundling with the fingerprint, the guest clone or fetch,
  and the `repos` record. Host git goes through `Process_runner`, guest
  commands through `Smolvm`, so it is tested with fakes.
- `Boot.start`: calls `Repo_sync` for Work starts. `Lifecycle.refresh` calls it
  too.
- `Pull`: reads the `repos` record instead of the manifest's clone mounts.
- `Creation_manifest`: version 2 without `clone`. A version 1 manifest is
  refused with "recreate it with ade rm and ade create"; pull and drift report
  that, and `rm` does not need the manifest.
- README: the clone section is rewritten for `[[repo]]`.

## Tests

- Declaration: `[[repo]]` parsing, duplicate names, the policy refusals, the
  `clone` error, the limit of 6 mounts.
- `Repo_sync` with a fake runner and a fake machine: the bundle argv, reuse when
  the fingerprint matches, clone on the first start and fetch after it, removal
  of a dropped repository's bundle, the warning on a guest failure and the
  error on a host failure. The bundles are real ones from a temporary git
  repository, so git's own behaviour is under test.
- Manifest v2: a Hegel round-trip of encode and decode, and v1 refused.
- Pull from the record, and refused without one.
- E2E harness: start then pull with two repositories through the fake runtime.
- Real run: `vibe` with all 12 repositories. A host commit reaches the guest on
  `ade refresh`, an agent commit comes back on `ade pull`, and the guest sees
  no host file outside the bundles.

## Not doing

- Incremental bundles (a basis of what the guest already has): the fingerprint
  check already makes an unchanged repository nearly free.
- Tags, notes and other refs: branches and HEAD are what the agents work from,
  and what pull brings back.
- A per-repository name override: there is no collision yet.
