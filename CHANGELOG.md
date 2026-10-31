# Changelog

## 2026-11-01

- **Repositories as bundles** (#17): `[[repo]] host = "..."` replaces clone
  mounts. Each Work start bundles the host's `HEAD` and branches into a
  read-only `/inbox`; the guest clones them into `/workspace/NAME` or fetches
  them into `host/*`, pruning deleted branches. `ade refresh` does the same on a
  running workbench, and `ade pull` reads the record of what was handed over.
  Every workbench has two fixed mounts, `/inbox` and `/outbox`, so a declaration
  may have at most 6 `[[mount]]` entries. Creation manifests are version 2; a
  machine made by an older ADE has to be recreated. Design:
  `design/repo-bundles.md`.
- **Attach opens Herdr from a login shell** (#18), so Herdr, its panes and
  Claude Code find `~/.local/bin` and the proxy settings.
- **Classifier confidence floor** (#19): an allow below 0.80, or without a
  confidence, is put to the user as ask.
- **Claude Code's non-essential traffic is off in provisioned guests** (#19):
  no telemetry, error reports or auto-updates.
- **`provision` takes a list of scripts** (#20), run in order in one
  maintenance boot, so a workbench can add its own setup after the shipped
  script.
- **Desktop notification when a host needs approval** (#14), the install docs
  for putting `ade` on `PATH` (#15), and a named error when a GitHub App key
  reference does not hold a PEM key (#16).
